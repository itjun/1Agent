import Foundation

/// `/usr/bin/ssh` for file work. The terminal's own ssh is the connection master (see
/// `SSHCommand`), so a host that asked for a password in the terminal needs none here.
enum RemoteShell {
    /// Unix sockets allow 104 bytes, and ssh adds a 17-character suffix while it creates one, so
    /// the 40-character `%C` hash needs a short folder: `~/.ssh`, not `~/Library/Caches/…`.
    static let controlDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")

    static func multiplexOptions() -> [String] {
        try? FileManager.default.createDirectory(
            atPath: controlDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlDirectory)/ghostty-%C",
            "-o", "ControlPersist=600",
        ]
    }

    /// `ControlPersist` would keep each shared connection alive after the app quits, so quitting ends them.
    static func closeSharedConnections() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: controlDirectory)) ?? []
        let processes = names.filter { $0.hasPrefix("ghostty-") }.compactMap { name -> Process? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            let socket = (controlDirectory as NSString).appendingPathComponent(name)
            process.arguments = ["-F", "/dev/null", "-S", socket, "-O", "exit", "ghostty"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return (try? process.run()) == nil ? nil : process
        }
        let deadline = Date().addingTimeInterval(1)
        for process in processes {
            while process.isRunning && Date() < deadline {
                usleep(20_000)
            }
        }
    }

    /// Never prompts: a host that needs a password fails at once with ssh's message.
    static func arguments(alias: String, command: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"] + multiplexOptions() + ["-T", "--", alias, command]
    }

    static func process(alias: String, command: String) async -> Process {
        let environment = await SSHLaunchEnvironment.shared.get()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments(alias: alias, command: command)
        process.environment = ProcessRunner.dictionary(environment)
        return process
    }

    /// Runs `command` on the host and returns its standard output; a failure carries ssh's or the
    /// command's last error line.
    static func run(alias: String, command: String, input: Data? = nil) async throws -> Data {
        let process = await process(alias: alias, command: command)
        let result = try await ProcessRunner.run(process, input: input)
        guard result.status == 0 else { throw ProcessRunner.failure(result) }
        return result.stdout
    }
}

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
}

enum ProcessRunner {
    static let chunkSize = 256 * 1024

    static func dictionary(_ environment: [String]) -> [String: String] {
        var values: [String: String] = [:]
        for entry in environment {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            values[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return values
    }

    static func failure(_ result: ProcessResult) -> FileError {
        let text = String(decoding: result.stderr, as: UTF8.self)
        let line = text.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let line { return .message(String(line).trimmingCharacters(in: .whitespaces)) }
        return .message(String(format: String(localized: "Command failed with exit code %d"), result.status))
    }

    /// Runs to the end on a background thread, reading both outputs at once so neither pipe fills.
    static func run(_ process: Process, input: Data? = nil) async throws -> ProcessResult {
        signal(SIGPIPE, SIG_IGN)
        let cancellation = FileOperationContext.cancellation
        try cancellation?.check()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let out = Pipe()
                let err = Pipe()
                let stdin = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = input == nil ? FileHandle.nullDevice : stdin
                do {
                    try cancellation?.register(process)
                    try process.run()
                    cancellation?.processStarted(process)
                } catch {
                    cancellation?.unregister(process)
                    continuation.resume(throwing: error)
                    return
                }
                defer { cancellation?.unregister(process) }
                let errors = Drain(err.fileHandleForReading)
                if let input {
                    try? stdin.fileHandleForWriting.write(contentsOf: input)
                    try? stdin.fileHandleForWriting.close()
                }
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let stderr = errors.wait()
                if cancellation?.shouldAbort == true {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(returning: ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr))
                }
            }
        }
    }

    /// Copies `reader` into `writer` until end of file, reporting each chunk's size.
    static func copy(_ reader: FileHandle, to writer: FileHandle, cancellation: FileOperationCancellation? = nil, progress: (Int) -> Void) throws {
        while true {
            try cancellation?.check()
            let chunk = try reader.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            try writer.write(contentsOf: chunk)
            progress(chunk.count)
        }
    }
}

/// Reads a pipe to the end on its own thread. Used for stderr, which is read only after the work.
final class Drain: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async {
            self.data = handle.readDataToEndOfFile()
            self.done.signal()
        }
    }

    func wait() -> Data {
        done.wait()
        return data
    }
}
