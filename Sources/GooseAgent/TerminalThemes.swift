import AppKit
import GhosttyTerminal
import SwiftUI

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
        terminalIsDark = TerminalThemePreferences.selected(isDark: mode.resolvesDark())
            .isDark(interfaceIsDark: mode.resolvesDark())
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

    /// 窗口使用所选外观，所有终端使用该外观下保存的主题，明暗可以不同。
    func reapply() {
        // 强调色变化不一定伴随浅深色切换，仍需刷新读取系统语义色的窗口。
        if preset == .system { objectWillChange.send() }
        let selectedPreset = AppTheme.stored()
        if preset != selectedPreset {
            preset = selectedPreset
        }
        let mode = TerminalAppearance.stored()
        let dark = mode.resolvesDark()
        let terminalDark = TerminalThemePreferences.selected(isDark: dark).isDark(interfaceIsDark: dark)
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


extension AppTheme {
    static func terminalName(isDark: Bool) -> String {
        AppTheme.id + (isDark ? "-dark" : "-light")
    }

    static func terminalConfiguration(isDark: Bool) -> TerminalConfiguration {
        TerminalThemeColors.system(isDark: isDark).configuration
    }
}
