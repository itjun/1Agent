import Foundation

/// A precise conversation reference, never a saved prompt or a "latest session" selector.
struct AgentConversation: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case grok, pi, omp, codex, claude }
    var kind: Kind
    var sessionID: String
    var sessionFile: String?
    var directory: String
    var executable: String
    /// Only storage locations are retained; credentials and command-line prompts are excluded.
    var storageEnvironment: [String: String] = [:]

    var isValid: Bool {
        guard UUID(uuidString: sessionID) != nil, directory.hasPrefix("/"), executable.hasPrefix("/"),
              ![sessionID, directory, executable, sessionFile ?? ""].contains(where: { $0.contains("\0") }) else { return false }
        if kind == .pi || kind == .omp { return sessionFile?.hasPrefix("/") == true }
        return true
    }

    var resumeArguments: [String] {
        switch kind {
        case .pi: return ["--session", sessionFile ?? ""]
        case .omp: return ["--resume", sessionFile ?? ""]
        case .codex: return ["resume", sessionID]
        case .grok, .claude: return ["--resume", sessionID]
        }
    }

    static let storageKeys = ["CODEX_HOME", "GROK_HOME", "PI_CODING_AGENT_DIR", "PI_AGENT_DIR", "CLAUDE_CONFIG_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME"]
}

/// Written atomically by the invocation supervisor and by the tool's session event adapter.
struct AgentInvocation: Codable, Equatable {
    enum Phase: String, Codable { case active, suspended, ended }
    var invocationID: UUID
    var ownerPID: Int32
    var kind: AgentConversation.Kind
    var executable: String
    var phase: Phase
    var conversation: AgentConversation?
}

enum AgentSessionFiles {
    static func read<T: Decodable>(_ type: T.Type, at path: String) -> T? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_537), data.count <= 65_536 else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, at path: String) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// Read only the small header, never the conversation body. OMP can prepend a title record.
    static func sessionHeader(at path: String) -> (id: String, cwd: String)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32_768) else { return nil }
        for line in data.split(separator: 10).prefix(4) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let body = object["type"] as? String == "session_meta" ? object["payload"] as? [String: Any] : object
            guard object["type"] as? String == "session" || object["type"] as? String == "session_meta",
                  let body, let id = (body["id"] ?? body["session_id"]) as? String,
                  UUID(uuidString: id) != nil, let cwd = body["cwd"] as? String, cwd.hasPrefix("/") else { continue }
            return (id, cwd)
        }
        return nil
    }
}
