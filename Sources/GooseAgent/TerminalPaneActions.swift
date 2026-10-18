import AppKit

/// Shared directory and layout commands for terminal and pane-title context menus.
/// Actions keep the pane identity that opened the menu; they never act on whichever
/// terminal happens to own the keyboard when the popup dismisses.
@MainActor
enum TerminalPaneActions {
    /// A title is the single entry to navigation, tabs and commands for that pane.
    static func titleItems(tab: TerminalTab?, model: AppModel, window: WindowState) -> [FamilyMenuItem] {
        let tabs = model.sidebarOrder(in: window).compactMap { id in model.tabs.first { $0.id == id } }
        let tabItems = tabs.map { target in
            FamilyMenuItem(title: title(of: target), checked: target.id == window.selectedTabID, action: {
                guard model.sidebarOrder(in: window).contains(target.id) else { return }
                model.selectOnly(target.id, in: window)
            })
        }
        var result: [FamilyMenuItem] = [
            FamilyMenuItem(title: String(localized: "Functions"), children: [
                FamilyMenuItem(title: String(localized: "Terminal"), checked: !window.presentation.fullFilesWorkspace, action: {
                    model.hideFiles(in: window)
                }),
                FamilyMenuItem(title: String(localized: "Files"), checked: window.presentation.fullFilesWorkspace, action: {
                    model.selectFilesLayout(.sideBySide, in: window)
                }),
                .separator,
                command(.newLocalTerminal) { model.openLocalTerminal(in: window) },
                command(.openHost) { model.openHostPicker(in: window, purpose: window.presentation.fullFilesWorkspace ? .files : .terminal) },
                command(.agentLauncher) { model.openAgentLauncher(in: window) },
                command(.settings) { SettingsWindowController.shared.show(model: model) },
            ]),
            FamilyMenuItem(title: String(localized: "Switch Tab"), enabled: !tabItems.isEmpty, children: tabItems),
        ]
        if let tab, tab.hasTerminal {
            result += [.separator] + items(tab: tab, model: model, window: window)
        }
        result += [.separator, command(.commandPalette) { model.openCommandPalette(in: window) }]
        if let tab {
            result.append(command(.closeTab) {
                guard model.sidebarOrder(in: window).contains(tab.id) else { return }
                model.closeTab(tab.id)
            })
        }
        return result
    }

    static func title(of tab: TerminalTab) -> String {
        if let title = tab.contentTitle { return title }
        if !tab.isLocal { return tab.alias ?? String(localized: "Terminal") }
        return workingDirectory(of: tab).map(LocalTerminal.displayPath) ?? String(localized: "This Mac")
    }

    static func showTitleContext(tab: TerminalTab, model: AppModel, window: WindowState) {
        guard let owner = MainWindowManager.shared.window(for: window) else { return }
        let point = NSEvent.mouseLocation
        DispatchQueue.main.async {
            FamilyMenuPresenter.shared.show(titleItems(tab: tab, model: model, window: window), at: point, owner: owner)
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
                      includingFind: Bool = true) -> [FamilyMenuItem] {
        let directory = workingDirectory(of: tab)
        let split = model.panelRow(for: tab.id, in: window)?.isSplit == true
        let zoomed = model.zoomedPane(in: window) == tab.id
        var items: [FamilyMenuItem] = [
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
            FamilyMenuItem(title: String(localized: "Reveal in Files"), action: {
                guard currentTab(tab.id, model: model) != nil else { return }
                model.showFiles(for: tab.id, in: window)
            }),
            .separator,
            FamilyMenuItem(title: String(localized: "Split View"), children: [
                splitItem(String(localized: "Split Left"), edge: .left, tabID: tab.id, model: model),
                splitItem(AppShortcutID.duplicateRight.title, edge: .right, shortcut: .duplicateRight, tabID: tab.id, model: model),
                splitItem(String(localized: "Split Up"), edge: .top, tabID: tab.id, model: model),
                splitItem(AppShortcutID.duplicateDown.title, edge: .bottom, shortcut: .duplicateDown, tabID: tab.id, model: model),
            ]),
            command(.toggleSplitZoom, enabled: split, checked: zoomed) {
                guard currentTab(tab.id, model: model) != nil else { return }
                model.selectOnly(tab.id, in: window, focusTerminal: false)
                model.toggleSplitZoom(in: window)
            },
        ]
        // The terminal's own context menu already owns Find and its native responder target.
        if includingFind {
            items += [
                .separator,
                command(.find) { find(tabID: tab.id, model: model, window: window) },
            ]
        }
        return items
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

    private static func command(_ shortcut: AppShortcutID, enabled: Bool = true, checked: Bool = false,
                                action: @escaping () -> Void) -> FamilyMenuItem {
        let chord = AppShortcuts.chord(for: shortcut)
        return FamilyMenuItem(title: shortcut.title, enabled: enabled, checked: checked,
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
