import Darwin
import Foundation

/// 本机命令完全不依赖远端 probe、时钟握手或 SSH 转发。
@main enum LocalCommandBridgeTests {
    static func main() async throws {
        let bridge = LocalCommandBridge()!
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
            for action in ["run", "query", "query"] {
                let fd = accept(listener, nil, nil)
                precondition(fd >= 0)
                var data = Data(), byte: UInt8 = 0
                while read(fd, &byte, 1) == 1 && byte != 10 { data.append(byte) }
                let fields = String(decoding: data, as: UTF8.self).split(separator: "|", omittingEmptySubsequences: false)
                precondition(fields.count == 6 && fields[0] == bridge.token && fields[2] == action)
                let remaining = Double(fields[3])! - Date().timeIntervalSince1970
                precondition(remaining > 0 && remaining < 0.7, "本地请求只使用本机时钟和短期限")
                if action == "run" {
                    precondition(Data(base64Encoded: String(fields[4])) == Data("/tmp/本机".utf8))
                    precondition(Data(base64Encoded: String(fields[5])) == Data("printf local".utf8))
                }
                let reply = "\(fields[1])|" + (action == "run" ? "accepted-wakeup" : "ready") + "\n"
                _ = reply.withCString { write(fd, $0, strlen($0)) }
                close(fd)
            }
        }
        let wakeup = try await bridge.run(id: UUID(), script: "printf local", expectedDirectory: "/tmp/本机")
        precondition(wakeup, "本机发送不需要远端时钟握手")
        let ready = await bridge.query(), readyAgain = await bridge.query()
        precondition(ready && readyAgain, "重复本机查询只接受本机协议响应")
        await server.value
        print("Local command bridge passed: no remote probe, local clock, short deadline, repeated readiness and payload preservation")
    }
}
