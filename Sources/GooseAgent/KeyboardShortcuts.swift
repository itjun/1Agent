import AppKit
import SwiftUI

enum AppShortcutID: String, CaseIterable, Identifiable {
    case newTab
    case newLocalTerminal
    case openHost
    case toggleFullScreen
    case previousTerminal
    case nextTerminal
    case selectTerminal1
    case selectTerminal2
    case selectTerminal3
    case selectTerminal4
    case selectTerminal5
    case selectTerminal6
    case selectTerminal7
    case selectTerminal8
    case selectLastTerminal
    case terminalSwitcher
    case duplicateRight
    case duplicateDown
    case toggleSplitZoom
    case closeTab
    case settings
    case nextPane
    case previousPane
    case paneLeft
    case paneRight
    case paneUp
    case paneDown
    case movePaneLeft
    case movePaneRight
    case movePaneUp
    case movePaneDown
    case increaseFontSize
    case decreaseFontSize
    case resetFontSize
    case clearScreen
    case scrollToTop
    case scrollToBottom
    case scrollPageUp
    case scrollPageDown
    case selectAll
    case previousPrompt
    case nextPrompt
    case find
    case findNext
    case findPrevious
    case useSelectionForFind

    var id: String { rawValue }

    var group: AppShortcutGroup {
        switch self {
        case .newTab, .newLocalTerminal, .openHost, .toggleFullScreen, .settings:
            return .app
        case .previousTerminal, .nextTerminal,
             .selectTerminal1, .selectTerminal2, .selectTerminal3, .selectTerminal4,
             .selectTerminal5, .selectTerminal6, .selectTerminal7, .selectTerminal8, .selectLastTerminal, .terminalSwitcher:
            return .sidebar
        case .duplicateRight, .duplicateDown, .toggleSplitZoom, .closeTab, .nextPane, .previousPane,
             .paneLeft, .paneRight, .paneUp, .paneDown,
             .movePaneLeft, .movePaneRight, .movePaneUp, .movePaneDown:
            return .pane
        case .increaseFontSize, .decreaseFontSize, .resetFontSize, .clearScreen,
             .scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown,
             .selectAll, .previousPrompt, .nextPrompt,
             .find, .findNext, .findPrevious, .useSelectionForFind:
            return .terminal
        }
    }

    var title: String {
        switch self {
        case .newTab: return String(localized: "New Tab")
        case .newLocalTerminal: return String(localized: "New Local Terminal")
        case .openHost: return String(localized: "Open Host…")
        case .toggleFullScreen: return String(localized: "Toggle Full Screen")
        case .previousTerminal: return String(localized: "Previous Terminal")
        case .nextTerminal: return String(localized: "Next Terminal")
        case .selectTerminal1, .selectTerminal2, .selectTerminal3, .selectTerminal4,
             .selectTerminal5, .selectTerminal6, .selectTerminal7, .selectTerminal8:
            let number = terminalNumber ?? 0
            return String(localized: "Go to Terminal \(number)")
        case .selectLastTerminal: return String(localized: "Go to Last Terminal")
        case .terminalSwitcher: return String(localized: "Terminal Switcher")
        case .duplicateRight: return String(localized: "Split Right")
        case .duplicateDown: return String(localized: "Split Down")
        case .toggleSplitZoom: return String(localized: "Zoom Split")
        case .closeTab: return String(localized: "Close Terminal")
        case .settings: return String(localized: "Settings")
        case .nextPane: return String(localized: "Next Pane")
        case .previousPane: return String(localized: "Previous Pane")
        case .paneLeft: return String(localized: "Focus Pane Left")
        case .paneRight: return String(localized: "Focus Pane Right")
        case .paneUp: return String(localized: "Focus Pane Above")
        case .paneDown: return String(localized: "Focus Pane Below")
        case .movePaneLeft: return String(localized: "Move Pane Left")
        case .movePaneRight: return String(localized: "Move Pane Right")
        case .movePaneUp: return String(localized: "Move Pane Up")
        case .movePaneDown: return String(localized: "Move Pane Down")
        case .increaseFontSize: return String(localized: "Increase Font Size")
        case .decreaseFontSize: return String(localized: "Decrease Font Size")
        case .resetFontSize: return String(localized: "Reset Font Size")
        case .clearScreen: return String(localized: "Clear Screen")
        case .scrollToTop: return String(localized: "Scroll to Top")
        case .scrollToBottom: return String(localized: "Scroll to Bottom")
        case .scrollPageUp: return String(localized: "Page Up")
        case .scrollPageDown: return String(localized: "Page Down")
        case .selectAll: return String(localized: "Select All")
        case .previousPrompt: return String(localized: "Previous Command")
        case .nextPrompt: return String(localized: "Next Command")
        case .find: return String(localized: "Find…")
        case .findNext: return String(localized: "Find Next")
        case .findPrevious: return String(localized: "Find Previous")
        case .useSelectionForFind: return String(localized: "Use Selection for Find")
        }
    }

    /// Pane switching and terminal actions follow Ghostty's macOS defaults.
    var defaultChord: KeyChord {
        switch self {
        case .newTab: return KeyChord(key: "t", modifiers: .command)
        case .newLocalTerminal: return KeyChord(key: "t", modifiers: [.command, .shift])
        case .openHost: return KeyChord(key: "o", modifiers: .command)
        case .toggleFullScreen: return KeyChord(key: "f", modifiers: [.command, .control])
        case .previousTerminal: return KeyChord(key: "[", modifiers: [.command, .shift])
        case .nextTerminal: return KeyChord(key: "]", modifiers: [.command, .shift])
        case .selectTerminal1: return KeyChord(key: "1", modifiers: .command)
        case .selectTerminal2: return KeyChord(key: "2", modifiers: .command)
        case .selectTerminal3: return KeyChord(key: "3", modifiers: .command)
        case .selectTerminal4: return KeyChord(key: "4", modifiers: .command)
        case .selectTerminal5: return KeyChord(key: "5", modifiers: .command)
        case .selectTerminal6: return KeyChord(key: "6", modifiers: .command)
        case .selectTerminal7: return KeyChord(key: "7", modifiers: .command)
        case .selectTerminal8: return KeyChord(key: "8", modifiers: .command)
        case .selectLastTerminal: return KeyChord(key: "9", modifiers: .command)
        case .terminalSwitcher: return KeyChord(key: "\t", modifiers: .control)
        case .duplicateRight: return KeyChord(key: "d", modifiers: .command)
        case .duplicateDown: return KeyChord(key: "d", modifiers: [.command, .shift])
        case .toggleSplitZoom: return KeyChord(key: "\r", modifiers: [.command, .shift])
        case .closeTab: return KeyChord(key: "w", modifiers: .command)
        case .settings: return KeyChord(key: ",", modifiers: .command)
        case .nextPane: return KeyChord(key: "]", modifiers: .command)
        case .previousPane: return KeyChord(key: "[", modifiers: .command)
        case .paneLeft: return KeyChord(key: KeyChord.leftArrow, modifiers: [.command, .option])
        case .paneRight: return KeyChord(key: KeyChord.rightArrow, modifiers: [.command, .option])
        case .paneUp: return KeyChord(key: KeyChord.upArrow, modifiers: [.command, .option])
        case .paneDown: return KeyChord(key: KeyChord.downArrow, modifiers: [.command, .option])
        case .movePaneLeft: return KeyChord(key: KeyChord.leftArrow, modifiers: [.command, .option, .shift])
        case .movePaneRight: return KeyChord(key: KeyChord.rightArrow, modifiers: [.command, .option, .shift])
        case .movePaneUp: return KeyChord(key: KeyChord.upArrow, modifiers: [.command, .option, .shift])
        case .movePaneDown: return KeyChord(key: KeyChord.downArrow, modifiers: [.command, .option, .shift])
        case .increaseFontSize: return KeyChord(key: "=", modifiers: .command)
        case .decreaseFontSize: return KeyChord(key: "-", modifiers: .command)
        case .resetFontSize: return KeyChord(key: "0", modifiers: .command)
        case .clearScreen: return KeyChord(key: "k", modifiers: .command)
        case .scrollToTop: return KeyChord(key: KeyChord.home, modifiers: .command)
        case .scrollToBottom: return KeyChord(key: KeyChord.end, modifiers: .command)
        case .scrollPageUp: return KeyChord(key: KeyChord.pageUp, modifiers: .command)
        case .scrollPageDown: return KeyChord(key: KeyChord.pageDown, modifiers: .command)
        case .selectAll: return KeyChord(key: "a", modifiers: .command)
        case .previousPrompt: return KeyChord(key: KeyChord.upArrow, modifiers: .command)
        case .nextPrompt: return KeyChord(key: KeyChord.downArrow, modifiers: .command)
        case .find: return KeyChord(key: "f", modifiers: .command)
        case .findNext: return KeyChord(key: "g", modifiers: .command)
        case .findPrevious: return KeyChord(key: "g", modifiers: [.command, .shift])
        case .useSelectionForFind: return KeyChord(key: "e", modifiers: .command)
        }
    }

    /// 1…8 for Go to Terminal N, counted in sidebar order; nil for every other shortcut.
    var terminalNumber: Int? {
        switch self {
        case .selectTerminal1: return 1
        case .selectTerminal2: return 2
        case .selectTerminal3: return 3
        case .selectTerminal4: return 4
        case .selectTerminal5: return 5
        case .selectTerminal6: return 6
        case .selectTerminal7: return 7
        case .selectTerminal8: return 8
        default: return nil
        }
    }
}

/// Sections of the shortcut settings page.
enum AppShortcutGroup: String, CaseIterable {
    case app
    case sidebar
    case pane
    case terminal

    var title: String {
        switch self {
        case .app: return String(localized: "App")
        case .sidebar: return String(localized: "Sidebar")
        case .pane: return String(localized: "Panes")
        case .terminal: return String(localized: "Terminal")
        }
    }
}

struct KeyChord: Codable, Equatable, Hashable {
    /// AppKit reports arrow and navigation keys as these private-use characters in `charactersIgnoringModifiers`.
    static let upArrow = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    static let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    static let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    static let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
    static let home = String(UnicodeScalar(NSHomeFunctionKey)!)
    static let end = String(UnicodeScalar(NSEndFunctionKey)!)
    static let pageUp = String(UnicodeScalar(NSPageUpFunctionKey)!)
    static let pageDown = String(UnicodeScalar(NSPageDownFunctionKey)!)
    static let forwardDelete = String(UnicodeScalar(NSDeleteFunctionKey)!)

    /// Stored for a shortcut the user cleared. An empty key never comes from a key press, so
    /// data written before clearing existed decodes unchanged.
    static let unbound = KeyChord(key: "", modifiers: [])

    var key: String
    var modifierRaw: Int

    init(key: String, modifiers: EventModifiers) {
        self.key = key
        self.modifierRaw = Self.pack(modifiers)
    }

    var modifiers: EventModifiers { Self.unpack(modifierRaw) }

    var isUnbound: Bool { key.isEmpty }

    /// F1–F19 work without a modifier; every other key needs ⌘, ⌃ or ⌥.
    var isFunctionKey: Bool {
        guard let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 else { return false }
        return scalar.value >= UInt32(NSF1FunctionKey) && scalar.value <= UInt32(NSF19FunctionKey)
    }

    var hasRequiredModifier: Bool {
        let modifiers = self.modifiers
        return modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)
    }

    /// Nil for a cleared shortcut, so the menu item shows no key equivalent.
    var keyboardShortcut: KeyboardShortcut? {
        if isUnbound {
            return nil
        }
        return KeyboardShortcut(keyEquivalent, modifiers: modifiers)
    }

    var menuModifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(Character(key))
    }

    var display: String {
        if isUnbound {
            return String(localized: "Not Set")
        }
        var parts: [String] = []
        let modifiers = self.modifiers
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        switch key {
        case KeyChord.upArrow: parts.append("↑")
        case KeyChord.downArrow: parts.append("↓")
        case KeyChord.leftArrow: parts.append("←")
        case KeyChord.rightArrow: parts.append("→")
        case KeyChord.home: parts.append("↖")
        case KeyChord.end: parts.append("↘")
        case KeyChord.pageUp: parts.append("⇞")
        case KeyChord.pageDown: parts.append("⇟")
        case KeyChord.forwardDelete: parts.append("⌦")
        case " ": parts.append(String(localized: "Space"))
        case "\r": parts.append("↩")
        case "\t": parts.append("⇥")
        default:
            if isFunctionKey, let scalar = key.unicodeScalars.first {
                parts.append("F\(Int(scalar.value) - Int(NSF1FunctionKey) + 1)")
            } else {
                parts.append(key.uppercased())
            }
        }
        return parts.joined()
    }

    static func pack(_ modifiers: EventModifiers) -> Int {
        var raw = 0
        if modifiers.contains(.command) { raw |= 1 << 0 }
        if modifiers.contains(.option) { raw |= 1 << 1 }
        if modifiers.contains(.shift) { raw |= 1 << 2 }
        if modifiers.contains(.control) { raw |= 1 << 3 }
        return raw
    }

    static func unpack(_ raw: Int) -> EventModifiers {
        var modifiers: EventModifiers = []
        if raw & (1 << 0) != 0 { modifiers.insert(.command) }
        if raw & (1 << 1) != 0 { modifiers.insert(.option) }
        if raw & (1 << 2) != 0 { modifiers.insert(.shift) }
        if raw & (1 << 3) != 0 { modifiers.insert(.control) }
        return modifiers
    }

    /// A key press that could trigger a shortcut: at least one modifier, or a function key.
    static func from(event: NSEvent) -> KeyChord? {
        guard let chord = KeyChord.pressed(by: event) else { return nil }
        if chord.modifiers.isEmpty && !chord.isFunctionKey {
            return nil
        }
        return chord
    }

    /// Whatever was pressed, modifiers or not. The shortcut recorder checks it afterwards.
    /// With Shift the key is still the one on the keycap: ⇧⌘[ is `[` plus Shift, not `{`, so it reads
    /// ⇧⌘[ everywhere and matches chords imported from Ghostty's `shift+bracket_left`.
    static func pressed(by event: NSEvent) -> KeyChord? {
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), var character = chars.first else {
            return nil
        }
        var modifiers: EventModifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift),
           let unshifted = event.characters(byApplyingModifiers: [])?.lowercased(),
           unshifted.count == 1,
           let base = unshifted.first {
            character = base
        }
        return KeyChord(key: String(character), modifiers: modifiers)
    }
}

/// Outcome of recording `chord` for one shortcut on the Shortcuts settings page.
enum ShortcutRecordingCheck: Equatable {
    case accepted
    case unchanged
    case needsModifier
    case reserved
    case conflict(AppShortcutID)
}

enum AppShortcuts {
    static let storageKey = "app.keyboardShortcuts"
    static let revisionKey = "app.keyboardShortcuts.revision"

    static func chord(for id: AppShortcutID, store: UserDefaults = .standard) -> KeyChord {
        loadAll(store: store)[id.rawValue] ?? id.defaultChord
    }

    static func display(for id: AppShortcutID, store: UserDefaults = .standard) -> String {
        chord(for: id, store: store).display
    }

    /// Every shortcut as it is in effect now; cleared ones are `KeyChord.unbound`.
    static func bindings(store: UserDefaults = .standard) -> [AppShortcutID: KeyChord] {
        let stored = AppShortcuts.loadAll(store: store)
        var result: [AppShortcutID: KeyChord] = [:]
        for id in AppShortcutID.allCases {
            result[id] = stored[id.rawValue] ?? id.defaultChord
        }
        return result
    }

    static func isDefault(_ id: AppShortcutID, store: UserDefaults = .standard) -> Bool {
        AppShortcuts.chord(for: id, store: store) == id.defaultChord
    }

    /// Replaces the listed shortcuts, keeps the others, and bumps the revision so views re-read them.
    /// Pass `KeyChord.unbound` to clear one.
    static func setChords(_ chords: [AppShortcutID: KeyChord], store: UserDefaults = .standard) {
        var all = AppShortcuts.loadAll(store: store)
        for (id, chord) in chords {
            all[id.rawValue] = chord
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        store.set(data, forKey: AppShortcuts.storageKey)
        AppShortcuts.bumpRevision(store: store)
    }

    /// Forgets the stored chord, so the shortcut follows its default again.
    static func resetToDefault(_ id: AppShortcutID, store: UserDefaults = .standard) {
        var all = AppShortcuts.loadAll(store: store)
        all.removeValue(forKey: id.rawValue)
        guard let data = try? JSONEncoder().encode(all) else { return }
        store.set(data, forKey: AppShortcuts.storageKey)
        AppShortcuts.bumpRevision(store: store)
    }

    static func resetAll(store: UserDefaults = .standard) {
        store.removeObject(forKey: AppShortcuts.storageKey)
        AppShortcuts.bumpRevision(store: store)
    }

    /// Menus, the key monitor and hover hints watch this number to pick up new bindings at once.
    static func bumpRevision(store: UserDefaults = .standard) {
        store.set(store.integer(forKey: AppShortcuts.revisionKey) + 1, forKey: AppShortcuts.revisionKey)
    }

    /// Keys macOS or every Mac app keeps for itself. ⌘, is not here: it is this app's own Settings shortcut.
    /// Keys are as `KeyChord.pressed(by:)` reports them: Shift variants use the unshifted key. The shifted
    /// characters are kept for chords stored before that.
    static let systemReserved: [KeyChord] = [
        KeyChord(key: "q", modifiers: .command),
        KeyChord(key: "q", modifiers: [.command, .shift]),
        KeyChord(key: "q", modifiers: [.command, .control]),
        KeyChord(key: "h", modifiers: .command),
        KeyChord(key: "h", modifiers: [.command, .option]),
        KeyChord(key: "m", modifiers: .command),
        KeyChord(key: "m", modifiers: [.command, .option]),
        KeyChord(key: "d", modifiers: [.command, .option]),
        KeyChord(key: "\t", modifiers: .command),
        KeyChord(key: "\t", modifiers: [.command, .shift]),
        KeyChord(key: "\u{19}", modifiers: [.command, .shift]),
        KeyChord(key: " ", modifiers: .command),
        KeyChord(key: " ", modifiers: [.command, .option]),
        KeyChord(key: " ", modifiers: .control),
        KeyChord(key: " ", modifiers: [.control, .option]),
        KeyChord(key: "`", modifiers: .command),
        KeyChord(key: "~", modifiers: [.command, .shift]),
        KeyChord(key: "`", modifiers: [.command, .shift]),
        KeyChord(key: "3", modifiers: [.command, .shift]),
        KeyChord(key: "#", modifiers: [.command, .shift]),
        KeyChord(key: "4", modifiers: [.command, .shift]),
        KeyChord(key: "$", modifiers: [.command, .shift]),
        KeyChord(key: "5", modifiers: [.command, .shift]),
        KeyChord(key: "%", modifiers: [.command, .shift]),
    ]

    static func isSystemReserved(_ chord: KeyChord) -> Bool {
        AppShortcuts.systemReserved.contains(chord)
    }

    /// Checks a freshly recorded chord for `id` against the other shortcuts in `bindings`.
    static func check(
        _ chord: KeyChord,
        for id: AppShortcutID,
        bindings: [AppShortcutID: KeyChord]
    ) -> ShortcutRecordingCheck {
        if !chord.hasRequiredModifier && !chord.isFunctionKey {
            return .needsModifier
        }
        if AppShortcuts.isSystemReserved(chord) {
            return .reserved
        }
        if bindings[id] == chord {
            return .unchanged
        }
        for other in AppShortcutID.allCases where other != id {
            if bindings[other] == chord {
                return .conflict(other)
            }
        }
        return .accepted
    }

    private static func loadAll(store: UserDefaults) -> [String: KeyChord] {
        guard let data = store.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: KeyChord].self, from: data)
        else { return [:] }
        return decoded
    }
}
