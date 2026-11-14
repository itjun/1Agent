import AppKit
import GhosttyTerminal
@testable import GooseAgent

@main enum HostedTerminalTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); print("HostedTerminalTests passed: \(CommandLine.arguments[1])"); exit(0) }
            catch { fputs("HostedTerminalTests failed: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func run() async throws {
        let phase = CommandLine.arguments[1], folder = CommandLine.arguments[2]
        let id = CommandLine.arguments[3] + "#3"
        let fixture = CommandLine.arguments[4], python = CommandLine.arguments[5]
        let log = folder + "/launches"
        let host = TerminalProcessHost(sessionID: id)
        let launch = TerminalLaunch(executable: python, args: [fixture, log], environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"], directory: folder)
        let view = SSHTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.sessionID = id
        view.processHost = host
        view.eventRelay.terminal = view
        view.delegate = view.eventRelay
        view.controller = GhosttyRuntime.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(host.session))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        if phase == "--save" { host.session.receive("HISTORY_BEFORE_SHELL\r\n") }
        host.start(launch)
        try await wait("TUI ready") { host.session.waitForPendingOutput(); return host.session.readScreenText()?.text.contains("TUI_READY") == true }
        let pid = host.process.shellPid
        precondition(pid > 0)
        if phase == "--save" {
            try String(pid).write(toFile: folder + "/pid", atomically: true, encoding: .utf8)
            host.process.write(Data("d".utf8))
            // 强制结束 UI 进程也必须保留后台会话；故意不调用 detach。
            return
        }
        let savedPID = Int32(try String(contentsOfFile: folder + "/pid"))
        let launchCount = try String(contentsOfFile: log).split(separator: "\n").count
        precondition(pid == savedPID, "PID changed across GUI process relaunch")
        precondition(launchCount == (phase == "--close" ? 2 : 1), "Startup command reran")
        if phase == "--close" {
            host.terminate()
            try await wait("explicit close after graceful relaunch") { !TerminalSessionConnection.hasSession(id) && kill(pid, 0) != 0 }
            window.close()
            try await quickCommandContinuity(folder: folder)
            try await unresponsiveHelperClose(folder: folder)
            return
        }
        try await wait("background output") { host.session.waitForPendingOutput(); return host.session.readScreenText()?.text.contains("DETACHED_OUTPUT") == true }
        // 接回后由真正的 GUI 引擎回答光标查询；验证快照的光标位置。
        host.process.write(Data("q".utf8))
        try await wait("cursor query reply") { host.session.waitForPendingOutput(); return host.session.readScreenText()?.text.contains("QUERY_REPLY:1b5b363b313752") == true }
        host.process.write(Data("HELLO_AFTER_REATTACH".utf8))
        try await wait("input") { host.session.waitForPendingOutput(); return host.session.readScreenText()?.text.contains("INPUT:HELLO_AFTER_REATTACH") == true }
        host.process.write(Data("l".utf8))
        try await wait("large input ready") { host.session.waitForPendingOutput(); return host.session.readScreenText()?.text.contains("LARGE_READY") == true }
        host.process.write(Data(repeating: 122, count: 2 * 1024 * 1024 + 123))
        try await wait("large input preserved") { host.session.waitForPendingOutput(); return host.session.readScreenText()?.text.contains("LARGE_INPUT_COMPLETE") == true }
        host.process.write(Data("p".utf8))
        try await wait("primary screen") { host.session.waitForPendingOutput(); let text = host.session.readScreenText()?.text ?? ""; return text.contains("HISTORY_BEFORE_SHELL") && text.contains("PRIMARY_HISTORY") && text.contains("PRIMARY_RETURN") }
        host.restart(notice: "TEST_RESTART")
        try await wait("new process after explicit restart") { host.process.shellPid > 0 && host.process.shellPid != pid }
        try await wait("second launch") { ((try? String(contentsOfFile: log)) ?? "").split(separator: "\n").count == 2 }
        try await wait("restarted TUI") { host.session.waitForPendingOutput(); return host.session.readScreenText()?.text.contains("TUI_READY") == true }
        try String(host.process.shellPid).write(toFile: folder + "/pid", atomically: true, encoding: .utf8)
        host.detachForApplicationExit()
        window.close()

        // 用户快速关闭刚创建的终端，不能漏出一个后台 shell。
        let fastID = UUID().uuidString + "#0"
        try recordSession(fastID, folder: folder)
        let process = TerminalProcess()
        process.startHosted(sessionID: fastID, executable: "/bin/cat", args: [], environment: ["PATH=/usr/bin:/bin"], directory: folder, columns: 80, rows: 24) { _ in }
        process.terminate()
        try await Task.sleep(for: .milliseconds(500))
        try await wait("close while starting") { !TerminalSessionConnection.hasSession(fastID) }
    }

    @MainActor static func quickCommandContinuity(folder: String) async throws {
        let id = UUID().uuidString + "#0"
        try recordSession(id, folder: folder)
        let home = folder + "/shell"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try "PS1='HOSTED_QC> '\n".write(toFile: home + "/.zshrc", atomically: true, encoding: .utf8)
        let environment = ["PATH=/usr/bin:/bin", "HOME=" + home, "ZDOTDIR=" + home, "TERM=xterm-256color"]
        let variables = ShellIntegrationEnvironment.variables(settings: .defaults, shellPath: "/bin/zsh", resourcesPath: Bundle.main.resourcePath, environment: environment)
        var bridge: LocalCommandBridge? = LocalCommandBridge(sessionID: id)!
        let token = bridge!.token
        let process = TerminalProcess()
        var isReady = false
        process.startHosted(sessionID: id, executable: "/bin/zsh", args: ["-d", "-i"],
            environment: ShellIntegrationEnvironment.merged(environment, overrides: variables) + bridge!.environment,
            directory: home, columns: 80, rows: 24) { value in Task { @MainActor in isReady = value } }
        defer { process.terminate(); TerminalSessionConnection.terminateDetached(id) }
        try await wait("shell attach") { isReady }
        var isPrompt = false
        for _ in 0..<20 { if await bridge!.query() { isPrompt = true; break }; try await Task.sleep(for: .milliseconds(50)) }
        precondition(isPrompt, "Initial quick-command probe failed")
        let pid = process.shellPid
        bridge!.isPreserved = true; bridge = nil
        process.detach()
        try await Task.sleep(for: .milliseconds(100))
        bridge = LocalCommandBridge(sessionID: id)!
        precondition(bridge!.token == token, "Bridge token must survive reattach")
        let restored = TerminalProcess()
        defer { restored.terminate() }
        isReady = false
        restored.startHosted(sessionID: id, executable: "/bin/false", args: [], environment: environment, directory: home, columns: 80, rows: 24) { value in Task { @MainActor in isReady = value } }
        try await wait("shell reattach") { isReady }
        precondition(restored.shellPid == pid)
        let isAvailable = await bridge!.query()
        precondition(isAvailable, "Quick-command channel disappeared after detach")
        let wake = try await bridge!.run(id: UUID(), script: "printf ok > hosted-result", expectedDirectory: restored.currentWorkingDirectory!)
        if wake { restored.write(Data([0])) }
        try await wait("quick command result") { (try? String(contentsOfFile: home + "/hosted-result")) == "ok" }
        restored.terminate()
        try await wait("shell cleanup") { !TerminalSessionConnection.hasSession(id) }
    }

    static func recordSession(_ id: String, folder: String) throws {
        let path = folder + "/sessions"
        let previous = (try? String(contentsOfFile: path)) ?? ""
        try (previous + id + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    @MainActor static func unresponsiveHelperClose(folder: String) async throws {
        for isDetached in [false, true] {
            let id = UUID().uuidString + "#0"
            try recordSession(id, folder: folder)
            let process = TerminalProcess()
            var isReady = false
            process.startHosted(sessionID: id, executable: "/bin/cat", args: [],
                environment: ["PATH=/usr/bin:/bin"], directory: folder, columns: 80, rows: 24) { value in
                    Task { @MainActor in isReady = value }
                }
            try await wait("helper ready") { isReady && process.shellPid > 0 }
            let child = process.shellPid
            var info = proc_bsdinfo()
            precondition(proc_pidinfo(child, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0)
            let helper = pid_t(info.pbi_ppid)
            precondition(helper > 1)
            if isDetached { process.detach(); try await Task.sleep(for: .milliseconds(100)) }
            // 模拟升级前的后台进程卡住：K 无响应，SIGTERM 也不能及时处理。
            precondition(kill(helper, SIGSTOP) == 0)
            defer {
                kill(helper, SIGCONT)
                process.terminate()
                TerminalSessionConnection.terminateDetached(id)
            }
            if isDetached { TerminalSessionConnection.terminateDetached(id) } else { process.terminate() }
            try await wait("unresponsive helper cleanup, detached=\(isDetached)", attempts: 500) {
                !TerminalSessionConnection.hasSession(id) && kill(child, 0) != 0 && kill(helper, 0) != 0
            }
            precondition(!FileManager.default.fileExists(atPath: TerminalSessionConnection.folder(for: id)!))
        }
    }

    @MainActor static func wait(_ label: String, attempts: Int = 300, until condition: () -> Bool) async throws {
        for _ in 0..<attempts { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw NSError(domain: "HostedTerminalTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
    }
}
