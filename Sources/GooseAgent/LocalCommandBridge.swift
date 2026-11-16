import Foundation

/// 本机 shell 直接响应本机 socket，不使用 SSH、远端时钟或网络超时。
final class LocalCommandBridge: TerminalCommandBridge {
    let channel: CommandBridgeSocket

    init?(sessionID: String? = nil) {
        guard let channel = CommandBridgeSocket(sessionID: sessionID) else { return nil }
        self.channel = channel
    }

    var environment: [String] { ["ONEAGENT_QC_SOCKET=\(socketPath)", "ONEAGENT_QC_TOKEN=\(token)"] }

    func query() async -> Bool {
        await channel.exchange(action: "query", id: UUID(), script: "", directory: "", lifetime: 0.6, timeout: 0.7) == ["ready"]
    }

    func run(id: UUID, script: String, expectedDirectory: String) async throws -> Bool {
        let reply = await channel.exchange(action: "run", id: id, script: script, directory: expectedDirectory,
                                           lifetime: 0.6, timeout: 0.7)
        return try LocalCommandBridge.needsWakeup(reply)
    }
}
