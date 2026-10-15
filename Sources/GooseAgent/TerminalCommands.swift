import AppKit
import SwiftUI

/// The terminal that has the keyboard in the key window, if any. The Terminal menu acts on it.
@MainActor
final class FocusedTerminal: ObservableObject {
    static let shared = FocusedTerminal()

    @Published private(set) var isAvailable = false
    /// A focused terminal, or a pane's find field with the keyboard.
    @Published private(set) var canFind = false

    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        let names = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSApplication.didBecomeActiveNotification,
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    FocusedTerminal.shared.refresh()
                    // Coming back from another app, the read made right at didBecomeKey finds no terminal.
                    FocusedTerminal.shared.refreshSoon()
                }
            }
            observers.append(observer)
        }
    }

    static var current: SSHTerminalNSView? {
        NSApp.keyWindow?.firstResponder as? SSHTerminalNSView
    }

    /// First responder changes settle after the call that caused them, so this reads them a turn later.
    func refreshSoon() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                FocusedTerminal.shared.refresh()
            }
        }
    }

    func refresh() {
        // While another app is active there is no key window. Keeping the last state means the menu
        // does not depend on when the key window comes back after the app is activated again.
        if !NSApp.isActive {
            return
        }
        let available = FocusedTerminal.current != nil
        if available != isAvailable {
            isAvailable = available
        }
        let findable = available || TerminalFind.editingField != nil
        if findable != canFind {
            canFind = findable
        }
    }

    /// Runs a Ghostty binding action such as `increase_font_size:1` on the focused terminal.
    @discardableResult
    static func perform(_ action: String) -> Bool {
        guard let terminal = FocusedTerminal.current else { return false }
        return terminal.performBindingAction(action)
    }
}

/// Top-level Terminal menu and Edit → Find. Their shortcuts come from `AppShortcuts`; Ghostty's own
/// defaults for the same actions are unbound in `TerminalSettings.appOwnedGhosttyTriggers`.
struct TerminalCommands: Commands {
    @ObservedObject var focus: FocusedTerminal
    @ObservedObject var model: AppModel
    /// Zooms the selected pane of the main window, or shows all panes again.
    var toggleSplitZoom: () -> Void
    /// Rebuilds the items when a shortcut changes, so the new key equivalents apply without a relaunch.
    @AppStorage(AppShortcuts.revisionKey) private var shortcutsRevision = 0

    var body: some Commands {
        let _ = shortcutsRevision
        CommandMenu("Terminal") {
            if let window = model.keyWindow {
                TerminalWorkspaceMenu(model: model, window: window)
                Divider()
            }
            TerminalCommands.item(.increaseFontSize, action: "increase_font_size:1", enabled: focus.isAvailable)
            TerminalCommands.item(.decreaseFontSize, action: "decrease_font_size:1", enabled: focus.isAvailable)
            TerminalCommands.item(.resetFontSize, action: "reset_font_size", enabled: focus.isAvailable)
            Divider()
            TerminalCommands.item(.clearScreen, action: "clear_screen", enabled: focus.isAvailable)
            Divider()
            Button(AppShortcutID.toggleSplitZoom.title, action: toggleSplitZoom)
                .keyboardShortcut(AppShortcuts.chord(for: .toggleSplitZoom).keyboardShortcut)
                .disabled(!focus.isAvailable)
            Divider()
            TerminalCommands.item(.scrollToTop, action: "scroll_to_top", enabled: focus.isAvailable)
            TerminalCommands.item(.scrollToBottom, action: "scroll_to_bottom", enabled: focus.isAvailable)
            TerminalCommands.item(.scrollPageUp, action: "scroll_page_up", enabled: focus.isAvailable)
            TerminalCommands.item(.scrollPageDown, action: "scroll_page_down", enabled: focus.isAvailable)
            Divider()
            TerminalCommands.item(.previousPrompt, action: "jump_to_prompt:-1", enabled: focus.isAvailable)
            TerminalCommands.item(.nextPrompt, action: "jump_to_prompt:1", enabled: focus.isAvailable)
        }
        // Edit → Find, where every Mac app keeps it.
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                TerminalCommands.findItem(.find, enabled: focus.canFind) {
                    TerminalFind.shared.showFindBar()
                }
                TerminalCommands.findItem(.findNext, enabled: focus.canFind) {
                    TerminalFind.shared.navigate(forward: true)
                }
                TerminalCommands.findItem(.findPrevious, enabled: focus.canFind) {
                    TerminalFind.shared.navigate(forward: false)
                }
                Divider()
                TerminalCommands.findItem(.useSelectionForFind, enabled: focus.canFind) {
                    TerminalFind.shared.useSelectionForFind()
                }
            }
        }
    }

    private static func findItem(_ id: AppShortcutID, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(id.title, action: action)
            .keyboardShortcut(AppShortcuts.chord(for: id).keyboardShortcut)
            .disabled(!enabled)
    }

    private static func item(_ id: AppShortcutID, action: String, enabled: Bool) -> some View {
        Button(id.title) {
            FocusedTerminal.perform(action)
        }
        .keyboardShortcut(AppShortcuts.chord(for: id).keyboardShortcut)
        .disabled(!enabled)
    }

    /// Edit → Select All is the system's menu item; only its key equivalent follows `AppShortcuts`.
    @MainActor
    static func applySelectAllShortcut() {
        guard let menu = NSApp.mainMenu,
              let item = TerminalCommands.menuItem(with: #selector(NSText.selectAll(_:)), in: menu) else { return }
        let chord = AppShortcuts.chord(for: .selectAll)
        item.keyEquivalent = chord.key
        item.keyEquivalentModifierMask = chord.menuModifierMask
    }

    @MainActor
    private static func menuItem(with action: Selector, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.action == action {
                return item
            }
            if let submenu = item.submenu,
               let found = TerminalCommands.menuItem(with: action, in: submenu) {
                return found
            }
        }
        return nil
    }
}

/// Independent of the terminal's first responder: available while a TUI owns the mouse,
/// or while the user is selecting read-only history text.
struct TerminalWorkspaceMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState

    private var tab: TerminalTab? { model.selectedTab(in: window) }
    private var available: Bool { !window.presentation.fullFilesWorkspace && tab?.hasTerminal == true }

    var body: some View {
        Button("Reveal in Files") {
            if let tab { model.showFiles(for: tab.id, in: window) }
        }.disabled(!available)
        Toggle("History", isOn: Binding(
            get: { window.historyVisible },
            set: { _ in if let tab { model.toggleTerminalHistory(for: tab.id, in: window) } }
        )).disabled(!available)
    }
}
