import AppKit
import ObjectiveC
@testable import Natty

/// 使用真实保存和恢复入口；隔离偏好，不启动 Shell 或 SSH。
@main enum CommandSidebarRestorationTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            do { try await run(); print("CommandSidebarRestorationTests passed"); exit(0) }
            catch { fputs("CommandSidebarRestorationTests failed: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }

    struct Failure: Error { let message: String }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
    }

    @MainActor static func run() async throws {
        let home = ProcessInfo.processInfo.environment["NATTY_TEST_HOME"]!
        precondition(home.hasPrefix("/private/tmp/natty-command-sidebar-restoration."))
        precondition(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
                     == URL(fileURLWithPath: home).resolvingSymlinksInPath())
        let suite = "natty.command-sidebar-restoration.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let getter = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!
        let previous = method_getImplementation(getter)
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(getter, imp_implementationWithBlock(block))
        defer { method_setImplementation(getter, previous); defaults.removePersistentDomain(forName: suite) }

        let id = UUID(), remoteID = UUID(), hostID = UUID(), untouchedID = UUID()
        let snapshot = SessionSnapshot(tabs: [
            .init(id: id, directory: home), .init(id: remoteID, alias: "sidebar-fixture"),
            .init(id: untouchedID, directory: "/private/tmp"), .init(id: hostID, alias: "build-fixture")
        ], workspaces: [], windows: [
            .init(id: UUID(), blocks: [.localGroup, .ungrouped], localGroup: [id, untouchedID],
                  ungrouped: [remoteID, hostID], selected: id)
        ], keyWindow: nil)
        defaults.set(try JSONEncoder().encode(snapshot), forKey: SessionSnapshot.storageKey)
        let model = try await restore(tabCount: 4)
        let store = QuickCommandStore.shared
        try store.save(QuickCommand(alias: "公共", command: "pwd", scope: .all))
        try store.save(QuickCommand(alias: "本地目录", command: "pwd", scope: .directory, directory: home))
        try store.save(QuickCommand(alias: "远程目录", command: "pwd", scope: .directory, host: "sidebar-fixture", directory: "/project"))
        try store.save(QuickCommand(alias: "主机", command: "pwd", scope: .host, host: "build-fixture"))
        for tab in model.tabs { model.expandCommandSidebarIfNeeded(for: tab) }
        try check(model.commandSidebars[id]?.isExpanded == true, "旧存档中无状态的本地终端按目录展开")
        try check(model.commandSidebars[untouchedID] == nil, "仅匹配公共命令时收起")
        try check(model.commandSidebars[remoteID] == nil, "远程目录尚未报告时收起")
        try check(model.commandSidebars[hostID]?.isExpanded == true, "匹配 SSH 主机时直接展开")
        guard let remote = model.tabs.first(where: { $0.id == remoteID }) else { throw Failure(message: "缺少测试终端") }
        model.noteWorkingDirectory("/project", forSession: remote.sessionID)
        for tab in model.tabs { model.expandCommandSidebarIfNeeded(for: tab) }
        try check(model.commandSidebars[remoteID]?.isExpanded == true, "首次报告的远程目录匹配时展开")
        let localSelection = UUID(), remoteSelection = UUID()
        model.commandSidebars[id]?.width = 310
        model.commandSidebars[id]?.selectedCommandID = localSelection
        model.commandSidebars[remoteID]?.width = 350
        model.commandSidebars[remoteID]?.selectedCommandID = remoteSelection
        try check(model.commandSidebars[id]?.isExpanded == true, "保存前命令栏已展开")
        try check(SessionSnapshot.load()?.tabs.first { $0.id == id }?.commandSidebar == model.commandSidebars[id],
                  "改变展开状态、宽度和选择后及时保存")
        try await model.prepareForApplicationExit(detachProcesses: false)

        let restored = try await restore(tabCount: 4)
        try check(restored.commandSidebars[id]?.isExpanded == true, "重新启动后应恢复已展开的命令栏")
        try check(restored.commandSidebars[id] == model.commandSidebars[id], "本地终端恢复宽度和选中命令")
        try check(restored.commandSidebars[remoteID] == model.commandSidebars[remoteID], "SSH 终端恢复自己的命令栏状态")
        try check(restored.commandSidebars[untouchedID] == nil, "未打开的命令栏仍保持默认收起")
        try check(TerminalCanvas.commandSidebarWidth(restored.sharedCommandSidebar(for: id), canvasWidth: 900) == 310,
                  "恢复的命令栏在正常窗口宽度下可见")
        try check(!restored.commandExecution(for: id).isSubmitting, "恢复界面不会恢复命令执行")
        print("PASS local/SSH sidebar expansion, width, selection, legacy defaults and visible layout")

        restored.commandSidebars[id]?.isExpanded = false
        try check(SessionSnapshot.load()?.tabs.first { $0.id == id }?.commandSidebar?.isExpanded == false,
                  "Esc 等直接收起命令栏的入口也及时保存")
        try await restored.prepareForApplicationExit(detachProcesses: false)
        let collapsed = try await restore(tabCount: 4)
        try store.save(QuickCommand(alias: "本机", command: "pwd", scope: .local))
        for tab in collapsed.tabs { collapsed.expandCommandSidebarIfNeeded(for: tab) }
        try check(collapsed.commandSidebars[untouchedID]?.isExpanded == true, "本机命令对其他本地终端生效")
        try check(collapsed.commandSidebars[id]?.isExpanded == false, "主动收起后再次启动仍保持收起")
        try check(collapsed.commandSidebars[id]?.width == 310 && collapsed.commandSidebars[id]?.selectedCommandID == localSelection,
                  "收起不丢失宽度和选中命令")
        try check(collapsed.commandSidebars[remoteID]?.isExpanded == true, "收起本地终端不影响 SSH 命令栏")
        collapsed.closeTab(remoteID)
        try await collapsed.prepareForApplicationExit(detachProcesses: false)
        let closed = try await restore(tabCount: 3)
        try check(closed.commandSidebars[remoteID] == nil, "已关闭终端不留下命令栏状态")
        print("PASS collapsed state, independent terminals and closed terminal cleanup")
    }

    @MainActor static func restore(tabCount: Int) async throws -> AppModel {
        let model = AppModel()
        model.restoreLastSession()
        let native = MainWindowManager.shared.window(for: model.mainWindow)!
        native.contentViewController = nil
        native.contentView = NSView(frame: native.contentLayoutRect)
        let deadline = Date().addingTimeInterval(6)
        while model.tabs.count != tabCount {
            try check(Date() < deadline, "会话恢复超时")
            try await Task.sleep(for: .milliseconds(20))
        }
        return model
    }
}
