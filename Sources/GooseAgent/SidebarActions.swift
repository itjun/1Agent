import AppKit

/// Menus capture the clicked panel's members, never the keyboard's current terminal.
/// Constructing a menu must not change selection, focus, or workspace membership.
@MainActor
enum SidebarActions {
    static func show(_ items: [FamilyMenuItem], in window: WindowState) {
        guard let owner = MainWindowManager.shared.window(for: window) else { return }
        FamilyMenuPresenter.shared.show(items, at: NSEvent.mouseLocation, owner: owner)
    }

    static func panelItems(_ row: TerminalPanelRow, model: AppModel, window: WindowState,
                           onRename: @escaping () -> Void) -> [FamilyMenuItem] {
        guard model.panelRows(in: window).contains(where: { $0.panelID == row.panelID }) else { return [] }
        let ids = model.sidebarTargets(clicking: row.focusedTabID, in: window)
        let rows = model.panelRows(in: window).filter { !Set($0.leafIDs).isDisjoint(with: ids) }
        let multiple = rows.count > 1
        let hasPreview = model.tabs.contains { ids.contains($0.id) && !$0.hasTerminal }
        var items: [FamilyMenuItem] = []
        if multiple {
            let title = hasPreview ? String(localized: "%lld Panels, %lld Panes Selected") : String(localized: "%lld Panels, %lld Terminals Selected")
            items.append(FamilyMenuItem(title: String(format: title,
                rows.count, ids.count), enabled: false))
        } else if let tab = model.tabs.first(where: { $0.id == row.focusedTabID }) {
            var sessionItems = terminalItems(tab, model: model, window: window)
            if row.isSplit {
                if !sessionItems.isEmpty { sessionItems.append(.separator) }
                let chord = AppShortcuts.chord(for: .closeTab)
                let closeTitle = tab.hasTerminal ? String(localized: "Close Current Terminal") : String(localized: "Close Current Preview")
                sessionItems += [FamilyMenuItem(title: closeTitle, destructive: true,
                    key: chord.key, modifiers: chord.menuModifierMask, action: {
                    guard model.tabs.contains(where: { $0.id == tab.id }) else { return }
                    model.closeTab(tab.id)
                })]
                let title = tab.hasTerminal ? String(localized: "Current Terminal: %@") : String(localized: "Current Preview: %@")
                items.append(FamilyMenuItem(title: String(format: title,
                    TerminalPaneActions.title(of: tab)), children: sessionItems))
            } else {
                items += sessionItems
            }
        }
        if !items.isEmpty && (multiple || row.isSplit) { items.append(.separator) }
        if ids.count > 1 {
            items.append(FamilyMenuItem(title: multiple ? String(localized: "Merge Panels") : String(localized: "Arrange Panel"),
                children: layoutItems(count: ids.count) { layout in
                    model.mergeSidebar(ids, onto: row.focusedTabID, as: layout, in: window)
                }))
            items.append(FamilyMenuItem(title: String(localized: "Detach Panels"),
                enabled: model.sidebarSplits(ids), action: { model.splitSidebar(ids, in: window) }))
        }
        if !items.isEmpty { items.append(.separator) }
        items += membershipItems(ids, model: model, window: window)
        let closeTitle: String
        if multiple {
            let title = hasPreview ? String(localized: "Close %lld Selected Panes…") : String(localized: "Close %lld Selected Terminals…")
            closeTitle = String(format: title, ids.count)
        } else if row.isSplit {
            let title = hasPreview ? String(localized: "Close %lld Panes in This Panel…") : String(localized: "Close %lld Terminals in This Panel…")
            closeTitle = String(format: title, ids.count)
        } else { closeTitle = hasPreview ? String(localized: "Close Preview") : String(localized: "Close Terminal") }
        items.append(.separator)
        let chord = !multiple && !row.isSplit ? AppShortcuts.chord(for: .closeTab) : nil
        items.append(FamilyMenuItem(title: closeTitle, destructive: true, key: chord?.key ?? "",
                                    modifiers: chord?.menuModifierMask ?? [], action: {
            close(ids, model: model, window: window, confirm: ids.count > 1)
        }))
        return items
    }

    static func terminalItems(_ tab: TerminalTab, model: AppModel, window: WindowState) -> [FamilyMenuItem] {
        guard tab.hasTerminal else { return [] }
        return TerminalPaneActions.items(tab: tab, model: model, window: window, includingFind: false, includingClose: false)
    }

    static func workspaceItems(_ workspace: Workspace, model: AppModel, window: WindowState,
                               onRename: @escaping () -> Void) -> [FamilyMenuItem] {
        let selected = model.panelRows(in: window).filter {
            !Set($0.leafIDs).isDisjoint(with: window.sidebarSelection)
        }.flatMap(\.leafIDs).filter { !workspace.members.contains($0) }
        let ids = workspace.members
        return [
            FamilyMenuItem(title: String(localized: "Rename…"), action: onRename),
            FamilyMenuItem(title: String(localized: "Add Selected Panels"), enabled: !selected.isEmpty, action: {
                guard model.workspace(for: workspace.id) != nil else { return }
                model.joinWorkspace(selected, workspace.id, beside: nil, after: true)
            }),
            .separator,
            FamilyMenuItem(title: String(localized: "Merge and Arrange"), enabled: ids.count > 1,
                children: layoutItems(count: ids.count) { model.applyWorkspaceLayout(workspace.id, $0) }),
            FamilyMenuItem(title: String(localized: "Detach Panels"), enabled: model.sidebarSplits(ids), action: {
                model.splitWorkspacePanels(workspace.id)
            }),
            .separator,
            FamilyMenuItem(title: String(localized: "Reconnect Disconnected Terminals"),
                enabled: model.tabs(in: workspace).contains { $0.hasTerminal && !$0.isLocal && $0.exited && !$0.reconnecting }, action: {
                    for id in ids {
                        guard let current = currentTab(id, model: model), !current.isLocal,
                              current.exited, !current.reconnecting else { continue }
                        model.reconnect(id)
                    }
                }),
            .separator,
            FamilyMenuItem(title: String(localized: "Dissolve Workspace…"), action: {
                guard model.workspace(for: workspace.id) != nil else { return }
                confirm(title: String(localized: "Dissolve Workspace?"),
                    detail: String(localized: "Terminals will stay open and existing split layouts will be preserved."),
                    button: String(localized: "Dissolve Workspace Now"), window: window) {
                        model.dissolveWorkspace(workspace.id)
                    }
            }),
            .separator,
            FamilyMenuItem(title: String(localized: "Close All Terminals…"), destructive: true, action: {
                close(ids, model: model, window: window, confirm: true)
            }),
        ]
    }

    private static func membershipItems(_ ids: [UUID], model: AppModel, window: WindowState) -> [FamilyMenuItem] {
        var items = [FamilyMenuItem(title: String(localized: "Create Workspace"), enabled: model.sidebarCanCreateArea(ids), action: {
            model.createAreaFromSidebar(ids, in: window)
        })]
        let destinations = model.workspacesByNumber.filter {
            $0.isGrouped && window.blocks.contains(.workspace($0.id)) && !Set(ids).isSubset(of: Set($0.members))
        }
        items.append(FamilyMenuItem(title: String(localized: "Move into Workspace"), enabled: !destinations.isEmpty,
            children: destinations.map { destination in
                FamilyMenuItem(title: workspaceTitle(destination), action: {
                    guard model.workspace(for: destination.id) != nil else { return }
                    model.joinWorkspace(ids, destination.id, beside: nil, after: true)
                })
            }))
        if model.workspaces.contains(where: { $0.isGrouped && !Set($0.members).isDisjoint(with: ids) }) {
            items.append(FamilyMenuItem(title: String(localized: "Move out of Workspace"), action: {
                model.removeSidebarFromWorkspace(ids, in: window)
            }))
        }
        return items
    }

    private static func layoutItems(count: Int, action: @escaping (WorkspaceLayout) -> Void) -> [FamilyMenuItem] {
        WorkspaceBoard.availableLayouts(paneCount: count).map { layout in
            FamilyMenuItem(title: workspaceLayoutTitle(layout), action: { action(layout) })
        }
    }

    private static func currentTab(_ id: UUID, model: AppModel) -> TerminalTab? {
        model.tabs.first { $0.id == id && $0.hasTerminal }
    }

    private static func close(_ ids: [UUID], model: AppModel, window: WindowState, confirm needsConfirmation: Bool) {
        let existing = ids.filter { id in model.tabs.contains { $0.id == id } }
        guard !existing.isEmpty else { return }
        guard needsConfirmation else { model.closeTabs(existing); return }
        let hasPreview = model.tabs.contains { existing.contains($0.id) && !$0.hasTerminal }
        let hasTerminal = model.tabs.contains { existing.contains($0.id) && $0.hasTerminal }
        let title = hasPreview ? String(localized: "Close %lld Panes?") : String(localized: "Close %lld Terminals?")
        let detail = hasTerminal ? String(localized: "Running commands in these terminals will be interrupted.") : String(localized: "These previews will be closed.")
        let button = hasPreview ? String(localized: "Close Panes") : String(localized: "Close Terminals")
        confirm(title: String(format: title, existing.count), detail: detail,
            button: button, window: window, destructive: true) {
                model.closeTabs(existing)
            }
    }

    private static func confirm(title: String, detail: String, button: String, window: WindowState,
                                destructive: Bool = false, action: @escaping () -> Void) {
        guard let owner = MainWindowManager.shared.window(for: window) else { return }
        let alert = FamilyAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = destructive ? .critical : .informational
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: owner) { if $0 == .alertFirstButtonReturn { action() } }
    }
}
