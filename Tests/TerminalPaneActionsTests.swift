import AppKit
import ObjectiveC
@testable import GooseAgent

/// Command-model checks against the production module. No shell or SSH session is launched.
@main
enum TerminalPaneActionsTests {
    @MainActor static func main() {
        let suite = "oneagent.pane-actions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let getter = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!
        let previous = method_getImplementation(getter)
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(getter, imp_implementationWithBlock(block))
        defer {
            method_setImplementation(getter, previous)
            defaults.removePersistentDomain(forName: suite)
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let model = AppModel()
        let window = WindowState()
        let local = TerminalTab(id: UUID(), alias: nil, directory: "/tmp/agent project", generation: 0, exited: false)
        let localItems = TerminalPaneActions.items(tab: local, model: model, window: window)
        expect(TerminalPaneActions.workingDirectory(of: local) == "/tmp/agent project", "local launch directory remains available before its process starts")
        expect(item("Reveal in Finder", in: localItems)?.enabled == true, "Finder belongs to local directory actions")
        expect(item("Copy Path", in: localItems)?.enabled == true, "known paths can be copied")

        var remote = TerminalTab(id: UUID(), alias: "remote", directory: "/wrong/local/path", generation: 0, exited: false)
        let unknownItems = TerminalPaneActions.items(tab: remote, model: model, window: window)
        expect(TerminalPaneActions.workingDirectory(of: remote) == nil, "remote sessions must never expose the local ssh process directory")
        expect(item("Copy Path", in: unknownItems)?.enabled == false, "unreported remote cwd cannot be copied as a fabricated path")
        expect(item("Reveal in Finder", in: unknownItems) == nil, "remote paths must not be sent to Finder")
        remote.remoteDirectory = "/srv/agent project"
        expect(TerminalPaneActions.workingDirectory(of: remote) == "/srv/agent project", "remote OSC or launch directory is retained verbatim")
        remote.remoteDirectory = "relative/path"
        expect(TerminalPaneActions.workingDirectory(of: remote) == nil, "relative paths are not claimed as current directories")
        remote.remoteDirectory = "/srv/invalid\0path"
        expect(TerminalPaneActions.workingDirectory(of: remote) == nil, "NUL paths are not actionable")

        let split = item("Split View", in: localItems)!
        expect(split.children.count == 4, "all four split directions are discoverable together")
        let custom = KeyChord(key: "r", modifiers: [.command, .control])
        AppShortcuts.setChords([.duplicateRight: custom], store: defaults)
        let customItems = TerminalPaneActions.items(tab: local, model: model, window: window)
        let right = item("Split View", in: customItems)!.children.first { $0.title == AppShortcutID.duplicateRight.title }!
        expect(right.key == custom.key && right.modifiers == custom.menuModifierMask, "menu shortcuts follow the user's saved binding")
        expect(customItems.contains { $0.title == AppShortcutID.closeTab.title }, "terminal context actions include closing their captured pane")

        // A popup can outlive its pane. A stale Find action must not touch a sibling's
        // selection or look up whichever terminal happens to be focused afterward.
        let sibling = UUID()
        window.selectedTabID = sibling
        customItems.first { $0.title == AppShortcutID.find.title }!.action()
        expect(window.selectedTabID == sibling, "a closed target must not redirect Find to another pane")
        mergedContextMenu(tab: local, model: model, window: window)
        expect(model.tabs.isEmpty, "building and dismissing actions must not launch sessions")
        sidebarState(defaults: defaults)
        titleNavigation()
        remoteTitleStatus()
        print("ok: merged terminal menu dispatch, directory ownership, split shortcuts, stale target safety, sidebar state preservation and remote title status")
    }

    @MainActor private static func remoteTitleStatus() {
        let model = AppModel()
        let window = model.mainWindow
        model.openRemoteTerminal("fixture-host", at: "/srv/fixture", placement: .newTab, beside: UUID(), in: window)
        let deadline = Date().addingTimeInterval(5)
        while !model.tabs.contains(where: { $0.alias == "fixture-host" }) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let tab = model.tabs.first { $0.alias == "fixture-host" }!
        let status = RemoteShellStatus.shared
        status.report(.commandStarted(nil), sessionID: tab.sessionID)
        status.report(.commandNamed("make build"), sessionID: tab.sessionID)
        status.report(.commandFinished(exitCode: 2), sessionID: tab.sessionID)
        expect(status.runningCommand(of: tab) == nil, "a command shorter than the show delay never replaces the directory")
        status.report(.commandStarted("vim build.sh"), sessionID: tab.sessionID)
        RunLoop.main.run(until: Date().addingTimeInterval(RemoteShellStatus.showDelay + 0.3))
        expect(status.runningCommand(of: tab) == "vim build.sh", "a longer command is shown after the delay")
        expect(RemoteShellStatus.shortDirectory("/root/diteng-knowall/knowall-logs") == "…/diteng-knowall/knowall-logs",
               "deep directories keep their last two folders")

        let menu = TerminalPaneActions.titleItems(model: model, window: window, tabID: tab.id)
        let titles = menu.map(\.title)
        expect(titles.first == "fixture-host", "the remote title menu starts with its host")
        expect(titles.contains(String(format: String(localized: "Directory: %@"), "/srv/fixture")), "the full remote directory is listed")
        expect(titles.contains { $0.contains("vim build.sh") }, "the running command is listed")
        expect(titles.contains { $0.contains("make build") && $0.contains(String(format: String(localized: "Exit Code %lld"), 2)) },
               "the last command and its exit code are listed")
        expect(menu.allSatisfy { !$0.enabled }, "status lines are information, not actions")
        expect(!menu.contains { $0.title == String(localized: "Switch Tab") }, "the title card does not switch tabs")
        expect(TerminalPaneActions.titleItems(model: model, window: window).isEmpty, "a title click without a pane shows nothing")
        if let path = ProcessInfo.processInfo.environment["ONEAGENT_REMOTE_MENU_SNAPSHOT"] {
            let owner = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            FamilyMenuPresenter.shared.show(menu, at: NSPoint(x: 600, y: 700), owner: owner)
            if let view = FamilyMenuPresenter.shared.panels.first?.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            }
            FamilyMenuPresenter.shared.dismiss()
        }

        status.report(.commandFinished(exitCode: 0), sessionID: tab.sessionID)
        expect(status.runningCommand(of: tab) == nil, "a finished command gives the title back to the directory")
        model.closeTab(tab.id)
        expect(status.states[tab.sessionID] == nil, "closing the tab forgets its remote status")
    }

    @MainActor private static func mergedContextMenu(tab: TerminalTab, model: AppModel, window: WindowState) {
        let terminal = SSHTerminalNSView(frame: .zero)
        var fallbackFilesActions = 0
        terminal.onRevealFiles = { fallbackFilesActions += 1 }
        terminal.paneMenuItems = {
            TerminalPaneActions.items(tab: tab, model: model, window: window, includingFind: false)
        }

        let nativeMenu = terminal.selectionContextMenu()
        // Exercise the actual delegate/filter path used by FamilyMenuPresenter. Pane
        // commands must survive it while an unrelated AppKit-added item is removed.
        nativeMenu.addItem(NSMenuItem(title: "External plugin fixture", action: nil, keyEquivalent: ""))
        let commands = FamilyMenuItem.commands(from: nativeMenu)
        expect(!commands.contains { $0.title == "External plugin fixture" }, "conversion invokes the native menu delegate")
        for title in [AppShortcutID.find.title, String(localized: "Open Files"), String(localized: "Host Information"),
                      AppShortcutID.commandPalette.title, AppShortcutID.closeTab.title] {
            expect(commands.filter { $0.title == title }.count == 1, "merged commands contain exactly one \(title)")
        }
        expect(item("Copy", in: commands)?.enabled == false, "Copy remains disabled without a terminal selection")
        expect(item("Paste", in: commands)?.enabled == true, "Paste remains available after merging pane commands")
        expect(commands.contains { $0.title == AppShortcutID.selectAll.title && $0.enabled }, "Select All is retained")
        expect(commands.contains { $0.title == AppShortcutID.clearScreen.title && $0.enabled }, "Clear Screen is retained")
        expect(item("Working Directory", in: commands)?.enabled == false, "directory headings remain informational")
        expect(commands.first { $0.title == tab.directory }?.enabled == false, "the current path remains informational")
        expect(item("Copy Path", in: commands)?.enabled == true, "a known local path remains actionable")
        expect(item("Reveal in Finder", in: commands)?.enabled == true, "local Finder reveal survives menu validation")

        let split = item("Split View", in: commands)!
        expect(split.enabled && split.children.count == 4, "all four split commands survive recursive conversion")
        expect(split.children.map(\.title) == [String(localized: "Split Left"), AppShortcutID.duplicateRight.title,
                                              String(localized: "Split Up"), AppShortcutID.duplicateDown.title],
               "split directions retain their menu order")
        for shortcut in [AppShortcutID.duplicateRight, .duplicateDown] {
            let child = split.children.first { $0.title == shortcut.title }!
            let chord = AppShortcuts.chord(for: shortcut)
            expect(child.enabled && child.key == chord.key && child.modifiers == chord.menuModifierMask,
                   "nested split commands retain the current saved shortcut")
        }
        let zoom = commands.first { $0.title == AppShortcutID.toggleSplitZoom.title }!
        expect(!zoom.enabled && !zoom.checked, "a single pane keeps Zoom disabled and unchecked")
        expect(item("History", in: commands) == nil, "terminal context menus no longer expose history")
        expect(item("History", in: TerminalPaneActions.items(tab: tab, model: model, window: window)) == nil,
               "title context menus no longer expose history")
        expect(!TerminalPaletteCommand.allCases.contains { $0.title == String(localized: "Terminal History") },
               "the command palette no longer exposes terminal history")

        // The tab is intentionally absent from the model, as when a menu outlives
        // its pane. Executing converted pane actions cannot select another terminal.
        let selected = window.selectedTabID
        let presentation = window.presentation
        let section = window.section
        item("Copy Path", in: commands)!.action()
        item("Open Files", in: commands)!.action()
        item("Host Information", in: commands)!.action()
        expect(window.hostInformationTabID == nil, "a stale Host Information action cannot show a sibling's information")
        zoom.action()
        split.children.forEach { $0.action() }
        expect(window.selectedTabID == selected && window.presentation == presentation && window.section == section,
               "stale pane actions retain their original target and leave a sibling's state untouched")
        expect(fallbackFilesActions == 0, "the merged pane reveal does not call the legacy fallback as well")

        let remote = TerminalTab(id: UUID(), alias: "remote", directory: "/wrong/local/path", generation: 0, exited: false)
        terminal.paneMenuItems = {
            TerminalPaneActions.items(tab: remote, model: model, window: window, includingFind: false)
        }
        let remoteCommands = FamilyMenuItem.commands(from: terminal.selectionContextMenu())
        expect(item("Reveal in Finder", in: remoteCommands) == nil, "a remote menu never exposes Finder")
        expect(item("Copy Path", in: remoteCommands)?.enabled == false, "unknown remote cwd remains disabled after bridging")
        expect(item("Directory Not Reported", in: remoteCommands)?.enabled == false, "unknown remote cwd remains explicit")
        expect(!remoteCommands.contains { $0.title == remote.directory }, "remote menus never show the local ssh directory")

        // Harmless fixture closures prove both levels of the bridge dispatch, without
        // opening sessions, changing clipboard contents or invoking file operations.
        var bridgeActions = 0
        terminal.paneMenuItems = {
            [FamilyMenuItem(title: "Enabled fixture", action: { bridgeActions += 1 }),
             FamilyMenuItem(title: "Disabled fixture", enabled: false, action: { bridgeActions += 100 }),
             FamilyMenuItem(title: "Submenu fixture", children: [
                FamilyMenuItem(title: "Checked child fixture", checked: true, key: "r", modifiers: [.command, .control],
                               action: { bridgeActions += 10 }),
             ])]
        }
        let bridged = FamilyMenuItem.commands(from: terminal.selectionContextMenu())
        bridged.first { $0.title == "Enabled fixture" }!.action()
        let disabled = bridged.first { $0.title == "Disabled fixture" }!
        expect(!disabled.enabled, "disabled pane commands survive native validation unchanged")
        disabled.action()
        let nested = bridged.first { $0.title == "Submenu fixture" }!.children[0]
        expect(nested.enabled && nested.checked && nested.key == "r" && nested.modifiers == [.command, .control],
               "recursive conversion retains checked state and shortcut metadata")
        nested.action()
        expect(bridgeActions == 11, "root and submenu closures execute once while a disabled action is guarded")

        terminal.paneMenuItems = { [] }
        let fallback = FamilyMenuItem.commands(from: terminal.selectionContextMenu())
        item("Open Files", in: fallback)!.action()
        expect(fallbackFilesActions == 1, "terminals without pane metadata retain their original Files callback")
        expect(terminal.processHost == nil, "menu construction and dispatch do not start a terminal process")
    }

    @MainActor private static func sidebarState(defaults: UserDefaults) {
        let model = AppModel()
        let window = model.mainWindow
        // Preview panes exercise the actual tab/panel tree without launching any process.
        model.open(.preview(path: "/tmp/oneagent-sidebar-a"), placement: .newTab, beside: UUID(), in: window)
        let first = window.selectedTabID!
        model.open(.preview(path: "/tmp/oneagent-sidebar-b"), placement: .split(.right), beside: first, in: window)
        let tabs = model.tabs
        let layouts = model.workspaces
        let selected = window.selectedTabID
        let selection = window.sidebarSelection
        let order = model.sidebarOrder(in: window)
        defaults.set(420.0, forKey: SidebarLayout.widthKey)
        window.presentation.filesVisible = true
        window.presentation.filesLayout = .sideBySide
        window.presentation.filesWidth = 612
        window.presentation.filesHeightRatio = 0.65
        window.section = .files
        window.presentation.sidebarCollapsed = false
        let original = window.presentation

        expect(model.sidebarIsCollapsed(in: window, totalWidth: 880), "a narrow files workspace may temporarily hide the sidebar")
        for expectedCollapsed in [true, false, true] {
            model.toggleSidebar(in: window)
            expect(window.presentation.sidebarCollapsed == expectedCollapsed, "repeated toggles alternate the explicit sidebar state")
            var expected = original
            expected.sidebarCollapsed = expectedCollapsed
            expect(window.presentation == expected, "sidebar toggles preserve the file layout, width and height ratio")
            expect(window.section == .files, "sidebar toggles must not switch the user's workspace mode")
            expect(defaults.double(forKey: SidebarLayout.widthKey) == 420, "sidebar toggles must retain the saved expanded width")
            expect(model.tabs == tabs && model.workspaces == layouts, "sidebar toggles preserve tab identities and split geometry")
            expect(window.selectedTabID == selected && window.sidebarSelection == selection,
                   "sidebar toggles preserve focus selection")
            expect(model.sidebarOrder(in: window) == order, "sidebar toggles preserve row order")
            if !expectedCollapsed {
                expect(!model.sidebarIsCollapsed(in: window, totalWidth: 880), "explicit reveal overrides the narrow-window collapse")
            }
        }
    }

    @MainActor private static func titleNavigation() {
        let model = AppModel()
        let window = model.mainWindow
        model.open(.preview(path: "/tmp/title-first"), placement: .newTab, beside: UUID(), in: window)
        let first = window.selectedTabID!
        model.open(.preview(path: "/tmp/title-second"), placement: .newTab, beside: first, in: window)
        let second = window.selectedTabID!
        expect(TerminalPaneActions.titleItems(model: model, window: window, tabID: first).isEmpty,
               "a local title click does not offer tab switching")
        let context = TerminalPaneActions.items(tab: model.tabs.first { $0.id == first }!, model: model, window: window)
        model.selectOnly(second, in: window, focusTerminal: false)
        context.first { $0.title == AppShortcutID.closeTab.title }!.action()
        expect(!model.tabs.contains { $0.id == first } && model.tabs.contains { $0.id == second },
               "Close from a terminal context menu retains its captured pane rather than closing the newly focused tab")
        model.open(.preview(path: "/tmp/title-third"), placement: .newTab, beside: second, in: window)
        expect(window.selectedTabID != second, "opening another tab leaves the closed pane closed")
        let local = TerminalTab(id: UUID(), alias: nil, directory: "/tmp/path with spaces", generation: 0, exited: false)
        var remote = TerminalTab(id: UUID(), alias: "fixture", directory: local.directory, generation: 0, exited: false)
        remote.remoteDirectory = "/srv/project"
        expect(TerminalPaneActions.externalDirectory(of: local)?.path == local.directory, "external tools receive an intact local directory URL")
        expect(TerminalPaneActions.externalDirectory(of: remote) == nil, "remote directories are never mistaken for local editor paths")
        expect(TerminalCanvas.headerHeight(for: CGRect(x: 0, y: 0, width: 500, height: 300)) == 0,
               "top-row panes use the window title band without a duplicate header")
        expect(TerminalCanvas.headerHeight(for: CGRect(x: 0, y: 305, width: 500, height: 300)) == Theme.PaneStyle.headerHeight,
               "lower split panes retain their own title and drag handle")
        let owner = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let anchor = NSView(frame: NSRect(x: 390, y: 540, width: 120, height: 32))
        owner.contentView?.addSubview(anchor)
        let presenter = FamilyMenuPresenter.shared
        presenter.show([FamilyMenuItem(title: "fixture-host", enabled: false)], centeredBelow: anchor)
        expect(presenter.panels.count == 1, "the title card opens under its anchor")
        let panel = presenter.panels[0]
        let anchorScreen = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        expect(abs(panel.frame.midX - anchorScreen.midX) < 1, "the title card is centered under the title")
        expect(abs(panel.frame.maxY - (anchorScreen.minY - 4)) < 1, "the title card sits just below the title")
        if let path = ProcessInfo.processInfo.environment["ONEAGENT_MENU_SNAPSHOT"],
           let view = panel.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        presenter.dismiss()
        owner.orderOut(nil)
    }

    @MainActor private static func item(_ key: String.LocalizationValue, in items: [FamilyMenuItem]) -> FamilyMenuItem? {
        let title = String(localized: key)
        return items.first { $0.title == title }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}
