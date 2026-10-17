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
    }

    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try check(predicate(), "Timed out waiting for model")
    }
}
