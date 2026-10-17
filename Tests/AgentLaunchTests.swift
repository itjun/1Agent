import Foundation

// No network connection or user shell configuration is used by these launch probes.
enum RemoteShell {
    static func multiplexOptions() -> [String] { ["-o", "ControlMaster=auto"] }
}

@main
enum AgentLaunchTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oneagent-agent-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("must-not-execute")
        let directory = folder.appendingPathComponent("project ' ; $(touch \"$ONEAGENT_TEST_MARKER\")")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("fake ' agent")
        try "#!/bin/sh\nprintf 'AGENT-CWD=<%s>\\n' \"$PWD\"\nprintf 'ARG=<%s>\\n' \"$@\"\nexit 9\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let shell = folder.appendingPathComponent("fake-login-shell")
        try "#!/bin/sh\nif [ \"$#\" -eq 4 ]; then exec /bin/sh -c \"$4\"; fi\nprintf 'SHELL-REMAINS=<%s>\\n' \"$PWD\"\n".write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)

        func run(_ command: String) throws -> (status: Int32, out: String, err: String) {
            let process = Process(), out = Pipe(), err = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = folder
            process.environment = ["SHELL": shell.path, "HOME": folder.path, "PATH": "/usr/bin:/bin", "ONEAGENT_TEST_MARKER": marker.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let output = out.fileHandleForReading.readDataToEndOfFile()
            let errors = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self))
        }

        let arguments = ["--profile", "value with spaces", "'; touch \"$ONEAGENT_TEST_MARKER\"; #", "$(touch \"$ONEAGENT_TEST_MARKER\")", ""]
        let request = try AgentLaunchRequest(executable: executable.path, arguments: arguments)
        let remote = try request.remoteStartupCommand(directory: directory.path)
        let result = try run(remote)
        expect(result.status == 0, "nonzero agent exit leaves a shell running")
        expect(result.out.contains("AGENT-CWD=<\(directory.resolvingSymlinksInPath().path)>"), "agent starts in the chosen remote directory")
        expect(result.out.contains("SHELL-REMAINS="), "remote shell remains after the agent exits")
        for argument in arguments { expect(result.out.contains("ARG=<\(argument)>"), "arguments remain literal, including spaces and quotes") }
        expect(!FileManager.default.fileExists(atPath: marker.path), "neither argv nor cwd executes shell substitutions")

        let args = SSHCommand.arguments(alias: "my-config-host", remoteDirectory: directory.path, startupCommand: remote)
        expect(args.suffix(3) == ["--", "my-config-host", remote], "agent runs through SSH's authenticated command channel")
        expect(args.contains("RemoteCommand=none") && args.contains("ControlMaster=auto"), "explicit launch retains existing connection options")
        let reconnect = SSHCommand.arguments(alias: "my-config-host", remoteDirectory: directory.path)
        expect(!reconnect.contains(remote), "ordinary reconnect arguments contain no agent launch")

        let missing = try AgentLaunchRequest(executable: "oneagent-test-absent-\(UUID().uuidString)")
        let missingResult = try run(missing.remoteStartupCommand(directory: directory.path))
        expect(missingResult.err.contains(missing.executable) && missingResult.out.contains("SHELL-REMAINS="), "missing CLI reports its name and leaves the terminal usable")
        let badDirectory = try run(request.remoteStartupCommand(directory: folder.appendingPathComponent("absent").path))
        expect(!badDirectory.out.contains("AGENT-CWD=") && badDirectory.out.contains("SHELL-REMAINS=") && !badDirectory.err.isEmpty,
               "unavailable remote directory reports the failure and never launches the agent elsewhere")

        let interruptedExecutable = folder.appendingPathComponent("interrupted-agent")
        try "#!/bin/sh\nkill -INT \"$PPID\"\nexit 130\n".write(to: interruptedExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: interruptedExecutable.path)
        let interruptedRequest = try AgentLaunchRequest(executable: interruptedExecutable.path)
        let interrupted = try run(interruptedRequest.remoteStartupCommand(directory: directory.path))
        expect(interrupted.out.contains("SHELL-REMAINS="), "interrupting the waiting wrapper still returns to a shell")

        let local = try run(String(request.localInitialInput.dropLast()) + "; printf 'LOCAL-SHELL-REMAINS\\n'")
        expect(local.out.contains("LOCAL-SHELL-REMAINS"), "local command does not replace its new shell")
        expect(request.localInitialInput.last == "\r", "new local shell receives one completed command")
        expect(AgentPreset.allCases.filter { $0 != .custom }.allSatisfy { !$0.executable.isEmpty && !$0.executable.contains(" ") }, "built-in presets carry no permission-changing flags")
        expect((try? AgentLaunchRequest(executable: "codex\nexit")) == nil, "executable control characters are rejected")
        expect((try? AgentLaunchRequest(executable: "codex", arguments: ["\u{1b}[A"])) == nil, "terminal escape injection is rejected")
        expect((try? AgentLaunchRequest(executable: "../codex")) == nil, "relative executable paths do not accidentally depend on a different host cwd")
        expect((try? AgentLaunchTarget.local(directory: folder.path).validated()) != nil, "existing local directory is accepted")
        expect((try? AgentLaunchTarget.local(directory: executable.path).validated()) == nil, "local file is not accepted as a directory")
        expect((try? AgentLaunchTarget.remote(host: "my-config-host", directory: "relative").validated()) == nil, "remote directories must be absolute")
        expect((try? AgentLaunchTarget.remote(host: "my-config-host", directory: nil).validated()) != nil, "unknown remote cwd uses the remote home")
        print("ok")
    }

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL \(message)\n", stderr); exit(1) }
    }
}
