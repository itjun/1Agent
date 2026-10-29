import AppKit

/// Terminal context actions and the pane-title status card.
/// Actions keep the pane identity that opened the menu; they never act on whichever
/// terminal happens to own the keyboard when the popup dismisses.
@MainActor
enum TerminalPaneActions {
    /// A remote title lists what its shell reported. It does not switch tabs.
    static func titleItems(model: AppModel, window: WindowState, tabID: UUID? = nil) -> [FamilyMenuItem] {
        guard let tabID, model.sidebarOrder(in: window).contains(tabID),
              let tab = currentTab(tabID, model: model), let host = model.remoteHostDescription(tab) else { return [] }
        return RemoteShellStatus.shared.detailLines(of: tab, host: host).map { line in
            FamilyMenuItem(title: line, enabled: false)
        }
    }

    static func title(of tab: TerminalTab) -> String {
        if let title = tab.contentTitle { return title }
        if !tab.isLocal { return tab.alias ?? String(localized: "Terminal") }
        return workingDirectory(of: tab).map(LocalTerminal.displayPath) ?? String(localized: "This Mac")
    }

    /// The card hangs from the middle of the title. A click with no anchor uses the window's title band.
    static func showTitleContext(model: AppModel, window: WindowState, tabID: UUID? = nil, anchor: NSView? = nil) {
        guard let owner = anchor?.window ?? MainWindowManager.shared.window(for: window) else { return }
        let items = titleItems(model: model, window: window, tabID: tabID)
        guard items.contains(where: { !$0.isSeparator }) else { return }
        DispatchQueue.main.async {
            if let anchor, anchor.window != nil {
                FamilyMenuPresenter.shared.show(items, centeredBelow: anchor)
            } else {
                let top = owner.frame.maxY - Theme.PaneStyle.titlebarHeight - 4
                FamilyMenuPresenter.shared.show(items, at: NSPoint(x: owner.frame.midX, y: top), owner: owner, centered: true)
            }
        }
    }

    /// Only genuine local directories can be handed to desktop editors.
    static func externalDirectory(of tab: TerminalTab) -> URL? {
        guard tab.isLocal, let path = workingDirectory(of: tab) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func externalItems(tab: TerminalTab, model: AppModel) -> [FamilyMenuItem] {
        guard externalDirectory(of: tab) != nil else { return [] }
        let editors = [("Cursor", "com.todesktop.230313mzl4w4u92"),
                       ("Visual Studio Code", "com.microsoft.VSCode"),
                       ("Zed", "dev.zed.Zed"), ("Xcode", "com.apple.dt.Xcode")]
        return editors.compactMap { name, bundleID in
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return FamilyMenuItem(title: name, action: {
                guard let current = currentTab(tab.id, model: model), let directory = externalDirectory(of: current) else { return }
                NSWorkspace.shared.open([directory], withApplicationAt: appURL, configuration: .init()) { _, error in
                    if let error { DispatchQueue.main.async { NSAlert(error: error).runModal() } }
                }
            })
        }
    }

    static func items(tab: TerminalTab, model: AppModel, window: WindowState,
                      includingFind: Bool = true, includingClose: Bool = true) -> [FamilyMenuItem] {
        if !tab.hasTerminal {
            guard includingClose else { return [] }
            let chord = AppShortcuts.chord(for: .closeTab)
            return [FamilyMenuItem(title: String(localized: "Close Preview"), destructive: true,
                                   key: chord.key, modifiers: chord.menuModifierMask, action: {
                guard model.sidebarOrder(in: window).contains(tab.id) else { return }
                model.closeTab(tab.id)
            })]
        }
        let directory = workingDirectory(of: tab)
        let split = model.panelRow(for: tab.id, in: window)?.isSplit == true
        let zoomed = model.zoomedPane(in: window) == tab.id
        var items = connectionItems(tab, model: model, window: window)
        if !items.isEmpty { items.append(.separator) }
        items += [
            FamilyMenuItem(title: String(localized: "Host Information"), action: {
                guard currentTab(tab.id, model: model) != nil else { return }
                window.hostInformationTabID = tab.id
            }),
            .separator,
            FamilyMenuItem(title: String(localized: "Working Directory"), enabled: false),
            FamilyMenuItem(title: directory ?? String(localized: "Directory Not Reported"), enabled: false),
            FamilyMenuItem(title: String(localized: "Copy Path"), enabled: directory != nil, action: {
                guard let current = currentTab(tab.id, model: model), let path = workingDirectory(of: current) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }),
        ]
        if tab.isLocal {
            items.append(FamilyMenuItem(title: String(localized: "Reveal in Finder"), enabled: directory != nil, action: {
                guard let current = currentTab(tab.id, model: model), current.isLocal,
                      let path = workingDirectory(of: current) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
            }))
        }
        let editors = externalItems(tab: tab, model: model)
        if !editors.isEmpty {
            items.append(FamilyMenuItem(title: String(localized: "Open In…"), children: editors))
        }
        items += [
            FamilyMenuItem(title: String(localized: "Open Files"), action: {
                guard currentTab(tab.id, model: model) != nil else { return }
                model.showFiles(for: tab.id, in: window)
            }),
            .separator,
            FamilyMenuItem(title: String(localized: "Split View"), enabled: !tab.isLocal || directory != nil, children: [
                splitItem(String(localized: "Split Left"), edge: .left, tabID: tab.id, model: model),
                splitItem(AppShortcutID.duplicateRight.title, edge: .right, shortcut: .duplicateRight, tabID: tab.id, model: model),
                splitItem(String(localized: "Split Up"), edge: .top, tabID: tab.id, model: model),
                splitItem(AppShortcutID.duplicateDown.title, edge: .bottom, shortcut: .duplicateDown, tabID: tab.id, model: model),
            ]),
        ]
        if !zoomed {
            items.append(command(.toggleSplitZoom, enabled: split) {
                guard currentTab(tab.id, model: model) != nil else { return }
                model.selectOnly(tab.id, in: window, focusTerminal: false)
                model.toggleSplitZoom(in: window)
            })
        }
        // The terminal's own context menu already owns Find and its native responder target.
        if includingFind {
            items += [
                .separator,
                command(.find) { find(tabID: tab.id, model: model, window: window) },
            ]
        }
        if includingClose { items += [
            command(.closeTab, destructive: true) {
                guard model.sidebarOrder(in: window).contains(tab.id) else { return }
                model.closeTab(tab.id)
            },
        ] }
        return items
    }

    private static func connectionItems(_ tab: TerminalTab, model: AppModel, window: WindowState) -> [FamilyMenuItem] {
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
        if !tab.isLocal {
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
                FamilyMenuItem(title: String(localized: "Connection Info"), action: {
                    guard let current = currentTab(tab.id, model: model) else { return }
                    copySessionInfo(current, model: model)
                }),
            ]))
        }
        return items
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func showContext(tab: TerminalTab, model: AppModel, window: WindowState) {
        guard let owner = MainWindowManager.shared.window(for: window) else { return }
        FamilyMenuPresenter.shared.show(items(tab: tab, model: model, window: window), at: NSEvent.mouseLocation, owner: owner)
    }

    /// Remote cwd only comes from its OSC report or explicit launch directory. The local
    /// ssh process's cwd is never a substitute for a remote directory.
    static func workingDirectory(of tab: TerminalTab) -> String? {
        let path = tab.isLocal
            ? SSHTerminalRegistry.currentWorkingDirectory(for: tab.sessionID) ?? tab.directory
            : tab.remoteDirectory
        guard let path, path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return path
    }

    private static func currentTab(_ id: UUID, model: AppModel) -> TerminalTab? {
        model.tabs.first { $0.id == id && $0.hasTerminal }
    }

    private static func command(_ shortcut: AppShortcutID, enabled: Bool = true, checked: Bool = false, destructive: Bool = false,
                                action: @escaping () -> Void) -> FamilyMenuItem {
        let chord = AppShortcuts.chord(for: shortcut)
        return FamilyMenuItem(title: shortcut.title, enabled: enabled, checked: checked, destructive: destructive,
                              key: chord.key, modifiers: chord.menuModifierMask, action: action)
    }

    private static func splitItem(_ title: String, edge: SplitEdge, shortcut: AppShortcutID? = nil,
                                  tabID: UUID, model: AppModel) -> FamilyMenuItem {
        let chord = shortcut.map { AppShortcuts.chord(for: $0) }
        return FamilyMenuItem(title: title, key: chord?.key ?? "", modifiers: chord?.menuModifierMask ?? [], action: {
            guard currentTab(tabID, model: model) != nil else { return }
            model.duplicate(tabID, edge: edge)
        })
    }

    private static func find(tabID: UUID, model: AppModel, window: WindowState) {
        guard let tab = currentTab(tabID, model: model) else { return }
        model.selectOnly(tabID, in: window)
        // Registry focus is queued. Queue find behind it, then verify the actual responder
        // before invoking the focused-terminal API. Closed panes cannot redirect the action.
        SSHTerminalRegistry.focus(tab.sessionID)
        DispatchQueue.main.async {
            guard currentTab(tabID, model: model)?.sessionID == tab.sessionID,
                  window.selectedTabID == tabID,
                  FocusedTerminal.current?.sessionID == tab.sessionID else { return }
            TerminalFind.shared.showFindBar()
        }
    }
}
