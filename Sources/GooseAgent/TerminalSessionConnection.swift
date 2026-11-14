import Darwin
import Foundation

/// 一个串行队列管理 socket、握手、收发和关闭，避免启动与快速关闭交错后留下后台进程。
final class TerminalSessionConnection: @unchecked Sendable {
    static let frameLimit = 32 * 1024 * 1024
    private let queue = DispatchQueue(label: "com.itjun.1agent.session")
    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var buffer = Data()
    private var output = Data()
    private var isClosed = false
    private var isReady = false
    private var isTerminating = false
    private var pendingExitCode: Int32?
    private var sessionFolder: String?
    private var helperIdentity: HelperIdentity?
    private var isForcedTermination = false
    private var ready: ((Bool) -> Void)?
    private var terminated: (() -> Void)?
    var onOutput: ((Data) -> Void)?
    var onSnapshot: ((Data) -> Void)?
    var onStatus: ((pid_t, pid_t, Bool) -> Void)?
    var onCommand: ((Bool, String?) -> Void)?
    var onExit: ((Int32?) -> Void)?

    /// 只向已认证 socket 对端的原进程发信号，避免超时后 PID 被其他进程复用。
    private struct HelperIdentity {
        let pid: pid_t
        let seconds: UInt64
        let microseconds: UInt64

        init?(socketFD: Int32) {
            var pid: pid_t = 0
            var size = socklen_t(MemoryLayout<pid_t>.size)
            guard getsockopt(socketFD, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 1 else { return nil }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  String(cString: path).hasSuffix("/Contents/Helpers/1AgentSessionHost") else { return nil }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
                  info.pbi_uid == getuid() else { return nil }
            self.pid = pid; seconds = info.pbi_start_tvsec; microseconds = info.pbi_start_tvusec
        }

        func signal(_ value: Int32) {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
                  info.pbi_uid == getuid(), info.pbi_start_tvsec == seconds, info.pbi_start_tvusec == microseconds else { return }
            kill(pid, value)
        }
    }

    static func folder(for sessionID: String) -> String? {
        let parts = sessionID.split(separator: "#")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
              let generation = UInt32(parts[1]) else { return nil }
        return "/tmp/1a-term-v1-\(getuid())/\(id.uuidString)-\(generation)"
    }

    static func prepareFolder(for sessionID: String) -> String? {
        guard let folder = TerminalSessionConnection.folder(for: sessionID) else { return nil }
        let root = (folder as NSString).deletingLastPathComponent
        for path in [root, folder] {
            if mkdir(path, 0o700) != 0 && errno != EEXIST { return nil }
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return nil }
        }
        return folder
    }

    /// socket 之外检查持有锁的后台进程，避免崩溃留下的文件被误认为活会话。
    static func hasSession(_ sessionID: String) -> Bool {
        guard let folder = TerminalSessionConnection.folder(for: sessionID) else { return false }
        var info = stat()
        guard lstat(folder + "/s", &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { return false }
        let lock = open(folder + "/lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard lock >= 0 else { return false }
        defer { close(lock) }
        if flock(lock, LOCK_EX | LOCK_NB) == 0 { flock(lock, LOCK_UN); return false }
        return errno == EWOULDBLOCK
    }

    private static func connectSocket(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        var uid: uid_t = 0, gid: gid_t = 0
        guard result == 0, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); return nil }
        var noPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { close(fd); return nil }
        return fd
    }

    func start(sessionID: String, executable: String, args: [String], environment: [String],
               directory: String?, columns: UInt16, rows: UInt16, initialOutput: Data = Data(),
               scrollbackBytes: Int = 128_000_000, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard !isClosed, let folder = TerminalSessionConnection.prepareFolder(for: sessionID) else { completion(false); return }
            sessionFolder = folder
            ready = completion
            var socketFD = TerminalSessionConnection.connectSocket(folder + "/s")
            if socketFD == nil {
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/1AgentSessionHost")
                guard FileManager.default.isExecutableFile(atPath: helper.path) else { fail(); return }
                let historyPath = folder + "/initial-output"
                guard FileManager.default.createFile(atPath: historyPath, contents: initialOutput,
                    attributes: [.posixPermissions: 0o600]) else { fail(); return }
                let launcher = Process()
                launcher.executableURL = helper
                launcher.arguments = [folder, String(columns), String(rows), String(scrollbackBytes), executable] + args
                launcher.environment = Dictionary(environment.compactMap { entry -> (String, String)? in
                    guard let index = entry.firstIndex(of: "=") else { return nil }
                    return (String(entry[..<index]), String(entry[entry.index(after: index)...]))
                }, uniquingKeysWith: { _, last in last })
                launcher.currentDirectoryURL = directory.map { URL(fileURLWithPath: $0) }
                launcher.standardInput = FileHandle.nullDevice
                launcher.standardOutput = FileHandle.nullDevice
                launcher.standardError = FileHandle.nullDevice
                do { try launcher.run() } catch { fail(); return }
                for _ in 0..<100 {
                    socketFD = TerminalSessionConnection.connectSocket(folder + "/s")
                    if socketFD != nil { break }
                    usleep(20_000)
                }
            }
            guard let socketFD else { fail(); return }
            observe(socketFD)
            enqueue(65, payload: TerminalSessionConnection.size(columns: columns, rows: rows, width: 0, height: 0))
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, !self.isReady, !self.isClosed else { return }
                self.fail()
            }
        }
    }

    private func observe(_ socketFD: Int32) {
        fd = socketFD
        helperIdentity = HelperIdentity(socketFD: socketFD)
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        // 连接在 detach/退出握手前自行保活，不依赖视图的存活时间。
        source.setEventHandler { [self] in readAvailable() }
        source.setCancelHandler { close(socketFD) }
        reader = source
        source.activate()
    }

    /// 未挂载的侧栏行只读取程序状态，不改变 PTY 大小或抢占界面连接。
    func inspect(sessionID: String, completion: @escaping (pid_t, String?) -> Void) {
        queue.async { [self] in
            guard let folder = TerminalSessionConnection.folder(for: sessionID),
                  let socketFD = TerminalSessionConnection.connectSocket(folder + "/p") else { completion(0, nil); return }
            fd = socketFD
            var foreground: pid_t = 0
            var command: String?
            onStatus = { _, group, _ in foreground = group }
            onCommand = { isRunning, value in command = isRunning ? value : nil }
            ready = { [weak self] isReady in
                completion(isReady ? foreground : 0, isReady ? command : nil)
                self?.disconnect()
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
            source.setEventHandler { [self] in readAvailable() }
            source.setCancelHandler { close(socketFD) }
            reader = source; source.activate()
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.isReady, !self.isClosed else { return }
                self.fail()
            }
        }
    }

    static func size(columns: UInt16, rows: UInt16, width: UInt32, height: UInt32) -> Data {
        let values: [UInt16] = [rows, columns, UInt16(clamping: width), UInt16(clamping: height)].map(\.bigEndian)
        return values.withUnsafeBytes { Data($0) }
    }

    func send(_ type: Character, payload: Data = Data()) {
        queue.async { [self] in
            guard !isClosed, !isTerminating else { return }
            // 大段粘贴拆帧，保持字节和顺序，不静默丢弃超过 1 MiB 的输入。
            if type == "I" {
                for offset in stride(from: 0, to: payload.count, by: 65_536) {
                    enqueue(73, payload: payload.subdata(in: offset..<min(offset + 65_536, payload.count)))
                }
            } else { enqueue(type.asciiValue!, payload: payload) }
        }
    }

    private func enqueue(_ type: UInt8, payload: Data = Data()) {
        guard !isClosed, fd >= 0 else { return }
        guard output.count + payload.count + 5 <= TerminalSessionConnection.frameLimit else { fail(); return }
        var size = UInt32(payload.count).bigEndian
        output.append(type)
        withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
        output.append(payload)
        flush()
    }

    private func flush() {
        while !output.isEmpty, !isClosed {
            let count = output.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno == EAGAIN {
                if writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    source.setEventHandler { [weak self] in self?.flush() }
                    writer = source; source.activate()
                }
                return
            }
            guard count > 0 else { fail(); return }
            output.removeFirst(count)
        }
        writer?.cancel(); writer = nil
    }

    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0 else {
            if count == 0 || (errno != EINTR && errno != EAGAIN) { fail() }
            return
        }
        buffer.append(contentsOf: bytes.prefix(count))
        while buffer.count >= 5, !isClosed {
            let length = buffer[buffer.startIndex + 1..<buffer.startIndex + 5].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= TerminalSessionConnection.frameLimit else { fail(); return }
            guard buffer.count >= length + 5 else { return }
            let type = buffer.first!, value = Data(buffer.dropFirst(5).prefix(length))
            buffer.removeFirst(length + 5)
            if isTerminating { continue }
            switch type {
            case 79: onOutput?(value)
            // 旧 helper 的 VT 导出在 OSC 7 尾部包含 C 字符串 NUL；它不是目录的一部分。
            case 82: onSnapshot?(value.filter { $0 != 0 }) // 画面恢复不重放命令通知。
            case 83:
                guard value.count == 12 else { fail(); return }
                let fields = stride(from: 0, to: 12, by: 4).map { offset in
                    value[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                }
                onStatus?(pid_t(bitPattern: fields[0]), pid_t(bitPattern: fields[1]), fields[2] != 0)
            case 77:
                guard let first = value.first else { fail(); return }
                let command = String(decoding: value.dropFirst(), as: UTF8.self)
                onCommand?(first != 0, command.isEmpty ? nil : command)
            case 72:
                isReady = true
                let callback = ready; ready = nil
                callback?(true)
            case 88:
                guard value.count == 4 else { fail(); return }
                // 等后台清理完目录再通知退出，避免立即重连接到正在退出的 helper。
                pendingExitCode = Int32(bitPattern: value.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            default: fail(); return
            }
        }
    }

    private func fail() {
        guard !isClosed else { return }
        let callback = ready; ready = nil
        let isClosing = isTerminating
        closeConnection()
        if isClosing { return }
        if let code = pendingExitCode { onExit?(code < 0 ? nil : code) }
        else if let callback { callback(false) } else { onExit?(nil) }
    }

    private func closeConnection() {
        isClosed = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR); fd = -1 }
        writer?.cancel(); writer = nil
        reader?.cancel(); reader = nil
        output.removeAll(); buffer.removeAll(); ready = nil
        if isForcedTermination { cleanupTerminatedFolder() }
        let callback = terminated; terminated = nil
        callback?()
    }

    func disconnect() { queue.async { [self] in closeConnection() } }

    func terminate(completion: @escaping () -> Void = {}) {
        queue.async { [self] in
            guard !isClosed, fd >= 0 else { completion(); return }
            isTerminating = true; terminated = completion
            enqueue(75)
            // 正常路径等待 helper 清理完 socket 后的 EOF，重启才能复用会话目录。
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, !self.isClosed else { return }
                // 兼容升级前的 helper：旧进程可能卡在 waitpid，结束对端会释放 PTY。
                self.isForcedTermination = true
                self.helperIdentity?.signal(SIGTERM)
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, !self.isClosed else { return }
                    self.helperIdentity?.signal(SIGKILL)
                    self.queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.closeConnection() }
                }
            }
        }
    }

    static func terminateDetached(_ sessionID: String) {
        guard let folder = TerminalSessionConnection.folder(for: sessionID) else { return }
        let connection = TerminalSessionConnection()
        connection.queue.async {
            guard let fd = TerminalSessionConnection.connectSocket(folder + "/s") else { return }
            connection.sessionFolder = folder
            connection.observe(fd)
            connection.terminate()
        }
    }

    private func cleanupTerminatedFolder() {
        guard let folder = sessionFolder else { return }
        let lock = open(folder + "/lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard lock >= 0 else { return }
        defer { close(lock) }
        // 后台进程确实退出并释放锁之后才清理；不递归删除任何未知文件。
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
        for name in ["s", "p", "bridge/s", "bridge/token", "initial-output", "lock"] { unlink(folder + "/" + name) }
        rmdir(folder + "/bridge")
        rmdir(folder)
    }
}
