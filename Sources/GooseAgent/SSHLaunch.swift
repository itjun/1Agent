import Foundation

/// Environment for the `ssh` child.
///
/// The remote shell's terminal type is whatever `ssh` copies from this process.
/// That value is only `xterm-256color`: no Ghostty terminfo name, no `COLORTERM`.
/// `PATH` and `SSH_AUTH_SOCK` come from a login shell so `ProxyCommand` and the
/// agent socket match Terminal.app. The child is still `/usr/bin/ssh`, not a shell.
actor SSHLaunchEnvironment {
    static let shared = SSHLaunchEnvironment()

    private var cached: [String]?

    func get() -> [String] {
        if let cached { return cached }
        let resolved = Self.resolve()
        cached = resolved
        return resolved
    }

    private static func resolve() -> [String] {
        let launch = ProcessInfo.processInfo.environment
        var values: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR"] {
            if let value = launch[key], !value.isEmpty {
                values[key] = value
            }
        }
        if values["LANG"] == nil { values["LANG"] = "en_US.UTF-8" }

        let login = loginExports()
        if let path = login["PATH"], !path.isEmpty {
            values["PATH"] = path
        } else {
            values["PATH"] = fallbackPath(home: values["HOME"])
        }
        if let socket = login["SSH_AUTH_SOCK"] ?? launch["SSH_AUTH_SOCK"], !socket.isEmpty {
            values["SSH_AUTH_SOCK"] = socket
        }

        values["TERM"] = "xterm-256color"
        values.removeValue(forKey: "TERM_PROGRAM")
        values.removeValue(forKey: "TERM_PROGRAM_VERSION")
        values.removeValue(forKey: "COLORTERM")
        return values.map { "\($0.key)=\($0.value)" }.sorted()
    }

    private static func fallbackPath(home: String?) -> String {
        var parts = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let home, !home.isEmpty {
            parts.insert("\(home)/.local/bin", at: 0)
        }
        return parts.joined(separator: ":")
    }

    /// One login shell, only to read `PATH` and `SSH_AUTH_SOCK`. Its own `TERM` is discarded.
    private static func loginExports() -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", #"printf '%s\n%s' "$PATH" "${SSH_AUTH_SOCK-}""#]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return [:]
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else { return [:] }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        var values: [String: String] = [:]
        if let path = lines.first, !path.isEmpty { values["PATH"] = String(path) }
        if lines.count > 1 {
            let socket = lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !socket.isEmpty { values["SSH_AUTH_SOCK"] = socket }
        }
        return values
    }
}

enum SSHCommand {
    /// `ssh -tt -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -- <alias>`.
    /// The keepalive is fixed on purpose: a dead link is noticed within 90 seconds and then reconnected.
    /// Command-line `-o` wins over `~/.ssh/config`, so these two values always apply.
    /// The connection is shared with the file pane and uploads, which never ask for a password.
    static func arguments(alias: String, remoteDirectory: String? = nil) -> [String] {
        var options = ["-tt", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3"]
            + RemoteShell.multiplexOptions()
        guard let remoteDirectory, !remoteDirectory.isEmpty else { return options + ["--", alias] }
        // A directory restore is the explicit launch command. A saved RemoteCommand must not
        // run before it or conflict with it; this changes this invocation, never ~/.ssh/config.
        options += ["-o", "RemoteCommand=none"]
        return options + ["--", alias, remoteStartupCommand(directory: remoteDirectory)]
    }

    /// Sent as SSH's remote command, after authentication. Nothing is typed into the PTY,
    /// so password and host-key prompts cannot consume a directory-changing command.
    static func remoteStartupCommand(directory: String) -> String {
        let printableDirectory = directory.replacingOccurrences(of: "\0", with: "�")
        let error = String(localized: "Cannot restore remote directory") + ": " + printableDirectory
        let fallback = String(localized: "Opened the remote home directory instead.")
        let failure = "printf '%s\\n' \(quote(error)) \(quote(fallback)) >&2; cd -- \"${HOME:-/}\" || exit 1"
        let changeDirectory: String
        if directory.hasPrefix("/"), !directory.contains("\0") {
            changeDirectory = "if ! cd -- \(quote(directory)); then \(failure); fi"
        } else {
            changeDirectory = failure
        }
        let script = changeDirectory + "; exec \"${SHELL:-/bin/sh}\" -l"
        return "exec /bin/sh -c " + quote(script)
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Reloads the host list when `~/.ssh/config` or anything under `~/.ssh/config.d` changes,
/// so a host 1Panel just wrote shows its address and user right away.
final class SSHConfigWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        stop()
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        for path in [ssh.path, ssh.appendingPathComponent("config").path, ssh.appendingPathComponent("config.d").path] {
            watch(path)
        }
    }

    func stop() {
        for source in sources {
            source.cancel()
        }
        sources = []
    }

    private func watch(_ path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
            // An editor that replaces the file leaves us watching a stale inode. Re-arm on the path.
            if source.data.contains(.rename) || source.data.contains(.delete) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.start()
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.activate()
        sources.append(source)
    }

    /// Several files often change in one burst; one reload a third of a second later covers them all.
    private func scheduleReload() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
