import Darwin
import Foundation

struct ResolvedSSHConfiguration: Equatable, Sendable {
    let hostName: String
    let user: String
    let port: String

    static func parse(_ data: Data) throws -> Self {
        var fields: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count == 2, ["hostname", "user", "port"].contains(String(parts[0])) {
                fields[String(parts[0])] = String(parts[1])
            }
        }
        guard let host = fields["hostname"], !host.isEmpty, let user = fields["user"], !user.isEmpty,
              let port = fields["port"], let number = UInt16(port), number > 0 else { throw SSHConfigurationError.invalidOutput }
        return Self(hostName: host, user: user, port: port)
    }
}

enum SSHConfigurationError: Error { case invalidOutput, failed, timedOut, outputTooLarge }

/// 页面按需请求；同一环境与别名共享进程，最后一个订阅者离开时取消。
@MainActor
final class SSHConfigurationResolver {
    static let shared = SSHConfigurationResolver()
    private struct Key: Hashable { let alias: String; let environment: [String] }
    private struct Request {
        let id: UUID
        let task: Task<ResolvedSSHConfiguration, Error>
        var subscribers: Set<UUID>
    }
    private var requests: [Key: Request] = [:]
    private let configurationFile: URL?

    init(configurationFile: URL? = nil) { self.configurationFile = configurationFile }

    func resolve(alias: String, environment: [String]) async throws -> ResolvedSSHConfiguration {
        try Task.checkCancellation()
        let key = Key(alias: alias, environment: environment.sorted())
        let subscriber = UUID()
        if requests[key] == nil {
            let query = SSHConfigurationQuery(alias: alias, environment: environment, configurationFile: configurationFile)
            requests[key] = Request(id: UUID(), task: Task { try await query.run() }, subscribers: [])
        }
        requests[key]!.subscribers.insert(subscriber)
        let request = requests[key]!
        defer { release(key, request: request.id, subscriber: subscriber) }
        return try await withTaskCancellationHandler {
            let value = try await request.task.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            Task { @MainActor in self.release(key, request: request.id, subscriber: subscriber) }
        }
    }

    private func release(_ key: Key, request id: UUID, subscriber: UUID) {
        guard var request = requests[key], request.id == id else { return }
        request.subscribers.remove(subscriber)
        if request.subscribers.isEmpty {
            request.task.cancel()
            requests[key] = nil
        } else { requests[key] = request }
    }
}

/// 状态只在 queue 上访问；读取不阻塞，超时/取消会关闭管道并结束自有进程组。
final class SSHConfigurationQuery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.itjun.1agent.ssh-config", qos: .utility)
    private let process = Process()
    private let pipe = Pipe()
    private let timeout: TimeInterval
    private let outputLimit: Int
    private var continuation: CheckedContinuation<ResolvedSSHConfiguration, Error>?
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var data = Data()
    private var isCancelled = false

    init(alias: String, environment: [String], configurationFile: URL? = nil,
         timeout: TimeInterval = 5, outputLimit: Int = 1 << 20) {
        self.timeout = timeout
        self.outputLimit = outputLimit
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G"] + (configurationFile.map { ["-F", $0.path] } ?? []) + ["--", alias]
        var values: [String: String] = [:]
        for item in environment {
            guard let index = item.firstIndex(of: "=") else { continue }
            values[String(item[..<index])] = String(item[item.index(after: index)...])
        }
        process.environment = values
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
    }

    func run() async throws -> ResolvedSSHConfiguration {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    if self.isCancelled { self.finish(.failure(CancellationError())); return }
                    self.start()
                }
            }
        } onCancel: { self.queue.async { self.isCancelled = true; self.finish(.failure(CancellationError())) } }
    }

    private func start() {
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.queue.async {
                self.drain()
                guard self.continuation != nil else { return }
                if process.terminationStatus == 0 {
                    self.finish(Result { try ResolvedSSHConfiguration.parse(self.data) })
                } else { self.finish(.failure(SSHConfigurationError.failed)) }
            }
        }
        do { try process.run() }
        catch { finish(.failure(error)); return }
        try? pipe.fileHandleForWriting.close()
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.drain() }
        reader.setCancelHandler { [pipe] in try? pipe.fileHandleForReading.close() }
        self.reader = reader
        reader.resume()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.finish(.failure(SSHConfigurationError.timedOut)) }
        self.timer = timer
        timer.resume()
    }

    private func drain() {
        guard continuation != nil else { return }
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                guard data.count + count <= outputLimit else { finish(.failure(SSHConfigurationError.outputTooLarge)); return }
                data.append(contentsOf: bytes.prefix(count))
            } else if count < 0 && errno == EINTR { continue }
            else { return }
        }
    }

    private func finish(_ result: Result<ResolvedSSHConfiguration, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel(); timer = nil
        if let reader { reader.cancel(); self.reader = nil }
        else { try? pipe.fileHandleForReading.close() }
        try? pipe.fileHandleForWriting.close()
        if process.isRunning {
            let pid = process.processIdentifier
            // Foundation 通常为子进程创建新进程组；只结束确认为自有的组。
            if getpgid(pid) == pid { kill(-pid, SIGKILL) }
            else { kill(pid, SIGKILL) }
        }
        process.terminationHandler = nil
        continuation.resume(with: result)
    }
}
