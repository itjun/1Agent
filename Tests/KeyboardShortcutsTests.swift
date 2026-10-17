import Foundation
import SwiftUI

@main
enum KeyboardShortcutsTests {
    static func main() {
        let suite = "KeyboardShortcutsTests.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suite) else { fail("no test defaults") }
        defer { store.removePersistentDomain(forName: suite) }

        storageSemantics(store)
        legacyData(store)
        restoredToggleSidebar(store)
        conflicts()
        reservedKeys()
        modifierRule()
        print("ok")
    }

    static func storageSemantics(_ store: UserDefaults) {
        expect(AppShortcuts.chord(for: .clearScreen, store: store) == AppShortcutID.clearScreen.defaultChord, "nothing stored means default")
        expect(AppShortcuts.isDefault(.clearScreen, store: store), "default before any change")

        let custom = KeyChord(key: "k", modifiers: [.command, .control])
        AppShortcuts.setChords([.clearScreen: custom], store: store)
        expect(AppShortcuts.chord(for: .clearScreen, store: store) == custom, "set chord is read back")
        expect(!AppShortcuts.isDefault(.clearScreen, store: store), "changed chord is not default")
        expect(store.integer(forKey: AppShortcuts.revisionKey) == 1, "setting bumps the revision")

        AppShortcuts.setChords([.selectAll: .unbound], store: store)
        let cleared = AppShortcuts.chord(for: .selectAll, store: store)
        expect(cleared.isUnbound, "cleared shortcut stays cleared, not default")
        expect(cleared.keyboardShortcut == nil, "cleared shortcut has no menu key equivalent")
        expect(!AppShortcuts.isDefault(.selectAll, store: store), "cleared is not default")
        expect(AppShortcuts.bindings(store: store)[.selectAll] == .unbound, "bindings report cleared")

        AppShortcuts.resetToDefault(.selectAll, store: store)
        expect(AppShortcuts.chord(for: .selectAll, store: store) == AppShortcutID.selectAll.defaultChord, "reset brings the default back")
        expect(AppShortcuts.chord(for: .clearScreen, store: store) == custom, "reset leaves other shortcuts alone")
        expect(store.integer(forKey: AppShortcuts.revisionKey) == 3, "clear and reset bump the revision")

        AppShortcuts.resetAll(store: store)
        expect(store.object(forKey: AppShortcuts.storageKey) == nil, "reset all removes the stored map")
        expect(AppShortcuts.isDefault(.clearScreen, store: store), "reset all restores every default")
        expect(store.integer(forKey: AppShortcuts.revisionKey) == 4, "reset all bumps the revision")

        let sameAsDefault = AppShortcutID.find.defaultChord
        AppShortcuts.setChords([.find: sameAsDefault], store: store)
        expect(AppShortcuts.isDefault(.find, store: store), "a stored chord equal to the default counts as default")
        AppShortcuts.resetAll(store: store)
    }

    /// Data written before clearing existed: `{"id": {"key", "modifierRaw"}}` with real keys only.
    static func legacyData(_ store: UserDefaults) {
        let json = #"{"clearScreen":{"key":"l","modifierRaw":9},"notAShortcutAnyMore":{"key":"x","modifierRaw":1}}"#
        store.set(Data(json.utf8), forKey: AppShortcuts.storageKey)
        let chord = AppShortcuts.chord(for: .clearScreen, store: store)
        expect(chord == KeyChord(key: "l", modifiers: [.command, .control]), "old entry decodes unchanged")
        expect(!chord.isUnbound, "old entry is not read as cleared")
        expect(AppShortcuts.isDefault(.newTab, store: store), "missing entries still follow the default")

        AppShortcuts.setChords([.newTab: .unbound], store: store)
        guard let data = store.data(forKey: AppShortcuts.storageKey),
              let raw = try? JSONDecoder().decode([String: KeyChord].self, from: data)
        else { fail("stored map no longer decodes as [String: KeyChord]") }
        expect(raw["newTab"] == KeyChord(key: "", modifiers: []), "cleared is stored as an empty key in the same format")
        expect(raw["notAShortcutAnyMore"] != nil, "unknown entries are kept")
        AppShortcuts.resetAll(store: store)
    }

    /// Restoring the action must honor a previously saved binding without changing other keys.
    static func restoredToggleSidebar(_ store: UserDefaults) {
        expect(AppShortcutID(rawValue: "toggleSidebar") == .toggleSidebar, "sidebar action retains its stored identity")
        let json = #"{"toggleSidebar":{"key":"b","modifierRaw":9},"clearScreen":{"key":"l","modifierRaw":9},"find":{"key":"","modifierRaw":0}}"#
        store.set(Data(json.utf8), forKey: AppShortcuts.storageKey)
        expect(AppShortcuts.chord(for: .clearScreen, store: store) == KeyChord(key: "l", modifiers: [.command, .control]), "custom binding next to the old entry survives")
        expect(AppShortcuts.chord(for: .find, store: store).isUnbound, "cleared binding next to the old entry stays cleared")
        expect(AppShortcuts.isDefault(.newTab, store: store), "untouched shortcuts keep their defaults")

        let bindings = AppShortcuts.bindings(store: store)
        expect(bindings.count == AppShortcutID.allCases.count, "bindings list only known shortcuts")
        let oldSidebarChord = KeyChord(key: "b", modifiers: [.command, .control])
        expect(AppShortcuts.chord(for: .toggleSidebar, store: store) == oldSidebarChord, "custom sidebar binding is restored")
        expect(AppShortcuts.check(oldSidebarChord, for: .selectAll, bindings: bindings) == .conflict(.toggleSidebar), "restored action reserves its custom chord")
        let oldDefault = KeyChord(key: "s", modifiers: [.command, .control])
        expect(AppShortcuts.check(oldDefault, for: .selectAll, bindings: bindings) == .accepted, "⌃⌘S is free again")

        AppShortcuts.setChords([.newTab: KeyChord(key: "n", modifiers: [.command, .control])], store: store)
        expect(AppShortcuts.chord(for: .clearScreen, store: store) == KeyChord(key: "l", modifiers: [.command, .control]), "saving another shortcut keeps the custom one")
        expect(AppShortcuts.chord(for: .find, store: store).isUnbound, "saving another shortcut keeps the cleared one")
        AppShortcuts.resetAll(store: store)
    }

    static func conflicts() {
        expect(AppShortcutID.toggleSidebar.defaultChord == KeyChord(key: "b", modifiers: .command), "sidebar toggles with Command-B")
        expect(AppShortcutID.settings.defaultChord == KeyChord(key: ",", modifiers: .command), "settings opens with Command-comma")
        expect(AppShortcutID.openFileBrowser.defaultChord == KeyChord(key: "o", modifiers: [.command, .option]), "Terminal/Files keeps its independent Option-Command-O shortcut")
        var bindings: [AppShortcutID: KeyChord] = [:]
        for id in AppShortcutID.allCases {
            bindings[id] = id.defaultChord
        }
        for id in AppShortcutID.allCases {
            for other in AppShortcutID.allCases where other != id {
                expect(id.defaultChord != other.defaultChord, "defaults of \(id.rawValue) and \(other.rawValue) differ")
            }
        }
        expect(AppShortcutID.selectTerminal8.terminalNumber == 8 && AppShortcutID.selectLastTerminal.terminalNumber == nil, "⌘9 is the last terminal, not a position")
        expect(AppShortcutID.nextTerminal.defaultChord.display == "⇧⌘]", "next terminal reads ⇧⌘], the key on the keycap")
        expect(AppShortcutID.previousTerminal.defaultChord.display == "⇧⌘[", "previous terminal reads ⇧⌘[")
        let newTab = AppShortcutID.newTab.defaultChord
        expect(AppShortcuts.check(newTab, for: .toggleFullScreen, bindings: bindings) == .conflict(.newTab), "⌘T for full screen conflicts with New Tab")
        expect(AppShortcuts.check(newTab, for: .newTab, bindings: bindings) == .unchanged, "own chord is unchanged, not a conflict")

        let fresh = KeyChord(key: "k", modifiers: [.command, .control])
        expect(AppShortcuts.check(fresh, for: .clearScreen, bindings: bindings) == .accepted, "unused chord is accepted")

        bindings[.selectAll] = .unbound
        bindings[.find] = .unbound
        expect(AppShortcuts.check(fresh, for: .clearScreen, bindings: bindings) == .accepted, "two cleared shortcuts do not conflict with a new chord")

        let plus = KeyChord(key: "+", modifiers: .command)
        expect(AppShortcuts.check(plus, for: .clearScreen, bindings: bindings) == .accepted, "⌘+ is only an alias, so claiming it is not a conflict")

        let settings = AppShortcutID.settings.defaultChord
        expect(AppShortcuts.check(settings, for: .clearScreen, bindings: bindings) == .conflict(.settings), "⌘, is an ordinary shortcut of this app")
    }

    static func reservedKeys() {
        expect(AppShortcuts.isSystemReserved(KeyChord(key: "q", modifiers: .command)), "⌘Q is reserved")
        expect(AppShortcuts.isSystemReserved(KeyChord(key: "h", modifiers: [.command, .option])), "⌥⌘H is reserved")
        expect(AppShortcuts.isSystemReserved(KeyChord(key: " ", modifiers: .command)), "⌘Space is reserved")
        expect(AppShortcuts.isSystemReserved(KeyChord(key: "`", modifiers: .command)), "⌘` is reserved")
        expect(AppShortcuts.isSystemReserved(KeyChord(key: "`", modifiers: [.command, .shift])), "⇧⌘` is reserved as the unshifted key is now recorded")
        expect(!AppShortcuts.isSystemReserved(KeyChord(key: ",", modifiers: .command)), "⌘, is not reserved")
        expect(!AppShortcuts.isSystemReserved(KeyChord(key: "k", modifiers: [.command, .control])), "⌃⌘K is free")
        for id in AppShortcutID.allCases {
            expect(!AppShortcuts.isSystemReserved(id.defaultChord), "default of \(id.rawValue) is not reserved")
        }
        let bindings = [AppShortcutID.clearScreen: AppShortcutID.clearScreen.defaultChord]
        expect(AppShortcuts.check(KeyChord(key: "q", modifiers: .command), for: .clearScreen, bindings: bindings) == .reserved, "recording ⌘Q is refused")
    }

    static func modifierRule() {
        let bindings = [AppShortcutID.clearScreen: AppShortcutID.clearScreen.defaultChord]
        expect(AppShortcuts.check(KeyChord(key: "k", modifiers: []), for: .clearScreen, bindings: bindings) == .needsModifier, "plain k needs a modifier")
        expect(AppShortcuts.check(KeyChord(key: "k", modifiers: .shift), for: .clearScreen, bindings: bindings) == .needsModifier, "Shift alone is not enough")
        expect(AppShortcuts.check(KeyChord(key: "k", modifiers: .option), for: .clearScreen, bindings: bindings) == .accepted, "⌥K is enough")

        let f5 = KeyChord(key: String(UnicodeScalar(NSF5FunctionKey)!), modifiers: [])
        expect(f5.isFunctionKey, "F5 is a function key")
        expect(f5.display == "F5", "F5 displays as F5")
        expect(AppShortcuts.check(f5, for: .clearScreen, bindings: bindings) == .accepted, "F5 needs no modifier")
        expect(!KeyChord(key: KeyChord.upArrow, modifiers: []).isFunctionKey, "arrows are not F-keys")

        expect(KeyChord(key: "k", modifiers: [.command, .control]).display == "⌃⌘K", "display uses modifier symbols")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    static func fail(_ message: String) -> Never {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}
