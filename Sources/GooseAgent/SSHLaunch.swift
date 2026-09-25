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
