import AppKit
import Darwin
import Foundation

/// Simulate SSH transport delay and an independently configured remote clock.
@main enum RemoteCommandBridgeTests {
    static func main() async throws {
        for skew in [-3600.0, 3600.0] {
            let bridge = LocalCommandBridge(remote: true)!
            let listener = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(bridge.socketPath.utf8) + [0]) }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            precondition(bound == 0 && listen(listener, 4) == 0)
            let server = Task.detached {
                defer { close(listener) }
                for action in ["probe", "run"] {
                    let fd = accept(listener, nil, nil)
                    precondition(fd >= 0)
                    var data = Data(), byte: UInt8 = 0
                    while read(fd, &byte, 1) == 1 && byte != 10 { data.append(byte) }
                    let fields = String(decoding: data, as: UTF8.self).split(separator: "|", omittingEmptySubsequences: false)
                    precondition(fields.count == 6 && fields[0] == bridge.token && fields[2] == action)
                    // Longer than the old local-only response timeout.
                    try? await Task.sleep(for: .milliseconds(800))
                    let now = Date().timeIntervalSince1970 + skew
                    if action == "run" {
                        let remaining = Double(fields[3])! - now
                        precondition(remaining > 0 && remaining < 7, "Execution expiry must use the remote clock")
                        precondition(Data(base64Encoded: String(fields[4])) == Data("/root/目录".utf8))
                        precondition(Data(base64Encoded: String(fields[5])) == Data("printf fixture".utf8))
                    }
                    let reply = "\(fields[1])|" + (action == "probe" ? "ready|\(now)" : "accepted") + "\n"
                    _ = reply.withCString { write(fd, $0, strlen($0)) }
                    close(fd)
                }
            }
            let ready = await bridge.query()
            precondition(ready, "Remote delay must not become a false busy state")
            try await bridge.run(id: UUID(), script: "printf fixture", expectedDirectory: "/root/目录")
            await server.value
        }
        print("Remote command bridge passed: delayed replies, clock ahead/behind, expiry and payload preservation")
    }
}
