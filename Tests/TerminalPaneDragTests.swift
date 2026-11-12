import AppKit
import ObjectiveC
import SwiftUI
@testable import GooseAgent

/// 在隔离窗口里拖动真实分屏标题栏，不启动 shell 或 SSH。
@main enum TerminalPaneDragTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            do { try await run(); print("TerminalPaneDragTests passed"); exit(0) }
            catch { fputs("TerminalPaneDragTests failed: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }

    struct Failure: Error { let message: String }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
    }

    @MainActor static func run() async throws {
        let home = ProcessInfo.processInfo.environment["ONEAGENT_TEST_HOME"]!
        precondition(home.hasPrefix("/private/tmp/oneagent-terminal-pane-drag."))
        precondition(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
                     == URL(fileURLWithPath: home).resolvingSymlinksInPath())
        let suite = "oneagent.terminal-pane-drag.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let getter = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!
        let previous = method_getImplementation(getter)
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(getter, imp_implementationWithBlock(block))
        defer { method_setImplementation(getter, previous); defaults.removePersistentDomain(forName: suite) }

        let ids = (0..<4).map { _ in UUID() }
        let layout = PaneNode.split(SplitNode(id: UUID(), axis: .vertical, ratio: 0.5,
            leading: .split(SplitNode(id: UUID(), axis: .horizontal, ratio: 0.5,
                leading: .leaf(ids[0]), trailing: .leaf(ids[1]))),
            trailing: .split(SplitNode(id: UUID(), axis: .horizontal, ratio: 0.5,
                leading: .leaf(ids[2]), trailing: .leaf(ids[3])))))
        let workspace = Workspace(id: UUID(), number: 1, members: ids,
            panels: [TerminalPanel(layout: layout)], isGrouped: false)
        let snapshot = SessionSnapshot(tabs: ids.map { .init(id: $0, directory: "/tmp") },
            workspaces: [workspace], windows: [
                .init(id: UUID(), blocks: [.localGroup], localGroup: ids, ungrouped: [], selected: ids[0])
            ], keyWindow: nil)
        defaults.set(try JSONEncoder().encode(snapshot), forKey: SessionSnapshot.storageKey)
        let model = AppModel(), window = model.mainWindow
        model.restoreLastSession()
        let native = MainWindowManager.shared.window(for: window)!
        native.contentViewController = nil
        defer { native.orderOut(nil) }
        for _ in 0..<150 {
            if model.tabs.count == ids.count { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Self.check(model.tabs.count == ids.count, "Fixture restores four terminals")
        let terminals = model.tabs.map { tab in
            SSHTerminalRegistry.view(for: tab.sessionID) {
                let view = SSHTerminalNSView(frame: .zero)
                view.sessionID = tab.sessionID
                return view
            }!
        }
        defer { for tab in model.tabs { SSHTerminalRegistry.destroy(tab.sessionID) } }
        TerminalAutomation.model = model
        defer { TerminalAutomation.model = nil }
        window.presentation.sidebarCollapsed = false
        window.presentation.toolSidebarOpen = false
        native.contentViewController = NSHostingController(rootView: RootView(model: model, window: window))
        native.setContentSize(NSSize(width: 1200, height: 760))
        native.orderFrontRegardless()
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(150))
            native.contentView?.layoutSubtreeIfNeeded()
        }
        try await settle()
        let relay = window.relay!
        func point(_ id: UUID, x: CGFloat, y: CGFloat) -> NSPoint {
            let catcher = relay.catcher!, frame = relay.frames[id]!
            return catcher.convert(NSPoint(x: frame.minX + x, y: catcher.bounds.height - frame.minY - y), to: nil)
        }
        func hit(_ point: NSPoint) -> NSView? {
            let root = native.contentView!.superview!
            return root.hitTest(root.convert(point, from: nil))
        }
        func gesture(from start: NSPoint, to end: NSPoint?) async throws {
            var events: [(NSEvent.EventType, NSPoint)] = [(.leftMouseDown, start)]
            if let end {
                events += [(.leftMouseDragged, NSPoint(x: start.x, y: start.y - 12)), (.leftMouseDragged, end)]
            }
            events.append((.leftMouseUp, end ?? start))
            let nativeEvents = events.map { type, location in
                NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: native.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            }
            for event in nativeEvents.dropFirst() { NSApp.postEvent(event, atStart: false) }
            native.sendEvent(nativeEvents[0])
            try await settle()
        }
        let headerY = ShellLayout.compactHeaderHeight / 2
        let before = model.workspaces
        let source = point(ids[2], x: relay.frames[ids[2]]!.width / 2, y: headerY)
        let target = point(ids[0], x: 12, y: relay.frames[ids[0]]!.height / 2)
        try Self.check(hit(source) is TabDragHandleView,
            "The pane title must receive pointer events, got \(String(describing: hit(source)))")
        let windowFrame = native.frame
        try await gesture(from: source, to: target)
        try Self.check(native.frame == windowFrame, "Dragging title text keeps the application window still")
        try Self.check(model.workspaces != before,
            "Dragging the upper-right pane title onto another pane's left edge must move the terminal")
        try Self.check(relay.frames[ids[2]]!.maxX <= relay.frames[ids[0]]!.minX + 1,
            "The dragged terminal appears to the left of its target")
        try Self.check(Set(WorkspaceBoard.leafIDs(model.displayRoot(in: window)!)) == Set(ids),
            "Dragging a pane keeps all four terminals in the split")
        try Self.check(window.draggingTabID == nil && window.draggingTabIDs.isEmpty && relay.catcher!.overlay.superview == nil,
            "Releasing the pointer clears drag state and the landing preview")

        // 中间文字拖动终端，两侧空白交给原生窗口拖动。
        let frame = relay.frames[ids[3]]!
        let blank = point(ids[3], x: frame.width - 70, y: headerY)
        try Self.check(hit(blank) is WindowDragAreaView, "The title's blank area drags the application window")
        try Self.check(hit(point(ids[3], x: 20, y: headerY)) is WindowDragAreaView,
            "The title's leading blank area drags the application window")
        try Self.check(hit(point(ids[3], x: frame.width - 20, y: headerY)) is WindowDragAreaView,
            "The title's trailing blank area drags the application window")
        let title = point(ids[3], x: frame.width / 2, y: headerY)
        try await gesture(from: title, to: nil)
        try Self.check(window.selectedTabID == ids[3], "Clicking pane title text still focuses its terminal")
        let beforeSecondMove = model.workspaces
        try await gesture(from: title, to: point(ids[1], x: relay.frames[ids[1]]!.width / 2, y: 12))
        try Self.check(model.workspaces != beforeSecondMove && relay.frames[ids[3]]!.maxY <= relay.frames[ids[1]]!.minY + 1,
            "Dragging title text to a top edge places the terminal above its target")
        let beforeSelfDrop = model.workspaces
        try await gesture(from: point(ids[3], x: relay.frames[ids[3]]!.width / 2, y: headerY),
                          to: point(ids[3], x: 12, y: relay.frames[ids[3]]!.height / 2))
        try Self.check(model.workspaces == beforeSelfDrop, "Dropping a pane onto itself keeps the layout")
        try Self.check(terminals.allSatisfy { $0.window === native && $0.processHost == nil } &&
            model.tabs.allSatisfy { tab in terminals.contains { $0 === SSHTerminalRegistry.automationView(tab.sessionID) } },
            "Pane moves retain the existing terminal views without starting a shell")
        let saved = try JSONDecoder().decode(SessionSnapshot.self, from: defaults.data(forKey: SessionSnapshot.storageKey)!)
        try Self.check(saved.workspaces == model.workspaces, "The moved split layout is persisted")
        try await gesture(from: point(ids[3], x: relay.frames[ids[3]]!.width / 2, y: headerY), to: nil)
        try Self.check(window.selectedTabID == ids[3] && model.tabs.count == 4,
            "Clicking title text focuses the terminal without closing it")
        let tab = model.tabs.first { $0.id == ids[3] }!
        let close = TerminalPaneActions.items(tab: tab, model: model, window: window)
            .first { $0.title == AppShortcutID.closeTab.title }!
        close.action()
        try Self.check(!model.tabs.contains { $0.id == ids[3] } && model.tabs.count == 3,
            "The context menu still closes only its terminal")
    }
}
