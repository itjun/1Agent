import AppKit
import SwiftUI

/// Captures one key press for the Shortcuts settings page. While it records, every key-down is
/// swallowed, and `AppDelegate.handleShortcut` lets keys through untouched (see `isRecording`).
@MainActor
final class ShortcutRecorder: ObservableObject {
    static let shared = ShortcutRecorder()

    @Published private(set) var recordingID: AppShortcutID?
    /// The recorder field under the mouse. A click there goes to its own button, which stops
    /// recording itself; a click anywhere else cancels.
    var hoveredID: AppShortcutID?

    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var onKey: ((NSEvent) -> Void)?

    static var isRecording: Bool {
        ShortcutRecorder.shared.recordingID != nil
    }

    func start(_ id: AppShortcutID, onKey: @escaping (NSEvent) -> Void) {
        stop()
        recordingID = id
        self.onKey = onKey
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if !event.isARepeat {
                    ShortcutRecorder.shared.onKey?(event)
                }
            }
            return nil
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                let recorder = ShortcutRecorder.shared
                if recorder.hoveredID == nil || recorder.hoveredID != recorder.recordingID {
                    recorder.stop()
                }
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ShortcutRecorder.shared.stop()
            }
        }
    }

    func stop() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        keyMonitor = nil
        mouseMonitor = nil
        resignObserver = nil
        onKey = nil
        if recordingID != nil {
            recordingID = nil
        }
    }
}

/// A recorded chord that another shortcut already uses, waiting for "Use Anyway" or "Cancel".
private struct PendingShortcutConflict {
    let id: AppShortcutID
    let chord: KeyChord
    let other: AppShortcutID
}

/// Settings → Keyboard Shortcuts: every `AppShortcutID` by group, each with a recorder field and a
/// restore-default button. Changes are written through `AppShortcuts` and take effect at once.
struct ShortcutsSettingsPage: View {
    @Environment(\.windowChrome) private var chrome
    @AppStorage(AppShortcuts.revisionKey) private var shortcutsRevision = 0
    @ObservedObject private var recorder = ShortcutRecorder.shared
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// Row that shows a refusal under it ("needs a modifier", "reserved by the system").
    @State private var hintID: AppShortcutID?
    @State private var hintText = ""
    @State private var pendingConflict: PendingShortcutConflict?
    @State private var confirmsResetAll = false

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let _ = shortcutsRevision
        let bindings = AppShortcuts.bindings()
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            HStack(spacing: Theme.Space.m) {
                searchField
                Button("Restore All Defaults") {
                    recorder.stop()
                    confirmsResetAll = true
                }
                .disabled(AppShortcutID.allCases.allSatisfy { bindings[$0] == $0.defaultChord })
            }

            let groups = AppShortcutGroup.allCases.filter { !matchingIDs(in: $0, bindings: bindings).isEmpty }
            if groups.isEmpty {
                Text("No matching shortcuts")
                    .font(Theme.Font.body)
                    .foregroundStyle(chrome.secondary)
            }
            ForEach(groups, id: \.self) { group in
                SettingsCard(ShortcutsSettingsPage.cardTitle(group)) {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(matchingIDs(in: group, bindings: bindings)) { id in
                            row(id, chord: bindings[id] ?? id.defaultChord)
                        }
                    }
                }
            }

            Text("Click a shortcut, then press the new keys. Esc cancels; Delete clears it.")
                .font(Theme.Font.rowMeta)
                .foregroundStyle(chrome.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear {
            recorder.stop()
        }
        .alert("Restore all shortcuts to their defaults?", isPresented: $confirmsResetAll) {
            Button("Restore Defaults", role: .destructive) {
                AppShortcuts.resetAll()
                clearNotices()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every shortcut you changed or cleared goes back to its default.")
        }
    }

    private static func cardTitle(_ group: AppShortcutGroup) -> LocalizedStringKey {
        switch group {
        case .app: return "App"
        case .sidebar: return "Sidebar"
        case .pane: return "Panes"
        case .terminal: return "Terminal"
        }
    }

    /// Matches the action name or the key text, e.g. "清屏" or "⌘K".
    private func matchingIDs(in group: AppShortcutGroup, bindings: [AppShortcutID: KeyChord]) -> [AppShortcutID] {
        let ids = AppShortcutID.allCases.filter { $0.group == group }
        if trimmedQuery.isEmpty {
            return ids
        }
        return ids.filter { id in
            let display = (bindings[id] ?? id.defaultChord).display
            return id.title.localizedCaseInsensitiveContains(trimmedQuery)
                || display.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private func row(_ id: AppShortcutID, chord: KeyChord) -> some View {
        let isDefault = chord == id.defaultChord
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Text(id.title)
                    .font(Theme.Font.body)
                    .foregroundStyle(chrome.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                recorderField(id, chord: chord)
                Button {
                    recorder.stop()
                    clearNotices()
                    AppShortcuts.resetToDefault(id)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(chrome.accent)
                        .frame(width: SettingsLayout.shortcutResetButtonSize, height: SettingsLayout.shortcutResetButtonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FamilyButtonStyle())
                .help(String(format: String(localized: "Restore default (%@)"), id.defaultChord.display))
                .opacity(isDefault ? 0 : 1)
                .disabled(isDefault)
            }
            if hintID == id {
                Text(hintText)
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.danger)
            }
            if let conflict = pendingConflict, conflict.id == id {
                conflictBar(conflict)
            }
        }
    }

    private func recorderField(_ id: AppShortcutID, chord: KeyChord) -> some View {
        let recording = recorder.recordingID == id
        var label = chord.display
        var labelColor = chrome.text
        if recording {
            label = String(localized: "Press shortcut…")
            labelColor = chrome.secondary
        } else if chord.isUnbound {
            labelColor = chrome.tertiary
        }
        return Button {
            if recording {
                recorder.stop()
                return
            }
            clearNotices()
            recorder.start(id) { event in
                handleRecordedKey(event, for: id)
            }
        } label: {
            Text(verbatim: label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .frame(width: SettingsLayout.shortcutRecorderWidth, height: SettingsLayout.shortcutRecorderHeight)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(chrome.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .stroke(recording ? chrome.accent : chrome.hairline, lineWidth: recording ? 2 : 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(FamilyButtonStyle())
        .help("Click to record a new shortcut")
        .onHover { hovering in
            if hovering {
                recorder.hoveredID = id
            } else if recorder.hoveredID == id {
                recorder.hoveredID = nil
            }
        }
    }

    private func conflictBar(_ conflict: PendingShortcutConflict) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(String(format: String(localized: "Conflicts with “%@”"), conflict.other.title))
                .font(Theme.Font.rowMeta)
                .foregroundStyle(chrome.danger)
            Spacer(minLength: Theme.Space.s)
            Button("Use Anyway (Clear Other)") {
                AppShortcuts.setChords([conflict.id: conflict.chord, conflict.other: .unbound])
                pendingConflict = nil
            }
            .controlSize(.small)
            Button("Cancel") {
                pendingConflict = nil
            }
            .controlSize(.small)
        }
    }

    private func handleRecordedKey(_ event: NSEvent, for id: AppShortcutID) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 {
            recorder.stop()
            clearNotices()
            return
        }
        // ⌫ (51) and ⌦ (117) without modifiers clear the shortcut; with modifiers they can be recorded.
        if (event.keyCode == 51 || event.keyCode == 117) && modifiers.isEmpty {
            recorder.stop()
            clearNotices()
            AppShortcuts.setChords([id: .unbound])
            return
        }
        guard let chord = KeyChord.pressed(by: event) else { return }
        switch AppShortcuts.check(chord, for: id, bindings: AppShortcuts.bindings()) {
        case .needsModifier:
            showHint(String(localized: "Include ⌘, ⌃ or ⌥"), for: id)
        case .reserved:
            showHint(String(format: String(localized: "%@ is reserved by the system"), chord.display), for: id)
        case .unchanged:
            recorder.stop()
            clearNotices()
        case .conflict(let other):
            recorder.stop()
            clearNotices()
            pendingConflict = PendingShortcutConflict(id: id, chord: chord, other: other)
        case .accepted:
            recorder.stop()
            clearNotices()
            AppShortcuts.setChords([id: chord])
        }
    }

    private func showHint(_ text: String, for id: AppShortcutID) {
        pendingConflict = nil
        hintID = id
        hintText = text
    }

    private func clearNotices() {
        hintID = nil
        hintText = ""
        pendingConflict = nil
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(chrome.secondary)
            TextField("Search shortcuts", text: $query)
                .focused($searchFocused)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .foregroundStyle(chrome.text)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(chrome.secondary)
                }
                .buttonStyle(FamilyButtonStyle())
                .help("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity)
        .frame(height: SettingsLayout.shortcutSearchHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(searchFocused ? chrome.background : chrome.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .stroke(searchFocused ? chrome.accent : chrome.hairline, lineWidth: 1)
        )
        .familyFocusRing(searchFocused)
    }
}
