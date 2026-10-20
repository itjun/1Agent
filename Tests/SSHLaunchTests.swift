import Foundation

// Keep launch construction tests isolated from real ~/.ssh sockets and network connections.
enum RemoteShell {
    static func multiplexOptions() -> [String] { ["-o", "ControlMaster=auto"] }
}

@main
enum SSHLaunchTests {
    static func main() throws {
        let ordinary = SSHCommand.arguments(alias: "example")
        expect(ordinary.suffix(2) == ["--", "example"], "ordinary SSH remains an interactive connection")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oneagent-ssh-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("must-not-execute")
        let tricky = folder.appendingPathComponent("project ' ; $(touch \"$ONEAGENT_TEST_MARKER\") `echo nope`")
        try FileManager.default.createDirectory(at: tricky, withIntermediateDirectories: true)
        let shell = folder.appendingPathComponent("probe-shell")
        try "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$1\"\n".write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)

        func run(_ command: String) throws -> (status: Int32, out: String, err: String) {
            let process = Process(), out = Pipe(), err = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["SHELL": shell.path, "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin",
                                   "ONEAGENT_TEST_MARKER": marker.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let output = out.fileHandleForReading.readDataToEndOfFile()
            let errors = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self))
        }

        let args = SSHCommand.arguments(alias: "example", remoteDirectory: tricky.path)
        expect(args.contains("RemoteCommand=none"), "cwd launch does not replay a configured remote command")
        expect(args.suffix(3).first == "--", "remote command stays after the SSH host separator")
        let restored = try run(args.last!)
        let resolved = tricky.resolvingSymlinksInPath().path
        expect(restored.status == 0 && restored.out == resolved + "\n-l\n", "quoted remote path becomes the login shell cwd")
        expect(!FileManager.default.fileExists(atPath: marker.path), "shell metacharacters in a directory are never executed")
        let missing = try run(SSHCommand.remoteStartupCommand(directory: folder.appendingPathComponent("missing").path))
        expect(missing.status == 0 && missing.out.hasPrefix(NSHomeDirectory()), "a missing remote directory returns to home with a fresh login shell")
        expect(missing.err.contains("missing") && !missing.err.isEmpty, "directory restore failure is visible")
        print("ok")
    }

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL \(message)\n", stderr); exit(1) }
    }
}
