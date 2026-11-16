import Darwin
import Foundation
import AppKit

/// 本地与远程分别实现就绪和执行规则，仅共用私有 socket 的收发与生命周期。
protocol TerminalCommandBridge: AnyObject, Sendable {
    var channel: CommandBridgeSocket { get }
    func query() async -> Bool
    func run(id: UUID, script: String, expectedDirectory: String) async throws -> Bool
}

extension TerminalCommandBridge {
    var socketPath: String { channel.socketPath }
    var token: String { channel.token }
    var isPreserved: Bool {
        get { channel.isPreserved }
        set { channel.isPreserved = newValue }
    }

    static func needsWakeup(_ reply: [String]?) throws -> Bool {
        if reply == ["accepted-wakeup"] { return true }
        if reply == ["accepted"] { return false }
        if reply == ["rejected"] { throw QuickCommandError.unavailable }
        throw QuickCommandError.uncertain
    }
}

/// A per-process, private Unix socket carries commands and readiness probes.
/// The adapter may request a NUL on the owned PTY to leave zsh's fd polling loop;
/// command text is never submitted through terminal input.
final class CommandBridgeSocket: @unchecked Sendable {
    let folder: String
    let socketPath: String
    let token: String
    var isPreserved = false
    private var terminationObserver: NSObjectProtocol?

    init?(sessionID: String? = nil) {
        if let sessionID, let sessionFolder = TerminalSessionConnection.prepareFolder(for: sessionID) {
            folder = sessionFolder + "/bridge"
        } else { folder = "/tmp/1a-qc-\(getuid())-\(UUID().uuidString)" }
        socketPath = folder + "/s"
        do { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { return nil }
        let tokenPath = folder + "/token"
        if let saved = try? String(contentsOfFile: tokenPath, encoding: .utf8), UUID(uuidString: saved) != nil {
            token = saved
        } else {
            token = UUID().uuidString
            do {
                try token.write(toFile: tokenPath, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenPath)
            } catch { return nil }
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.isPreserved else { return }
            try? FileManager.default.removeItem(atPath: self.folder)
        }
    }
    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        if !isPreserved { try? FileManager.default.removeItem(atPath: folder) }
    }
    func exchange(action: String, id: UUID, script: String, directory: String,
                  clockOffset: TimeInterval = 0, lifetime: TimeInterval, timeout: TimeInterval) async -> [String]? {
        let path = socketPath, token = token
        return await Task.detached(priority: .userInitiated) {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var noPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
            withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { return nil }
            let deadline = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Date().timeIntervalSince1970 + clockOffset + lifetime)
            let payload = [token, id.uuidString, action, deadline,
                           Data(directory.utf8).base64EncodedString(), Data(script.utf8).base64EncodedString()]
                .joined(separator: "|") + "\n"
            let sent = Data(payload.utf8).withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
            guard sent else { return nil }
            var response = Data(), buffer = [UInt8](repeating: 0, count: 256)
            while response.count < 512 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return nil }
                response.append(contentsOf: buffer.prefix(count))
                if response.contains(10) { break }
            }
            let fields = String(decoding: response, as: UTF8.self).trimmingCharacters(in: .newlines).split(separator: "|")
            guard fields.count >= 2, fields[0] == id.uuidString else { return nil }
            return fields.dropFirst().map(String.init)
        }.value
    }
}
