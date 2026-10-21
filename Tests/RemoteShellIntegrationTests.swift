import Foundation

@main enum RemoteShellIntegrationTests {
    static func main() throws {
        if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--agent-bootstrap" {
            let seed = CommandLine.arguments.count > 4 && CommandLine.arguments[4] != "-"
                ? try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4])) : nil
            let directory = CommandLine.arguments.count > 5 ? CommandLine.arguments[5] : nil
            guard let command = RemoteAgentBootstrap.command(resources: CommandLine.arguments[2], token: CommandLine.arguments[3],
                                                             conversation: seed, directory: directory, startupCommand: nil,
                                                             unavailableMessage: "Agent recovery unavailable", restoreError: "Agent recovery failed") else { exit(2) }
            print(command); return
        }
        if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--bootstrap" {
            guard let command = RemoteShellIntegration.bootstrap(resources: CommandLine.arguments[2], token: CommandLine.arguments[3],
                                                                 startupCommand: CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : nil) else { exit(2) }
            print(command); return
        }
        var tracker = RemoteDirectoryTracker()
        let frame = Data("\u{1b}]7;file://fixture-build/root/a%20b/%E4%B8%AD\u{7}".utf8)
        var paths: [RemoteShellEvent] = []
        for byte in frame { paths += tracker.receive(Data([byte])) }
        precondition(paths == [.directory("/root/a b/中")])
        precondition(tracker.receive(Data("\u{1b}]7;kitty-shell-cwd://fixture-build/root/100% dir\u{1b}\\".utf8)) == [.directory("/root/100% dir")])
        for invalid in ["\u{1b}]0;/root/fake\u{7}", "\u{1b}]7;file:///root/%0Aevil\u{7}", "\u{1b}]7;file:///root/a?b\u{7}", "prompt ~/dir"] {
            precondition(tracker.receive(Data(invalid.utf8)).isEmpty)
        }
        precondition(tracker.receive(Data(("\u{1b}]7;file:///" + String(repeating: "x", count: 20_000) + "\u{7}").utf8)).isEmpty)
        precondition(tracker.receive(frame) == paths, "oversized OSC must not poison the next report")
        // Zsh: the prompt's directory title comes before 133;A, the command title after 133;C.
        let zsh = "\u{1b}]7;kitty-shell-cwd://h/root/x\u{7}\u{1b}]2;~/x\u{7}\u{1b}]133;A;cl=line\u{7}$ \u{1b}]133;B\u{7}"
            + "\u{1b}]133;C\u{7}\u{1b}]2;vim build.sh\u{7}" + "\u{1b}]2;build.sh - VIM\u{7}"
            + "\u{1b}]133;D;0\u{7}\u{1b}]7;kitty-shell-cwd://h/root/x\u{7}\u{1b}]2;~/x\u{7}"
        var zshTracker = RemoteDirectoryTracker()
        var zshEvents: [RemoteShellEvent] = []
        for byte in Data(zsh.utf8) { zshEvents += zshTracker.receive(Data([byte])) }
        precondition(zshEvents == [.directory("/root/x"), .commandStarted(nil), .commandNamed("vim build.sh"),
                                   .commandFinished(exitCode: 0), .directory("/root/x")], "zsh command: \(zshEvents)")
        // Bash: the directory title follows 133;A, the command title comes before 133;C.
        let bash = "\u{1b}]133;A\u{7}\u{1b}]7;file://h/root/x\u{7}\u{1b}]2;~/x\u{7}$ \u{1b}]133;B\u{7}"
            + "\u{1b}]2;make build\u{7}\u{1b}]133;C\u{7}out\u{1b}]2;other\u{7}" + "\u{1b}]133;D;2\u{7}\u{1b}]133;A\u{7}"
        var bashTracker = RemoteDirectoryTracker()
        let bashEvents = bashTracker.receive(Data(bash.utf8))
        precondition(bashEvents == [.directory("/root/x"), .commandStarted("make build"), .commandFinished(exitCode: 2)], "bash command: \(bashEvents)")
        var markTracker = RemoteDirectoryTracker()
        let long = String(repeating: "y", count: 500)
        let marks = markTracker.receive(Data(("\u{1b}]133;D;0\u{7}\u{1b}]133;B\u{7}\u{1b}]133;C\u{7}\u{1b}]0;" + long + "\u{7}\u{1b}]133;A\u{7}").utf8))
        precondition(marks == [.commandStarted(nil), .commandNamed(String(repeating: "y", count: RemoteDirectoryTracker.maxCommandLength)),
                               .commandFinished(exitCode: nil)], "lone D is ignored; A ends an unfinished command: \(marks)")
        let resources = FileManager.default.currentDirectoryPath + "/Resources"
        let token = UUID().uuidString
        let launch = RemoteShellIntegration.prepare(arguments: ["-F", "/dev/null", "--", "fixture", "printf test"],
                                                  environment: [], resources: resources, socket: "/tmp/fixture-socket", token: token)
        precondition(launch?.arguments.contains("-L") == true)
        precondition(launch?.cancelArguments.contains("cancel") == true)
        precondition(launch?.arguments.last?.contains("ZDOTDIR") == true)
        let agents = RemoteShellIntegration.prepare(arguments: ["-F", "/dev/null", "--", "fixture", "managed-cd"],
                                                   environment: [], resources: resources, socket: "/tmp/qc-socket", token: token,
                                                   agentSocket: "/tmp/agent-socket", remoteDirectory: "/a b/中", directoryCommand: "managed-cd")
        precondition(agents?.arguments.contains("/tmp/agent-socket:/tmp/1a-remote-\(token)/agent") == true)
        precondition(agents?.cancelArguments.contains("/tmp/agent-socket:/tmp/1a-remote-\(token)/agent") == true)
        precondition(agents?.arguments.last?.contains("managed-cd") == false, "managed directory must not become a custom command")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remote-config-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "Host fixture\n RemoteCommand tmux attach\n".write(to: folder, atomically: true, encoding: .utf8)
        precondition(RemoteShellIntegration.prepare(arguments: ["-F", folder.path, "--", "fixture"], environment: [],
                                                   resources: resources, socket: "/tmp/fixture-socket", token: token) == nil,
                     "explicit SSH RemoteCommand must retain its behavior")
        precondition(launch?.arguments.last?.contains("GHOSTTY_SHELL_FEATURES=path,title") == true, "remote shells must report command titles")
        print("Remote shell integration: chunked cwd, Unicode, invalid frames, zsh/bash commands, launch forwarding and custom RemoteCommand passed")
    }
}
