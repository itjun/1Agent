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
    @Published private(set) var preset: AppThemePreset
    var isDark: Bool { interfaceIsDark }
    private let themeWatcher = SystemThemeWatcher()

    private init() {
        let mode = TerminalAppearance.stored()
        interfaceIsDark = mode.resolvesDark()
        terminalIsDark = mode.resolvesDark()
        isShellTransparent = ShellStyle.isTransparent
        preset = AppTheme.stored()
        themeWatcher.start()
    }

    var interfaceColorScheme: ColorScheme {
        if isDark {
            return .dark
        }
        return .light
    }

    /// 外观模式同时切换窗口与所有本机／远程终端。
    func reapply() {
        // 强调色变化不一定伴随浅深色切换，仍需刷新读取系统语义色的窗口。
        if preset == .system { objectWillChange.send() }
        let selectedPreset = AppTheme.stored()
        if preset != selectedPreset {
            preset = selectedPreset
        }
        let mode = TerminalAppearance.stored()
        let dark = mode.resolvesDark()
        let terminalDark = dark
        TerminalAppearance.applyAppKit(isDark: dark)
        GhosttyRuntime.applySelectedThemes()
        if dark != interfaceIsDark { interfaceIsDark = dark }
        if terminalDark != terminalIsDark { terminalIsDark = terminalDark }
        GhosttyRuntime.applyColorSchemes(isDark: dark)
        let isTransparent = ShellStyle.isTransparent
        if isShellTransparent != isTransparent {
            isShellTransparent = isTransparent
            GhosttyRuntime.applyTerminalSettings()
        }
    }

    func selectPreset(_ preset: AppThemePreset) {
        UserDefaults.standard.set(preset.rawValue, forKey: AppTheme.storageKey)
        reapply()
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
            name: NSColor.systemColorsDidChangeNotification,
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

extension AppTheme {
    static func terminalDefinition(isDark: Bool) -> GhosttyThemeDefinition {
        let colors = AppTheme.colors(isDark: isDark)
        return GhosttyThemeDefinition(
            name: AppTheme.id + (isDark ? "-dark" : "-light"),
            background: colors.background, foreground: colors.foreground,
            cursorColor: colors.accent, cursorText: colors.background,
            selectionBackground: colors.selection,
            selectionForeground: SystemTheme.hex(.selectedTextColor, isDark: isDark, over: .selectedTextBackgroundColor),
            palette: Dictionary(uniqueKeysWithValues: colors.ansi.enumerated().map { ($0.offset, $0.element) })
        )
    }
}
