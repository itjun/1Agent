import Darwin
import Foundation
import AppKit

/// A per-process, private Unix socket. No PTY bytes are used to probe or submit commands.
/// Only the bundled zsh ZLE adapter accepts requests, inside its input-buffer guard.
final class LocalCommandBridge: @unchecked Sendable {
    let folder: String
    let socketPath: String
    let token = UUID().uuidString
    private var terminationObserver: NSObjectProtocol?

    private let remote: Bool
    private let clockLock = NSLock()
    private var remoteClockOffset: TimeInterval?

    init?(remote: Bool = false) {
        self.remote = remote
        folder = "/tmp/1a-qc-\(getuid())-\(UUID().uuidString)"
        socketPath = folder + "/s"
        do { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { return nil }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            try? FileManager.default.removeItem(atPath: self.folder)
        }
    }
    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        try? FileManager.default.removeItem(atPath: folder)
    }
    var environment: [String] { ["ONEAGENT_QC_SOCKET=\(socketPath)", "ONEAGENT_QC_TOKEN=\(token)"] }

    func query() async -> Bool { await exchange(action: remote ? "probe" : "query", id: UUID(), script: "", directory: "") == "ready" }

    func run(id: UUID, script: String, expectedDirectory: String) async throws {
        let reply = await exchange(action: "run", id: id, script: script, directory: expectedDirectory)
        if reply == "accepted" { return }
        if reply == "rejected" { throw QuickCommandError.unavailable }
        throw QuickCommandError.uncertain
    }

    private func exchange(action: String, id: UUID, script: String, directory: String) async -> String? {
        let path = socketPath, token = token, remote = remote
        let offset = clockLock.withLock { remoteClockOffset }
        // A remote run must follow a fresh readiness probe; host clocks need not agree.
        guard !remote || action != "run" || offset != nil else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var noPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: remote ? 8 : 0, tv_usec: 700_000)
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
            let deadline = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Date().timeIntervalSince1970 + (offset ?? 0) + (remote ? 7 : 0.6))
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
            if remote && action == "probe" {
                guard fields.count == 3, let serverTime = Double(fields[2]), serverTime.isFinite else { return nil }
                // Receiving time underestimates server time by the return trip, so expiry is conservative.
                self.clockLock.withLock { self.remoteClockOffset = serverTime - Date().timeIntervalSince1970 }
            } else if fields.count != 2 { return nil }
            return String(fields[1])
        }.value
    }
}
