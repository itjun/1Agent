import AppKit
import SwiftUI

enum AppShortcutID: String, CaseIterable, Identifiable {
    case newTab
    case duplicateRight
    case duplicateDown
    case closeTab
    case settings
    case nextPane
    case previousPane
    case paneLeft
    case paneRight
    case paneUp
    case paneDown

    var id: String { rawValue }

    /// Pane switching follows Ghostty's macOS defaults.
    var defaultChord: KeyChord {
        switch self {
        case .newTab: return KeyChord(key: "t", modifiers: .command)
        case .duplicateRight: return KeyChord(key: "d", modifiers: .command)
        case .duplicateDown: return KeyChord(key: "d", modifiers: [.command, .shift])
        case .closeTab: return KeyChord(key: "w", modifiers: .command)
        case .settings: return KeyChord(key: ",", modifiers: .command)
        case .nextPane: return KeyChord(key: "]", modifiers: .command)
        case .previousPane: return KeyChord(key: "[", modifiers: .command)
        case .paneLeft: return KeyChord(key: KeyChord.leftArrow, modifiers: [.command, .option])
        case .paneRight: return KeyChord(key: KeyChord.rightArrow, modifiers: [.command, .option])
        case .paneUp: return KeyChord(key: KeyChord.upArrow, modifiers: [.command, .option])
        case .paneDown: return KeyChord(key: KeyChord.downArrow, modifiers: [.command, .option])
        }
    }
}

struct KeyChord: Codable, Equatable, Hashable {
    /// AppKit reports arrow keys as these private-use characters in `charactersIgnoringModifiers`.
    static let upArrow = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    static let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    static let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    static let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)

    var key: String
    var modifierRaw: Int

    init(key: String, modifiers: EventModifiers) {
        self.key = key
        self.modifierRaw = Self.pack(modifiers)
    }

    var modifiers: EventModifiers { Self.unpack(modifierRaw) }

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
        default: parts.append(key.uppercased())
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

    static func from(event: NSEvent) -> KeyChord? {
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), let character = chars.first else {
            return nil
        }
        var modifiers: EventModifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        guard !modifiers.isEmpty else { return nil }
        return KeyChord(key: String(character), modifiers: modifiers)
    }
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

    private static func loadAll(store: UserDefaults) -> [String: KeyChord] {
        guard let data = store.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: KeyChord].self, from: data)
        else { return [:] }
        return decoded
    }
}
