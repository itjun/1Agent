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
        let terminalDark = ThemePreview.shared.previewingDark ?? dark
        TerminalAppearance.applyAppKit(isDark: dark)
        if dark != interfaceIsDark { interfaceIsDark = dark }
        if terminalDark != terminalIsDark { terminalIsDark = terminalDark }
        GhosttyRuntime.controller.setColorScheme(terminalDark ? .dark : .light)
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


/// What fills one appearance slot: a named theme from Ghostty's built-in catalog.
/// Stored as the plain catalog name; custom files are never loaded.
/// Empty or unknown names fall back to the GitHub theme for the slot.
struct TerminalThemeChoice: Equatable, Hashable {
    static let defaultLightName = "GitHub Light Default"
    static let defaultDarkName = "GitHub Dark Default"

    let name: String

    var rawValue: String { name }
    var title: String { name }

    /// Nil when the string is empty or absent from the official catalog.
    init?(raw: String?) {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return nil
        }
        guard GhosttyThemeCatalog.theme(named: trimmed) != nil else { return nil }
        name = trimmed
    }

    private init(defaultNamed name: String) {
        self.name = name
    }

    static func slotDefault(dark: Bool) -> TerminalThemeChoice {
        if dark {
            return TerminalThemeChoice(defaultNamed: TerminalThemeChoice.defaultDarkName)
        }
        return TerminalThemeChoice(defaultNamed: TerminalThemeChoice.defaultLightName)
    }

    /// The bundled GitHub themes always exist in the catalog; the forced unwrap guards that assumption.
    var definition: GhosttyThemeDefinition {
        if let theme = GhosttyThemeCatalog.theme(named: name) {
            return theme
        }
        return GhosttyThemeCatalog.theme(named: TerminalThemeChoice.defaultLightName)!
    }

    func terminalConfiguration() -> TerminalConfiguration {
        definition.terminalConfiguration()
    }

    // MARK: Storage

    static func storedLight(defaults: UserDefaults = .standard) -> TerminalThemeChoice {
        TerminalThemeChoice.resolved(raw: defaults.string(forKey: TerminalAppearance.lightThemeKey), dark: false)
    }

    static func storedDark(defaults: UserDefaults = .standard) -> TerminalThemeChoice {
        TerminalThemeChoice.resolved(raw: defaults.string(forKey: TerminalAppearance.darkThemeKey), dark: true)
    }

    /// A catalog theme only counts for the slot whose brightness it matches. Anything else is the slot default.
    static func resolved(raw: String?, dark: Bool) -> TerminalThemeChoice {
        guard let choice = TerminalThemeChoice(raw: raw) else {
            return TerminalThemeChoice.slotDefault(dark: dark)
        }
        if choice.definition.isLightBackground == dark {
            return TerminalThemeChoice.slotDefault(dark: dark)
        }
        return choice
    }

    /// Copies the old single-theme key into the matching slot once.
    /// Only built-in theme names migrate; obsolete custom names resolve to the slot default.
    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        let legacy = defaults.string(forKey: TerminalAppearance.legacyThemeKey) ?? ""
        if !legacy.isEmpty {
            if let theme = TerminalThemeChoice(raw: legacy)?.definition {
                let key = theme.isLightBackground ? TerminalAppearance.lightThemeKey : TerminalAppearance.darkThemeKey
                if (defaults.string(forKey: key) ?? "").isEmpty {
                    defaults.set(legacy, forKey: key)
                }
            }
            defaults.removeObject(forKey: TerminalAppearance.legacyThemeKey)
        }
    }
}

/// A theme the user clicked in Settings but has not saved. Terminal surfaces show it at once;
/// nothing is written to defaults until Save. Cancel, or closing Settings, drops it.
@MainActor
final class ThemePreview: ObservableObject {
    static let shared = ThemePreview()

    @Published private(set) var light: TerminalThemeChoice?
    @Published private(set) var dark: TerminalThemeChoice?
    /// Slot of the theme clicked last. A light theme only shows in light mode (and dark in dark),
    /// so terminal surfaces switch until Save or Cancel; nil means follow the stored mode.
    @Published private(set) var previewingDark: Bool?

    var isActive: Bool {
        light != nil || dark != nil
    }

    /// Names shown in the action bar, light slot first.
    var previewedNames: [String] {
        [light, dark].compactMap { $0?.name }
    }

    func effectiveLight() -> TerminalThemeChoice {
        light ?? TerminalThemeChoice.storedLight()
    }

    func effectiveDark() -> TerminalThemeChoice {
        dark ?? TerminalThemeChoice.storedDark()
    }

    /// A light-background theme previews in the light slot, anything else in the dark slot.
    func show(_ definition: GhosttyThemeDefinition) {
        guard let choice = TerminalThemeChoice(raw: definition.name) else { return }
        if definition.isLightBackground {
            light = choice
        } else {
            dark = choice
        }
        previewingDark = !definition.isLightBackground
        GhosttyRuntime.applySelectedThemes()
        AppearanceDriver.shared.reapply()
    }

    /// Both effective slots already show the GitHub defaults, so restoring would change nothing.
    var showsDefaults: Bool {
        effectiveLight() == TerminalThemeChoice.slotDefault(dark: false)
            && effectiveDark() == TerminalThemeChoice.slotDefault(dark: true)
    }

    /// Previews both slot defaults at once; Save writes them, Cancel restores the saved themes.
    /// Both slots change, so the app keeps the stored light/dark mode instead of forcing one.
    func showDefaults() {
        light = TerminalThemeChoice.slotDefault(dark: false)
        dark = TerminalThemeChoice.slotDefault(dark: true)
        previewingDark = nil
        GhosttyRuntime.applySelectedThemes()
        AppearanceDriver.shared.reapply()
    }

    func save(defaults: UserDefaults = .standard) {
        if let light {
            defaults.set(light.rawValue, forKey: TerminalAppearance.lightThemeKey)
        }
        if let dark {
            defaults.set(dark.rawValue, forKey: TerminalAppearance.darkThemeKey)
        }
        light = nil
        dark = nil
        previewingDark = nil
        GhosttyRuntime.applySelectedThemes()
        AppearanceDriver.shared.reapply()
    }

    func cancel() {
        guard isActive else { return }
        light = nil
        dark = nil
        previewingDark = nil
        GhosttyRuntime.applySelectedThemes()
        AppearanceDriver.shared.reapply()
    }
}
