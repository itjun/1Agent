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
        GooseAgentFocusRing.install()
        TerminalDefaults.registerBundledFonts()
        model.restoreLastSession()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                self.handleShortcut(event)
            }
        }
    }

    /// Cmd+D duplicates to the right and Cmd+Shift+D duplicates downward.
    /// Cmd+W closes the selected terminal so the window stays open. Ctrl+D is left for the shell.
    private func handleShortcut(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53, model.draggingTabID != nil {
            model.endDrag()
            return nil
        }
        guard let chord = KeyChord.from(event: event) else { return event }
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
        if model.hostPickerPresented {
            if closesTerminal {
                model.hostPickerPresented = false
            }
            return nil
        }
        if duplicatesRight || duplicatesDown {
            guard model.selectedTabID != nil else { return event }
            model.duplicateFocused(downward: duplicatesDown)
            return nil
        }
        guard model.selectedTabID != nil else { return event }
        model.closeSelectedTab()
        return nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
    }

    var body: some Scene {
        Window(String(localized: "1Agent"), id: "main") {
            RootView(model: appDelegate.model)
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { appDelegate.model.newTab() }
                    .keyboardShortcut(
                        AppShortcuts.chord(for: .newTab).keyEquivalent,
                        modifiers: AppShortcuts.chord(for: .newTab).modifiers
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
