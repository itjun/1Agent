import Foundation
import Darwin

@main enum RemoteShellIntegrationTests {
    static func main() throws {
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
        precondition(launch?.cancelArguments == RemoteShellIntegration.cancellationArguments(
            arguments: ["-F", "/dev/null", "--", "fixture", "printf test"], socket: "/tmp/fixture-socket", token: token),
            "reattach must cancel the same forwarding without rerunning the bootstrap")
        precondition(launch?.arguments.last?.contains("ZDOTDIR") == true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remote-config-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "Host fixture\n RemoteCommand tmux attach\n".write(to: folder, atomically: true, encoding: .utf8)
        precondition(RemoteShellIntegration.prepare(arguments: ["-F", folder.path, "--", "fixture"], environment: [],
                                                   resources: resources, socket: "/tmp/fixture-socket", token: token) == nil,
                     "explicit SSH RemoteCommand must retain its behavior")
        precondition(launch?.arguments.last?.contains("GHOSTTY_SHELL_FEATURES=path,title") == true, "remote shells must report command titles")
        try forwardingSocketRecovery(resources: resources)
        print("Remote shell integration: chunked cwd, Unicode, invalid frames, zsh/bash commands, launch forwarding and custom RemoteCommand passed")
    }

    private static func forwardingSocketRecovery(resources: String) throws {
        let folder = "/tmp/1a-forward-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/s"
        let token = UUID().uuidString
        func prepare() -> RemoteShellIntegration.Prepared? {
            RemoteShellIntegration.prepare(arguments: ["-F", "/dev/null", "--", "fixture", "printf test"],
                                           environment: [], resources: resources, socket: path, token: token)
        }
        func bindListener() -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            precondition(fd >= 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
            let status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            precondition(status == 0, "SSH 转发必须能绑定原来的命令通道；errno=\(errno)")
            precondition(listen(fd, 4) == 0)
            return fd
        }

        // SSH 退出会留下 socket 文件；下一次连接仍使用同一会话路径。
        close(bindListener())
        precondition(prepare() != nil)
        let active = bindListener()
        defer { close(active) }
        var before = stat(), after = stat()
        precondition(lstat(path, &before) == 0)
        precondition(prepare() != nil)
        precondition(lstat(path, &after) == 0 && before.st_ino == after.st_ino,
                     "已有转发仍在监听时不能移除 socket")
        unlink(path)

        try "keep".write(toFile: path, atomically: true, encoding: .utf8)
        _ = prepare()
        let preserved = try String(contentsOfFile: path, encoding: .utf8)
        precondition(preserved == "keep", "不能删除同名普通文件")
        unlink(path)
        let target = folder + "/target"
        try "keep".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        _ = prepare()
        precondition(lstat(path, &after) == 0 && after.st_mode & S_IFMT == S_IFLNK, "不能跟随或删除符号链接")
        print("PASS stale SSH forwarding socket recovery, active listener preservation and unrelated path protection")
    }
}
