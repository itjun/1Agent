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
        var items: [FamilyMenuItem] = []
        if multiple {
            items.append(FamilyMenuItem(title: String(format: String(localized: "%lld Panels, %lld Terminals Selected"),
                rows.count, ids.count), enabled: false))
        } else if let tab = model.tabs.first(where: { $0.id == row.focusedTabID }) {
            var sessionItems = terminalItems(tab, model: model, window: window)
            if row.isSplit {
                sessionItems += [.separator, FamilyMenuItem(title: String(localized: "Close Current Terminal"), destructive: true, action: {
                    guard currentTab(tab.id, model: model) != nil else { return }
                    model.closeTab(tab.id)
                })]
                items.append(FamilyMenuItem(title: String(format: String(localized: "Current Terminal: %@"),
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
        if !multiple {
            items.append(FamilyMenuItem(title: String(localized: "Rename…"), action: onRename))
        }
        items.append(.separator)
        items += membershipItems(ids, model: model, window: window)
        items.append(.separator)
        let closeTitle: String
        if multiple {
            closeTitle = String(format: String(localized: "Close %lld Selected Terminals…"), ids.count)
        } else if row.isSplit {
            closeTitle = String(format: String(localized: "Close %lld Terminals in This Panel…"), ids.count)
        } else {
            closeTitle = String(localized: "Close Terminal")
        }
        items.append(FamilyMenuItem(title: closeTitle, destructive: true, action: {
            close(ids, model: model, window: window, confirm: ids.count > 1)
        }))
        return items
    }

    static func terminalItems(_ tab: TerminalTab, model: AppModel, window: WindowState) -> [FamilyMenuItem] {
        guard tab.hasTerminal else { return [] }
        let directory = TerminalPaneActions.workingDirectory(of: tab)
        var items = [FamilyMenuItem(title: tab.isLocal ? String(localized: "New Terminal Here") : String(localized: "New Connection"),
            enabled: !tab.isLocal || directory != nil, action: {
                guard currentTab(tab.id, model: model) != nil else { return }
                model.duplicateAsTab(tab.id, in: window)
            })]
        if tab.isLocal {
            if tab.exited {
                items.append(FamilyMenuItem(title: String(localized: "Reopen Terminal"), action: {
                    model.reopenLocalTerminal(tab.id)
                }))
            }
        } else {
            items.append(FamilyMenuItem(title: tab.reconnecting ? String(localized: "Reconnecting…") : String(localized: "Reconnect"),
                enabled: tab.exited && !tab.reconnecting, action: {
                    guard let current = currentTab(tab.id, model: model), current.exited, !current.reconnecting else { return }
                    model.reconnect(tab.id)
                }))
        }
        items += [.separator, FamilyMenuItem(title: String(localized: "Open Files"), action: {
            guard currentTab(tab.id, model: model) != nil else { return }
            model.showFiles(for: tab.id, in: window)
        })]
        if tab.isLocal {
            items.append(FamilyMenuItem(title: String(localized: "Reveal in Finder"), enabled: directory != nil, action: {
                guard let current = currentTab(tab.id, model: model),
                      let path = TerminalPaneActions.workingDirectory(of: current) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
            }))
            let editors = TerminalPaneActions.externalItems(tab: tab, model: model)
            if !editors.isEmpty { items.append(FamilyMenuItem(title: String(localized: "Open With"), children: editors)) }
            items.append(copyPathItem(tab, model: model))
        } else {
            items.append(FamilyMenuItem(title: String(localized: "Copy Info"), children: [
                FamilyMenuItem(title: String(localized: "Host Address"), action: {
                    guard let current = currentTab(tab.id, model: model), let alias = current.alias else { return }
                    copy(model.host(alias)?.hostName ?? alias)
                }),
                FamilyMenuItem(title: String(localized: "SSH Command"), action: {
                    guard let alias = currentTab(tab.id, model: model)?.alias else { return }
                    // A quoted alias preserves the user's SSH config, including ProxyJump and port.
                    copy("ssh -- '" + alias.replacingOccurrences(of: "'", with: "'\\''") + "'")
                }),
                copyPathItem(tab, model: model),
                FamilyMenuItem(title: String(localized: "Connection Info"), action: {
                    guard let current = currentTab(tab.id, model: model) else { return }
                    copySessionInfo(current, model: model)
                }),
            ]))
        }
        items += [.separator, FamilyMenuItem(title: String(localized: "New Split"),
            enabled: !tab.isLocal || directory != nil, children: [
                splitItem(String(localized: "Split to Right"), .right, .duplicateRight, tab: tab, model: model),
                splitItem(String(localized: "Split to Bottom"), .bottom, .duplicateDown, tab: tab, model: model),
                splitItem(String(localized: "Split to Left"), .left, nil, tab: tab, model: model),
                splitItem(String(localized: "Split to Top"), .top, nil, tab: tab, model: model),
            ])]
        return items
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

    private static func splitItem(_ title: String, _ edge: SplitEdge, _ shortcut: AppShortcutID?,
                                  tab: TerminalTab, model: AppModel) -> FamilyMenuItem {
        let chord = shortcut.map { AppShortcuts.chord(for: $0) }
        return FamilyMenuItem(title: title, key: chord?.key ?? "", modifiers: chord?.menuModifierMask ?? [], action: {
            guard currentTab(tab.id, model: model) != nil else { return }
            model.duplicate(tab.id, edge: edge)
        })
    }

    private static func copyPathItem(_ tab: TerminalTab, model: AppModel) -> FamilyMenuItem {
        FamilyMenuItem(title: String(localized: "Copy Path"), enabled: TerminalPaneActions.workingDirectory(of: tab) != nil, action: {
            guard let current = currentTab(tab.id, model: model),
                  let path = TerminalPaneActions.workingDirectory(of: current) else { return }
            copy(path)
        })
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func currentTab(_ id: UUID, model: AppModel) -> TerminalTab? {
        model.tabs.first { $0.id == id && $0.hasTerminal }
    }

    private static func close(_ ids: [UUID], model: AppModel, window: WindowState, confirm needsConfirmation: Bool) {
        let existing = ids.filter { id in model.tabs.contains { $0.id == id } }
        guard !existing.isEmpty else { return }
        guard needsConfirmation else { model.closeTabs(existing); return }
        confirm(title: String(format: String(localized: "Close %lld Terminals?"), existing.count),
            detail: String(localized: "Running commands in these terminals will be interrupted."),
            button: String(localized: "Close Terminals"), window: window, destructive: true) {
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
