import AppKit
import ObjectiveC
import SwiftUI
@testable import GooseAgent

/// Exercises production sidebar hit testing and delivery without shells or network access.
@main enum SidebarPanelDropTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            do { try await run(); print("SidebarPanelDropTests passed"); exit(0) }
            catch { fputs("SidebarPanelDropTests failed: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }

    struct Failure: Error { let message: String }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
    }

    @MainActor static func run() async throws {
        let home = ProcessInfo.processInfo.environment["ONEAGENT_TEST_HOME"]!
        precondition(home.hasPrefix("/private/tmp/oneagent-sidebar-panel-drop."))
        precondition(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
                     == URL(fileURLWithPath: home).resolvingSymlinksInPath())
        let suite = "oneagent.sidebar-panel-drop.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let getter = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!
        let previous = method_getImplementation(getter)
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(getter, imp_implementationWithBlock(block))
        defer { method_setImplementation(getter, previous); defaults.removePersistentDomain(forName: suite) }

        let first = UUID(), second = UUID(), outsider = UUID(), panelID = UUID()
        let split = Workspace(id: UUID(), number: 1, members: [first, second], panels: [
            TerminalPanel(id: panelID, layout: .split(SplitNode(id: UUID(), axis: .vertical, ratio: 0.4,
                                                               leading: .leaf(first), trailing: .leaf(second))))
        ], isGrouped: false)
        let snapshot = SessionSnapshot(tabs: [
            .init(id: first, directory: home), .init(id: second, directory: home),
            .init(id: outsider, directory: home)
        ], workspaces: [split], windows: [
            .init(id: UUID(), blocks: [.localGroup], localGroup: [first, second, outsider], ungrouped: [], selected: outsider)
        ], keyWindow: nil)
        defaults.set(try JSONEncoder().encode(snapshot), forKey: SessionSnapshot.storageKey)
        let model = AppModel(), window = model.mainWindow
        model.restoreLastSession()
        let native = MainWindowManager.shared.window(for: window)!
        native.contentViewController = nil
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        native.contentView = content
        defer { native.orderOut(nil) }
        let deadline = Date().addingTimeInterval(3)
        while model.tabs.count != 3, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try check(model.tabs.count == 3, "Fixture restores all terminals")

        let relay = CanvasDropRelay()
        relay.modelBox = model; relay.windowBox = window
        let sidebar = BoundsAnchorView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
        content.addSubview(sidebar)
        relay.sidebarAnchor = sidebar
        let category = BoundsAnchorView(frame: sidebar.bounds)
        sidebar.addSubview(category)
        relay.blockAnchors[.localGroup] = AnchorBox(category)
        let header = BoundsAnchorView(frame: NSRect(x: 8, y: 60, width: 204, height: 44))
        category.addSubview(header)
        relay.rowAnchors[first] = AnchorBox(header)
        relay.rowAnchors[second] = AnchorBox(header)
        let source = BoundsAnchorView(frame: NSRect(x: 8, y: 180, width: 204, height: 44))
        category.addSubview(source)
        relay.rowAnchors[outsider] = AnchorBox(source)
        let initialBlocks = window.blocks, initialLooseMembers = window.looseMembers
        func reset() {
            model.moveToLooseGroup([outsider], .localGroup, in: window, beside: nil, after: true)
            window.blocks = initialBlocks
            window.looseMembers = initialLooseMembers
            window.selectedTabID = outsider
            window.sidebarSelection = [outsider]
            window.panelLastFocused = [:]
            window.dropHighlight = nil
        }

        relay.performDrop(of: .tabs([outsider], source: window),
                          windowPoint: header.convert(NSPoint(x: 80, y: 22), to: nil), model: model)
        try check(model.panelRow(for: outsider, in: window)?.panelID == panelID,
                  "Dragging onto an existing split-group header must join that panel")
        try check(model.panelRow(for: first, in: window)?.leafIDs.count == 3,
                  "Sidebar drop adds the terminal to the existing group")
        reset()

        // Use the actual SwiftUI sidebar so missing or incorrectly registered member anchors fail.
        var terminalViews: [SSHTerminalNSView] = []
        for tab in model.tabs {
            let terminal = SSHTerminalRegistry.view(for: tab.sessionID) {
                let view = SSHTerminalNSView(frame: .zero)
                view.sessionID = tab.sessionID
                return view
            }
            terminalViews.append(terminal!)
        }
        TerminalAutomation.model = model
        defer { TerminalAutomation.model = nil }
        window.panelTitles = [panelID: "拖放目标组", outsider: "待加入终端"]
        window.presentation.sidebarCollapsed = false
        window.presentation.toolSidebarOpen = false
        native.contentViewController = NSHostingController(rootView: RootView(model: model, window: window))
        native.setContentSize(NSSize(width: 1100, height: 760))
        native.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(350))
        native.contentView?.layoutSubtreeIfNeeded()
        let productionRelay = window.relay!
        try check(productionRelay.paneRowAnchors[first]?.view?.window === native &&
                  productionRelay.paneRowAnchors[second]?.view?.window === native,
                  "Production sidebar registers both member rows as drop targets")

        let member = productionRelay.paneRowAnchors[second]!.view!
        let memberPoint = member.convert(NSPoint(x: 80, y: member.bounds.midY), to: nil)
        productionRelay.dragBegan(outsider)
        productionRelay.dragMoved(windowPoint: memberPoint)
        try check(window.dropHighlight == .sidebarRow(first), "Member hover highlights its target group")
        try check(model.workspaces == [split], "Hover never changes group membership")
        productionRelay.dragEnded(windowPoint: memberPoint)
        try check(model.panelRow(for: outsider, in: window)?.panelID == panelID,
                  "Dropping on a production member row joins the existing panel")
        try check(model.tabs.count == 3 && Set(model.workspaces.flatMap(\.members)).count == 3,
                  "Merging keeps every terminal exactly once")
        try check(window.draggingTabID == nil && window.draggingTabIDs.isEmpty && window.dropHighlight == nil,
                  "Releasing the drag clears its state and hover highlight")
        let saved = try JSONDecoder().decode(SessionSnapshot.self, from: defaults.data(forKey: SessionSnapshot.storageKey)!)
        try check(saved.workspaces.first { $0.id == split.id }?.panels.first?.id == panelID &&
                  saved.workspaces.first { $0.id == split.id }?.members.contains(outsider) == true,
                  "Group identity and new membership persist")
        reset()
        try await Task.sleep(for: .milliseconds(150))
        native.contentView?.layoutSubtreeIfNeeded()

        let productionHeader = productionRelay.rowAnchors[first]!.view!
        productionRelay.performDrop(of: .tabs([outsider], source: window),
                                    windowPoint: productionHeader.convert(NSPoint(x: 80, y: 2), to: nil), model: model)
        try check(model.workspaces == [split] && model.panelRows(in: window).first?.focusedTabID == outsider,
                  "The header's upper edge still reorders instead of merging")
        reset()
        productionRelay.performDrop(of: .tabs([first, second], source: window), windowPoint: memberPoint, model: model)
        try check(model.workspaces.flatMap(\.panels) == split.panels &&
                  model.panelRow(for: first, in: window)?.leafIDs == [first, second],
                  "Dropping a group on itself preserves its panel identity and split")
        let beforeOutside = model.workspaces
        productionRelay.performDrop(of: .tabs([outsider], source: window), windowPoint: NSPoint(x: -20, y: -20), model: model)
        try check(model.workspaces == beforeOutside, "Outside drops leave membership unchanged")
        try check(terminalViews.allSatisfy { $0.processHost == nil },
                  "Drop verification never starts a shell")
        print("Verified header/member delivery, production anchors, hover, reorder edges, self/outside drops and persistence")
    }
}
