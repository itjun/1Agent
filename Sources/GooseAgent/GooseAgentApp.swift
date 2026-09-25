import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private var shortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        GooseAgentFocusRing.install()
        TerminalDefaults.registerBundledFonts()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                self.handleShortcut(event)
            }
        }
    }

    /// Cmd+W closes the selected tab. Swallowing the event keeps the window open.
    private func handleShortcut(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53, model.draggingTabID != nil {
            model.endDrag()
            return nil
        }
        guard let chord = KeyChord.from(event: event),
              chord == AppShortcuts.chord(for: .closeTab)
        else { return event }
        if model.hostPickerPresented {
            model.hostPickerPresented = false
            return nil
        }
        guard model.selectedTabID != nil else { return event }
        model.closeSelectedTab()
        return nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct GooseAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppLanguage.synchronize()
    }

    var body: some Scene {
        Window(String(localized: "Goose Agent"), id: "main") {
            RootView(model: appDelegate.model)
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
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
