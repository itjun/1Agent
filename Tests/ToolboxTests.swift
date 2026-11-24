import AppKit
import SwiftUI
import ObjectiveC
@testable import Natty

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
        let suite = "natty.toolbox.\(UUID())"
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
        precondition(model.commandSidebars[a.id]?.isExpanded == true, "同一分屏共用一列命令栏，从 B 打开后 A 也算展开")
        precondition(model.commandSidebarTab(in: state)?.id == b.id, "命令栏显示当前终端 B 的命令")
        let hideCommands = TerminalPaneActions.items(tab: b, model: model, window: state)
            .first { $0.title == String(localized: "Hide Quick Commands") }!
        precondition(hideCommands.key == "b" && hideCommands.modifiers == [.command, .shift])
        AppShortcuts.setChords([.toggleToolSidebar: KeyChord(key: "j", modifiers: [.command, .option])])
        let customToggle = TerminalPaneActions.items(tab: b, model: model, window: state)
            .first { $0.title == String(localized: "Hide Quick Commands") }!
        precondition(customToggle.key == "j" && customToggle.modifiers == [.command, .option], "右键菜单跟随自定义快捷键")
        AppShortcuts.resetToDefault(.toggleToolSidebar)
        precondition(NSApp.windows.count == initialWindows, "快捷命令属于终端窗口")
        let widthBeforeFocusChange = TerminalCanvas.commandSidebarWidth(model.sharedCommandSidebar(for: b.id), canvasWidth: 900)
        model.selectOnly(a.id, in: state, focusTerminal: false)
        precondition(model.commandSidebarTab(in: state)?.id == a.id, "切到 A 后命令栏跟着显示 A 的命令")
        precondition(widthBeforeFocusChange > 0
                     && TerminalCanvas.commandSidebarWidth(model.sharedCommandSidebar(for: a.id), canvasWidth: 900) == widthBeforeFocusChange,
                     "切换焦点不改变命令栏宽度，终端不用重排")
        precondition(TerminalPaneActions.items(tab: b, model: model, window: state)
            .contains { $0.title == String(localized: "Hide Quick Commands") }, "未聚焦终端的菜单也反映分屏共用的状态")
        let selection = UUID()
        model.commandSidebars[a.id]?.selectedCommandID = selection
        model.toggleToolSidebar(in: state)
        precondition(model.commandSidebars[a.id]?.isExpanded == false && model.commandSidebars[b.id]?.isExpanded == false,
                     "在 A 收起，整个分屏的命令栏一起收起")
        precondition(TerminalPaneActions.items(tab: b, model: model, window: state)
            .contains { $0.title == String(localized: "Show Quick Commands") }, "收起后 B 的菜单显示展开入口")
        model.selectOnly(b.id, in: state, focusTerminal: false)
        precondition(model.sharedCommandSidebar(for: b.id) == nil, "切到 B 不会重新展开")
        model.toggleToolSidebar(in: state)
        precondition(model.commandSidebars[a.id]?.isExpanded == true && model.commandSidebars[b.id]?.isExpanded == true,
                     "在 B 展开，整个分屏一起展开")
        precondition(model.commandSidebars[a.id]?.selectedCommandID == selection, "展开收起不影响各终端选中的命令")
        model.updateSharedCommandSidebar(for: b.id) { $0.width = 310 }
        precondition(model.commandSidebars[a.id]?.width == 310 && model.commandSidebars[b.id]?.width == 310,
                     "拖宽对整个分屏生效")
        precondition(model.commandSidebars[a.id]?.selectedCommandID == selection && model.commandSidebars[b.id]?.selectedCommandID == nil,
                     "选中的命令仍按终端各自保存")
        let otherWindow = WindowState()
        model.toggleCommandSidebar(for: a.id, in: otherWindow)
        precondition(model.commandSidebars[a.id]?.isExpanded == true, "其他窗口不能修改不属于自己的终端")
        print("PASS shared split sidebar follows focus, toggles and resizes together, keeps per-terminal selection")

        model.openLocalTerminal(at: "/private/tmp", placement: .split(.right), beside: b.id, in: state)
        try await eventually { model.tabs.count == 3 }
        let c = model.tabs.first { $0.id != a.id && $0.id != b.id }!
        model.expandCommandSidebarIfNeeded(for: c)
        precondition(model.commandSidebars[c.id] == TerminalCommandSidebarState(isExpanded: true, width: 310),
                     "新分出来的终端沿用分屏的展开状态和宽度")
        model.closeTab(c.id)
        model.toggleCommandSidebar(for: a.id, in: state)
        model.openLocalTerminal(at: "/private/tmp", placement: .split(.right), beside: b.id, in: state)
        try await eventually { model.tabs.count == 3 }
        let d = model.tabs.first { $0.id != a.id && $0.id != b.id }!
        model.expandCommandSidebarIfNeeded(for: d)
        precondition(model.commandSidebars[d.id]?.isExpanded == false, "分屏已收起时，新终端不会自动展开")
        model.closeTab(d.id)
        model.toggleCommandSidebar(for: a.id, in: state)
        model.open(.preview(path: "/private/tmp/preview.txt"), placement: .split(.right), beside: b.id, in: state)
        try await eventually { model.tabs.count == 3 }
        let preview = model.tabs.first { !$0.hasTerminal }!
        model.selectOnly(preview.id, in: state, focusTerminal: false)
        precondition(model.commandSidebarTab(in: state)?.id == a.id && model.sharedCommandSidebar(for: preview.id) != nil,
                     "选中预览面板时命令栏不消失，显示分屏里第一个终端的命令")
        model.closeTab(preview.id)
        model.selectOnly(a.id, in: state, focusTerminal: false)
        model.commandSidebars[a.id] = TerminalCommandSidebarState(isExpanded: false, width: 250)
        model.commandSidebars[b.id] = TerminalCommandSidebarState(isExpanded: true, width: 300)
        precondition(model.sharedCommandSidebar(for: a.id)?.width == 300, "旧存档里只有 B 展开时，命令栏用 B 的宽度")
        model.toggleCommandSidebar(for: a.id, in: state)
        model.toggleCommandSidebar(for: a.id, in: state)
        precondition(model.sharedCommandSidebar(for: a.id)?.width == 300, "收起再展开后宽度不变")
        print("PASS new split terminals follow the shared state and preview panes keep the sidebar")

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
        let width = TerminalCanvas.commandSidebarWidth(expanded, canvasWidth: frame.width)
        let area = TerminalCanvas.paneArea(frame, commandSidebarWidth: width)
        precondition(area.minX == frame.minX && area.minY == frame.minY && area.height == frame.height)
        precondition(frame.width - area.width == width + 5, "command island keeps the same 5pt gap as the internal splits")
        precondition(TerminalCanvas.paneArea(frame, commandSidebarWidth: 0) == frame, "收起后分屏占满整个画布")
        precondition(TerminalCanvas.commandSidebarWidth(nil, canvasWidth: 900) == 0)
        precondition(TerminalCanvas.commandSidebarWidth(TerminalCommandSidebarState(), canvasWidth: 900) == 0)
        precondition(TerminalCanvas.commandSidebarWidth(expanded, canvasWidth: 300) == 0)
        precondition(TerminalCanvas.commandSidebarWidth(expanded, canvasWidth: 900) == width)
        precondition(TerminalCanvas.commandSidebarWidth(TerminalCommandSidebarState(isExpanded: true, width: 2000), canvasWidth: 500) == 315)
        print("PASS shared sidebar reserves one canvas column without changing pane header/search geometry and restores after narrow layout")
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
