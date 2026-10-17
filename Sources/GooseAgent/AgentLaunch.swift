import Foundation

enum AgentPreset: String, CaseIterable, Identifiable {
    case codex, claude, gemini, opencode, cursor, custom

    var id: String { rawValue }
    var name: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .gemini: return "Gemini CLI"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor Agent"
        case .custom: return String(localized: "Custom Agent")
        }
    }
    var executable: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        case .gemini: return "gemini"
        case .opencode: return "opencode"
        case .cursor: return "agent"
        case .custom: return ""
        }
    }
}

enum AgentLaunchTarget: Equatable {
    case local(directory: String)
    case remote(host: String, directory: String?)

    var directory: String {
        switch self {
        case .local(let directory): return directory
        case .remote(_, let directory): return directory ?? ""
        }
    }

    func replacingDirectory(_ directory: String) -> Self {
        switch self {
        case .local: return .local(directory: directory)
        case .remote(let host, _): return .remote(host: host, directory: directory.isEmpty ? nil : directory)
        }
    }

    func validated() throws -> Self {
        switch self {
        case .local(let directory):
            guard !directory.isEmpty, !AgentLaunchRequest.hasControlCharacters(directory) else {
                throw AgentLaunchError.invalidDirectory
            }
            let expanded = (directory as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw AgentLaunchError.invalidDirectory }
            let resolved = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw AgentLaunchError.invalidDirectory
            }
            return .local(directory: resolved)
        case .remote(let host, let directory):
            guard !host.isEmpty, !AgentLaunchRequest.hasControlCharacters(host) else {
                throw AgentLaunchError.invalidHost
            }
            if let directory, !directory.isEmpty {
                guard directory.hasPrefix("/"), !AgentLaunchRequest.hasControlCharacters(directory) else {
                    throw AgentLaunchError.invalidRemoteDirectory
                }
            }
            return .remote(host: host, directory: directory?.isEmpty == true ? nil : directory)
        }
    }
}

enum AgentLaunchError: LocalizedError {
    case invalidExecutable, invalidArguments, invalidDirectory, invalidRemoteDirectory, invalidHost

    var errorDescription: String? {
        switch self {
        case .invalidExecutable: return String(localized: "Enter an executable name or absolute path without control characters.")
        case .invalidArguments: return String(localized: "Agent arguments cannot contain control characters.")
        case .invalidDirectory: return String(localized: "Choose an existing local directory.")
        case .invalidRemoteDirectory: return String(localized: "Use an absolute remote directory, or leave it empty for home.")
        case .invalidHost: return String(localized: "The SSH host is invalid.")
        }
    }
}

/// A command is argv, never a shell expression. It is deliberately memory-only: session
/// restoration recreates the terminal, and never silently repeats an agent launch.
struct AgentLaunchRequest: Equatable {
    let executable: String
    let arguments: [String]

    init(executable: String, arguments: [String] = []) throws {
        guard !executable.isEmpty, !Self.hasControlCharacters(executable),
              !executable.hasPrefix("-"),
              (executable.hasPrefix("/") || !executable.contains("/")) else {
            throw AgentLaunchError.invalidExecutable
        }
        guard arguments.allSatisfy({ !Self.hasControlCharacters($0) }) else {
            throw AgentLaunchError.invalidArguments
        }
        self.executable = executable
        self.arguments = arguments
    }

    static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var command: String {
        "command " + ([executable] + arguments).map(Self.quote).joined(separator: " ")
    }

    /// Used only by a newly-created local login shell. Keeping the shell (no exec) means
    /// an absent executable and a completed agent both leave a usable terminal behind.
    var localInitialInput: String { command + "\r" }

    /// SSH sends this command after authentication. The user's interactive login shell
    /// establishes its exported PATH; a POSIX child handles argv and cwd consistently even
    /// if that login shell is fish. On completion a fresh interactive login shell remains.
    func remoteStartupCommand(directory: String?) throws -> String {
        _ = try AgentLaunchTarget.remote(host: "validation", directory: directory).validated()
        let notFound = String(localized: "Agent executable was not found") + ": " + executable
        let run = "if command -v \(Self.quote(executable)) >/dev/null 2>&1; then \(command); else printf '%s\\n' \(Self.quote(notFound)) >&2; fi"
        let startup: String
        if let directory, !directory.isEmpty {
            let failure = String(localized: "Agent was not started because the remote directory is unavailable") + ": " + directory
            startup = "if cd -- \(Self.quote(directory)); then \(run); else printf '%s\\n' \(Self.quote(failure)) >&2; fi"
        } else {
            startup = run
        }
        // A terminal Ctrl-C reaches the whole foreground process group. Keep the small
        // waiting wrapper alive so stopping an agent still returns to the login shell.
        // An executed child receives the default SIGINT behavior, not this shell trap.
        let body = "trap ':' INT; " + startup + "; exec \"${SHELL:-/bin/sh}\" -l"
        let loginCommand = "exec /bin/sh -c " + Self.quote(body)
        return "exec /bin/sh -c " + Self.quote("exec \"${SHELL:-/bin/sh}\" -l -i -c " + Self.quote(loginCommand))
    }
}
