import XCTest
@testable import GooseKit

/// Integration tests against the real local gooseagent server.
/// Skipped when no local gooseagent socket exists.
final class LocalSocketTests: XCTestCase {
    private var socketPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/gooseagent/gooseagent.sock")
    }

    private func requireLocalGooseAgent() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: socketPath),
            "no local gooseagent server running"
        )
    }

    func testPingReportsCompatibleProtocol() async throws {
        try requireLocalGooseAgent()
        let rpc = SocketRPC(socketPath: socketPath)
        let pong = try await rpc.request(method: "ping", params: .object([:]), as: PingResult.self)
        XCTAssertGreaterThanOrEqual(pong.protocolVersion, GooseService.minimumProtocolVersion)
        XCTAssertFalse(pong.version.isEmpty)
    }

    func testServiceConnectSnapshotAndLists() async throws {
        try requireLocalGooseAgent()
        let service = GooseService(device: .local, autoStartLocalServer: false)
        _ = try await service.connect()

        let snapshot = try await service.snapshot()
        let agents = try await service.agents()
        let workspaces = try await service.workspaces()
        let manifests = try await service.agentManifests()

        // snapshot and dedicated list endpoints must agree
        XCTAssertEqual(Set(snapshot.agents.map(\.paneID)), Set(agents.map(\.paneID)))
        XCTAssertEqual(Set(snapshot.workspaces.map(\.workspaceID)), Set(workspaces.map(\.workspaceID)))
        for pane in snapshot.panes ?? [] {
            XCTAssertNotNil(pane.terminalID, "pane \(pane.paneID) has no attachable terminal id")
        }
        XCTAssertFalse(manifests.isEmpty, "server advertised no agent manifests")
        _ = AgentAttachmentCapabilityRegistry(manifests: manifests)
        // every agent belongs to a listed workspace
        let workspaceIDs = Set(workspaces.map(\.workspaceID))
        for agent in agents {
            XCTAssertTrue(workspaceIDs.contains(agent.workspaceID), "agent \(agent.paneID) has unknown workspace")
        }
    }

    func testUnknownMethodSurfacesRPCError() async throws {
        try requireLocalGooseAgent()
        let rpc = SocketRPC(socketPath: socketPath)
        do {
            _ = try await rpc.request(method: "definitely.not.a.method")
            XCTFail("expected an RPC error")
        } catch let GooseAgentError.rpc(code, _) {
            XCTAssertFalse(code.isEmpty)
        }
    }

    func testStatusSortBuckets() {
        XCTAssertLessThan(AgentStatus.blocked.sortBucket, AgentStatus.done.sortBucket)
        XCTAssertLessThan(AgentStatus.done.sortBucket, AgentStatus.working.sortBucket)
        XCTAssertLessThan(AgentStatus.working.sortBucket, AgentStatus.idle.sortBucket)
        XCTAssertEqual(AgentStatus(wire: "nonsense"), .unknown)
        XCTAssertEqual(AgentStatus(wire: nil), .unknown)
    }

    func testOnlyPaneBusyErrorsAreRetryable() {
        XCTAssertTrue(GooseService.isPaneBusy(.rpc(code: "agent_pane_busy", message: "busy")))
        XCTAssertFalse(GooseService.isPaneBusy(.rpc(code: "agent_name_taken", message: "taken")))
        XCTAssertFalse(GooseService.isPaneBusy(.rpc(code: "agent_pane_unavailable", message: "gone")))
        XCTAssertFalse(GooseService.isPaneBusy(.connectionFailed("dropped")))
    }

    func testEventStreamDeliversTabLifecycle() async throws {
        try requireLocalGooseAgent()
        let service = GooseService(device: .local, autoStartLocalServer: false)
        _ = try await service.connect()
        let stream = try await service.events()

        // Create and close a tab; expect at least one pane/tab event to arrive.
        let collector = Task { () -> [String] in
            var kinds: [String] = []
            for try await event in stream {
                if event.kind == GooseAgentEvent.subscriptionStartedKind { continue }
                kinds.append(event.kind)
                if kinds.count >= 2 { break }
            }
            return kinds
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let paneID = try await service.createTab(workspaceID: nil, cwd: nil, label: "gooseagent-test")
        try await Task.sleep(nanoseconds: 300_000_000)
        try await service.closePane(paneID: paneID)

        let result = try await withTimeout(seconds: 10) { try await collector.value }
        XCTAssertFalse(result.isEmpty, "no events received for tab lifecycle")
    }

    func testEventStreamFallsBackWhenAStatusPaneClosedBeforeSubscribe() async throws {
        try requireLocalGooseAgent()
        let service = GooseService(device: .local, autoStartLocalServer: false)
        _ = try await service.connect()
        let stream = try await service.events(statusPaneIDs: ["pane-that-does-not-exist"])

        let collector = Task { () -> [String] in
            var kinds: [String] = []
            for try await event in stream {
                kinds.append(event.kind)
                if event.kind == "pane.created" { break }
            }
            return kinds
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let paneID = try await service.createTab(
            workspaceID: nil,
            cwd: nil,
            label: "gooseagent-stale-subscription-test"
        )
        do {
            let result = try await withTimeout(seconds: 10) { try await collector.value }
            try await service.closePane(paneID: paneID)
            XCTAssertEqual(result.first, GooseAgentEvent.subscriptionStartedKind)
            XCTAssertTrue(result.contains("pane.created"))
        } catch {
            try? await service.closePane(paneID: paneID)
            throw error
        }
    }

    func testMoveWorkspaceBlockReordersTemporarySpaces() async throws {
        try requireLocalGooseAgent()
        let service = GooseService(device: .local, autoStartLocalServer: false)
        _ = try await service.connect()
        let cwd = NSTemporaryDirectory()
        let first = try await service.createWorkspace(label: "gooseagent-reorder-a", cwd: cwd)
        let second = try await service.createWorkspace(label: "gooseagent-reorder-b", cwd: cwd)
        do {
            try await service.moveWorkspaceBlock(
                workspaceIDs: [second.workspaceID],
                beforeWorkspaceID: first.workspaceID
            )
            let ids = try await service.workspaces().map(\.workspaceID)
            let a = try XCTUnwrap(ids.firstIndex(of: first.workspaceID))
            let b = try XCTUnwrap(ids.firstIndex(of: second.workspaceID))
            XCTAssertEqual(b + 1, a)
            try await service.closeWorkspace(workspaceID: first.workspaceID)
            try await service.closeWorkspace(workspaceID: second.workspaceID)
        } catch {
            try? await service.closeWorkspace(workspaceID: first.workspaceID)
            try? await service.closeWorkspace(workspaceID: second.workspaceID)
            throw error
        }
    }
}

func withTimeout<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw GooseAgentError.connectionFailed("timed out after \(seconds)s")
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}
