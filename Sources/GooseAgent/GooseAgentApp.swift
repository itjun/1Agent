import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private var shortcutMonitor: Any?

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            model.openExternalURL(url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceDriver.shared.reapply()
        GooseAgentFocusRing.install()
        TerminalDefaults.registerBundledFonts()
        GhosttyRuntime.applyFontSettings()
        MainWindowManager.shared.attach(model: model)
        // Reading PATH from a login shell takes a moment; do it now so the first ⌘T does not wait.
        Task.detached(priority: .utility) { _ = await SSHLaunchEnvironment.shared.get() }
        model.watchSSHConfig()
        model.restoreLastSession()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                self.handleShortcut(event)
            }
        }
    }

    /// Clicking the Dock icon with every window closed opens a fresh one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, model.windows.isEmpty {
            model.newWindow()
        }
        return true
    }

    /// Cmd+D duplicates to the right and Cmd+Shift+D duplicates downward.
    /// Cmd+W closes the selected terminal so the window stays open. Ctrl+D is left for the shell.
    /// Everything acts on the key window.
    private func handleShortcut(_ event: NSEvent) -> NSEvent? {
        let window = model.keyWindow
        if event.keyCode == 53, let window, window.draggingTabID != nil || window.draggingBlock != nil {
            model.endDrag(in: window)
            return nil
        }
        guard let chord = KeyChord.from(event: event) else { return event }
        if let handled = switchPane(chord, in: window) {
            return handled ? nil : event
        }
        let duplicatesRight = chord == AppShortcuts.chord(for: .duplicateRight)
        let duplicatesDown = chord == AppShortcuts.chord(for: .duplicateDown)
        let closesTerminal = chord == AppShortcuts.chord(for: .closeTab)
            || chord == KeyChord(key: "w", modifiers: .command)
        guard duplicatesRight || duplicatesDown || closesTerminal else { return event }
        if NSApp.keyWindow?.identifier == SettingsWindowController.windowID {
            if chord == KeyChord(key: "w", modifiers: .command) {
                NSApp.keyWindow?.close()
            }
            return nil
        }
        guard let window else { return event }
        if window.hostPickerPresented {
            if closesTerminal {
                window.hostPickerPresented = false
            }
            return nil
        }
        if duplicatesRight || duplicatesDown {
            guard window.selectedTabID != nil else { return event }
            model.duplicateFocused(downward: duplicatesDown, in: window)
            return nil
        }
        // ⌘W with nothing selected closes the window itself, like any other Mac app.
        guard window.selectedTabID != nil else {
            MainWindowManager.shared.close(window)
            return nil
        }
        model.closeSelectedTab(in: window)
        return nil
    }

    /// Nil when the chord is not a pane-switching shortcut. False lets the key through.
    private func switchPane(_ chord: KeyChord, in window: WindowState?) -> Bool? {
        let paneShortcuts: [AppShortcutID] = [
            .nextPane, .previousPane, .paneLeft, .paneRight, .paneUp, .paneDown,
            .movePaneLeft, .movePaneRight, .movePaneUp, .movePaneDown,
        ]
        guard paneShortcuts.contains(where: { AppShortcuts.chord(for: $0) == chord }) else { return nil }
        guard let window else { return false }
        if NSApp.keyWindow?.identifier == SettingsWindowController.windowID || window.hostPickerPresented {
            return false
        }
        // Moving comes first: it shares the arrow keys with focusing and adds Shift.
        if chord == AppShortcuts.chord(for: .movePaneLeft) {
            return model.movePane(toward: .left, in: window)
        }
        if chord == AppShortcuts.chord(for: .movePaneRight) {
            return model.movePane(toward: .right, in: window)
        }
        if chord == AppShortcuts.chord(for: .movePaneUp) {
            return model.movePane(toward: .up, in: window)
        }
        if chord == AppShortcuts.chord(for: .movePaneDown) {
            return model.movePane(toward: .down, in: window)
        }
        if chord == AppShortcuts.chord(for: .nextPane) {
            return model.focusAdjacentPane(forward: true, in: window)
        }
        if chord == AppShortcuts.chord(for: .previousPane) {
            return model.focusAdjacentPane(forward: false, in: window)
        }
        if chord == AppShortcuts.chord(for: .paneLeft) {
            return model.focusPane(toward: .left, in: window)
        }
        if chord == AppShortcuts.chord(for: .paneRight) {
            return model.focusPane(toward: .right, in: window)
        }
        if chord == AppShortcuts.chord(for: .paneUp) {
            return model.focusPane(toward: .up, in: window)
        }
        return model.focusPane(toward: .down, in: window)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quitting closes every window; mark it first so those closes keep the terminals in the snapshot.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.isQuitting = true
        model.persistSessionIfReady()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.persistSessionIfReady()
    }
}

@main
struct GooseAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppLanguage.synchronize()
        TerminalThemeChoice.migrateIfNeeded()
    }

    /// Main windows are AppKit windows run by `MainWindowManager`, so several can share one model.
    /// The Settings scene only exists to give the app a scene; ⌘, is replaced below.
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { appDelegate.model.newTab() }
                    .keyboardShortcut(
                        AppShortcuts.chord(for: .newTab).keyEquivalent,
                        modifiers: AppShortcuts.chord(for: .newTab).modifiers
                    )
                Button("New Window") { appDelegate.model.newWindow() }
                    .keyboardShortcut(
                        AppShortcuts.chord(for: .newWindow).keyEquivalent,
                        modifiers: AppShortcuts.chord(for: .newWindow).modifiers
                    )
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings") { appDelegate.model.toggleSettings() }
                    .keyboardShortcut(
                        AppShortcuts.chord(for: .settings).keyEquivalent,
                        modifiers: AppShortcuts.chord(for: .settings).modifiers
                    )
            }
        }
    }
}
