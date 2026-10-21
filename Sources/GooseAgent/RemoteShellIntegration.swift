import Foundation

/// Session-only zsh integration, transported in SSH's authenticated command channel.
/// The shell's rc files remain untouched. Unsupported/custom commands keep their launch behavior.
enum RemoteShellIntegration {
    struct Prepared {
        let arguments: [String]
        let forwarding: String
        let cancelArguments: [String]
    }

    static func prepare(arguments: [String], environment: [String], resources: String,
                        socket: String, token: String, agentSocket: String? = nil, agentConversation: Data? = nil,
                        remoteDirectory: String? = nil, directoryCommand: String? = nil,
                        agentUnavailableMessage: String = "", agentRestoreError: String = "") -> Prepared? {
        guard let separator = arguments.firstIndex(of: "--"), arguments.count > separator + 1 else { return nil }
        let prefix = Array(arguments[..<separator]), alias = arguments[separator + 1]
        let explicit = arguments.count > separator + 2 ? arguments[separator + 2] : nil
        // A custom RemoteCommand (e.g. a tmux attach) must not silently become a login shell.
        if explicit == nil && !hasOrdinaryShell(arguments: prefix + ["--", alias], environment: environment) { return nil }
        let managedDirectory = explicit != nil && directoryCommand != nil && explicit == directoryCommand
        let command: String?
        if agentSocket != nil {
            command = RemoteAgentBootstrap.command(resources: resources, token: token, conversation: agentConversation,
                                                   directory: managedDirectory ? remoteDirectory : nil, startupCommand: managedDirectory ? nil : explicit,
                                                   unavailableMessage: agentUnavailableMessage, restoreError: agentRestoreError)
        } else { command = bootstrap(resources: resources, token: token, startupCommand: explicit) }
        guard let command else { return nil }
        let forward = socket + ":" + remoteFolder(token: token) + "/s"
        let forwards = ["-L", forward] + (agentSocket.map { ["-L", $0 + ":" + remoteFolder(token: token) + "/agent"] } ?? [])
        return Prepared(arguments: prefix + ["-o", "RemoteCommand=none"] + forwards + ["--", alias, command],
                        forwarding: forward, cancelArguments: prefix + ["-O", "cancel"] + forwards + ["--", alias])
    }

    static func remoteFolder(token: String) -> String { "/tmp/1a-remote-" + token }

    static func bootstrap(resources: String, token: String, startupCommand: String?) -> String? {
        guard UUID(uuidString: token) != nil else { return nil }
        let files = [".zshenv", "ghostty-integration", "oneagent-quick-commands"]
        var writes: [String] = []
        for name in files {
            let url = URL(fileURLWithPath: resources).appendingPathComponent("shell-integration/zsh/" + name)
            guard let data = try? Data(contentsOf: url) else { return nil }
            writes.append("printf '%s' " + quote(data.base64EncodedString()) + " | base64 -d > \"$d/shell-integration/zsh/" + name + "\" || exit 1")
        }
        let start = startupCommand.map { "/bin/sh -c " + quote($0) } ?? "\"${SHELL:-/bin/sh}\" -l"
        let script = """
        case "${SHELL##*/}" in zsh) ;; *) exec \(start);; esac
        d=\(quote(remoteFolder(token: token)))
        umask 077
        if ! mkdir "$d"; then exec \(start); fi
        trap 'rm -rf -- "$d"' EXIT
        mkdir -p "$d/shell-integration/zsh" || exit 1
        \(writes.joined(separator: "\n"))
        if [ "${ZDOTDIR+x}" = x ]; then export GHOSTTY_ZSH_ZDOTDIR="$ZDOTDIR"; else unset GHOSTTY_ZSH_ZDOTDIR; fi
        export ZDOTDIR="$d/shell-integration/zsh" GHOSTTY_RESOURCES_DIR="$d" GHOSTTY_SHELL_FEATURES=path,title
        export ONEAGENT_QC_SOCKET="$d/s" ONEAGENT_QC_TOKEN=\(quote(token))
        export ONEAGENT_QC_READ_TIMEOUT=5
        unset ONEAGENT_QC_OWNER
        \(start)
        """
        return "exec /bin/sh -c " + quote(script)
    }

    private static func hasOrdinaryShell(arguments: [String], environment: [String]) -> Bool {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G"] + arguments
        process.environment = Dictionary(environment.compactMap { entry -> (String, String)? in
            guard let i = entry.firstIndex(of: "=") else { return nil }
            return (String(entry[..<i]), String(entry[entry.index(after: i)...]))
        }, uniquingKeysWith: { _, last in last })
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        guard process.terminationStatus == 0 else { return false }
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first { $0.hasPrefix("remotecommand ") }
        return line == nil || line == "remotecommand none"
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// What the remote shell integration reported.
enum RemoteShellEvent: Equatable {
    /// OSC 7.
    case directory(String)
    /// OSC 133;C. The command line when its title already arrived (Bash sends it first).
    case commandStarted(String?)
    /// The command line, when its title came after the start mark (Zsh).
    case commandNamed(String)
    /// OSC 133;D.
    case commandFinished(exitCode: Int?)
}

/// The in-memory terminal engine does not emit PWD callbacks for these OSC 7 reports.
/// Parse only bounded OSC frames, across arbitrary PTY chunk boundaries, on the output queue.
/// With the `title` feature the shell sets the title to the command line around 133;C, and to the
/// directory at the prompt; only the first title of a command is its command line.
struct RemoteDirectoryTracker {
    static let maxCommandLength = 200
    private enum State { case text, escape, osc, oscEscape, discard, discardEscape }
    private var state = State.text
    private var buffer = Data()
    /// Title set after input started and before the command did.
    private var pendingTitle: String?
    private var isAtInput = false
    private var isRunning = false
    private var isNamed = false

    mutating func receive(_ data: Data) -> [RemoteShellEvent] {
        var events: [RemoteShellEvent] = []
        for byte in data {
            switch state {
            case .text: if byte == 27 { state = .escape }
            case .escape: state = byte == 93 ? .osc : byte == 27 ? .escape : .text; buffer.removeAll(keepingCapacity: true)
            case .osc:
                if byte == 7 { finish(into: &events) }
                else if byte == 27 { state = .oscEscape }
                else if buffer.count < 16_384 { buffer.append(byte) }
                else { buffer.removeAll(keepingCapacity: true); state = .discard }
            case .oscEscape:
                if byte == 92 { finish(into: &events) }
                else { buffer.removeAll(keepingCapacity: true); state = byte == 93 ? .osc : .text }
            case .discard: if byte == 7 { state = .text } else if byte == 27 { state = .discardEscape }
            case .discardEscape: state = byte == 92 ? .text : .discard
            }
        }
        return events
    }
    private mutating func finish(into events: inout [RemoteShellEvent]) {
        defer { state = .text; buffer.removeAll(keepingCapacity: true) }
        guard let value = String(data: buffer, encoding: .utf8) else { return }
        if value.hasPrefix("0;") || value.hasPrefix("2;") {
            noteTitle(String(value.dropFirst(2)), into: &events)
            return
        }
        if value.hasPrefix("133;") {
            noteMark(value.dropFirst(4).split(separator: ";", omittingEmptySubsequences: false), into: &events)
            return
        }
        guard value.hasPrefix("7;") else { return }
        let report = String(value.dropFirst(2))
        let path: String?
        if report.hasPrefix("kitty-shell-cwd://") {
            let tail = report.dropFirst("kitty-shell-cwd://".count)
            path = tail.firstIndex(of: "/").map { String(tail[$0...]) }
        } else if report.hasPrefix("file://"), let url = URLComponents(string: report), url.query == nil, url.fragment == nil {
            path = url.path
        } else { path = nil }
        guard let path, path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return }
        events.append(.directory(path))
    }

    private mutating func noteTitle(_ raw: String, into events: inout [RemoteShellEvent]) {
        let visible = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        let title = String(visible.trimmingCharacters(in: .whitespaces).prefix(RemoteDirectoryTracker.maxCommandLength))
        guard !title.isEmpty else { return }
        if isRunning {
            // Later titles come from the program itself, such as vim naming its file.
            if !isNamed {
                isNamed = true
                events.append(.commandNamed(title))
            }
        } else if isAtInput {
            pendingTitle = title
        }
    }

    /// The directory title at a prompt arrives before input starts (133;B), so it never names a command.
    private mutating func noteMark(_ parts: [Substring], into events: inout [RemoteShellEvent]) {
        switch parts.first {
        case "A":
            if isRunning {
                isRunning = false
                events.append(.commandFinished(exitCode: nil))
            }
            isAtInput = false
            pendingTitle = nil
        case "B":
            isAtInput = true
            pendingTitle = nil
        case "C":
            isRunning = true
            isNamed = pendingTitle != nil
            events.append(.commandStarted(pendingTitle))
            isAtInput = false
            pendingTitle = nil
        case "D":
            guard isRunning else { return }
            isRunning = false
            var exitCode: Int?
            if parts.count > 1 {
                exitCode = Int(parts[1])
            }
            events.append(.commandFinished(exitCode: exitCode))
        default:
            return
        }
    }
}
