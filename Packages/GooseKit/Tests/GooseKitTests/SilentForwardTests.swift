import XCTest
@testable import GooseKit

final class SilentForwardTests: XCTestCase {
    func testOnlyAnEmptyReplyReadsAsASilentForward() {
        XCTAssertTrue(GooseService.isSilentForward(.malformedResponse("empty reply")))
        // Everything below proves somebody replied (or the local socket itself failed);
        // replacing those errors with a forward diagnosis would hide the real failure.
        XCTAssertFalse(GooseService.isSilentForward(.malformedResponse("undecodable reply")))
        XCTAssertFalse(GooseService.isSilentForward(.connectionFailed("connect(): Connection refused")))
        XCTAssertFalse(GooseService.isSilentForward(.socketUnavailable("/tmp/gooseagent.sock")))
        XCTAssertFalse(GooseService.isSilentForward(.rpc(code: "unknown_method", message: "nope")))
        XCTAssertFalse(GooseService.isSilentForward(.tunnelFailed("ssh exited 255")))
        XCTAssertFalse(GooseService.isSilentForward(.incompatibleProtocol(3)))
    }

    func testMissingRemoteSocketMeansGooseAgentIsDownOverThere() throws {
        let error = try XCTUnwrap(SSHTunnel.silentForwardDiagnosis(
            probeOutput: "missing\n",
            target: "user@192.0.2.10",
            remoteSocketPath: "/home/vincent/.config/gooseagent/gooseagent.sock"
        ))
        guard case .remoteGooseAgentDown(let target, let socketPath) = error else {
            return XCTFail("expected remoteGooseAgentDown, got \(error)")
        }
        XCTAssertEqual(target, "user@192.0.2.10")
        XCTAssertEqual(socketPath, "/home/vincent/.config/gooseagent/gooseagent.sock")
    }

    func testExistingButMuteSocketBlamesTheForwardInstead() throws {
        let error = try XCTUnwrap(SSHTunnel.silentForwardDiagnosis(
            probeOutput: " exists\n",
            target: "user@192.0.2.10",
            remoteSocketPath: "/home/vincent/.config/gooseagent/gooseagent.sock"
        ))
        guard case .tunnelFailed(let reason) = error else {
            return XCTFail("expected tunnelFailed, got \(error)")
        }
        XCTAssertTrue(reason.contains("AllowStreamLocalForwarding"))
    }

    func testUnrecognizedProbeOutputStaysUndiagnosed() {
        // e.g. a login shell that chokes on the probe; the original error must surface.
        XCTAssertNil(SSHTunnel.silentForwardDiagnosis(
            probeOutput: "zsh: command not found: test",
            target: "user@192.0.2.10",
            remoteSocketPath: "/home/vincent/.config/gooseagent/gooseagent.sock"
        ))
    }
}
