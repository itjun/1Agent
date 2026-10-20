import Darwin
import Foundation
import SQLite3

@main
enum AgentConversationTests {
    static func main() throws {
        let id = UUID().uuidString
        for kind in AgentConversation.Kind.allCases {
            let item = AgentConversation(kind: kind, sessionID: id, sessionFile: "/tmp/a '会话'.jsonl", directory: "/tmp", executable: "/tmp/agent")
            expect(item.isValid, "valid exact conversation")
            expect(try JSONDecoder().decode(AgentConversation.self, from: JSONEncoder().encode(item)) == item, "snapshot roundtrip")
            expect(!item.resumeArguments.contains("--last") && !item.resumeArguments.contains("--continue") && !item.resumeArguments.contains("--restore"), "resume must neither guess nor continue an interrupted turn")
            expect(item.resumeArguments.count == 2, "resume contains identity only, no old prompt")
            expect(!AgentLaunchPolicy.tracks(kind, arguments: ["--help"]), "help is never an active Agent")
        }
        expect(!AgentLaunchPolicy.tracks(.pi, arguments: ["--mode", "rpc"]), "RPC is not an interactive terminal")
        expect(!AgentLaunchPolicy.tracks(.pi, arguments: ["--no-session"]), "respect disabled persistence")
        expect(!AgentLaunchPolicy.tracks(.claude, arguments: ["--no-session-persistence"]), "respect Claude persistence")
        expect(!AgentLaunchPolicy.tracks(.codex, arguments: ["-m", "model", "exec", "old prompt"]), "headless after options")
        expect(AgentLaunchPolicy.tracks(.codex, arguments: ["-p", "profile", "resume", id]), "Codex profile is not print mode")
        expect(!AgentLaunchPolicy.tracks(.grok, arguments: ["--single", "prompt"]), "Grok single is headless")
        expect(AgentLaunchPolicy.directory(arguments: ["-C", "sibling"], defaultDirectory: "/tmp") == "/tmp/sibling", "Codex explicit working directory")
        expect(AgentProcessInspection.codexSessionIDs(paths: ["/tmp/thread-writer-locks/\(id).lock", "/unrelated/\(UUID()).lock"]) == [id], "kernel file identity is precise")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-header-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("session.jsonl")
        let header = ["type": "session", "id": id, "cwd": "/tmp"]
        var bytes = Data("{\"type\":\"title\",\"title\":\"OMP\"}\n".utf8)
        bytes.append(try JSONSerialization.data(withJSONObject: header)); bytes.append(10)
        try bytes.write(to: file)
        expect(AgentSessionFiles.sessionHeader(at: file.path)?.id == id, "OMP title slot before header")
        let databasePath = folder.appendingPathComponent("state_5.sqlite").path
        var database: OpaquePointer?
        expect(sqlite3_open(databasePath, &database) == SQLITE_OK, "isolated Codex metadata fixture")
        defer { sqlite3_close(database) }
        expect(sqlite3_exec(database, "CREATE TABLE threads(id TEXT,cwd TEXT,has_user_event INTEGER); INSERT INTO threads VALUES('\(id)','/tmp/project',0);", nil, nil, nil) == SQLITE_OK, "empty conversation fixture")
        expect(AgentProcessInspection.codexDirectory(id: id, paths: [databasePath]) == nil, "unused Codex TUI is not a saved conversation")
        sqlite3_exec(database, "UPDATE threads SET has_user_event = 1", nil, nil, nil)
        expect(AgentProcessInspection.codexDirectory(id: id, paths: [databasePath]) == "/tmp/project", "read exact persisted conversation cwd")
        expect(AgentProcessInspection.codexDirectory(id: UUID().uuidString, paths: [databasePath]) == nil, "never substitute another session")
        expect(AgentProcessInspection.descendants(of: getpid()).contains(getpid()), "process root ownership")
        print("AgentConversationTests passed: exact resume, legacy-safe metadata, persistence opt-outs, headless exclusion and session headers")
    }
    static func expect(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
}
