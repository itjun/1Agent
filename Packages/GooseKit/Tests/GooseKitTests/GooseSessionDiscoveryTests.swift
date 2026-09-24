#if os(macOS)
import XCTest

@testable import GooseKit

final class GooseSessionDiscoveryTests: XCTestCase {
    private func makeConfigDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gooseagent-disco-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSession(_ config: URL, _ name: String, socket: Bool) throws {
        let dir = config.appendingPathComponent("sessions/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if socket {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("gooseagent.sock").path, contents: nil)
        }
    }

    func testFindsNamedSessionsWithLiveSockets() throws {
        let config = try makeConfigDir()
        defer { try? FileManager.default.removeItem(at: config) }
        try makeSession(config, "work", socket: true)
        try makeSession(config, "review", socket: true)
        try makeSession(config, "stale", socket: false)   // no socket → skipped
        try makeSession(config, "default", socket: true)   // reserved → skipped

        let sessions = GooseSessionDiscovery.namedSessions(configDirectory: config)
        XCTAssertEqual(sessions.map(\.name), ["review", "work"])   // sorted, no stale/default
        XCTAssertTrue(sessions.contains { $0.socketPath.hasSuffix("sessions/work/gooseagent.sock") })
    }

    func testNoSessionsDirectoryReturnsEmpty() throws {
        let config = try makeConfigDir()
        defer { try? FileManager.default.removeItem(at: config) }
        XCTAssertEqual(GooseSessionDiscovery.namedSessions(configDirectory: config), [])
    }

    func testNamedSessionDeviceIsStableLocalWithSocketOverride() {
        let session = GooseSessionDiscovery.NamedSession(name: "work", socketPath: "/tmp/x/gooseagent.sock")
        let device = GooseSessionDiscovery.device(for: session)
        XCTAssertTrue(device.isLocal)
        XCTAssertTrue(device.isNamedSession)
        XCTAssertEqual(device.socketPath, "/tmp/x/gooseagent.sock")
        XCTAssertEqual(device.name, "work")
        // Deterministic id: same name → same id, different names → different ids.
        XCTAssertEqual(device.id, GooseSessionDiscovery.device(for: session).id)
        XCTAssertNotEqual(
            device.id,
            GooseSessionDiscovery.device(for: .init(name: "review", socketPath: "/tmp/y/gooseagent.sock")).id
        )
        XCTAssertNotEqual(device.id, Device.local.id)
    }
}
#endif
