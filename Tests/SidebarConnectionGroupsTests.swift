import AppKit
import Foundation
import ObjectiveC
import SwiftUI
@testable import GooseAgent

/// Exercises the production model and session codec with isolated storage, no PTYs or network.
@main enum SidebarConnectionGroupsTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        if ProcessInfo.processInfo.environment["ONEAGENT_SIDEBAR_PREVIEW"] == "1" { NSApp.setActivationPolicy(.regular) }
        Task { @MainActor in
            do { try await run(); print("SidebarConnectionGroupsTests passed"); exit(0) }
            catch { fputs("SidebarConnectionGroupsTests failed: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }

    struct Failure: Error { let message: String }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
    }

    @MainActor static func run() async throws {
        let home = ProcessInfo.processInfo.environment["ONEAGENT_TEST_HOME"]!
        precondition(home.hasPrefix("/private/tmp/oneagent-sidebar-groups."))
        precondition(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
                     == URL(fileURLWithPath: home).resolvingSymlinksInPath())
        let suite = "oneagent.sidebar-groups.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let getter = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!
        let previous = method_getImplementation(getter)
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(getter, imp_implementationWithBlock(block))
        defer { method_setImplementation(getter, previous); defaults.removePersistentDomain(forName: suite) }

        let l1 = UUID(), l2 = UUID(), r1 = UUID(), r2 = UUID(), ml = UUID(), mr = UUID()
        let wl = UUID(), wr = UUID(), preview = UUID(), panelID = UUID(), workspaceID = UUID()
        let previewPath = home + "/preview.txt"
        try Data("fixture".utf8).write(to: URL(fileURLWithPath: previewPath))
        let mixed = Workspace(id: UUID(), number: 1, members: [ml, mr], panels: [
            TerminalPanel(id: panelID, layout: .split(SplitNode(id: UUID(), axis: .vertical, ratio: 0.4,
                                                              leading: .leaf(ml), trailing: .leaf(mr))))
        ], isGrouped: false)
        let grouped = Workspace(id: workspaceID, number: 2, members: [wl, wr], name: "Mixed workspace")
        let snapshot = SessionSnapshot(tabs: [
            .init(id: l1, directory: home), .init(id: l2, directory: home),
            .init(id: r1, alias: "fixture-remote-a"), .init(id: r2, alias: "fixture-remote-b"),
            .init(id: ml, directory: home), .init(id: mr, alias: "fixture-mixed"),
            .init(id: wl, directory: home), .init(id: wr, alias: "fixture-workspace"),
            .init(id: preview, preview: previewPath)
        ], workspaces: [mixed, grouped], windows: [
            .init(id: UUID(), blocks: [.ungrouped, .workspace(workspaceID), .localGroup],
                  localGroup: [r1, l1, ml], ungrouped: [r2, l2, mr, preview], selected: l1)
        ], keyWindow: nil)
        // The old format has no mixedGroup field or collapsedConnectionGroups.
        defaults.set(try JSONEncoder().encode(snapshot), forKey: SessionSnapshot.storageKey)
        let model = AppModel(), window = model.mainWindow
        model.restoreLastSession()
        let native = MainWindowManager.shared.window(for: window)!
        native.contentViewController = nil
        native.contentView = NSView(frame: native.contentLayoutRect)
        defer { native.orderOut(nil) }
        try await wait { model.tabs.count == 9 }
        try check(model.tabs.count == 9, "Restore must preserve every terminal and preview")
        try check(window.presentation.collapsedConnectionGroups.isEmpty, "Legacy groups start expanded")
        let rows = model.panelRows(in: window)
        let groups = rows.map { model.connectionGroup(for: $0.block) }
        try check(groups == [.local, .local, .local, .remote, .remote, .mixed, .mixed, .mixed], "Fixed category order and panel counts")
        try check(Set(rows.flatMap(\.leafIDs)).count == 9 && rows.count == 8, "Every terminal appears exactly once; split counts once")
        try checkSidebarMenus(model: model, window: window, local: l1, remote: r1,
                              splitLeaf: ml, workspace: grouped)
        try check(model.panelRow(for: preview, in: window)?.block == .localGroup, "Preview is local")
        try check(model.sessionSubtitle(model.tabs.first { $0.id == preview }!).hasPrefix(String(localized: "This Mac")), "Preview subtitle agrees with Local category")
        try check(model.panelRow(for: r1, in: window)?.block == .ungrouped, "Legacy wrong local placement is repaired")
        try check(model.panelRow(for: l2, in: window)?.block == .localGroup, "Legacy wrong remote placement is repaired")
        try check(model.panelRow(for: ml, in: window)?.block == .mixedGroup, "Mixed split has its own category")
        try check(model.panelRows(in: .workspace(workspaceID), window: window).count == 2, "Mixed workspace remains intact")
        try check(model.workspace(for: workspaceID)?.name == "Mixed workspace", "Workspace name survives")

        if ProcessInfo.processInfo.environment["ONEAGENT_SIDEBAR_PREVIEW"] == "1" {
            for tab in model.tabs where tab.hasTerminal {
                _ = SSHTerminalRegistry.view(for: tab.sessionID) {
                    let view = SSHTerminalNSView(frame: .zero)
                    view.sessionID = tab.sessionID
                    return view
                }
            }
            window.presentation.sidebarCollapsed = false
            window.presentation.toolSidebarOpen = false
            native.contentViewController = NSHostingController(rootView: RootView(model: model, window: window))
            native.setContentSize(NSSize(width: 1100, height: 760))
            native.orderFrontRegardless()
            print("Isolated sidebar preview ready")
            fflush(stdout)
            try await Task.sleep(for: .milliseconds(350))
            native.contentView?.layoutSubtreeIfNeeded()
            if let view = native.contentView,
               let image = view.bitmapImageRepForCachingDisplay(in: view.bounds),
               let output = ProcessInfo.processInfo.environment["ONEAGENT_SIDEBAR_PREVIEW_OUTPUT"] {
                view.cacheDisplay(in: view.bounds, to: image)
                try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
                try check(model.tabs.count == 9, "Rendering must not launch or close terminal fixtures")
                print("Rendered production RootView to \(output)")
            }
            return
        }

        model.selectTab(ml, in: window, focusTerminal: false)
        let order = model.panelRows(in: window).map(\.id)
        model.selectTab(mr, in: window, focusTerminal: false)
        try check(model.panelRows(in: window).map(\.id) == order, "Focus inside mixed split cannot move the row")
        try check(model.workspaces.first(where: { $0.id == mixed.id })?.panels == mixed.panels, "Split geometry and identity survive")

        model.moveToLooseGroup([l1], .ungrouped, in: window, beside: r1, after: false)
        try check(model.panelRow(for: l1, in: window)?.block == .localGroup, "Cross-category drop cannot change connection type")
        model.moveToLooseGroup([l2], .localGroup, in: window, beside: l1, after: false)
        let localOrder = model.panelRows(in: .localGroup, window: window).map(\.focusedTabID)
        try check(localOrder.firstIndex(of: l2)! < localOrder.firstIndex(of: l1)!, "Within-category reorder works")
        model.reorderSidebarBlock(.workspace(workspaceID), toIndex: 0, in: window)
        try check(model.panelRows(in: window).first?.block == .localGroup, "Workspace dragging cannot reorder categories")

        model.selectOnly(l2, in: window, focusTerminal: false)
        model.clickSidebar(r1, command: false, shift: true, in: window, focusTerminal: false)
        let rangeRows = model.panelRows(in: window)
        let lower = rangeRows.firstIndex(where: { $0.leafIDs.contains(l2) })!
        let upper = rangeRows.firstIndex(where: { $0.leafIDs.contains(r1) })!
        try check(window.sidebarSelection == Set(rangeRows[min(lower, upper)...max(lower, upper)].flatMap(\.leafIDs)), "Shift range follows displayed categories")
        model.clickSidebar(mr, command: true, shift: false, in: window, focusTerminal: false)
        try check(window.sidebarSelection.contains(ml) && window.sidebarSelection.contains(mr), "Command multi-select includes the whole mixed panel")
        model.createAreaFromSidebar([l1, l2], in: window)
        let localWorkspace = model.panelRow(for: l1, in: window)!.workspaceID!
        try check(model.connectionGroup(for: .workspace(localWorkspace)) == .local, "Pure local workspace stays in Local")
        model.dissolveWorkspace(localWorkspace)
        model.createAreaFromSidebar([r1, r2], in: window)
        let remoteWorkspace = model.panelRow(for: r1, in: window)!.workspaceID!
        try check(model.connectionGroup(for: .workspace(remoteWorkspace)) == .remote, "Pure remote workspace stays in Remote")
        model.dissolveWorkspace(remoteWorkspace)

        model.updatePresentation(in: window) { $0.collapsedConnectionGroups = [.remote, .mixed]; $0.collapsedWorkspaces = [workspaceID] }
        try check(model.visiblePanelRows(in: window).allSatisfy { model.connectionGroup(for: $0.block) == .local }, "Collapsed groups excluded from range selection")
        model.selectTab(wr, in: window, focusTerminal: false)
        try check(!window.presentation.collapsedConnectionGroups.contains(.mixed) && !window.presentation.collapsedWorkspaces.contains(workspaceID), "Explicit selection reveals category and workspace")
        model.selectTab(l1, in: window, focusTerminal: false)
        try check(model.selectAdjacentTerminal(forward: true, in: window), "Next-terminal navigation succeeds")
        let currentRows = model.panelRows(in: window)
        let index = currentRows.firstIndex(where: { $0.leafIDs.contains(l1) })!
        try check(window.selectedTabID == currentRows[(index + 1) % currentRows.count].focusedTabID, "Keyboard order matches sidebar")

        model.mergeSidebar([l1, r1], onto: l1, as: .columns, in: window)
        try check(model.panelRow(for: l1, in: window)?.block == .mixedGroup, "Cross-category merge enters Mixed")
        try check(Set(model.panelRow(for: l1, in: window)!.leafIDs) == [l1, r1], "Merge preserves both terminals")
        model.splitSidebar([l1, r1], in: window)
        try check(model.panelRow(for: l1, in: window)?.block == .localGroup && model.panelRow(for: r1, in: window)?.block == .ungrouped, "Detach returns each terminal to its type")
        model.dissolveWorkspace(workspaceID)
        try check(model.panelRow(for: wl, in: window)?.block == .localGroup && model.panelRow(for: wr, in: window)?.block == .ungrouped, "Dissolving workspace preserves sessions and reclassifies")

        model.updatePresentation(in: window) { $0.collapsedConnectionGroups = [.local, .remote, .mixed] }
        let saved = try JSONDecoder().decode(SessionSnapshot.self, from: defaults.data(forKey: SessionSnapshot.storageKey)!)
        try check(saved.windows?.first?.presentation?.collapsedConnectionGroups == Set(SidebarConnectionGroup.allCases), "Collapse state persisted")
        try check(Set(saved.windows?.first?.mixedGroup ?? []) == [ml, mr], "Mixed split membership persisted")
        let restored = WindowState()
        saved.apply(to: restored, keeping: Set(model.tabs.map(\.id)))
        try check(restored.presentation.collapsedConnectionGroups == Set(SidebarConnectionGroup.allCases), "Collapse state restored")
        try check(restored.looseMembers == window.looseMembers, "Ordering and mixed members round-trip")
        model.openLocalTerminal(at: home, in: window)
        try await wait { model.tabs.count == 10 }
        try check(!window.presentation.collapsedConnectionGroups.contains(.local), "New local terminal reveals Local")
        model.openHost("fixture-new-remote", in: window)
        try await wait { model.tabs.count == 11 }
        try check(!window.presentation.collapsedConnectionGroups.contains(.remote), "New remote terminal reveals Remote")
        print("Verified legacy migration, preview, mixed focus, workspace integrity, order, selection, drag constraints, merge/detach, persistence, and new-terminal reveal")
        // A context action remains bound to its original row after keyboard selection changes.
        let target = model.panelRow(for: l2, in: window)!
        window.sidebarSelection = [l2]
        let close = SidebarActions.panelItems(target, model: model, window: window, onRename: {}).last!
        model.selectOnly(r1, in: window, focusTerminal: false)
        close.action()
        try check(!model.tabs.contains { $0.id == l2 } && model.tabs.contains { $0.id == r1 },
                  "Close must target the clicked row, not the subsequently focused terminal")
        print("Verified sidebar menus and frozen action targets")
    }

    @MainActor static func checkSidebarMenus(model: AppModel, window: WindowState, local: UUID,
                                             remote: UUID, splitLeaf: UUID, workspace: Workspace) throws {
        let selection = window.sidebarSelection, focused = window.selectedTabID
        defer { window.sidebarSelection = selection; window.selectedTabID = focused }
        func items(_ id: UUID) -> [FamilyMenuItem] {
            SidebarActions.panelItems(model.panelRow(for: id, in: window)!, model: model, window: window, onRename: {})
        }
        func named(_ key: String.LocalizationValue, in items: [FamilyMenuItem]) -> FamilyMenuItem? {
            items.first { $0.title == String(localized: key) }
        }
        func checkSeparators(_ items: [FamilyMenuItem]) throws {
            try check(items.first?.isSeparator != true && items.last?.isSeparator != true, "No edge separator")
            for pair in zip(items, items.dropFirst()) {
                try check(!(pair.0.isSeparator && pair.1.isSeparator), "No consecutive separators")
            }
            for item in items where !item.children.isEmpty { try checkSeparators(item.children) }
        }
        window.sidebarSelection = [remote]
        let localItems = items(local)
        try check(window.sidebarSelection == [remote] && window.selectedTabID == focused, "Right-click does not move focus or selection")
        try check(named("New Terminal Here", in: localItems) != nil, "Local row opens another terminal at cwd")
        try check(named("Reconnect", in: localItems) == nil, "Local row cannot use SSH reconnect")
        try check(named("Move out of Workspace", in: localItems) == nil, "Loose panel does not offer removal")
        let remoteItems = items(remote)
        try check(named("New Connection", in: remoteItems) != nil, "Remote connection action exists")
        try check(named("Reveal in Finder", in: remoteItems) == nil, "Remote row cannot reveal a local path")
        let copy = named("Copy Info", in: remoteItems)!
        try check(named("Copy Path", in: copy.children)?.enabled == false, "Unknown remote cwd is disabled")
        let split = items(splitLeaf)
        try check(named("Arrange Panel", in: split) != nil && named("Detach Panels", in: split)?.enabled == true,
                  "Split row operates on all its panes")
        try check(split.first?.children.isEmpty == false, "Single-terminal actions are nested for a split")
        let splitIDs = model.panelRow(for: splitLeaf, in: window)!.leafIDs
        window.sidebarSelection = Set(splitIDs + [remote])
        let batch = items(splitLeaf)
        try check(named("Rename…", in: batch) == nil && named("New Connection", in: batch) == nil, "Batch omits single-target operations")
        try check(named("Merge Panels", in: batch) != nil, "Batch supports merge")
        let workspaceItems = SidebarActions.workspaceItems(workspace, model: model, window: window, onRename: {})
        try check(named("Add Selected Panels", in: workspaceItems)?.enabled == true, "Workspace can adopt selected panels")
        try check(named("Dissolve Workspace…", in: workspaceItems)?.destructive == false, "Dissolve does not terminate sessions")
        try check(named("Close All Terminals…", in: workspaceItems)?.destructive == true, "Closing workspace is explicitly destructive")
        for menu in [localItems, remoteItems, split, batch, workspaceItems] { try checkSeparators(menu) }
        if let output = ProcessInfo.processInfo.environment["ONEAGENT_SIDEBAR_MENU_OUTPUT"],
           let owner = MainWindowManager.shared.window(for: window) {
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            for (name, menu) in [("local", localItems), ("remote", remoteItems), ("split", split),
                                 ("batch", batch), ("workspace", workspaceItems)] {
                FamilyMenuPresenter.shared.show(menu, at: NSPoint(x: owner.frame.minX + 30, y: owner.frame.maxY - 60), owner: owner)
                let panel = FamilyMenuPresenter.shared.panels.first!
                let view = panel.contentView!
                view.layoutSubtreeIfNeeded()
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output + "/" + name + ".png"))
                try check(panel.frame.width >= 180 && panel.frame.height > 100, "Native menu has usable dimensions")
                FamilyMenuPresenter.shared.dismiss()
            }
            print("Rendered five production context menus to \(output)")
        }
        // Reconnect/reopen availability is based on actual connection state, not directory or focus.
        var remoteTab = model.tabs.first { $0.id == remote }!
        remoteTab.exited = false
        try check(named("Reconnect", in: SidebarActions.terminalItems(remoteTab, model: model, window: window))?.enabled == false,
                  "Connected terminal cannot be restarted by reconnect")
        remoteTab.exited = true
        try check(named("Reconnect", in: SidebarActions.terminalItems(remoteTab, model: model, window: window))?.enabled == true,
                  "Disconnected terminal can reconnect")
        remoteTab.reconnecting = true
        try check(named("Reconnecting…", in: SidebarActions.terminalItems(remoteTab, model: model, window: window))?.enabled == false,
                  "Automatic reconnect cannot be started twice")
        var localTab = model.tabs.first { $0.id == local }!
        localTab.exited = true
        try check(named("Reopen Terminal", in: SidebarActions.terminalItems(localTab, model: model, window: window)) != nil,
                  "Exited local shell can reopen")
        let original = model.tabs.first { $0.id == local }!
        let originalRows = model.panelRows(in: window).map(\.panelID)
        model.markClosed(local, lived: 10)
        model.reopenLocalTerminal(local)
        let reopened = model.tabs.first { $0.id == local }!
        try check(!reopened.exited && reopened.generation == original.generation + 1 && reopened.directory == original.directory,
                  "Reopen starts a fresh shell at the same directory and identity")
        try check(model.panelRows(in: window).map(\.panelID) == originalRows, "Reopen preserves sidebar panels and order")
        model.reopenLocalTerminal(local)
        try check(model.tabs.first { $0.id == local }!.generation == reopened.generation, "Reopen cannot restart a running shell")
    }

    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try check(predicate(), "Timed out waiting for model")
    }
}
