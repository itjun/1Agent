import AppKit
import SwiftUI
import ObjectiveC
@testable import GooseAgent

@main enum ToolboxTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        Task { @MainActor in
            do { try await run(); print("ToolboxTests passed"); exit(0) }
            catch { fputs("ToolboxTests failed: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func run() async throws {
        let suite = "oneagent.toolbox.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let getter = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!
        let previous = method_getImplementation(getter)
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(getter, imp_implementationWithBlock(block))
        defer { method_setImplementation(getter, previous); defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(), state = model.mainWindow
        MainWindowManager.shared.show(state, model: model)
        let owner = MainWindowManager.shared.window(for: state)!
        // 真实窗口和生产路由，替换终端正文以禁止 shell 和网络访问。
        owner.contentViewController = nil
        owner.contentView = NSTextView(frame: owner.contentLayoutRect)
        defer { MainWindowManager.shared.close(state) }
        model.openLocalTerminal(at: NSHomeDirectory(), placement: .newTab, beside: UUID(), in: state)
        try await eventually { model.tabs.count == 1 }
        let a = model.tabs[0]
        model.openLocalTerminal(at: "/private/tmp", placement: .split(.right), beside: a.id, in: state)
        try await eventually { model.tabs.count == 2 }
        let b = model.tabs.first { $0.id != a.id }!
        model.selectOnly(a.id, in: state, focusTerminal: false)
        let menu = TerminalPaneActions.items(tab: b, model: model, window: state)
        let initialWindows = NSApp.windows.count
        let showCommands = menu.first { $0.title == String(localized: "Show Quick Commands") }!
        precondition(showCommands.key == "b" && showCommands.modifiers == [.command, .shift])
        showCommands.action()
        precondition(model.commandSidebars[b.id]?.isExpanded == true && state.selectedTabID == b.id)
        precondition(TerminalCanvas.commandSidebarWidth(model.commandSidebars[a.id], paneWidth: 900) == 0,
                     "打开 B 不占用 A 的正文宽度")
        let hideCommands = TerminalPaneActions.items(tab: b, model: model, window: state)
            .first { $0.title == String(localized: "Hide Quick Commands") }!
        precondition(hideCommands.key == "b" && hideCommands.modifiers == [.command, .shift])
        AppShortcuts.setChords([.toggleToolSidebar: KeyChord(key: "j", modifiers: [.command, .option])])
        let customToggle = TerminalPaneActions.items(tab: b, model: model, window: state)
            .first { $0.title == String(localized: "Hide Quick Commands") }!
        precondition(customToggle.key == "j" && customToggle.modifiers == [.command, .option], "右键菜单跟随自定义快捷键")
        AppShortcuts.resetToDefault(.toggleToolSidebar)
        precondition(NSApp.windows.count == initialWindows, "快捷命令属于终端窗口")
        model.selectOnly(a.id, in: state, focusTerminal: false)
        precondition(model.commandSidebars[a.id]?.isExpanded != true && state.selectedTabID == a.id,
                     "切换到 A 不会自动打开它的命令栏")
        precondition(TerminalCanvas.commandSidebarWidth(model.commandSidebars[b.id], paneWidth: 900) > 0,
                     "B 失去焦点后仍保留自己的命令栏")
        precondition(TerminalPaneActions.items(tab: b, model: model, window: state)
            .contains { $0.title == String(localized: "Hide Quick Commands") }, "未聚焦终端的菜单使用自身状态")
        let selection = UUID()
        model.commandSidebars[a.id] = TerminalCommandSidebarState(width: 310, selectedCommandID: selection)
        model.toggleToolSidebar(in: state)
        precondition(model.commandSidebars[a.id]?.isExpanded == true && model.commandSidebars[b.id]?.isExpanded == true,
                     "两个分屏终端可以分别打开命令栏")
        model.toggleToolSidebar(in: state)
        precondition(model.commandSidebars[a.id]?.isExpanded == false && model.commandSidebars[b.id]?.isExpanded == true,
                     "关闭 A 不影响 B")
        model.selectOnly(b.id, in: state, focusTerminal: false)
        precondition(model.commandSidebars[b.id]?.isExpanded == true, "切回 B 保留展开")
        model.selectOnly(a.id, in: state, focusTerminal: false)
        precondition(model.commandSidebars[a.id]?.isExpanded == false, "切回 A 保留收起")
        model.toggleToolSidebar(in: state)
        precondition(model.commandSidebars[a.id]?.selectedCommandID == selection && model.commandSidebars[a.id]?.width == 310)
        let otherWindow = WindowState()
        model.toggleCommandSidebar(for: a.id, in: otherWindow)
        precondition(model.commandSidebars[a.id]?.isExpanded == true, "其他窗口不能修改不属于自己的终端")
        print("PASS independent terminal sidebars, split focus retention, isolated toggles and width/selection retention")

        let old = model.commandContext(in: state, targetTabID: b.id)
        model.selectOnly(a.id, in: state, focusTerminal: false)
        precondition(model.commandContext(in: state, targetTabID: b.id) == old, "焦点变化不影响指定终端")
        model.noteWorkingDirectory(NSHomeDirectory(), forSession: b.sessionID)
        try await eventually { model.commandContext(in: state, targetTabID: b.id).directory != old.directory }
        let command = QuickCommand(alias: "fixture", command: "printf test", scope: .local)
        let request = try QuickCommandRunRequest(item: command, context: old, directory: old.directory!)
        do {
            try await model.executeQuickCommand(request, in: state, newTerminal: false, targetTabID: b.id)
            preconditionFailure("旧目录执行快照必须被拒绝")
        } catch QuickCommandError.changedTarget { }
        let foreign = WindowState()
        precondition(model.commandContext(in: foreign, targetTabID: b.id).sessionID == nil)
        model.closeTab(b.id)
        precondition(model.commandSidebars[b.id] == nil)
        precondition(model.commandContext(in: state, targetTabID: b.id).sessionID == nil, "关闭后不会改绑其他终端")
        precondition(model.commandSidebars[a.id]?.isExpanded == true, "关闭 B 不影响 A 的命令栏")
        print("PASS captured target, cwd changes, foreign windows and closed terminal rejection")

        model.openRemoteTerminal("commands-fixture", at: "/srv/test", placement: .newTab, beside: a.id, in: state)
        try await eventually { model.tabs.count == 2 }
        let remote = model.tabs.first { !$0.isLocal }!
        precondition(model.commandSidebars[remote.id]?.isExpanded != true, "新终端默认收起命令栏")
        model.toggleCommandSidebar(for: remote.id, in: state)
        model.selectOnly(a.id, in: state, focusTerminal: false)
        precondition(model.commandContext(in: state, targetTabID: remote.id).host == "commands-fixture")
        model.noteWorkingDirectory("/srv/next", forSession: remote.sessionID)
        precondition(model.commandContext(in: state, targetTabID: remote.id).directory == "/srv/next")
        model.markClosed(remote.id, lived: 0)
        precondition(!model.commandContext(in: state, targetTabID: remote.id).isLive)
        print("PASS remote directory tracking and disconnected terminal")

        let frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        let expanded = TerminalCommandSidebarState(isExpanded: true)
        let width = TerminalCanvas.commandSidebarWidth(expanded, paneWidth: frame.width)
        let before = TerminalCanvas.terminalContentFrame(frame, isFloating: false, accessoryHeight: 30)
        let after = TerminalCanvas.terminalContentFrame(frame, isFloating: false, accessoryHeight: 30, commandSidebarWidth: width)
        precondition(before.minX == after.minX && before.minY == after.minY && before.height == after.height)
        precondition(before.width - after.width == width)
        precondition(TerminalCanvas.commandSidebarWidth(nil, paneWidth: 900) == 0)
        precondition(TerminalCanvas.commandSidebarWidth(TerminalCommandSidebarState(), paneWidth: 900) == 0)
        precondition(TerminalCanvas.commandSidebarWidth(expanded, paneWidth: 300) == 0)
        precondition(TerminalCanvas.commandSidebarWidth(expanded, paneWidth: 900) == width)
        precondition(TerminalCanvas.commandSidebarWidth(TerminalCommandSidebarState(isExpanded: true, width: 2000), paneWidth: 500) == 320)
        print("PASS sidebar reserves terminal width without changing header/search geometry and restores after narrow layout")
    }

    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func value(_ element: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
    }
    @MainActor static func element(_ id: String, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if value(object, "accessibilityIdentifier") as? String == id { return object }
            for child in value(object, "accessibilityChildren") as? [NSObject] ?? [] {
                if let match = find(child) { return match }
            }
            return nil
        }
        return find(root)
    }
    @MainActor static func press(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
    }
    @MainActor static func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(6)
        while !predicate() {
            guard Date() < deadline else { throw NSError(domain: "ToolboxTests.timeout", code: 1) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
