import Foundation

@main enum RemoteShellIntegrationTests {
    static func main() throws {
        if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--bootstrap" {
            guard let command = RemoteShellIntegration.bootstrap(resources: CommandLine.arguments[2], token: CommandLine.arguments[3],
                                                                 startupCommand: CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : nil) else { exit(2) }
            print(command); return
        }
        var tracker = RemoteDirectoryTracker()
        let frame = Data("\u{1b}]7;file://fixture-build/root/a%20b/%E4%B8%AD\u{7}".utf8)
        var paths: [String] = []
        for byte in frame { paths += tracker.receive(Data([byte])) }
        precondition(paths == ["/root/a b/中"])
        precondition(tracker.receive(Data("\u{1b}]7;kitty-shell-cwd://fixture-build/root/100% dir\u{1b}\\".utf8)) == ["/root/100% dir"])
        for invalid in ["\u{1b}]0;/root/fake\u{7}", "\u{1b}]7;file:///root/%0Aevil\u{7}", "\u{1b}]7;file:///root/a?b\u{7}", "prompt ~/dir"] {
            precondition(tracker.receive(Data(invalid.utf8)).isEmpty)
        }
        precondition(tracker.receive(Data(("\u{1b}]7;file:///" + String(repeating: "x", count: 20_000) + "\u{7}").utf8)).isEmpty)
        precondition(tracker.receive(frame) == paths, "oversized OSC must not poison the next report")
        let resources = FileManager.default.currentDirectoryPath + "/Resources"
        let token = UUID().uuidString
        let launch = RemoteShellIntegration.prepare(arguments: ["-F", "/dev/null", "--", "fixture", "printf test"],
                                                  environment: [], resources: resources, socket: "/tmp/fixture-socket", token: token)
        precondition(launch?.arguments.contains("-L") == true)
        precondition(launch?.cancelArguments.contains("cancel") == true)
        precondition(launch?.arguments.last?.contains("ZDOTDIR") == true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remote-config-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "Host fixture\n RemoteCommand tmux attach\n".write(to: folder, atomically: true, encoding: .utf8)
        precondition(RemoteShellIntegration.prepare(arguments: ["-F", folder.path, "--", "fixture"], environment: [],
                                                   resources: resources, socket: "/tmp/fixture-socket", token: token) == nil,
                     "explicit SSH RemoteCommand must retain its behavior")
        print("Remote shell integration: chunked cwd, Unicode, invalid frames, launch forwarding and custom RemoteCommand passed")
    }
}
