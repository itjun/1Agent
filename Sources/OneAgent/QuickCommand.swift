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

/// 管理页按执行主机归类，不从命令正文推断发布目标。
enum QuickCommandCollection: Hashable, Identifiable {
    case common, local, host(String)

    var id: String {
        switch self {
        case .common: "common"
        case .local: "local"
        case .host(let host): "host:" + host
        }
    }
    var title: String {
        switch self {
        case .common: String(localized: "Command Library")
        case .local: String(localized: "This Mac")
        case .host(let host): host
        }
    }
    var host: String? {
        if case .host(let host) = self { return host }
        return nil
    }
    static func owner(of item: QuickCommand) -> Self {
        if item.scope == .all { return .common }
        return item.host.map(Self.host) ?? .local
    }
    func contains(_ item: QuickCommand) -> Bool { self == Self.owner(of: item) }

    func orderedCommands(in commands: [QuickCommand], sidebarContext: QuickCommandContext?) -> [QuickCommand] {
        let ordered = commands.filter(contains).sorted(by: QuickCommand.displayOrder)
        guard self != .common, let context = sidebarContext, context.host == host else { return ordered }
        // 当前目录可见的命令使用终端侧栏原号；其余目录和待修复的命令接在后面。
        return ordered.filter { $0.appearsInSidebar(for: context) } + ordered.filter { !$0.appearsInSidebar(for: context) }
    }

    static func available(in commands: [QuickCommand]) -> [Self] {
        let owners = Set(commands.map(Self.owner))
        let hosts = owners.compactMap(\.host).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return [.common] + [.local].filter { owners.contains($0) } + hosts.map(Self.host)
    }
    func draft(in context: QuickCommandContext) -> QuickCommand {
        if self == .common { return QuickCommand(scope: .all) }
        let target = host
        let directory = target == context.host ? context.directory : nil
        return QuickCommand(scope: directory == nil ? (target == nil ? .local : .host) : .directory,
                            host: target, directory: directory)
    }
}

struct QuickCommand: Codable, Hashable, Identifiable, Sendable {
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

    func matchesSearch(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || [alias, command, group, host ?? "", directory ?? "", QuickCommandCollection.owner(of: self).title]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

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

    func appearsInSidebar(for context: QuickCommandContext) -> Bool {
        scope != .all && matches(context)
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

struct QuickCommandNumberedEntry: Identifiable, Equatable, Sendable {
    let number: Int
    let item: QuickCommand
    var id: UUID { item.id }
}

enum QuickCommandDirectoryGroupKind: Hashable, Sendable {
    case common
    case directory(path: String, includesSubdirectories: Bool)
    case hostWide(isLocal: Bool)
}

/// 相邻且归属同一工作目录的命令合并为一个组头，保留侧栏原始序号与排列顺序。
struct QuickCommandDirectoryGroup: Identifiable, Equatable, Sendable {
    let id: String
    let kind: QuickCommandDirectoryGroupKind
    let entries: [QuickCommandNumberedEntry]

    var showsHeader: Bool { kind != .common }

    static func group(entries: [(offset: Int, element: QuickCommand)],
                      in collection: QuickCommandCollection) -> [QuickCommandDirectoryGroup] {
        let numbered = entries.map { QuickCommandNumberedEntry(number: $0.offset + 1, item: $0.element) }
        guard !numbered.isEmpty else { return [] }
        if collection == .common {
            return [QuickCommandDirectoryGroup(id: "common", kind: .common, entries: numbered)]
        }
        var groups: [(kind: QuickCommandDirectoryGroupKind, items: [QuickCommandNumberedEntry])] = []
        for entry in numbered {
            let kind: QuickCommandDirectoryGroupKind
            if entry.item.scope == .directory, let path = entry.item.directory, !path.isEmpty {
                kind = .directory(path: path, includesSubdirectories: entry.item.includesSubdirectories)
            } else {
                kind = .hostWide(isLocal: collection == .local)
            }
            if let last = groups.last, last.kind == kind {
                groups[groups.count - 1].items.append(entry)
            } else {
                groups.append((kind: kind, items: [entry]))
            }
        }
        return groups.enumerated().map { index, bucket in
            QuickCommandDirectoryGroup(id: "group-\(index)-\(bucket.items[0].id.uuidString)",
                                       kind: bucket.kind, entries: bucket.items)
        }
    }
}

enum QuickCommandTokenRole: Equatable, Sendable {
    case plain
    case command
    case operatorToken
    case flag
    case flagValue
    case stringOrVariable
    case comment
}

struct QuickCommandToken: Equatable, Sendable {
    let text: String
    let role: QuickCommandTokenRole
}

struct QuickCommandFlagParameter: Equatable, Identifiable, Sendable {
    let index: Int
    let flag: String
    let value: String
    let isFlagOnly: Bool
    var id: Int { index }
}

/// 命令行轻量词法切分与长参数提取；保持原字符序列一字不改。
enum QuickCommandLexer {
    static let highlightByteLimit = 8_192
    private static let commandWrappers: Set<String> = ["sudo", "env", "nohup", "time", "command", "exec"]

    static func tokenizeLine(_ line: String) -> [QuickCommandToken] {
        guard !line.isEmpty else { return [] }
        let characters = Array(line)
        let count = characters.count
        var index = 0
        var tokens: [QuickCommandToken] = []
        var isExpectingCommand = true
        var isExpectingFlagValue = false
        var isAtLineLead = true

        func append(_ text: String, role: QuickCommandTokenRole) {
            guard !text.isEmpty else { return }
            tokens.append(QuickCommandToken(text: text, role: role))
        }

        while index < count {
            let ch = characters[index]
            if ch.isWhitespace {
                let start = index
                while index < count, characters[index].isWhitespace { index += 1 }
                append(String(characters[start..<index]), role: .plain)
                continue
            }
            if ch == "#", isAtLineLead || tokens.last?.text.last?.isWhitespace == true {
                append(String(characters[index..<count]), role: .comment)
                break
            }
            isAtLineLead = false

            if ch == "|" || ch == "&" || ch == ";" {
                if index + 1 < count, (ch == "|" && characters[index + 1] == "|") || (ch == "&" && characters[index + 1] == "&") {
                    append(String(characters[index...(index + 1)]), role: .operatorToken)
                    index += 2
                    isExpectingCommand = true
                    isExpectingFlagValue = false
                    continue
                } else if ch == "|" || ch == ";" {
                    append(String(ch), role: .operatorToken)
                    index += 1
                    isExpectingCommand = true
                    isExpectingFlagValue = false
                    continue
                }
            }

            if ch == "'" || ch == "\"" {
                let quote = ch
                let start = index
                index += 1
                while index < count {
                    if quote == "\"", characters[index] == "\\", index + 1 < count {
                        index += 2
                        continue
                    }
                    if characters[index] == quote {
                        index += 1
                        break
                    }
                    index += 1
                }
                let text = String(characters[start..<index])
                let role: QuickCommandTokenRole = isExpectingFlagValue ? .flagValue : .stringOrVariable
                append(text, role: role)
                isExpectingCommand = false
                isExpectingFlagValue = false
                continue
            }

            let start = index
            while index < count {
                let current = characters[index]
                if current.isWhitespace || current == ";" || current == "'" || current == "\"" { break }
                if current == "|" { break }
                if current == "&", index + 1 < count, characters[index + 1] == "&" { break }
                index += 1
            }
            if index == start {
                append(String(characters[index]), role: .plain)
                index += 1
                continue
            }

            let word = String(characters[start..<index])
            if isExpectingCommand {
                if QuickCommandLexer.isEnvironmentAssignment(word) {
                    append(word, role: .stringOrVariable)
                } else {
                    append(word, role: .command)
                    if !QuickCommandLexer.commandWrappers.contains(word) {
                        isExpectingCommand = false
                    }
                }
                isExpectingFlagValue = false
            } else if word.hasPrefix("--"), word.count > 2 {
                if let eq = word.firstIndex(of: "=") {
                    let flagPart = String(word[..<eq])
                    let valuePart = String(word[word.index(after: eq)...])
                    append(flagPart, role: .flag)
                    append("=", role: .operatorToken)
                    if valuePart.isEmpty {
                        isExpectingFlagValue = index < count && (characters[index] == "'" || characters[index] == "\"")
                    } else {
                        append(valuePart, role: .flagValue)
                        isExpectingFlagValue = false
                    }
                } else {
                    append(word, role: .flag)
                    isExpectingFlagValue = true
                }
            } else if word.hasPrefix("-"), word.count > 1 {
                append(word, role: .flag)
                isExpectingFlagValue = false
            } else if isExpectingFlagValue {
                append(word, role: .flagValue)
                isExpectingFlagValue = false
            } else if word.hasPrefix("$") {
                append(word, role: .stringOrVariable)
            } else {
                append(word, role: .plain)
            }
        }
        return tokens
    }

    static func extractLongFlags(_ command: String, limit: Int = 12) -> [QuickCommandFlagParameter] {
        guard command.utf8.count <= QuickCommandLexer.highlightByteLimit, limit > 0 else { return [] }
        var parameters: [QuickCommandFlagParameter] = []
        for line in command.components(separatedBy: "\n") {
            let meaningful = QuickCommandLexer.tokenizeLine(line).filter { token in
                token.role != .comment && !token.text.allSatisfy(\.isWhitespace)
            }
            var i = 0
            while i < meaningful.count, parameters.count < limit {
                let token = meaningful[i]
                if token.role == .flag, token.text.hasPrefix("--"), token.text.count > 2 {
                    if i + 2 < meaningful.count, meaningful[i + 1].text == "=", meaningful[i + 2].role == .flagValue {
                        parameters.append(QuickCommandFlagParameter(
                            index: parameters.count,
                            flag: token.text,
                            value: QuickCommandLexer.unquoted(meaningful[i + 2].text),
                            isFlagOnly: false
                        ))
                        i += 3
                        continue
                    } else if i + 1 < meaningful.count, meaningful[i + 1].role == .flagValue {
                        parameters.append(QuickCommandFlagParameter(
                            index: parameters.count,
                            flag: token.text,
                            value: QuickCommandLexer.unquoted(meaningful[i + 1].text),
                            isFlagOnly: false
                        ))
                        i += 2
                        continue
                    } else {
                        parameters.append(QuickCommandFlagParameter(
                            index: parameters.count,
                            flag: token.text,
                            value: "",
                            isFlagOnly: true
                        ))
                    }
                }
                i += 1
            }
            if parameters.count >= limit { break }
        }
        return parameters
    }

    private static func isEnvironmentAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
        let name = word[..<eq]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func unquoted(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        if (text.hasPrefix("'") && text.hasSuffix("'")) || (text.hasPrefix("\"") && text.hasSuffix("\"")) {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}
