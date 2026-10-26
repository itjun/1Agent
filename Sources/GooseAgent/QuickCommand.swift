import Foundation

enum QuickCommandScope: String, Codable, CaseIterable, Identifiable {
    case all, local, host, directory
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return String(localized: "All Hosts")
        case .local: return String(localized: "This Mac")
        case .host: return String(localized: "SSH Host")
        case .directory: return String(localized: "Specific Folder")
        }
    }
}

struct QuickCommandContext: Equatable, Sendable {
    var sessionID: String?
    var processID: UUID?
    var host: String?
    var directory: String?
    var isLive = false
}

struct QuickCommand: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var alias = ""
    var command = ""
    var group = ""
    var scope: QuickCommandScope = .directory
    var host: String?
    var directory: String?
    var includesSubdirectories = false
    var order = 0
    var updatedAt = Date()
    /// Imported host/path bindings remain visible in the library until explicitly repaired.
    var needsRepair = false

    func matches(_ context: QuickCommandContext) -> Bool {
        guard !needsRepair else { return false }
        switch scope {
        case .all: return true
        case .local: return context.host == nil
        case .host: return host != nil && host == context.host
        case .directory:
            guard host == context.host, let base = directory, let current = context.directory else { return false }
            return Self.contains(base: base, path: current, descendants: includesSubdirectories)
        }
    }

    var section: Int { scope == .directory ? 0 : scope == .all ? 2 : 1 }
    static func displayOrder(_ a: Self, _ b: Self) -> Bool {
        if a.section != b.section { return a.section < b.section }
        if a.order != b.order { return a.order < b.order }
        if a.alias != b.alias { return a.alias < b.alias }
        return a.id.uuidString < b.id.uuidString
    }
    func executionDirectory(in context: QuickCommandContext) -> String? {
        scope == .directory ? directory : context.directory
    }
    static func path(_ value: String) -> String {
        // Lexical normalization only. Remote paths must never be resolved on this Mac.
        (value as NSString).standardizingPath
    }
    static func contains(base: String, path: String, descendants: Bool) -> Bool {
        let base = Self.path(base), path = Self.path(path)
        return base == path || (descendants && path.hasPrefix(base == "/" ? "/" : base + "/"))
    }
    static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func validHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && !host.contains(where: { $0.isWhitespace || $0.isNewline })
            && !host.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    func validated() throws -> Self {
        var result = self
        result.alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        result.group = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.alias.isEmpty, result.alias.count <= 200,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.utf8.count <= 65_536,
              !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else {
            throw QuickCommandError.invalidCommand
        }
        if scope == .all || scope == .local { result.host = nil }
        if scope != .directory { result.directory = nil; result.includesSubdirectories = false }
        if let host = result.host, !Self.validHost(host) { throw QuickCommandError.invalidHost }
        if scope == .host, result.host == nil { throw QuickCommandError.invalidHost }
        if scope == .directory {
            guard let directory = result.directory, Self.validPath(directory) else { throw QuickCommandError.invalidDirectory }
            result.directory = Self.path(directory)
        }
        return result
    }
}

enum QuickCommandError: LocalizedError {
    case invalidCommand, invalidHost, invalidDirectory, invalidBackup, unsupportedVersion, changedTarget, unavailable, uncertain
    case directoryMismatch(current: String, required: String)
    var errorDescription: String? {
        switch self {
        case .directoryMismatch(let current, let required):
            return String(format: String(localized: "The terminal is in %1$@, but this command must run in %2$@. Execution is not allowed."), current, required)
        case .invalidCommand: return String(localized: "Enter an alias and a command up to 64 KiB. Terminal control characters are not allowed.")
        case .invalidHost: return String(localized: "Choose a valid SSH host.")
        case .invalidDirectory: return String(localized: "Choose an available absolute working directory.")
        case .invalidBackup: return String(localized: "The command library is invalid. Existing commands were not changed.")
        case .unsupportedVersion: return String(localized: "This command library version is not supported.")
        case .changedTarget: return String(localized: "The terminal or its directory changed. Close this dialog and confirm again.")
        case .unavailable: return String(localized: "The terminal cannot accept this command. Open the confirmation again to use a new terminal.")
        case .uncertain: return String(localized: "Execution was not acknowledged. Check the terminal before running again; this request will not be retried.")
        }
    }
}

struct QuickCommandLibrary: Codable, Equatable {
    var version = 1
    var commands: [QuickCommand] = []
    /// Display-only context for migration. Never trusted to automatically bind a host.
    var hostHints: [String: String] = [:]

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32 * 1024 * 1024 else { throw QuickCommandError.invalidBackup }
        let library = try JSONDecoder().decode(Self.self, from: data)
        guard library.version == 1 else { throw QuickCommandError.unsupportedVersion }
        guard library.commands.count <= 10_000, Set(library.commands.map(\.id)).count == library.commands.count else {
            throw QuickCommandError.invalidBackup
        }
        for command in library.commands { _ = try command.validated() }
        return library
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

enum QuickCommandConflict: String, CaseIterable, Identifiable {
    case keep, replace, copy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keep: return String(localized: "Keep Existing")
        case .replace: return String(localized: "Replace Existing")
        case .copy: return String(localized: "Import as Copy")
        }
    }
}

enum QuickCommandMerge {
    static func merge(existing: [QuickCommand], incoming: [QuickCommand], choices: [UUID: QuickCommandConflict]) -> [QuickCommand] {
        var result = existing
        for item in incoming {
            if let index = result.firstIndex(where: { $0.id == item.id }) {
                if result[index] == item { continue }
                switch choices[item.id] ?? .keep {
                case .keep: continue
                case .replace: result[index] = item
                case .copy:
                    var copy = item
                    copy.id = UUID()
                    copy.order = (result.map(\.order).max() ?? -1) + 1
                    result.append(copy)
                }
            } else { result.append(item) }
        }
        return result
    }
}

/// Captured at the click/drop, before a dialog can be mounted or selection changes.
struct QuickCommandConfirmationTarget: Identifiable {
    let id = UUID()
    let item: QuickCommand
    let context: QuickCommandContext
}

/// An immutable snapshot of the confirmation. Never serialized with restored terminals.
struct QuickCommandRunRequest: Identifiable, Equatable {
    let id: UUID
    let item: QuickCommand
    let context: QuickCommandContext
    let directory: String

    init(item: QuickCommand, context: QuickCommandContext, directory: String) throws {
        self.item = try item.validated()
        guard !item.needsRepair, QuickCommand.validPath(directory) else { throw QuickCommandError.invalidDirectory }
        guard item.matches(context) else { throw QuickCommandError.changedTarget }
        if let current = context.directory, QuickCommand.path(current) != QuickCommand.path(directory) {
            throw QuickCommandError.directoryMismatch(current: current, required: QuickCommand.path(directory))
        }
        id = UUID()
        self.context = context
        self.directory = QuickCommand.path(directory)
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// Submitted unchanged, as if typed. The adapter only accepts it while the shell is in `directory`.
    var currentShellCommand: String { item.command }

    /// Transport the saved text as data, then give it directly to the login shell's
    /// command argument. Do not escape it, prepend shell code or reinterpret it with eval.
    /// The supervisor only opens the folder and retains a shell after the command ends.
    func startupCommand(shell: String? = nil) -> String {
        let q = Self.quote
        let payload = Data(item.command.utf8).base64EncodedString()
        let shellValue = shell.map(q) ?? "\"${SHELL:-/bin/sh}\""
        // The sentinel preserves trailing newlines removed by command substitution.
        // Wait for the child to release its foreground process group after Ctrl-C.
        let body = "trap 'wait' INT; qc_shell=" + shellValue + "; qc_command=$(printf '%s' " + q(payload)
            + " | base64 -d; printf '.'); qc_command=${qc_command%.}; if cd -- " + q(directory) + "; then case \"${qc_shell##*/}\" in "
            + "zsh|bash|fish) \"$qc_shell\" -lic \"$qc_command\";; "
            + "*) printf '%s\\n' " + q(String(localized: "Quick commands require zsh, bash or fish.")) + "; (exit 126);; esac; else (exit 1); fi; "
            + "qc_status=$?; printf '\\n%s %s\\n' " + q(String(localized: "Exit code:")) + " \"$qc_status\"; exec \"$qc_shell\" -l"
        return "exec /bin/sh -c " + q(body)
    }
}

/// Requests live only in memory. Claim before any asynchronous work; an uncertain
/// acknowledgement must never lead to a second delivery of the same request.
@MainActor enum QuickCommandExecution {
    private static var consumed: Set<UUID> = []
    static func claim(_ id: UUID) throws {
        guard consumed.insert(id).inserted else { throw QuickCommandError.uncertain }
    }
}
