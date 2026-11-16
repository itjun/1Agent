import Foundation

/// SSH 转发后的远程 shell，单独处理网络等待和主机时钟偏差。
final class RemoteCommandBridge: TerminalCommandBridge, @unchecked Sendable {
    let channel: CommandBridgeSocket
    private let clockLock = NSLock()
    private var clockOffset: TimeInterval?

    init?(sessionID: String? = nil) {
        guard let channel = CommandBridgeSocket(sessionID: sessionID) else { return nil }
        self.channel = channel
    }

    func query() async -> Bool {
        let reply = await channel.exchange(action: "probe", id: UUID(), script: "", directory: "", lifetime: 7, timeout: 8.7)
        guard let reply, reply.count == 2, let serverTime = Double(reply[1]), serverTime.isFinite else { return false }
        // 使用收到响应的时间，让请求期限保守地扣除回程耗时。
        clockLock.withLock { clockOffset = serverTime - Date().timeIntervalSince1970 }
        return reply[0] == "ready"
    }

    func run(id: UUID, script: String, expectedDirectory: String) async throws -> Bool {
        guard let offset = clockLock.withLock({ clockOffset }) else { throw QuickCommandError.uncertain }
        let reply = await channel.exchange(action: "run", id: id, script: script, directory: expectedDirectory,
                                           clockOffset: offset, lifetime: 7, timeout: 8.7)
        return try RemoteCommandBridge.needsWakeup(reply)
    }
}
