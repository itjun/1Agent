import XCTest
@testable import GooseKit

/// E2E tests against a real remote gooseagent over SSH.
/// Enabled by GOOSEAGENT_E2E_SSH_TARGET (e.g. "user@192.0.2.10"); skipped otherwise.
final class RemoteSSHTests: XCTestCase {
    private var target: String? {
        ProcessInfo.processInfo.environment["GOOSEAGENT_E2E_SSH_TARGET"]
    }

    func testProbeRemoteHome() async throws {
        guard let target else { throw XCTSkip("GOOSEAGENT_E2E_SSH_TARGET not set") }
        let tunnel = SSHTunnel(target: target)
        let home = try await tunnel.probeRemoteHome()
        XCTAssertTrue(home.hasPrefix("/"), "unexpected remote home: \(home)")
    }

    func testTunnelPingSnapshotAndAgents() async throws {
        guard let target else { throw XCTSkip("GOOSEAGENT_E2E_SSH_TARGET not set") }
        let device = Device(name: "e2e-remote", kind: .ssh(target: target))
        let service = GooseService(device: device)
        let pong = try await service.connect()
        XCTAssertGreaterThanOrEqual(pong.protocolVersion, GooseService.minimumProtocolVersion)

        let snapshot = try await service.snapshot()
        let agents = try await service.agents()
        XCTAssertEqual(Set(snapshot.agents.map(\.paneID)), Set(agents.map(\.paneID)))
        XCTAssertFalse(snapshot.workspaces.isEmpty, "remote session has no workspaces")

        // Round-trip a mutation: create a tab remotely, verify it in the snapshot, close it.
        let paneID = try await service.createTab(workspaceID: nil, cwd: nil, label: "gooseagent-e2e")
        let after = try await service.snapshot()
        XCTAssertNotEqual(snapshot.agents.count + snapshot.workspaces.count, 0)
        XCTAssertTrue(
            after.workspaces.count >= snapshot.workspaces.count,
            "workspace count went backwards after tab.create"
        )
        XCTAssertNotNil(
            after.panes?.first(where: { $0.paneID == paneID })?.terminalID,
            "created remote pane has no attachable terminal id"
        )
        try await service.closePane(paneID: paneID)
        await service.disconnect()
    }

    func testTunnelSurvivesRepeatedRequests() async throws {
        guard let target else { throw XCTSkip("GOOSEAGENT_E2E_SSH_TARGET not set") }
        let device = Device(name: "e2e-remote", kind: .ssh(target: target))
        let service = GooseService(device: device)
        _ = try await service.connect()
        for _ in 0..<10 {
            _ = try await service.workspaces()
        }
        await service.disconnect()
    }

    func testUploadFileRoundTrip() async throws {
        guard let target else { throw XCTSkip("GOOSEAGENT_E2E_SSH_TARGET not set") }
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gooseagent-e2e-\(UUID().uuidString).txt")
        let payload = "gooseagent remote upload \(UUID().uuidString)"
        try Data(payload.utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let tunnel = SSHTunnel(target: target)
        let remotePath = try await tunnel.uploadFile(from: localURL)
        XCTAssertTrue(remotePath.hasPrefix("/"))
        XCTAssertTrue(remotePath.hasSuffix(".txt"))

        let quotedPath = GooseService.shellQuoted(remotePath)
        let output = try await SSHTunnel.runSSH(
            target: target,
            command: "cat \(quotedPath); rm -f \(quotedPath)",
            timeout: 15
        )
        XCTAssertEqual(output, payload)
    }

    func testForwardedSocketStartsAgentInNewPane() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let socketPath = environment["GOOSEAGENT_E2E_SOCKET_PATH"] else {
            throw XCTSkip("GOOSEAGENT_E2E_SOCKET_PATH not set")
        }
        let kind = environment["GOOSEAGENT_E2E_AGENT_KIND"] ?? "claude"
        let device = Device(
            name: "e2e-forwarded",
            kind: .local,
            socketPath: socketPath
        )
        let service = GooseService(device: device)
        _ = try await service.connect()

        var paneID: String?
        do {
            let pane = try await service.createTab(workspaceID: nil, cwd: nil, label: "gooseagent-e2e")
            paneID = pane
            let name = "gooseagent-e2e-\(UUID().uuidString.prefix(6).lowercased())"
            try await service.startAgent(
                name: name,
                kind: kind,
                paneID: pane,
                waitForShell: true
            )
            let agents = try await service.agents()
            XCTAssertTrue(
                agents.contains { $0.paneID == pane },
                "started agent did not appear in agent.list"
            )
            try await service.closePane(paneID: pane)
            paneID = nil
        } catch {
            if let paneID { try? await service.closePane(paneID: paneID) }
            throw error
        }
        await service.disconnect()
    }

}
