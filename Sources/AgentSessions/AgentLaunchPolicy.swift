import Foundation

enum AgentLaunchPolicy {
    static func tracks(_ kind: AgentConversation.Kind, arguments: [String]) -> Bool {
        let excluded = ["--help", "-h", "--version", "-V", "--no-session", "--no-session-persistence", "--ephemeral", "--no-extensions", "--print", "--mode", "--remote"]
        guard !arguments.contains(where: excluded.contains) else { return false }
        if kind != .codex, arguments.contains("-p") { return false }
        if kind == .grok, arguments.contains(where: ["--single", "--prompt-file", "--prompt-json"].contains) { return false }
        if kind == .codex {
            let commands = ["exec", "e", "review", "login", "logout", "mcp", "plugin", "app-server", "remote-control", "app", "completion", "update", "doctor", "sandbox", "debug", "apply", "a", "queue", "archive", "delete", "unarchive", "migrate-rollouts", "cloud", "exec-server", "features", "help", "agents"]
            if let first = firstPositional(arguments), commands.contains(first) { return false }
        }
        if kind == .grok, let first = firstPositional(arguments),
           ["agent", "sessions", "export", "login", "logout", "update", "completion", "help", "mcp"].contains(first) { return false }
        return true
    }

    private static func firstPositional(_ args: [String]) -> String? {
        let values = ["-c", "--config", "-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval", "-C", "--cd", "--add-dir", "--enable", "--disable", "--local-provider", "--settings", "--image", "-i"]
        var index = 0
        while index < args.count {
            let value = args[index]
            if value == "--" { return nil }
            if values.contains(value) { index += 2; continue }
            if !value.hasPrefix("-") { return value }
            index += 1
        }
        return nil
    }

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func directory(arguments: [String], defaultDirectory: String) -> String {
        var value: String?
        for (index, word) in arguments.enumerated() {
            if (word == "-C" || word == "--cd"), index + 1 < arguments.count { value = arguments[index + 1] }
            if word.hasPrefix("--cd=") { value = String(word.dropFirst(5)) }
        }
        guard let value else { return defaultDirectory }
        return URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: defaultDirectory, isDirectory: true)).standardizedFileURL.path
    }
}
