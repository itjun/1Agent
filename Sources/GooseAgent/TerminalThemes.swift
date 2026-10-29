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
    @Published private(set) var isShellTransparent: Bool
    var isDark: Bool { interfaceIsDark }
    private let themeWatcher = SystemThemeWatcher()

    private init() {
        let mode = TerminalAppearance.stored()
        interfaceIsDark = mode.resolvesDark()
        terminalIsDark = mode.resolvesDark()
        isShellTransparent = ShellStyle.isTransparent
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
        GhosttyRuntime.applyColorSchemes(isDark: dark)
        let isTransparent = ShellStyle.isTransparent
        if isShellTransparent != isTransparent {
            isShellTransparent = isTransparent
            GhosttyRuntime.applyTerminalSettings()
        }
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemThemeChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
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


enum TerminalThemeTarget: String, CaseIterable {
    case local
    case remote
}

/// Terminal themes are independent of app icons and window appearance colors.
struct TerminalThemeChoice: Equatable, Hashable {
    static let defaultLightName = "GitHub Light Default"
    static let defaultDarkName = "GitHub Dark Default"
    static let migrationKey = "appearance.terminalTheme.shared.v1"

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

    static func storedLight(defaults: UserDefaults = .standard) -> TerminalThemeChoice {
        TerminalThemeChoice.resolved(raw: defaults.string(forKey: TerminalAppearance.lightThemeKey), dark: false)
    }

    static func storedDark(defaults: UserDefaults = .standard) -> TerminalThemeChoice {
        TerminalThemeChoice.resolved(raw: defaults.string(forKey: TerminalAppearance.darkThemeKey), dark: true)
    }

    static func resolved(raw: String?, dark: Bool) -> TerminalThemeChoice {
        guard let choice = TerminalThemeChoice(raw: raw) else { return TerminalThemeChoice.slotDefault(dark: dark) }
        if choice.definition.isLightBackground == dark {
            return TerminalThemeChoice.slotDefault(dark: dark)
        }
        return choice
    }

    /// Prefer the current local choices when merging connection themes. Keep the old keys for recovery.
    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        if defaults.object(forKey: LocalPalette.storageKey) == nil {
            let icon = ApplicationIcon.stored(defaults: defaults)
            defaults.set((icon.palette == nil ? LocalPalette.defaultPalette : icon).rawValue,
                forKey: LocalPalette.storageKey)
        }
        guard !defaults.bool(forKey: TerminalThemeChoice.migrationKey) else { return }
        for dark in [false, true] {
            let slot = dark ? "dark" : "light"
            let key = dark ? TerminalAppearance.darkThemeKey : TerminalAppearance.lightThemeKey
            let previous = [
                "appearance.terminalTheme.local.\(slot)",
                "appearance.terminalTheme.remote.\(slot)",
                key,
                TerminalAppearance.legacyThemeKey,
            ].compactMap { TerminalThemeChoice(raw: defaults.string(forKey: $0)) }
                .first { $0.definition.isLightBackground != dark }
            let choice = previous ?? TerminalThemeChoice.slotDefault(dark: dark)
            defaults.set(choice.rawValue, forKey: key)
        }
        defaults.set(true, forKey: TerminalThemeChoice.migrationKey)
    }
}

/// One preview transaction applies to every local and remote terminal.
@MainActor
final class ThemePreview: ObservableObject {
    static let shared = ThemePreview()

    @Published private(set) var light: TerminalThemeChoice?
    @Published private(set) var dark: TerminalThemeChoice?
    @Published private(set) var previewingDark: Bool?

    var isActive: Bool { light != nil || dark != nil }

    var previewedNames: [String] {
        [false, true].compactMap { isDark in
            (isDark ? dark : light).map { choice in
                let appearance = isDark ? String(localized: "Dark theme") : String(localized: "Light theme")
                return "\(appearance) · \(choice.title)"
            }
        }
    }

    func effectiveLight() -> TerminalThemeChoice {
        light ?? TerminalThemeChoice.storedLight()
    }

    func effectiveDark() -> TerminalThemeChoice {
        dark ?? TerminalThemeChoice.storedDark()
    }

    func show(_ definition: GhosttyThemeDefinition) {
        guard let choice = TerminalThemeChoice(raw: definition.name) else { return }
        if definition.isLightBackground {
            light = choice
        } else {
            dark = choice
        }
        previewingDark = !definition.isLightBackground
        apply()
    }

    var showsDefaults: Bool {
        effectiveLight() == .slotDefault(dark: false) && effectiveDark() == .slotDefault(dark: true)
    }

    func showDefaults() {
        light = .slotDefault(dark: false)
        dark = .slotDefault(dark: true)
        previewingDark = nil
        apply()
    }

    func save(defaults: UserDefaults = .standard) {
        if let light { defaults.set(light.rawValue, forKey: TerminalAppearance.lightThemeKey) }
        if let dark { defaults.set(dark.rawValue, forKey: TerminalAppearance.darkThemeKey) }
        light = nil
        dark = nil
        previewingDark = nil
        apply()
    }

    func cancel() {
        guard isActive else { return }
        light = nil
        dark = nil
        previewingDark = nil
        apply()
    }

    private func apply() {
        GhosttyRuntime.applySelectedThemes()
        AppearanceDriver.shared.reapply()
    }
}
