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
        terminal.onQuickCommandDrop = { model.confirmDroppedQuickCommand($0, on: right.id, in: window) }
        nativeWindow.contentView?.addSubview(terminal)
        precondition(model.commandForDrop(item.id, on: right.id, in: window) != nil)
        precondition(TerminalActivity.shared.isOnScreen(sessionID: right.sessionID), "Fixture destination must be visible")
        precondition(QuickCommandDragHandleView.terminal(at: NSPoint(x: 200, y: 200), in: nativeWindow) === terminal)
        precondition(QuickCommandDragHandleView.terminal(at: NSPoint(x: -100, y: -100), in: nativeWindow) == nil)
        terminal.highlightQuickCommand(item.id)
        precondition(window.selectedTabID == left.id && window.quickCommandConfirmation == nil, "Hover must not change selection or execute")
        precondition(terminal.dropQuickCommand(item.id))
        let confirmation = window.quickCommandConfirmation!
        precondition(window.selectedTabID == right.id && confirmation.context.sessionID == right.sessionID)
        precondition(confirmation.context.directory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
                     == URL(fileURLWithPath: folder).resolvingSymlinksInPath(), "Destination directory: \(String(describing: confirmation.context.directory))")
        precondition(confirmation.item.command == item.command)
        precondition(terminal.processHost == nil && model.tabs.count == 2, "Drop must only request confirmation")
        precondition(!terminal.dropQuickCommand(item.id), "An open confirmation must not be replaced")
        window.quickCommandConfirmation = nil // Cancel
        precondition(model.tabs.count == 2 && terminal.processHost == nil)

        // The click and drop entries carry the same immutable target snapshot.
        model.confirmQuickCommand(item, in: window)
        precondition(window.quickCommandConfirmation?.context == confirmation.context)
        model.selectTab(left.id, in: window, focusTerminal: false)
        precondition(window.quickCommandConfirmation?.context != model.quickCommandContext(in: window))
        window.quickCommandConfirmation = nil

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
        print("Verified split destination, click/drop parity, cancel, stale selection, host/folder scope, hidden panes, deleted IDs and outside drops")
    }

    @MainActor private static func wait(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        precondition(predicate(), "Fixture did not become ready")
    }
}
