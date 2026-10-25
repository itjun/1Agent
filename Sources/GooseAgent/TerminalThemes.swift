import AppKit
import GhosttyTerminal
import GhosttyTheme
import SwiftUI

extension GhosttyThemeDefinition {
    func terminalConfiguration() -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withBackground(Self.ghosttyHex(background))
            builder.withForeground(Self.ghosttyHex(foreground))
            if let cursorColor { builder.withCursorColor(Self.ghosttyHex(cursorColor)) }
            if let cursorText { builder.withCursorText(Self.ghosttyHex(cursorText)) }
            if let selectionBackground { builder.withSelectionBackground(Self.ghosttyHex(selectionBackground)) }
            if let selectionForeground { builder.withSelectionForeground(Self.ghosttyHex(selectionForeground)) }
            for (index, color) in palette.sorted(by: { $0.key < $1.key }) {
                builder.withPalette(index, color: Self.ghosttyHex(color))
            }
        }
    }

    static func ghosttyHex(_ raw: String) -> String {
        raw.hasPrefix("#") ? raw : "#\(raw)"
    }

    /// Light backgrounds belong in the white-theme list. Night themes stay in the other list.
    var isLightBackground: Bool {
        Self.relativeLuminance(of: background) >= 0.45
    }

    private static func relativeLuminance(of raw: String) -> Double {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return 0 }
        func channel(_ component: Int) -> Double {
            let s = Double(component) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let red = channel((value >> 16) & 0xFF)
        let green = channel((value >> 8) & 0xFF)
        let blue = channel(value & 0xFF)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}

enum TerminalAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearance.colorScheme"
    static let lightThemeKey = "appearance.terminalTheme.light"
    static let darkThemeKey = "appearance.terminalTheme.dark"
    /// Previous single-theme choice, copied into the matching light or dark slot once.
    static let legacyThemeKey = "appearance.terminalTheme"

    static func themeKey(for target: TerminalThemeTarget, dark: Bool) -> String {
        "appearance.terminalTheme.\(target.rawValue).\(dark ? "dark" : "light")"
    }

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "Follow System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Follow System must not pass `nil` to `preferredColorScheme`. Inside a
    /// `NavigationSplitView`, clearing the preference leaves the last light or
    /// dark override in place, so the window stays dark while the system is light.
    func resolvesDark() -> Bool {
        switch self {
        case .system: TerminalAppearance.systemIsDark
        case .light: false
        case .dark: true
        }
    }

    static func stored(defaults: UserDefaults = .standard) -> TerminalAppearance {
        let raw = defaults.string(forKey: TerminalAppearance.storageKey) ?? TerminalAppearance.system.rawValue
        return TerminalAppearance(rawValue: raw) ?? .system
    }

    /// Global interface style. Missing key means light. The app's own override
    /// must not be consulted here, or Follow System would read itself.
    static var systemIsDark: Bool {
        let domain = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let style = domain?["AppleInterfaceStyle"] as? String
        return style == "Dark"
    }

    static func appKitAppearance(isDark: Bool) -> NSAppearance? {
        if isDark {
            return NSAppearance(named: .darkAqua)
        }
        return NSAppearance(named: .aqua)
    }

    static func applyAppKit(isDark: Bool) {
        let desired = TerminalAppearance.appKitAppearance(isDark: isDark)
        // Compare identity. Reading NSAppearance.name traps on macOS 27 when the
        // current appearance has no public name.
        if NSApp.appearance !== desired {
            NSApp.appearance = desired
        }
        for window in NSApp.windows {
            if window.appearance !== desired {
                window.appearance = desired
            }
        }
    }
}

/// Publishes the appearance the windows should use, including Follow System.
@MainActor
final class AppearanceDriver: ObservableObject {
    static let shared = AppearanceDriver()

    @Published private(set) var interfaceIsDark: Bool
    @Published private(set) var terminalIsDark: Bool
    var isDark: Bool { interfaceIsDark }
    private let themeWatcher = SystemThemeWatcher()

    private init() {
        let mode = TerminalAppearance.stored()
        interfaceIsDark = mode.resolvesDark()
        terminalIsDark = mode.resolvesDark()
        themeWatcher.start()
    }

    var interfaceColorScheme: ColorScheme {
        if isDark {
            return .dark
        }
        return .light
    }

    /// AppKit chrome follows the saved mode; only terminal surfaces follow a preview slot.
    func reapply() {
        let mode = TerminalAppearance.stored()
        let dark = mode.resolvesDark()
        let terminalDark = ThemePreview.shared.previewingDark(for: .local) ?? dark
        TerminalAppearance.applyAppKit(isDark: dark)
        if dark != interfaceIsDark { interfaceIsDark = dark }
        if terminalDark != terminalIsDark { terminalIsDark = terminalDark }
        GhosttyRuntime.applyColorSchemes(isDark: dark)
    }
}

/// System Settings posts this on the distributed center when light/dark changes.
private final class SystemThemeWatcher: NSObject {
    func start() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemThemeChanged(_:)),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemThemeChanged(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func systemThemeChanged(_ notification: Notification) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AppearanceDriver.shared.reapply()
            }
        }
    }
}


enum TerminalThemeTarget: String, CaseIterable, Identifiable {
    case local
    case remote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: String(localized: "This Mac")
        case .remote: String(localized: "Remote")
        }
    }
}

/// Terminal themes are independent of app icons and window appearance colors.
struct TerminalThemeChoice: Equatable, Hashable {
    static let defaultLightName = "GitHub Light Default"
    static let defaultDarkName = "GitHub Dark Default"
    static let migrationKey = "appearance.terminalTheme.connectionDefaults.v1"

    let name: String

    var rawValue: String { name }
    var title: String { name }

    init?(raw: String?) {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard GhosttyThemeCatalog.theme(named: trimmed) != nil else { return nil }
        name = trimmed
    }

    private init(name: String) {
        self.name = name
    }

    static func slotDefault(dark: Bool) -> TerminalThemeChoice {
        TerminalThemeChoice(name: dark ? TerminalThemeChoice.defaultDarkName : TerminalThemeChoice.defaultLightName)
    }

    var definition: GhosttyThemeDefinition {
        GhosttyThemeCatalog.theme(named: name)!
    }

    func terminalConfiguration() -> TerminalConfiguration {
        definition.terminalConfiguration()
    }

    /// The border keeps the connection palette while contrasting with the actual terminal theme.
    func focusBorderColor(for target: TerminalThemeTarget, defaults: UserDefaults = .standard) -> RGBColor {
        let theme = definition
        let background = RGBColor(ghosttyHex: theme.background)!
        let icon = target == .local ? LocalPalette.stored(defaults: defaults) : RemotePalette.stored(defaults: defaults)
        let palette = icon.palette!
        let color = RGBColor(ghosttyHex: theme.isLightBackground ? palette.ink : palette.terminalAccent)!
        let black = RGBColor(red: 0, green: 0, blue: 0)
        let white = RGBColor(red: 1, green: 1, blue: 1)
        let correction = black.contrastRatio(with: background) >= white.contrastRatio(with: background) ? black : white
        return RGBColor.ensureContrast(color, against: background, toward: correction, minimum: 3)
    }

    static func storedLight(for target: TerminalThemeTarget = .local, defaults: UserDefaults = .standard) -> TerminalThemeChoice {
        TerminalThemeChoice.resolved(raw: defaults.string(forKey: TerminalAppearance.themeKey(for: target, dark: false)), dark: false)
    }

    static func storedDark(for target: TerminalThemeTarget = .local, defaults: UserDefaults = .standard) -> TerminalThemeChoice {
        TerminalThemeChoice.resolved(raw: defaults.string(forKey: TerminalAppearance.themeKey(for: target, dark: true)), dark: true)
    }

    static func resolved(raw: String?, dark: Bool) -> TerminalThemeChoice {
        guard let choice = TerminalThemeChoice(raw: raw) else { return TerminalThemeChoice.slotDefault(dark: dark) }
        if choice.definition.isLightBackground == dark {
            return TerminalThemeChoice.slotDefault(dark: dark)
        }
        return choice
    }

    /// Restore themes replaced by icon-following defaults; retain explicit per-connection choices.
    /// Old preference values remain available for recovery.
    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        if defaults.object(forKey: LocalPalette.storageKey) == nil {
            let icon = ApplicationIcon.stored(defaults: defaults)
            defaults.set((icon.palette == nil ? LocalPalette.defaultPalette : icon).rawValue,
                forKey: LocalPalette.storageKey)
        }
        TerminalThemeChoice.restoreIndependentThemes(defaults: defaults)
        defaults.set(true, forKey: TerminalThemeChoice.migrationKey)
    }


    /// Recover themes replaced by icon-following builds without overwriting named selections.
    private static func restoreIndependentThemes(defaults: UserDefaults) {
        for target in ["local", "remote"] {
            for dark in [false, true] {
                let key = "appearance.terminalTheme.\(target).\(dark ? "dark" : "light")"
                let raw = defaults.string(forKey: key)
                if raw == nil || raw == "follow-palette" {
                    let previousKey = dark ? TerminalAppearance.darkThemeKey : TerminalAppearance.lightThemeKey
                    let previous = TerminalThemeChoice(raw: defaults.string(forKey: previousKey))
                        ?? TerminalThemeChoice(raw: defaults.string(forKey: TerminalAppearance.legacyThemeKey))
                    let choice = TerminalThemeChoice.resolved(raw: previous?.rawValue, dark: dark)
                    defaults.set(choice.rawValue, forKey: key)
                }
            }
        }
    }


}

/// Preview transactions span both connection types without changing the other type's appearance.
@MainActor
final class ThemePreview: ObservableObject {
    static let shared = ThemePreview()

    private struct Slot: Hashable {
        let target: TerminalThemeTarget
        let dark: Bool
    }

    @Published private var choices: [Slot: TerminalThemeChoice] = [:]
    @Published private var appearances: [TerminalThemeTarget: Bool] = [:]

    var light: TerminalThemeChoice? { choices[Slot(target: .local, dark: false)] }
    var dark: TerminalThemeChoice? { choices[Slot(target: .local, dark: true)] }
    var previewingDark: Bool? { previewingDark(for: .local) }
    var isActive: Bool { !choices.isEmpty }

    var previewedNames: [String] {
        TerminalThemeTarget.allCases.flatMap { target in
            [false, true].compactMap { dark in
                choices[Slot(target: target, dark: dark)].map { choice in
                    let appearance = dark ? String(localized: "Dark theme") : String(localized: "Light theme")
                    return "\(target.title) · \(appearance) · \(choice.title)"
                }
            }
        }
    }

    func previewingDark(for target: TerminalThemeTarget) -> Bool? {
        appearances[target]
    }

    func effectiveLight(for target: TerminalThemeTarget = .local) -> TerminalThemeChoice {
        choices[Slot(target: target, dark: false)] ?? TerminalThemeChoice.storedLight(for: target)
    }

    func effectiveDark(for target: TerminalThemeTarget = .local) -> TerminalThemeChoice {
        choices[Slot(target: target, dark: true)] ?? TerminalThemeChoice.storedDark(for: target)
    }

    func show(_ definition: GhosttyThemeDefinition, for target: TerminalThemeTarget = .local) {
        guard let choice = TerminalThemeChoice(raw: definition.name) else { return }
        let dark = !definition.isLightBackground
        choices[Slot(target: target, dark: dark)] = choice
        appearances[target] = dark
        apply()
    }

    var showsDefaults: Bool { showsDefaults(for: .local) }

    func showsDefaults(for target: TerminalThemeTarget) -> Bool {
        effectiveLight(for: target) == .slotDefault(dark: false) && effectiveDark(for: target) == .slotDefault(dark: true)
    }

    func showDefaults(for target: TerminalThemeTarget = .local) {
        choices[Slot(target: target, dark: false)] = .slotDefault(dark: false)
        choices[Slot(target: target, dark: true)] = .slotDefault(dark: true)
        appearances.removeValue(forKey: target)
        apply()
    }

    func save(defaults: UserDefaults = .standard) {
        for (slot, choice) in choices {
            defaults.set(choice.rawValue, forKey: TerminalAppearance.themeKey(for: slot.target, dark: slot.dark))
        }
        choices.removeAll()
        appearances.removeAll()
        apply()
    }

    func cancel() {
        guard isActive else { return }
        choices.removeAll()
        appearances.removeAll()
        apply()
    }

    private func apply() {
        GhosttyRuntime.applySelectedThemes()
        AppearanceDriver.shared.reapply()
    }
}
