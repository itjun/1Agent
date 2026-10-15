import Foundation

/// What another app (1Panel) asked for through `oneagent://open?…`.
///
/// Query parameters, all optional except that at least one `host` or a `group` must be present:
/// - `host=<alias>` (repeatable): SSH config aliases to open.
/// - `group=<name>`: every alias declared in `~/.ssh/config.d/<name>.conf`.
/// - `reuse=1`: an alias that is already open is focused instead of opened again.
/// - `layout=columns|rows|grid|leadingSide|leadingTop`: explicitly combine the opened hosts.
///   Without it they share a workspace but keep independent panels.
/// - `name=<title>`: sidebar title of the workspace created for two or more hosts.
/// - `window=new`: still parsed for the 1Panel URL contract, but ignored. 1Agent has one main
///   window now and everything opens there.
struct ExternalOpenRequest: Equatable {
    var hosts: [String] = []
    var group: String?
    var reuse = false
    var layout: WorkspaceLayout?
    var name: String?
    var newWindow = false
    var destination: ExternalOpenDestination = .terminal
    var path: String?

    var isEmpty: Bool {
        hosts.isEmpty && (group?.isEmpty ?? true)
    }
}

enum ExternalOpenDestination: String { case terminal, files }

struct LocalTerminalCandidate {
    var id: UUID
    var directory: String
    var isRunning: Bool
}

/// A local shell in `directory` that types `command` once it starts.
///
/// Comes from `--working-directory=<dir> -e <cmd> <args…>` on the command line (VS Code / Cursor
/// debug "runInTerminal"), or from a second instance handing that request over as
/// `oneagent://run?cwd=<dir>&cmd=<line>&wait=1`. `cmd` is one shell line, already quoted.
struct ExternalRunRequest: Equatable {
    var directory: String?
    var command: String?
    var waitAfterCommand = false
}

/// What a second instance leaves for the running one in the hand-off folder. The notification only
/// carries the file name, so a process that can post notifications but not write there cannot run commands.
struct HandOffTicket: Codable, Equatable {
    /// The second instance itself; the receiver checks that it runs the same executable.
    var pid: Int32
    /// A `oneagent://run?…` URL.
    var url: String
}

enum ExternalOpen {
    /// Scheme registered in Info.plist. 1Panel opens hosts with `oneagent://open`.
    static let scheme = "oneagent"
    static let handOffMaxAge: TimeInterval = 10

    /// A ticket counts only as a regular file of the current user, readable and writable by that user
    /// alone, created at most `handOffMaxAge` seconds ago.
    static func handOffFileIsAcceptable(
        isRegularFile: Bool,
        owner: UInt32,
        currentUser: UInt32,
        permissions: Int,
        createdAt: Date,
        now: Date
    ) -> Bool {
        if !isRegularFile || owner != currentUser || permissions != 0o600 {
            return false
        }
        let age = now.timeIntervalSince(createdAt)
        return age >= 0 && age <= ExternalOpen.handOffMaxAge
    }

    /// Nil for any other scheme or path. Blank and multi-line aliases are dropped.
    static func request(from url: URL) -> ExternalOpenRequest? {
        guard url.scheme?.lowercased() == ExternalOpen.scheme else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let action = (components.host ?? "").lowercased()
        guard action == "open" else { return nil }
        var request = ExternalOpenRequest()
        for item in components.queryItems ?? [] {
            let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch item.name.lowercased() {
            case "host":
                if value.isEmpty || value.contains(where: \.isNewline) { continue }
                request.hosts.append(value)
            case "group":
                if !value.isEmpty {
                    request.group = value
                }
            case "reuse":
                request.reuse = ExternalOpen.isTrue(value)
            case "layout":
                request.layout = WorkspaceLayout(rawValue: value)
            case "name":
                if !value.isEmpty {
                    request.name = value
                }
            case "window":
                request.newWindow = value.lowercased() == "new"
            case "view":
                request.destination = ExternalOpenDestination(rawValue: value) ?? .terminal
            case "path":
                if let path = item.value, path.hasPrefix("/"), !path.contains("\0") { request.path = path }
            default:
                continue
            }
        }
        return request
    }

    /// Just the `host` aliases, for callers that do not care about the rest.
    static func hostAliases(from url: URL) -> [String] {
        ExternalOpen.request(from: url)?.hosts ?? []
    }

    /// `oneagent://run?…`. Nil for any other URL, or when neither `cwd` nor `cmd` is given.
    static func runRequest(from url: URL) -> ExternalRunRequest? {
        guard url.scheme?.lowercased() == ExternalOpen.scheme else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard (components.host ?? "").lowercased() == "run" else { return nil }
        var request = ExternalRunRequest()
        for item in components.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "cwd":
                request.directory = value
            case "cmd":
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    request.command = value
                }
            case "wait":
                request.waitAfterCommand = ExternalOpen.isTrue(value)
            default:
                continue
            }
        }
        if request.directory == nil && request.command == nil {
            return nil
        }
        return request
    }

    static func runURL(for request: ExternalRunRequest) -> URL? {
        var components = URLComponents()
        components.scheme = ExternalOpen.scheme
        components.host = "run"
        var items: [URLQueryItem] = []
        if let directory = request.directory {
            items.append(URLQueryItem(name: "cwd", value: directory))
        }
        if let command = request.command {
            items.append(URLQueryItem(name: "cmd", value: command))
        }
        if request.waitAfterCommand {
            items.append(URLQueryItem(name: "wait", value: "1"))
        }
        components.queryItems = items
        return components.url
    }

    /// `--working-directory=<dir>` and `-e <cmd> <args…>` from the process arguments.
    /// Everything after `-e` belongs to the command. Other flags, including the ones macOS adds
    /// (`-psn_…`, `-NSDocumentRevisionsDebugMode YES`), are ignored. Nil when neither is present.
    /// A bare existing folder before `-e` (`1Agent <dir>`, as GitHub Desktop's custom shell passes it)
    /// counts as the working directory when `--working-directory` is absent.
    static func runRequest(
        fromArguments arguments: [String],
        isDirectory: (String) -> Bool = ExternalOpen.isExistingDirectory
    ) -> ExternalRunRequest? {
        var request = ExternalRunRequest()
        if let folder = ExternalOpen.positionalDirectory(in: arguments, isDirectory: isDirectory) {
            request.directory = folder
        }
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-e" {
                let words = arguments[(index + 1)...].map { ExternalOpen.shellQuoted($0) }
                if !words.isEmpty {
                    request.command = words.joined(separator: " ")
                }
                break
            }
            if argument.hasPrefix("--working-directory=") {
                let value = String(argument.dropFirst("--working-directory=".count))
                request.directory = value
            } else if argument.hasPrefix("--wait-after-command") {
                request.waitAfterCommand = !argument.hasSuffix("=false")
            }
            index += 1
        }
        if request.directory == nil && request.command == nil {
            return nil
        }
        return request
    }

    /// The first argument before `-e` that is not a flag and names an existing folder, made absolute
    /// against the current directory.
    static func positionalDirectory(
        in arguments: [String],
        isDirectory: (String) -> Bool = ExternalOpen.isExistingDirectory
    ) -> String? {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for argument in arguments.dropFirst() {
            if argument == "-e" {
                return nil
            }
            if argument.isEmpty || argument.hasPrefix("-") {
                continue
            }
            let path = URL(fileURLWithPath: (argument as NSString).expandingTildeInPath, relativeTo: base).standardizedFileURL.path
            // Keep explicit paths even when missing: the receiver reports an invalid cwd.
            // Plain system flag values such as YES still cannot become a directory request.
            if isDirectory(path) || argument.hasPrefix("/") || argument.hasPrefix("~/") || argument.hasPrefix("./") || argument.hasPrefix("../") {
                return path
            }
        }
        return nil
    }

    static func isExistingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func canonicalDirectory(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Resolve before matching, so Finder aliases such as /tmp and /private/tmp share a shell.
    static func validatedDirectory(_ path: String) -> String? {
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        let canonical = canonicalDirectory(path)
        return isExistingDirectory(canonical) ? canonical : nil
    }

    static func reusableLocalTerminal(at directory: String, candidates: [LocalTerminalCandidate],
                                      mostRecentFirst: [UUID]) -> UUID? {
        let target = canonicalDirectory(directory)
        let matches = candidates.filter { $0.isRunning && canonicalDirectory($0.directory) == target }
        for id in mostRecentFirst where matches.contains(where: { $0.id == id }) { return id }
        return matches.last?.id
    }

    /// What the new shell types for `-e`. Like Ghostty, the command replaces the shell (`exec`), so the
    /// terminal closes when it ends; `--wait-after-command` keeps the shell and the terminal instead.
    /// The leading space keeps the line out of history when the shell ignores space-prefixed lines.
    static func initialInput(for request: ExternalRunRequest) -> String? {
        guard let command = request.command else { return nil }
        if request.waitAfterCommand {
            return command + "\r"
        }
        return " exec " + command + "\r"
    }

    /// Folders and files from `open`, Finder, or the Dock, each kept in the order given.
    /// Folders open without asking; files run, so they wait for one confirmation that covers all of them.
    static func splitOpenedPaths(_ items: [(path: String, isDirectory: Bool)]) -> (directories: [String], files: [String]) {
        var directories: [String] = []
        var files: [String] = []
        for item in items {
            if item.isDirectory {
                directories.append(item.path)
            } else {
                files.append(item.path)
            }
        }
        return (directories, files)
    }

    /// Title and detail of the prompt shown before opened files run. One file is named in the title,
    /// like Ghostty's own prompt; several are listed in the detail.
    static func executionPrompt(for files: [String]) -> (title: String, detail: String?) {
        if files.count == 1 {
            let path = files[0]
            return (String(localized: "Allow 1Agent to execute \"\(path)\"?"), nil)
        }
        let title = String(localized: "Allow 1Agent to execute these \(files.count) files?")
        return (title, files.joined(separator: "\n"))
    }

    /// Single-quoted for sh/zsh/bash: `it's` becomes `'it'\''s'`.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isTrue(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return lowered == "1" || lowered == "true" || lowered == "yes" || lowered.isEmpty
    }
}
