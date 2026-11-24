import AppKit
import Carbon
import Darwin
import Foundation
import GhosttyTerminal
import ObjectiveC
@testable import agent

/// Runs AppKit's real resize/layout callbacks, including callbacks outside a Swift task.
@main enum TerminalWindowsTests {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--password-fixture") {
            var attributes = termios()
            guard tcgetattr(STDIN_FILENO, &attributes) == 0 else { exit(2) }
            let original = attributes
            attributes.c_lflag &= ~tcflag_t(ECHO)
            attributes.c_lflag |= tcflag_t(ICANON)
            guard tcsetattr(STDIN_FILENO, TCSANOW, &attributes) == 0 else { exit(2) }
            var buffer = [UInt8](repeating: 0, count: 32)
            _ = read(STDIN_FILENO, &buffer, buffer.count)
            var restored = original
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &restored)
            while true { pause() }
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                if CommandLine.arguments.contains(where: { $0.hasSuffix("compatibility") }) {
                    try await TerminalCompatibilityTests.run()
                    print("TerminalCompatibilityTests passed")
                } else {
                    try await run()
                    if CommandLine.arguments.contains("--command-drag") {
                        print("TerminalWindowsTests passed: repeated window switching and real command drag execution")
                    } else {
                        print("TerminalWindowsTests passed: saved windows merge into one, 24 terminals, 720 AppKit resizes, ownership, recovery and secure input lifecycle")
                    }
                }
                exit(0)
            }
            catch {
                let name = CommandLine.arguments.contains(where: { $0.hasSuffix("compatibility") }) ? "TerminalCompatibilityTests" : "TerminalWindowsTests"
                fputs("\(name) failed: \(error)\n", stderr)
                exit(1)
            }
        }
        NSApp.run()
    }
    struct Failure: Error { let message: String }
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    @MainActor static func run() async throws {
        guard let home = ProcessInfo.processInfo.environment["ONEAGENT_TEST_HOME"] else {
            throw Failure(message: "Missing isolated test home")
        }
        let homeURL = URL(fileURLWithPath: home).resolvingSymlinksInPath()
        let temporaryURL = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()
        try check(homeURL.deletingLastPathComponent().deletingLastPathComponent() == temporaryURL && homeURL.deletingLastPathComponent().lastPathComponent.hasPrefix("oneagent-terminal-windows."), "Test home must be isolated")
        try check(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == homeURL, "Foundation must use the isolated test home")
        let suite = "oneagent.window-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let getter = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard))!
        let old = method_setImplementation(getter, imp_implementationWithBlock({ _ in defaults } as @convention(block) (AnyObject) -> UserDefaults))
        defer { method_setImplementation(getter, old); defaults.removePersistentDomain(forName: suite) }
        let firstTab = UUID(), firstWindow = UUID(), secondTab = UUID(), secondWindow = UUID()
        installTerminal(firstTab, home: home)
        installTerminal(secondTab, home: home)
        let fixture = SessionSnapshot(tabs: [.init(id: firstTab, directory: home), .init(id: secondTab, directory: home)], workspaces: [], windows: [
            .init(id: firstWindow, blocks: [.localGroup, .ungrouped], localGroup: [firstTab], ungrouped: [], selected: firstTab),
            .init(id: secondWindow, blocks: [.localGroup, .ungrouped], localGroup: [secondTab], ungrouped: [], selected: secondTab)
        ], keyWindow: firstWindow)
        defaults.set(try JSONEncoder().encode(fixture), forKey: SessionSnapshot.storageKey)
        let model = AppModel()
        TerminalAutomation.model = model
        MainWindowManager.shared.attach(model: model)
        model.restoreLastSession()
        for _ in 0..<500 { if model.tabs.count == 2 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try check(model.windows.count == 1, "Saved windows merge into the one 1Agent window")
        let main = model.mainWindow
        try check(main.id == firstWindow && model.keyWindow?.id == firstWindow, "The merged window keeps the first saved window identity")
        try check(Set(model.sidebarOrder(in: main)) == [firstTab, secondTab], "Every saved terminal is listed in the one sidebar")
        let scriptWindow = TerminalAutomation.window(firstWindow)
        try check(scriptWindow.objectSpecifier?.descriptor != nil, "A returned script window must serialize to a real Apple event object reference")
        try check((scriptWindow.objectSpecifier?.objectsByEvaluatingSpecifier as? ScriptTerminalWindow)?.uuid == firstWindow, "Returned script object references must resolve by stable ID")
        model.createWorkspace(from: [firstTab, secondTab], atBlockIndex: 0, in: main)
        let grouped = model.workspaces.first(where: \.isGrouped)!
        try check(Set(model.sidebarOrder(in: main)) == [firstTab, secondTab], "A group owns both complete rows")
        model.dissolveWorkspace(grouped.id)
        let native = MainWindowManager.shared.window(for: main)!
        let workspaceView = SSHTerminalRegistry.automationView("\(main.selectedTabID!.uuidString)#0")!
        // 模型恢复早于异步 PTY 启动，必须等到真实进程就绪后再记录要保留的 PID。
        for _ in 0..<500 {
            if workspaceView.processHost!.process.shellPid > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(workspaceView.processHost!.process.shellPid > 0, "Workspace terminal process must finish starting")
        let workspacePID = workspaceView.processHost!.process.shellPid
        if CommandLine.arguments.contains("--command-drag") {
            defer { model.closeTab(firstTab); model.closeTab(secondTab); native.close() }
            try await commandDrag(model, home: home)
            return
        }
        // 覆盖当前版本支持的非终端页面，不依赖尚未合入的页面枚举。
        for section in ["files", "commands"].compactMap({ AppSection(rawValue: $0) }) {
            main.section = section
            try await Task.sleep(for: .milliseconds(300))
            try check((workspaceView.superview as? TerminalHostView)?.isHidden == true,
                      "Leaving Terminals for \(section.rawValue) must hide the native terminal surface")
            model.hideFiles(in: main)
            try await Task.sleep(for: .milliseconds(300))
            try check((workspaceView.superview as? TerminalHostView)?.isHidden == false &&
                      workspaceView.processHost!.process.shellPid == workspacePID,
                      "Returning from \(section.rawValue) must reveal the same terminal process: hidden=\(String(describing: (workspaceView.superview as? TerminalHostView)?.isHidden)), pid=\(workspacePID) -> \(workspaceView.processHost!.process.shellPid)")
        }
        for iteration in 0..<24 {
            let config = try TerminalCreationConfiguration(record: ["workingDirectory": home])
            let terminal = try await model.createScriptTerminal(configuration: config, in: main)
            installTerminal(terminal, home: home)
            try check(model.windows.count == 1 && model.window(containing: terminal)?.id == main.id, "A new terminal joins the one window")
            for frame in 0..<30 {
                native.setContentSize(NSSize(width: 900 + (frame * 17) % 300, height: 560 + (frame * 11) % 180))
                native.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            model.closeTab(terminal)
            try await Task.sleep(nanoseconds: 10_000_000)
            try check(model.tabs.contains { $0.id == firstTab } && model.tabs.contains { $0.id == secondTab }, "Closing terminal \(iteration) must preserve unrelated sessions")
            try check(!model.tabs.contains { $0.id == terminal }, "Closed terminal \(iteration) must be released")
        }
        model.persistSessionIfReady()
        let saved = SessionSnapshot.load()!
        try check(saved.windows?.count == 1 && saved.tabs.count == 2, "The saved session has one window with the two original sessions")
        try await secureInput(model, home: home)
        native.orderOut(nil)
    }

    /// 完整工作区、真实 ZLE 通道和鼠标事件分发，不能用按钮执行或回调计数代替。
    @MainActor static func commandDrag(_ model: AppModel, home: String) async throws {
        TerminalActivity.shared.model = model
        let state = model.mainWindow, id = state.selectedTabID!
        let otherID = model.tabs.first { $0.id != id }!.id
        let native = MainWindowManager.shared.window(for: state)!
        let terminal = SSHTerminalRegistry.automationView("\(id.uuidString)#0")!
        let host = terminal.processHost!
        try "PS1='DRAG_READY> '\n".write(toFile: home + "/.zshrc", atomically: true, encoding: .utf8)
        let environment = ["PATH=/usr/bin:/bin", "HOME=" + home, "ZDOTDIR=" + home, "TERM=xterm-256color"]
        let integration = ShellIntegrationEnvironment.variables(settings: .defaults, shellPath: "/bin/zsh",
            resourcesPath: Bundle.main.resourcePath, environment: environment)
        host.updateLaunch(TerminalLaunch(executable: "/bin/zsh", args: ["-d", "-i"], environment: environment,
            directory: home, shellIntegrationEnvironment: integration))
        host.restart(notice: "拖拽验证")
        let item = QuickCommand(alias: "切换窗口拖拽验证", command: "((ONEAGENT_DRAG_COUNT+=1)); printf '\\nDRAG_CHECK_%s\\n' \"$ONEAGENT_DRAG_COUNT\"", scope: .local)
        try QuickCommandStore.shared.save(item)
        model.commandSidebars[id, default: TerminalCommandSidebarState()].isExpanded = true
        native.setContentSize(NSSize(width: 1100, height: 750))

        func eventually(_ label: String, _ predicate: () async -> Bool) async throws {
            for _ in 0..<200 {
                if await predicate() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw Failure(message: "\(label) (active=\(NSApp.isActive), key=\(NSApp.keyWindow?.title ?? "nil"), front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"))")
        }
        func bringFront() async throws {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            native.makeKeyAndOrderFront(nil)
            try await eventually("测试窗口未前置") { NSApp.isActive && native.isKeyWindow }
        }
        func handle(in view: NSView) -> QuickCommandDragHandleView? {
            if let row = view as? QuickCommandDragHandleView, row.commandID == item.id { return row }
            return view.subviews.lazy.compactMap { handle(in: $0) }.first
        }
        func output() -> String {
            host.session.waitForPendingOutput()
            return host.session.readScreenText()?.text ?? ""
        }
        func drag() throws {
            native.contentView?.layoutSubtreeIfNeeded()
            guard let content = native.contentView, let row = handle(in: content) else { throw Failure(message: "真实指令行未挂载") }
            let visible = row.bounds.intersection(row.visibleRect)
            try check(!visible.isEmpty, "指令行不可见")
            let start = row.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
            let end = terminal.convert(NSPoint(x: terminal.bounds.midX, y: terminal.bounds.midY), to: nil)
            let hitPoint = content.superview?.convert(start, from: nil) ?? start
            try check(content.hitTest(hitPoint) === row, "鼠标按下必须经过真实拖拽层")
            let screenPoint = native.convertPoint(toScreen: end)
            try check(terminal.acceptsQuickCommand(item.id), "真实终端必须接受本次命令")
            try check(QuickCommandDragHandleView.dropDestination(at: screenPoint)?.window === native,
                      "实际窗口仍被遮挡，不能把后台投递当作前台验证")
            func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: native.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            NSApp.postEvent(event(.leftMouseUp, at: end), atStart: true)
            NSApp.postEvent(event(.leftMouseDragged, at: end), atStart: true)
            NSApp.sendEvent(event(.leftMouseDown, at: start))
        }

        try await bringFront()
        try await eventually("测试 shell 的命令通道未就绪") { await SSHTerminalRegistry.quickCommandReady(terminal.sessionID!) }
        let processID = host.process.identity
        let cover = NSWindow(contentRect: native.frame.insetBy(dx: 80, dy: 80), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.title = "窗口切换验证"
        defer { cover.close() }
        for iteration in 1...30 {
            switch iteration % 3 {
            case 0:
                NSApp.hide(nil)
                try await eventually("应用未切到后台") { NSApp.isHidden && !NSApp.isActive }
            case 1:
                try await bringFront()
                cover.makeKeyAndOrderFront(nil)
                try await eventually("辅助窗口未获得焦点") { cover.isKeyWindow }
                cover.orderOut(nil)
            default:
                model.selectTab(otherID, in: state, focusTerminal: false)
                try await Task.sleep(for: .milliseconds(50))
                model.selectTab(id, in: state, focusTerminal: false)
            }
            try await bringFront()
            try await eventually("切回后的终端未就绪") { await SSHTerminalRegistry.quickCommandReady(terminal.sessionID!) }
            try drag()
            let marker = "DRAG_CHECK_\(iteration)"
            try await eventually("第 \(iteration) 次拖拽未执行；\(model.commandExecution(for: id).error ?? "无错误反馈")") {
                output().split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == marker }
            }
            try await eventually("执行状态未恢复") { !model.commandExecution(for: id).isSubmitting }
            try await eventually("执行后的 shell 未回到空闲提示符") { await SSHTerminalRegistry.quickCommandReady(terminal.sessionID!) }
            let counters = output().split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("DRAG_CHECK_") }
            try check(counters.last == marker, "每次拖拽只能执行一次，不能多投递命令")
            try check(host.process.identity == processID, "窗口切换不能重建终端进程")
        }
        print("PASS 30 real drag executions after app/window/session switching, once-only counter and same shell process")
    }

    @MainActor static func secureInput(_ model: AppModel, home: String) async throws {
        let state = model.mainWindow
        let terminal = try await model.createScriptTerminal(configuration: TerminalCreationConfiguration(record: ["workingDirectory": home]), in: state)
        installTerminal(terminal, home: home, passwordFixture: true)
        guard let native = MainWindowManager.shared.window(for: state) else { throw Failure(message: "Missing main window") }
        let view = SSHTerminalRegistry.automationView("\(terminal.uuidString)#0")!
        for _ in 0..<100 {
            if view.processHost?.process.isPasswordInput == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let process = view.processHost!.process
        try check(process.isPasswordInput, "The fixture must have ECHO off and canonical input")
        native.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        native.makeFirstResponder(view)
        TerminalSecureInput.shared.start()
        try await Task.sleep(for: .milliseconds(150))
        TerminalSecureInput.shared.refresh()
        try check(TerminalSecureInput.shared.isEnabled && IsSecureEventInputEnabled(), "Password input enables the native secure input reference (active=\(NSApp.isActive), key=\(native.isKeyWindow), focused=\(native.firstResponder === view), hidden=\(view.isHiddenOrHasHiddenAncestor), current=\(FocusedTerminal.current === view))")
        let field = NSTextField(frame: .zero)
        native.contentView?.addSubview(field)
        native.makeFirstResponder(field)
        TerminalSecureInput.shared.refresh()
        try check(!TerminalSecureInput.shared.isEnabled, "Text-field focus releases secure input")
        native.makeFirstResponder(view)
        process.write(Data("fixture\n".utf8))
        for _ in 0..<100 {
            if !process.isPasswordInput { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        TerminalSecureInput.shared.refresh()
        try check(!TerminalSecureInput.shared.isEnabled, "Restoring ECHO releases automatic secure input")
        TerminalSecureInput.shared.manual = true
        try check(TerminalSecureInput.shared.isEnabled, "Manual secure input applies to the focused terminal")
        native.makeFirstResponder(field)
        TerminalSecureInput.shared.refresh()
        try check(!TerminalSecureInput.shared.isEnabled, "Manual secure input is released outside a terminal")
        native.makeFirstResponder(view)
        TerminalSecureInput.shared.refresh()
        try check(TerminalSecureInput.shared.isEnabled, "Manual input resumes when terminal focus returns")
        field.removeFromSuperview()
        TerminalSecureInput.shared.stop()
        TerminalSecureInput.shared.manual = false
        try check(!TerminalSecureInput.shared.isEnabled, "Quit releases secure input")
        model.closeTab(terminal)
        try check(!model.tabs.contains { $0.id == terminal }, "Closing the fixture terminal releases it")
    }

    /// Real renderer and PTY, with cat instead of the user's login shell/configuration.
    @MainActor static func installTerminal(_ id: UUID, home: String, passwordFixture: Bool = false) {
        _ = SSHTerminalRegistry.view(for: "\(id.uuidString)#0") {
            let host = TerminalProcessHost()
            let view = SSHTerminalNSView(frame: .zero)
            view.sessionID = "\(id.uuidString)#0"
            view.processHost = host
            view.eventRelay.terminal = view
            view.delegate = view.eventRelay
            view.controller = GhosttyRuntime.controller
            view.configuration = TerminalSurfaceOptions(backend: .inMemory(host.session))
            host.start(TerminalLaunch(executable: passwordFixture ? CommandLine.arguments[0] : "/bin/cat", args: passwordFixture ? ["--password-fixture"] : [], environment: ["PATH=/usr/bin:/bin"], directory: home))
            return view
        }
    }
}
