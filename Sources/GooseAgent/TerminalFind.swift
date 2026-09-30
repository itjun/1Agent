import AppKit
import SwiftUI

/// One pane's find bar. Memory only; never saved with the session.
@MainActor
final class TerminalFindState: ObservableObject {
    let sessionID: String
    @Published var query = ""
    /// Changed only through `TerminalFind`, which also keeps `openSessionIDs` in step.
    @Published fileprivate(set) var isOpen = false
    /// Ghostty refused `search:` for the current query.
    @Published var failed = false
    /// Set to move the keyboard into the field and select its text; the field clears it.
    @Published var wantsFieldFocus = false
    weak var terminal: SSHTerminalNSView?
    fileprivate var pendingSearch: DispatchWorkItem?

    init(sessionID: String) {
        self.sessionID = sessionID
    }
}

/// Find bars keyed by terminal session. The engine keeps the matches and highlights; the bar only
/// sends `search:` / `navigate_search:` / `end_search`. libghostty does not report match counts here,
/// so the bar shows none.
@MainActor
final class TerminalFind: ObservableObject {
    static let shared = TerminalFind()

    /// Typing pauses this long before the terminal searches again.
    static let searchDelay: TimeInterval = 0.12

    @Published private(set) var states: [String: TerminalFindState] = [:]
    /// Panes whose bar is showing. The canvas moves those terminals down so the bar hides no rows;
    /// Ghostty scrolls the current match to the top row.
    @Published private(set) var openSessionIDs: Set<String> = []

    /// The find field that has the keyboard in the key window, if any.
    static var editingField: TerminalFindTextField? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor,
              let delegate = editor.delegate else { return nil }
        // The field editor's delegate is the NSTextField being edited; Swift does not see that conformance.
        return (delegate as AnyObject) as? TerminalFindTextField
    }

    /// ⌘F. Opens the focused pane's bar, or selects the field's text when it is already open.
    func showFindBar() {
        guard let state = focusedState(creating: true) else { return }
        let wasOpen = state.isOpen
        setOpen(state, true)
        state.wantsFieldFocus = true
        if !wasOpen, !state.query.isEmpty {
            runSearch(state)
        }
    }

    /// ⌘G / ⇧⌘G. A closed bar with an earlier query opens again without taking the keyboard.
    func navigate(forward: Bool) {
        guard let state = focusedState(creating: false), !state.query.isEmpty else { return }
        if !state.isOpen {
            setOpen(state, true)
            runSearch(state)
        } else if state.pendingSearch != nil {
            runSearch(state)
        }
        let direction: String
        if forward {
            direction = "next"
        } else {
            direction = "previous"
        }
        state.terminal?.performBindingAction("navigate_search:\(direction)")
    }

    /// ⌘E. Searches for the first line of the terminal's selection. `readSelection()` is used instead of
    /// the engine's `search_selection`, which would not tell the bar what it searched for.
    func useSelectionForFind() {
        guard let state = focusedState(creating: true),
              let selection = state.terminal?.attachedSurface?.readSelection() else { return }
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? ""
        guard !firstLine.isEmpty else { return }
        state.query = firstLine
        setOpen(state, true)
        runSearch(state)
    }

    /// Esc or the close button: clears the highlights and gives the keyboard back to the terminal.
    func close(_ state: TerminalFindState) {
        state.pendingSearch?.cancel()
        state.pendingSearch = nil
        setOpen(state, false)
        state.failed = false
        state.wantsFieldFocus = false
        guard let terminal = state.terminal else { return }
        terminal.performBindingAction("end_search")
        terminal.window?.makeFirstResponder(terminal)
    }

    /// Esc typed in a terminal whose bar is open. Ghostty would end its search on the same key.
    func closeForFocusedTerminal() -> Bool {
        guard let terminal = FocusedTerminal.current,
              let id = terminal.sessionID,
              let state = states[id], state.isOpen else { return false }
        close(state)
        return true
    }

    func queryChanged(_ state: TerminalFindState) {
        state.pendingSearch?.cancel()
        let work = DispatchWorkItem { [weak self, weak state] in
            MainActor.assumeIsolated {
                guard let self, let state else { return }
                self.runSearch(state)
            }
        }
        state.pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TerminalFind.searchDelay, execute: work)
    }

    /// The pane closed.
    func forget(_ sessionID: String) {
        guard let state = states.removeValue(forKey: sessionID) else { return }
        state.pendingSearch?.cancel()
        state.pendingSearch = nil
        openSessionIDs.remove(sessionID)
    }

    private func setOpen(_ state: TerminalFindState, _ open: Bool) {
        state.isOpen = open
        if open {
            openSessionIDs.insert(state.sessionID)
        } else {
            openSessionIDs.remove(state.sessionID)
        }
    }

    private func runSearch(_ state: TerminalFindState) {
        state.pendingSearch?.cancel()
        state.pendingSearch = nil
        guard let terminal = state.terminal else { return }
        if state.query.isEmpty {
            terminal.performBindingAction("end_search")
            state.failed = false
            return
        }
        state.failed = !terminal.performBindingAction("search:\(state.query)")
    }

    /// The pane whose find field has the keyboard, else the focused terminal's pane.
    private func focusedState(creating: Bool) -> TerminalFindState? {
        if let state = TerminalFind.editingField?.findState {
            return state
        }
        guard let terminal = FocusedTerminal.current, let id = terminal.sessionID else { return nil }
        if let existing = states[id] {
            existing.terminal = terminal
            return existing
        }
        guard creating else { return nil }
        let state = TerminalFindState(sessionID: id)
        state.terminal = terminal
        states[id] = state
        return state
    }
}

/// Strip under a pane's title bar (and under the connection banner when both show).
struct TerminalFindBar: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject var state: TerminalFindState
    /// Re-renders the button hints when a shortcut changes.
    @AppStorage(AppShortcuts.revisionKey) private var shortcutsRevision = 0
    /// The field took the keyboard; the pane becomes the selected one.
    var onFocus: () -> Void

    var body: some View {
        let _ = shortcutsRevision
        if state.isOpen {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: Theme.PaneStyle.findIconSize, weight: .medium))
                    .foregroundStyle(chrome.secondary)
                TerminalFindField(state: state, onFocus: onFocus)
                    .padding(.horizontal, Theme.Space.s)
                    .frame(maxWidth: Theme.PaneStyle.findFieldMaxWidth)
                    .frame(height: Theme.PaneStyle.findFieldHeight)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.Radius.row)
                            .fill(chrome.background)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.row)
                            .strokeBorder(state.failed ? chrome.danger : chrome.hairline, lineWidth: 1)
                    }
                // Ghostty's `navigate_search:next` starts at the bottom match and walks up into older
                // output, so ↑ is Find Next and ↓ is Find Previous, as in Ghostty's own find bar.
                button(
                    "chevron.up",
                    help: TerminalFindBar.help(String(localized: "Find Next"), AppShortcuts.display(for: .findNext))
                ) {
                    TerminalFind.shared.navigate(forward: true)
                }
                button(
                    "chevron.down",
                    help: TerminalFindBar.help(String(localized: "Find Previous"), AppShortcuts.display(for: .findPrevious))
                ) {
                    TerminalFind.shared.navigate(forward: false)
                }
                Spacer(minLength: 0)
                button("xmark", help: TerminalFindBar.help(String(localized: "Hide Find Bar"), "Esc")) {
                    TerminalFind.shared.close(state)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                VStack(spacing: 0) {
                    chrome.sidebarBackground
                    chrome.hairline
                        .frame(height: 1)
                }
            }
            .contentShape(Rectangle())
        }
    }

    private static func help(_ title: String, _ shortcut: String) -> String {
        "\(title) (\(shortcut))"
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Theme.PaneStyle.findIconSize, weight: .medium))
                .foregroundStyle(chrome.secondary)
                .frame(width: Theme.PaneStyle.findButtonSize, height: Theme.PaneStyle.findButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

/// The query field. AppKit rather than SwiftUI so ⏎ / ⇧⏎ / Esc and "take the keyboard now" are reliable.
final class TerminalFindTextField: NSTextField {
    weak var findState: TerminalFindState?
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocus?()
        }
        FocusedTerminal.shared.refreshSoon()
        return accepted
    }
}

struct TerminalFindField: NSViewRepresentable {
    @ObservedObject var state: TerminalFindState
    var onFocus: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalFindTextField {
        let field = TerminalFindTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = String(localized: "Find in Terminal")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: TerminalFindTextField, context: Context) {
        field.findState = state
        field.onFocus = onFocus
        if field.stringValue != state.query {
            field.stringValue = state.query
        }
        if state.wantsFieldFocus {
            DispatchQueue.main.async { [weak field, weak state] in
                MainActor.assumeIsolated {
                    guard let field, let state, state.wantsFieldFocus else { return }
                    state.wantsFieldFocus = false
                    guard let window = field.window else { return }
                    window.makeFirstResponder(field)
                    field.currentEditor()?.selectAll(nil)
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? TerminalFindTextField,
                  let state = field.findState else { return }
            // Pinyin still being composed is not a query yet.
            if let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView, editor.hasMarkedText() {
                return
            }
            state.query = field.stringValue
            TerminalFind.shared.queryChanged(state)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            FocusedTerminal.shared.refreshSoon()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? TerminalFindTextField, let state = field.findState else { return false }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                TerminalFind.shared.navigate(forward: !shift)
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                TerminalFind.shared.close(state)
                return true
            }
            return false
        }
    }
}
