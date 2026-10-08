import Foundation

/// What another app (1Panel) asked for through `ghostty://open?…`.
///
/// Query parameters, all optional except that at least one `host` or a `group` must be present:
/// - `host=<alias>` (repeatable): SSH config aliases to open.
/// - `group=<name>`: every alias declared in `~/.ssh/config.d/<name>.conf`.
/// - `reuse=1`: an alias that is already open is focused instead of opened again.
/// - `layout=columns|rows|grid|leadingSide|leadingTop`: explicitly combine the opened hosts.
///   Without it they share a workspace but keep independent panels.
/// - `name=<title>`: sidebar title of the workspace created for two or more hosts.
/// - `window=new`: still parsed for the 1Panel URL contract, but ignored. Ghostty has one main
///   window now and everything opens there.
struct ExternalOpenRequest: Equatable {
    var hosts: [String] = []
    var group: String?
    var reuse = false
    var layout: WorkspaceLayout?
    var name: String?
    var newWindow = false

    var isEmpty: Bool {
        hosts.isEmpty && (group?.isEmpty ?? true)
    }
}

/// A local shell in `directory` that types `command` once it starts.
///
/// Comes from `--working-directory=<dir> -e <cmd> <args…>` on the command line (VS Code / Cursor
/// debug "runInTerminal"), or from a second instance handing that request over as
/// `ghostty://run?cwd=<dir>&cmd=<line>&wait=1`. `cmd` is one shell line, already quoted.
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
    /// A `ghostty://run?…` URL.
    var url: String
}

enum ExternalOpen {
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
        guard url.scheme?.lowercased() == "ghostty" else { return nil }
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

    /// `ghostty://run?…`. Nil for any other URL, or when neither `cwd` nor `cmd` is given.
    static func runRequest(from url: URL) -> ExternalRunRequest? {
        guard url.scheme?.lowercased() == "ghostty" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard (components.host ?? "").lowercased() == "run" else { return nil }
        var request = ExternalRunRequest()
        for item in components.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "cwd":
                if !value.isEmpty {
                    request.directory = value
                }
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
        components.scheme = "ghostty"
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
    static func runRequest(fromArguments arguments: [String]) -> ExternalRunRequest? {
        var request = ExternalRunRequest()
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
                if !value.isEmpty {
                    request.directory = value
                }
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
            return (String(localized: "Allow Ghostty to execute \"\(path)\"?"), nil)
        }
        let title = String(localized: "Allow Ghostty to execute these \(files.count) files?")
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
