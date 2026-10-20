import Darwin
import Foundation

/// Private metadata transport for one terminal. Conversation contents stay in the Agent's store.
final class AgentSessionContext {
    let folder: String
    let statePath: String
    private let seed: AgentConversation?
    private let helper: String

    init?(conversation: AgentConversation?) {
        helper = (Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/oneagent-agent-session")).path
        guard FileManager.default.isExecutableFile(atPath: helper) else { return nil }
        folder = "/tmp/1a-agent-\(getuid())-\(UUID().uuidString)"
        statePath = folder + "/invocation.json"
        seed = conversation?.isValid == true ? conversation : nil
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            if let seed { try AgentSessionFiles.write(seed, at: folder + "/resume.json") }
        } catch { return nil }
    }

    var environment: [String] {
        ["ONEAGENT_AGENT_HELPER=\(helper)", "ONEAGENT_AGENT_STATE=\(statePath)",
         "ONEAGENT_AGENT_RESOURCES=\(Bundle.main.resourcePath ?? "")/agent-sessions",
         "ONEAGENT_AGENT_RESTORE_ERROR=\(String(localized: "Cannot restore the Agent conversation. Check the tool, session file and directory."))\n"]
    }

    var resumeCommand: String? {
        guard seed != nil else { return nil }
        return AgentLaunchPolicy.quote(helper) + " resume " + AgentLaunchPolicy.quote(folder + "/resume.json")
    }

    var conversation: AgentConversation? {
        guard let invocation = AgentSessionFiles.read(AgentInvocation.self, at: statePath) else { return seed }
        guard invocation.phase != .ended else { return nil }
        let event = folder + "/" + invocation.invocationID.uuidString + ".json"
        guard let result = AgentSessionFiles.read(AgentConversation.self, at: event) ?? invocation.conversation,
              result.isValid, result.kind == invocation.kind, result.executable == invocation.executable else { return nil }
        if result.kind == .pi || result.kind == .omp {
            guard let file = result.sessionFile, let header = AgentSessionFiles.sessionHeader(at: file),
                  header.id.caseInsensitiveCompare(result.sessionID) == .orderedSame else { return nil }
        }
        return result
    }

    /// Signal only the invocation actually owned by this terminal, never a saved/reused PID.
    func stop(ownedBy shellPID: pid_t) -> pid_t? {
        guard let invocation = AgentSessionFiles.read(AgentInvocation.self, at: statePath), invocation.phase == .active,
              invocation.ownerPID > 0, AgentProcessInspection.descendants(of: shellPID).contains(invocation.ownerPID) else { return nil }
        kill(invocation.ownerPID, SIGTERM)
        return invocation.ownerPID
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }
}
