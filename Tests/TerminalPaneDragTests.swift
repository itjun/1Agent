import AppKit
import ObjectiveC
import SwiftUI
@testable import Natty

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
        let home = ProcessInfo.processInfo.environment["NATTY_TEST_HOME"]!
        precondition(home.hasPrefix("/private/tmp/natty-terminal-pane-drag."))
        precondition(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
                     == URL(fileURLWithPath: home).resolvingSymlinksInPath())
        let suite = "natty.terminal-pane-drag.\(UUID())"
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
        func gesture(from start: NSPoint, to end: NSPoint?, clickCount: Int = 1) async throws {
            var events: [(NSEvent.EventType, NSPoint)] = [(.leftMouseDown, start)]
            if let end {
                events += [(.leftMouseDragged, NSPoint(x: start.x, y: start.y - 12)), (.leftMouseDragged, end)]
            }
            events.append((.leftMouseUp, end ?? start))
            let nativeEvents = events.map { type, location in
                NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: native.windowNumber,
                    context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)!
            }
            for event in nativeEvents.dropFirst() { NSApp.postEvent(event, atStart: false) }
            native.sendEvent(nativeEvents[0])
            try await settle()
        }
        let headerY = ShellLayout.compactHeaderHeight / 2
        func titleCenter(_ id: UUID) -> NSPoint {
            point(id, x: relay.frames[id]!.width / 2, y: headerY)
        }
        // Exercise the full height of the custom title bar, including the strip below
        // the native title bar. Start with window movement locked by a pane title.
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        func accessibilityFrame(_ identifier: String) -> CGRect? {
            func find(_ object: NSObject) -> NSObject? {
                if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
                   object.value(forKey: "accessibilityIdentifier") as? String == identifier { return object }
                guard object.responds(to: NSSelectorFromString("accessibilityChildren")),
                      let children = object.value(forKey: "accessibilityChildren") as? [NSObject] else { return nil }
                return children.lazy.compactMap { find($0) }.first
            }
            return (find(native)?.value(forKey: "accessibilityFrame") as? NSValue).map { native.convertFromScreen($0.rectValue) }
        }
        let canvas = relay.catcher!.bounds
        // 先改变左列上下比例，再拖整条竖边；两次双击后应回到原来的四宫格。
        let grid = relay.frames
        let first = grid[ids[0]]!
        let horizontal = point(ids[0], x: first.width / 2, y: first.height)
        for offset: CGFloat in [-3, 0, 3] {
            let target = hit(NSPoint(x: horizontal.x, y: horizontal.y + offset))
            try check((target as? PaneDividerView)?.vertical == false,
                      "Horizontal resize target at offset \(offset): \(String(describing: target))")
        }
        try await gesture(from: horizontal, to: NSPoint(x: horizontal.x, y: horizontal.y - 40))
        let taller = relay.frames[ids[0]]!
        try check(abs(taller.height - first.height - 40) <= 1 && taller.maxY == relay.frames[ids[1]]!.minY,
                  "Dragging the shared edge changes both heights without opening a gap")
        let vertical = point(ids[0], x: taller.width, y: taller.height / 2)
        for offset: CGFloat in [-3, 0, 3] {
            let target = hit(NSPoint(x: vertical.x + offset, y: vertical.y))
            try check((target as? PaneDividerView)?.vertical == true,
                      "Vertical resize target at offset \(offset): \(String(describing: target))")
        }
        try await gesture(from: vertical, to: NSPoint(x: vertical.x + 50, y: vertical.y))
        let wider = relay.frames[ids[0]]!
        try check(abs(wider.width - taller.width - 50) <= 1 && wider.maxX == relay.frames[ids[2]]!.minX,
                  "Dragging the shared edge changes both widths without opening a gap")
        func doubleClick(at point: NSPoint) async throws {
            try await gesture(from: point, to: nil)
            try await gesture(from: point, to: nil, clickCount: 2)
        }
        try await doubleClick(at: point(ids[0], x: wider.width, y: wider.height / 2))
        try await doubleClick(at: point(ids[0], x: first.width / 2, y: taller.height))
        try check(relay.frames == grid, "Double-clicking both invisible boundaries restores the original grid")
        let framesWithoutCommands = relay.frames
        model.commandSidebars[ids[0], default: .init()].isExpanded = true
        try await settle()
        let paneWidth = relay.frames[ids[0]]!.width
        let commandsWidth = TerminalCanvas.commandSidebarWidth(model.sharedCommandSidebar(for: ids[0]), canvasWidth: canvas.width)
        try check(commandsWidth > 0, "The fixture shows the split's shared command sidebar")
        let paneEdge = canvas.width - commandsWidth
        try check(ids.allSatisfy { relay.frames[$0]!.maxX <= paneEdge + 1 } && abs(relay.frames[ids[2]]!.maxX - paneEdge) < 1,
                  "Every pane sits left of the one shared command island without a gap")
        try check(paneWidth < framesWithoutCommands[ids[0]]!.width && relay.frames[ids[2]]!.width < framesWithoutCommands[ids[2]]!.width,
                  "The shared island takes its width from the whole split, not from one pane")
        guard let island = accessibilityFrame("quickCommands.pane." + ids[0].uuidString) else {
            throw Failure(message: "The shared command island shows the focused terminal's commands")
        }
        let canvasFrame = relay.catcher!.convert(canvas, to: nil)
        try check(abs(island.minX - (canvasFrame.minX + paneEdge)) < 1
                  && abs(island.maxX - canvasFrame.maxX) < 1 && abs(island.height - canvasFrame.height) < 1,
                  "The shared command island fills the canvas's right column from top to bottom")
        for offset: CGFloat in [-2, 0, 2] {
            let grabPoint = NSPoint(x: island.minX + offset, y: island.midY)
            try check(hit(grabPoint) is PaneDividerView,
                      "The invisible command boundary can be grabbed from either side")
        }
        try check(accessibilityFrame("quickCommands.target." + ids[0].uuidString) != nil,
                  "In a split the island's title names the terminal that receives commands")
        let headerBottom = ShellLayout.compactHeaderHeight - 2
        let sidebarBlank = NSPoint(x: 130, y: point(ids[0], x: 0, y: headerBottom).y)
        let commandHeader = relay.catcher!.convert(NSPoint(x: canvas.width - 25, y: canvas.height - headerY), to: nil)
        for (name, blank) in [
            ("navigation header", sidebarBlank),
            ("left of terminal title", point(ids[0], x: 8, y: headerY)),
            ("right of terminal title", point(ids[0], x: paneWidth - 8, y: headerBottom)),
            ("command header", commandHeader)
        ] {
            try check(hit(blank) is WindowDragAreaView, "Window drag must receive presses on the \(name)")
            native.isMovable = false
            try await gesture(from: blank, to: nil)
            try check(native.isMovable, "A press on the \(name) must release the pane title's movement lock")
        }
        let framesBeforeFocusChange = relay.frames
        model.selectOnly(ids[3], in: window, focusTerminal: false)
        try await settle()
        try check(accessibilityFrame("quickCommands.pane." + ids[3].uuidString) == island
                  && accessibilityFrame("quickCommands.pane." + ids[0].uuidString) == nil,
                  "The island follows the focused terminal and stays in place")
        try check(relay.frames == framesBeforeFocusChange, "Changing focus keeps every pane's size, so no terminal reflows")
        model.selectOnly(ids[0], in: window, focusTerminal: false)
        model.updateSharedCommandSidebar(for: ids[0]) { $0.isExpanded = false }
        try await settle()
        try check(relay.frames == framesWithoutCommands, "Collapsing the island returns its column to the panes")
        let before = model.workspaces
        let source = titleCenter(ids[2])
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

        // 居中的文字拖动终端，两侧空白交给原生窗口拖动。
        let frame = relay.frames[ids[3]]!
        let blank = point(ids[3], x: frame.width - 70, y: headerY)
        try Self.check(hit(blank) is WindowDragAreaView, "The title's blank area drags the application window")
        try Self.check(hit(point(ids[3], x: 4, y: headerY)) is WindowDragAreaView,
            "The title's leading blank area drags the application window")
        try Self.check(hit(point(ids[3], x: frame.width - 20, y: headerY)) is WindowDragAreaView,
            "The title's trailing blank area drags the application window")
        let title = titleCenter(ids[3])
        try await gesture(from: title, to: nil)
        try Self.check(window.selectedTabID == ids[3], "Clicking pane title text still focuses its terminal")
        let beforeSecondMove = model.workspaces
        try await gesture(from: title, to: point(ids[1], x: relay.frames[ids[1]]!.width / 2, y: 12))
        try Self.check(model.workspaces != beforeSecondMove && relay.frames[ids[3]]!.maxY <= relay.frames[ids[1]]!.minY + 1,
            "Dragging title text to a top edge places the terminal above its target")
        let beforeSelfDrop = model.workspaces
        try await gesture(from: titleCenter(ids[3]),
                          to: point(ids[3], x: 12, y: relay.frames[ids[3]]!.height / 2))
        try Self.check(model.workspaces == beforeSelfDrop, "Dropping a pane onto itself keeps the layout")
        try Self.check(terminals.allSatisfy { $0.window === native && $0.processHost == nil } &&
            model.tabs.allSatisfy { tab in terminals.contains { $0 === SSHTerminalRegistry.automationView(tab.sessionID) } },
            "Pane moves retain the existing terminal views without starting a shell")
        let saved = try JSONDecoder().decode(SessionSnapshot.self, from: defaults.data(forKey: SessionSnapshot.storageKey)!)
        try Self.check(saved.workspaces == model.workspaces, "The moved split layout is persisted")
        try await gesture(from: titleCenter(ids[3]), to: nil)
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
