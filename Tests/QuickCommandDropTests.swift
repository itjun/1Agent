import AppKit
import ObjectiveC
@testable import GooseAgent

/// Production drop routing with native terminal views, isolated storage and no PTYs.
@main enum QuickCommandDropTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run(); print("QuickCommandDropTests passed"); exit(0) }
            catch { fputs("QuickCommandDropTests failed: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }

    @MainActor private static func run() async throws {
        let home = ProcessInfo.processInfo.environment["ONEAGENT_TEST_HOME"]!
        precondition(home.hasPrefix("/private/tmp/oneagent-quick-command-drop."))
        precondition(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
                     == URL(fileURLWithPath: home).resolvingSymlinksInPath())
        let suite = "oneagent.command-drop.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let getter = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!
        let previous = method_getImplementation(getter)
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(getter, imp_implementationWithBlock(block))
        defer { method_setImplementation(getter, previous); defaults.removePersistentDomain(forName: suite) }

        let model = AppModel(), window = model.mainWindow
        MainWindowManager.shared.show(window, model: model)
        // Keep a real visible destination window, but remove SwiftUI before adding
        // model tabs so no terminal view can launch a shell in this fixture.
        let nativeWindow = MainWindowManager.shared.window(for: window)!
        nativeWindow.contentViewController = nil
        nativeWindow.contentView = NSView(frame: nativeWindow.contentLayoutRect)
        nativeWindow.orderFrontRegardless()
        defer { MainWindowManager.shared.close(window) }
        TerminalActivity.shared.model = model
        model.openLocalTerminal(at: home, placement: .newTab, beside: UUID(), in: window)
        await wait { model.tabs.count == 1 }
        let left = model.tabs[0]
        let folder = home + "/目标 文件夹"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        model.openLocalTerminal(at: folder, placement: .split(.right), beside: left.id, in: window)
        await wait { model.tabs.count == 2 }
        let right = model.tabs.first { $0.id != left.id }!
        model.selectTab(left.id, in: window, focusTerminal: false)

        let store = QuickCommandStore.shared
        precondition(store.url.resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/"),
                     "Never write the real command library: \(store.url.path), fixture: \(home)")
        let item = QuickCommand(alias: "Fixture", command: "printf '%s\\n' 'drag fixture'", scope: .local)
        try store.save(item)
        let terminal = SSHTerminalNSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        terminal.sessionID = right.sessionID
        terminal.canDropQuickCommand = { model.commandForDrop($0, on: right.id, in: window) != nil }
        terminal.onQuickCommandDrop = { model.runDroppedQuickCommand($0, on: right.id, in: window) }
        nativeWindow.contentView?.addSubview(terminal)
        precondition(model.commandForDrop(item.id, on: right.id, in: window) != nil)
        precondition(TerminalActivity.shared.isOnScreen(sessionID: right.sessionID), "Fixture destination must be visible")
        precondition(QuickCommandDragHandleView.terminal(at: NSPoint(x: 200, y: 200), in: nativeWindow) === terminal)
        precondition(QuickCommandDragHandleView.terminal(at: NSPoint(x: -100, y: -100), in: nativeWindow) == nil)
        // 工具箱独立后，落点必须按屏幕坐标解析到实际窗口。
        nativeWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let screenPoint = nativeWindow.convertPoint(toScreen: NSPoint(x: 200, y: 200))
        try await Task.sleep(for: .milliseconds(150))
        let drop = QuickCommandDragHandleView.dropDestination(at: screenPoint)
        precondition(drop?.window === nativeWindow)
        precondition(QuickCommandDragHandleView.terminal(at: drop!.point, in: drop!.window) === terminal)
        let cover = NSPanel(contentRect: NSRect(x: screenPoint.x - 40, y: screenPoint.y - 40, width: 80, height: 80),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.level = .popUpMenu
        cover.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        cover.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(100))
        let blockedDrop = QuickCommandDragHandleView.dropDestination(at: screenPoint)
        precondition(blockedDrop?.window === cover, "不能穿过前方窗口执行后台终端命令")
        precondition(QuickCommandDragHandleView.terminal(at: blockedDrop!.point, in: blockedDrop!.window) == nil)
        cover.ignoresMouseEvents = true
        try await Task.sleep(for: .milliseconds(100))
        precondition(QuickCommandDragHandleView.dropDestination(at: screenPoint)?.window === nativeWindow,
                     "拖拽浮动预览不遮挡真正落点")
        cover.close()
        print("PASS screen-coordinate drop routing, overlapping-window rejection and drag preview passthrough")
        let dragWindow = NSPanel(contentRect: NSRect(x: screenPoint.x + 300, y: screenPoint.y, width: 180, height: 100),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        dragWindow.isReleasedWhenClosed = false
        let dragContent = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 100))
        let dragHandle = QuickCommandDragHandleView(frame: NSRect(x: 0, y: 50, width: 180, height: 50))
        dragHandle.commandID = item.id
        dragHandle.section = item.section
        let reorder = QuickCommandReorderTargetView(frame: NSRect(x: 0, y: 0, width: 180, height: 50))
        reorder.commandID = UUID()
        reorder.section = item.section
        var moves = 0
        reorder.onMove = { source, _, _ in precondition(source == item.id); moves += 1 }
        dragContent.addSubview(dragHandle)
        dragContent.addSubview(reorder)
        dragWindow.contentView = dragContent
        dragWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        // AppKit 进程内事件队列；不发送系统输入，不执行 shell。
        func drag(to point: NSPoint) {
            func event(_ type: NSEvent.EventType, _ location: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: dragWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            NSApp.postEvent(event(.leftMouseUp, point), atStart: true)
            NSApp.postEvent(event(.leftMouseDragged, point), atStart: true)
            dragHandle.mouseDown(with: event(.leftMouseDown, NSPoint(x: 80, y: 75)))
        }
        drag(to: NSPoint(x: 80, y: 20))
        precondition(moves == 1, "真实鼠标跟踪流程必须触发排序一次")
        var deliveries = 0
        let originalDrop = terminal.onQuickCommandDrop
        terminal.onQuickCommandDrop = { dropped in precondition(dropped == item.id); deliveries += 1; return true }
        drag(to: dragWindow.convertPoint(fromScreen: screenPoint))
        precondition(deliveries == 1, "独立工具箱跨窗口拖动必须投递到实际终端一次")
        terminal.onQuickCommandDrop = originalDrop
        dragWindow.close()
        print("PASS native mouse-down/drag/up tracking for reorder and cross-window command delivery")
        terminal.highlightQuickCommand(item.id)
        precondition(window.selectedTabID == left.id && window.quickCommandConfirmation == nil, "Hover must not change selection or execute")
        precondition(terminal.dropQuickCommand(item.id))
        let droppedContext = model.quickCommandContext(in: window)
        precondition(window.selectedTabID == right.id && droppedContext.sessionID == right.sessionID)
        precondition(droppedContext.directory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
                     == URL(fileURLWithPath: folder).resolvingSymlinksInPath())
        precondition(window.quickCommandConfirmation == nil && model.commandExecution(for: right.id).isSubmitting,
                     "Dropping submits directly in the destination terminal, without confirmation")
        precondition(!terminal.dropQuickCommand(item.id), "A pending run cannot be submitted twice")
        await wait { !model.commandExecution(for: right.id).isSubmitting }
        precondition(model.commandExecution(for: right.id).error != nil, "A destination without a shell must reject execution")
        precondition(terminal.processHost == nil && model.tabs.count == 2, "A busy destination must not create another terminal")
        model.selectTab(left.id, in: window, focusTerminal: false)
        precondition(!model.runSidebarQuickCommand(item.id, in: window, expectedContext: droppedContext),
                     "The old preview context must not execute in the newly selected terminal")
        precondition(window.quickCommandConfirmation == nil)

        var bound = item; bound.scope = .directory; bound.directory = folder
        try store.save(bound)
        precondition(model.commandForDrop(item.id, on: left.id, in: window) == nil)
        precondition(model.commandForDrop(item.id, on: right.id, in: window) != nil)
        bound.host = "remote-fixture"
        try store.save(bound)
        precondition(!terminal.acceptsQuickCommand(item.id), "Local destination must reject a remote command")
        precondition(!terminal.dropQuickCommand(item.id))
        try store.save(item)
        window.presentation.filesVisible = true
        window.presentation.filesExpanded = true
        precondition(!terminal.dropQuickCommand(item.id), "Hidden terminals must reject drops")
        window.presentation.filesVisible = false
        try store.remove(item.id)
        precondition(!terminal.dropQuickCommand(item.id), "Deleted commands cannot execute from an old drag")
        precondition(window.quickCommandConfirmation == nil)

        // Native list destinations must be distinct from terminal delivery and must
        // account for flipped coordinates, clipping, groups and the release location.
        let first = QuickCommand(alias: "First", command: "pwd", scope: .local)
        let last = QuickCommand(alias: "Last", command: "ls", scope: .local)
        try store.save(first); try store.save(last)
        let row = QuickCommandReorderTargetView(frame: NSRect(x: 550, y: 80, width: 240, height: 64))
        row.commandID = first.id; row.section = first.section
        row.onMove = { source, destination, after in
            do { try store.move(source, relativeTo: destination, after: after) }
            catch { preconditionFailure("Reorder failed: \(error)") }
        }
        nativeWindow.contentView?.addSubview(row)
        let above = row.convert(NSPoint(x: 20, y: 4), to: nil)
        let below = row.convert(NSPoint(x: 20, y: 60), to: nil)
        precondition(QuickCommandDragHandleView.reorderTarget(at: above, in: nativeWindow, sourceID: last.id, section: last.section) === row)
        precondition(!row.isAfter(above) && row.isAfter(below))
        precondition(QuickCommandDragHandleView.reorderTarget(at: above, in: nativeWindow, sourceID: first.id, section: first.section) == nil)
        precondition(QuickCommandDragHandleView.reorderTarget(at: above, in: nativeWindow, sourceID: last.id, section: 2) == nil)
        row.move(last.id, after: false)
        precondition(store.commands.sorted(by: QuickCommand.displayOrder).map(\.id) == [last.id, first.id])
        precondition(window.quickCommandConfirmation == nil && terminal.processHost == nil, "Sorting must never request terminal execution")
        row.isHidden = true
        precondition(QuickCommandDragHandleView.reorderTarget(at: above, in: nativeWindow, sourceID: last.id, section: last.section) == nil)
        let common = QuickCommand(alias: "公共文本", command: "printf '%s\\n' 'text only'", scope: .all)
        try store.save(common)
        let copyTarget = QuickCommandCopyTargetView(frame: NSRect(x: 550, y: 200, width: 240, height: 44))
        copyTarget.onCopy = { model.copyLibraryCommand($0, to: .host("offline-host"), in: window) }
        nativeWindow.contentView?.addSubview(copyTarget)
        let destination = copyTarget.convert(NSPoint(x: 20, y: 20), to: nil)
        precondition(QuickCommandCopyTargetView.target(at: destination, in: nativeWindow, commandID: common.id) === copyTarget)
        precondition(QuickCommandCopyTargetView.target(at: destination, in: nativeWindow, commandID: first.id) == nil)
        copyTarget.onCopy(common.id)
        precondition(store.commands.contains { $0.host == "offline-host" && $0.command == common.command && $0.id != common.id })
        precondition(window.quickCommandConfirmation == nil && terminal.processHost == nil && model.tabs.count == 2)
        copyTarget.isEnabled = false
        precondition(QuickCommandCopyTargetView.target(at: destination, in: nativeWindow, commandID: common.id) == nil)
        copyTarget.isEnabled = true; copyTarget.isHidden = true
        precondition(QuickCommandCopyTargetView.target(at: destination, in: nativeWindow, commandID: common.id) == nil)
        copyTarget.isHidden = false
        window.section = .commands
        precondition(!terminal.acceptsQuickCommand(common.id), "hidden terminal beneath management cannot receive text")
        window.section = .terminals
        precondition(!terminal.dropQuickCommand(common.id), "a view without a running surface cannot paste text")
        precondition(window.quickCommandConfirmation == nil, "public text never opens command execution or directory checks")
        try store.remove(common.id)
        precondition(QuickCommandCopyTargetView.target(at: destination, in: nativeWindow, commandID: common.id) == nil)
        print("Verified public text copy to offline host, no execution, hidden/disabled targets and deleted source rejection")
        print("Verified direct split destination, shared submission guard, no new terminal, stale selection, host/folder scope, hidden panes, deleted IDs and outside drops")
    }

    @MainActor private static func wait(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        precondition(predicate(), "Fixture did not become ready")
    }
}
