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
                        socket: String, token: String) -> Prepared? {
        guard let separator = arguments.firstIndex(of: "--"), arguments.count > separator + 1 else { return nil }
        let prefix = Array(arguments[..<separator]), alias = arguments[separator + 1]
        let explicit = arguments.count > separator + 2 ? arguments[separator + 2] : nil
        // A custom RemoteCommand (e.g. a tmux attach) must not silently become a login shell.
        if explicit == nil && !hasOrdinaryShell(arguments: prefix + ["--", alias], environment: environment) { return nil }
        guard let command = bootstrap(resources: resources, token: token, startupCommand: explicit) else { return nil }
        let forward = socket + ":" + remoteFolder(token: token) + "/s"
        return Prepared(arguments: prefix + ["-o", "RemoteCommand=none", "-L", forward, "--", alias, command],
                        forwarding: forward, cancelArguments: prefix + ["-O", "cancel", "-L", forward, "--", alias])
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
        export ZDOTDIR="$d/shell-integration/zsh" GHOSTTY_RESOURCES_DIR="$d" GHOSTTY_SHELL_FEATURES=path
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

/// The in-memory terminal engine does not emit PWD callbacks for these OSC 7 reports.
/// Parse only bounded OSC frames, across arbitrary PTY chunk boundaries, on the output queue.
struct RemoteDirectoryTracker {
    private enum State { case text, escape, osc, oscEscape, discard, discardEscape }
    private var state = State.text
    private var buffer = Data()

    mutating func receive(_ data: Data) -> [String] {
        var paths: [String] = []
        for byte in data {
            switch state {
            case .text: if byte == 27 { state = .escape }
            case .escape: state = byte == 93 ? .osc : byte == 27 ? .escape : .text; buffer.removeAll(keepingCapacity: true)
            case .osc:
                if byte == 7 { finish(into: &paths) }
                else if byte == 27 { state = .oscEscape }
                else if buffer.count < 16_384 { buffer.append(byte) }
                else { buffer.removeAll(keepingCapacity: true); state = .discard }
            case .oscEscape:
                if byte == 92 { finish(into: &paths) }
                else { buffer.removeAll(keepingCapacity: true); state = byte == 93 ? .osc : .text }
            case .discard: if byte == 7 { state = .text } else if byte == 27 { state = .discardEscape }
            case .discardEscape: state = byte == 92 ? .text : .discard
            }
        }
        return paths
    }
    private mutating func finish(into paths: inout [String]) {
        defer { state = .text; buffer.removeAll(keepingCapacity: true) }
        guard let value = String(data: buffer, encoding: .utf8), value.hasPrefix("7;") else { return }
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
        paths.append(path)
    }
}
