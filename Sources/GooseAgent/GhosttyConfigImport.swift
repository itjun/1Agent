import AppKit
import GhosttyTheme
import SwiftUI

/// Set by the first-launch prompt: Settings opens the Advanced page and shows the import preview.
@MainActor
final class GhosttyImportRequests: ObservableObject {
    static let shared = GhosttyImportRequests()

    @Published var previewPending = false
}

/// Applies a `GhosttyImportPlan` to the app's own settings, keeps one undo step, and asks about
/// importing on the first launch that finds a Ghostty config file.
@MainActor
enum GhosttyConfigImport {
    /// Old values of every key an import may write: `["values": [key: value], "absent": [key]]`.
    static let backupKey = "ghostty.import.backup"
    static let promptShownKey = "ghostty.importPromptShown"
    /// The prompt waits until the main window is up and launch requests (`-e`, opened folders) are handled.
    static let promptDelay: TimeInterval = 1.0

    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static func detectedFiles() -> [URL] {
        GhosttyConfigImporter.existingConfigFiles(
            environment: ProcessInfo.processInfo.environment,
            home: GhosttyConfigImport.home
        )
    }

    static func makePlan() -> GhosttyImportPlan {
        let config = GhosttyConfigImporter.loadConfig(
            files: GhosttyConfigImport.detectedFiles(),
            home: GhosttyConfigImport.home
        )
        let context = GhosttyImportContext(
            settings: TerminalSettings.load(),
            lightTheme: TerminalThemeChoice.storedLight().name,
            darkTheme: TerminalThemeChoice.storedDark().name,
            userThemesDirectory: UserThemeStore.directoryURL,
            home: GhosttyConfigImport.home,
            lookupTheme: { name in
                // Same rules as a stored slot value: retired names do not count.
                guard let choice = TerminalThemeChoice(raw: name) else { return nil }
                return GhosttyThemeLookup(
                    isLightBackground: choice.definition.isLightBackground,
                    isUserTheme: UserThemeStore.shared.theme(named: name) != nil
                )
            },
            lookupThemeFile: { url in
                guard let contents = try? String(contentsOf: url, encoding: .utf8),
                      let theme = UserThemeParser.parse(name: url.lastPathComponent, contents: contents)
                else { return nil }
                return GhosttyThemeLookup(isLightBackground: theme.isLightBackground, isUserTheme: false)
            }
        )
        return GhosttyConfigImporter.makePlan(config: config, context: context)
    }

    // MARK: - Apply and undo

    private static var backupKeys: [String] {
        TerminalSettings.storageKeys + [
            TerminalAppearance.lightThemeKey,
            TerminalAppearance.darkThemeKey,
            AppShortcuts.storageKey,
        ]
    }

    static func hasBackup(defaults: UserDefaults = .standard) -> Bool {
        defaults.dictionary(forKey: GhosttyConfigImport.backupKey) != nil
    }

    /// Writes settings, theme slots, shortcuts and the snippet in one go, then applies them to every
    /// terminal. Returns messages for theme files that could not be copied; the rest still applies.
    @discardableResult
    static func applyPlan(_ plan: GhosttyImportPlan, defaults: UserDefaults = .standard) -> [String] {
        GhosttyConfigImport.saveBackup(defaults: defaults)
        ThemePreview.shared.cancel()
        var errors: [String] = []

        plan.newSettings.save(to: defaults)

        if let light = plan.theme.light,
           let name = GhosttyConfigImport.storedThemeName(for: light, errors: &errors) {
            defaults.set(name, forKey: TerminalAppearance.lightThemeKey)
        }
        if let dark = plan.theme.dark,
           let name = GhosttyConfigImport.storedThemeName(for: dark, errors: &errors) {
            defaults.set(name, forKey: TerminalAppearance.darkThemeKey)
        }

        var chords: [AppShortcutID: KeyChord] = [:]
        for shortcut in plan.shortcuts {
            if let id = AppShortcutID(rawValue: shortcut.shortcutID) {
                chords[id] = GhosttyConfigImport.chord(for: shortcut.trigger)
            }
        }
        if !chords.isEmpty {
            AppShortcuts.setChords(chords, store: defaults)
        }

        GhosttyConfigImport.applyToRuntime()
        return errors
    }

    /// Restores the values saved by the last import and forgets the backup. Theme files copied into
    /// the themes folder stay there.
    static func undoLastImport(defaults: UserDefaults = .standard) {
        guard let backup = defaults.dictionary(forKey: GhosttyConfigImport.backupKey) else { return }
        ThemePreview.shared.cancel()
        let values = backup["values"] as? [String: Any] ?? [:]
        let absent = backup["absent"] as? [String] ?? []
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        for key in absent {
            defaults.removeObject(forKey: key)
        }
        defaults.set(defaults.integer(forKey: AppShortcuts.revisionKey) + 1, forKey: AppShortcuts.revisionKey)
        defaults.removeObject(forKey: GhosttyConfigImport.backupKey)
        GhosttyConfigImport.applyToRuntime()
    }

    private static func saveBackup(defaults: UserDefaults) {
        var values: [String: Any] = [:]
        var absent: [String] = []
        for key in GhosttyConfigImport.backupKeys {
            if let value = defaults.object(forKey: key) {
                values[key] = value
            } else {
                absent.append(key)
            }
        }
        defaults.set(["values": values, "absent": absent], forKey: GhosttyConfigImport.backupKey)
    }

    private static func storedThemeName(for slot: GhosttyThemeSlotPlan, errors: inout [String]) -> String? {
        guard case .importFile(let url) = slot.source else { return slot.name }
        do {
            return try UserThemeStore.shared.importThemeFile(from: url)
        } catch {
            errors.append(error.localizedDescription)
            return nil
        }
    }

    private static func applyToRuntime() {
        GhosttyRuntime.applyTerminalSettings()
        GhosttyRuntime.applySelectedThemes()
        AppearanceDriver.shared.reapply()
    }

    // MARK: - Shortcuts

    static func chord(for trigger: GhosttyTrigger) -> KeyChord {
        var modifiers: EventModifiers = []
        if trigger.command { modifiers.insert(.command) }
        if trigger.option { modifiers.insert(.option) }
        if trigger.shift { modifiers.insert(.shift) }
        if trigger.control { modifiers.insert(.control) }
        var key = trigger.key
        switch trigger.key {
        case "arrow_left": key = KeyChord.leftArrow
        case "arrow_right": key = KeyChord.rightArrow
        case "arrow_up": key = KeyChord.upArrow
        case "arrow_down": key = KeyChord.downArrow
        default: break
        }
        return KeyChord(key: key, modifiers: modifiers)
    }

    static func shortcutTitle(_ id: AppShortcutID) -> String {
        id.title
    }

    // MARK: - First launch

    /// Asks once. The alert is a sheet on the main window, so launch requests keep running.
    static func promptIfNeeded(model: AppModel, defaults: UserDefaults = .standard) {
        if defaults.bool(forKey: GhosttyConfigImport.promptShownKey) {
            return
        }
        let files = GhosttyConfigImport.detectedFiles()
        if files.isEmpty {
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Found a Ghostty config file. Import its font, theme and other settings?")
        var paths: [String] = []
        for url in files {
            paths.append((url.path as NSString).abbreviatingWithTildeInPath)
        }
        alert.informativeText = paths.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "Review and Import…"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            defaults.set(true, forKey: GhosttyConfigImport.promptShownKey)
            if response == .alertFirstButtonReturn {
                GhosttyImportRequests.shared.previewPending = true
                SettingsWindowController.shared.show(model: model)
            }
        }
        if let window = MainWindowManager.shared.window(for: model.mainWindow), window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }
}
