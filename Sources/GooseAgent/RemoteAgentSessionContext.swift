import Darwin
import Foundation

/// Authenticated SSH stream-local forwarding, separate from keyboard input and the ZLE bridge.
@MainActor
final class RemoteAgentSessionContext {
    private(set) var conversation: AgentConversation?
    private let socketPath: String
    private let token: String
    private var polling: Task<Void, Never>?
    private var stopping = false
    private var invocationID: UUID?

    init(socketPath: String, token: String, conversation: AgentConversation?) {
        self.socketPath = socketPath
        self.token = token
        self.conversation = conversation?.isValid == true ? conversation : nil
    }

    func start() {
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let response = await self.exchange(action: "snapshot")
                guard !Task.isCancelled, !self.stopping else { return }
                if let response { self.accept(response) }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    func stop() async {
        stopping = true
        polling?.cancel()
        if let response = await exchange(action: "snapshot") { accept(response) }
        if let response = await exchange(action: "stop", invocationID: invocationID) { accept(response) }
    }

    func cancel() { polling?.cancel(); polling = nil }

    struct Response: Decodable {
        var id: UUID
        var invocationID: UUID?
        var phase: AgentInvocation.Phase
        var conversation: AgentConversation?
    }

    private func accept(_ response: Response) {
        invocationID = response.invocationID
        conversation = response.phase != .ended && response.conversation?.isValid == true ? response.conversation : nil
    }

    private func exchange(action: String, invocationID: UUID? = nil) async -> Response? {
        let path = socketPath, token = token, id = UUID()
        return await Task.detached(priority: .utility) {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var noPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: action == "stop" ? 5 : 1, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            var request = ["id": id.uuidString, "token": token, "action": action]
            if let invocationID { request["invocationID"] = invocationID.uuidString }
            guard connected == 0, var payload = try? JSONSerialization.data(withJSONObject: request) else { return nil }
            payload.append(10)
            let sent = payload.withUnsafeBytes { raw -> Bool in
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
            var response = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while response.count <= 65_536 {
                let count = Darwin.read(fd, &buffer, min(buffer.count, 65_537 - response.count))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return nil }
                response.append(contentsOf: buffer.prefix(count))
                if response.contains(10) { break }
            }
            guard response.count <= 65_536, let value = try? JSONDecoder().decode(Response.self, from: response), value.id == id else { return nil }
            return value
        }.value
    }

    deinit { polling?.cancel() }
}
