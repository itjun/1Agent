import AppKit
import SwiftUI

@main
enum RemotePaletteTests {
    struct Failure: Error { let message: String }

    static func main() {
        do { try run() }
        catch {
            fputs("RemotePaletteTests failed: \(error)\n", stderr)
            exit(1)
        }
        print("RemotePaletteTests passed")
    }

    static func run() throws {
        for preset in AppThemePreset.allCases {
            for isDark in [false, true] {
                let colors = AppTheme.colors(isDark: isDark, preset: preset)
                let base = RGBColor(ghosttyHex: colors.background)!
                let foreground = RGBColor(ghosttyHex: colors.foreground)!
                let secondary = RGBColor(ghosttyHex: colors.secondary)!
                let focused = AppTheme.terminalPaneBackground(isDark: isDark, isFocused: true, preset: preset)
                let inactive = AppTheme.terminalPaneBackground(isDark: isDark, isFocused: false, preset: preset)
                let label = "\(preset.rawValue) \(isDark ? "dark" : "light")"
                let isWhiteDefault = preset == .system && !isDark
                try check(focused.contrastRatio(with: base) == 1, "\(label): focused pane keeps theme background")
                try check(inactive.contrastRatio(with: focused) > 1
                          && inactive.contrastRatio(with: focused) <= 1.08,
                          "\(label): inactive background stays subtle instead of becoming a gray slab")
                try check(foreground.contrastRatio(with: inactive) >= 4.5, "\(label): inactive output remains readable")
                try check(secondary.contrastRatio(with: inactive) >= 4.5, "\(label): secondary output remains readable")
                for hex in colors.ansi {
                    let text = RGBColor(ghosttyHex: hex)!
                    try check(text.contrastRatio(with: inactive) >= 4.5
                              && (isWhiteDefault || text.contrastRatio(with: inactive) >= text.contrastRatio(with: focused)),
                              "\(label): inactive ANSI text keeps its reading contrast")
                }
                try check(isDark || isWhiteDefault ? inactive.relativeLuminance < focused.relativeLuminance
                                 : inactive.relativeLuminance > focused.relativeLuminance,
                          "\(label): inactive background recedes without dimming the text")
            }
        }
        let suite = "oneagent.remote-palette.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try check(LocalPalette.stored(defaults: defaults) == .clearSkyBlue, "Local must default to M07")
        try check(RemotePalette.stored(defaults: defaults) == .vanillaCustard, "Remote must default to M03")
        try check(Set([ApplicationIcon.storageKey, LocalPalette.storageKey, RemotePalette.storageKey]).count == 3,
                  "Dock, local, and remote choices must persist independently")

        defaults.set(ApplicationIcon.strawberryCream.rawValue, forKey: ApplicationIcon.storageKey)
        try check(LocalPalette.stored(defaults: defaults) == .clearSkyBlue, "Changing the Dock icon must not change the local theme")
        try check(RemotePalette.stored(defaults: defaults) == .vanillaCustard, "Changing the Dock icon must not change the remote theme")

        for invalid in [ApplicationIcon.original.rawValue, "M99"] {
            defaults.set(invalid, forKey: LocalPalette.storageKey)
            defaults.set(invalid, forKey: RemotePalette.storageKey)
            try check(LocalPalette.stored(defaults: defaults) == .clearSkyBlue, "An invalid local choice falls back to M07")
            try check(RemotePalette.stored(defaults: defaults) == .vanillaCustard, "An invalid remote choice falls back to M03")
        }

        defaults.set(ApplicationIcon.mintCandy.rawValue, forKey: LocalPalette.storageKey)
        defaults.set(ApplicationIcon.cloudSoda.rawValue, forKey: RemotePalette.storageKey)
        try check(LocalPalette.stored(defaults: defaults) == .mintCandy, "A saved local choice must be kept")
        try check(RemotePalette.stored(defaults: defaults) == .cloudSoda, "An existing saved remote choice must be kept")
        try check(ApplicationIcon.stored(defaults: defaults) == .strawberryCream, "Terminal choices must not overwrite the Dock icon")

        try check(SharedPalette.stored(defaults: defaults) == .original,
                  "Shared selection starts neutral blue regardless of legacy connection colors")
        defaults.set(ApplicationIcon.cloudSoda.rawValue, forKey: SharedPalette.storageKey)
        try check(SharedPalette.stored(defaults: defaults) == .cloudSoda,
                  "One shared preference restores the selected color for every connection")
        try check(LocalPalette.stored(defaults: defaults) == .mintCandy
                  && RemotePalette.stored(defaults: defaults) == .cloudSoda,
                  "Shared colors preserve legacy preferences for rollback")
        defaults.set("unknown", forKey: SharedPalette.storageKey)
        try check(SharedPalette.stored(defaults: defaults) == .original,
                  "Invalid shared colors fall back to neutral blue")

        try check(AppTheme.stored(defaults: defaults) == .system, "New installs start with the system preset")
        defaults.set("M99", forKey: AppTheme.storageKey)
        try check(AppTheme.stored(defaults: defaults) == .system, "Unknown presets fall back to the system preset")
        defaults.set("M05", forKey: AppTheme.storageKey)
        try check(AppTheme.stored(defaults: defaults) == .mintCandy, "Existing saved themes survive the new default")
        defaults.set("M01", forKey: AppTheme.storageKey)
        try check(AppTheme.stored(defaults: defaults) == .strawberryCream, "Strawberry Cream persists")
        defaults.set("M02", forKey: AppTheme.storageKey)
        try check(AppTheme.stored(defaults: defaults) == .apricotCream, "Apricot Cream persists")
        try check(Set(AppThemePreset.allCases.map(\.icon)) == Set(ApplicationIcon.allCases),
                  "Every existing macaron identity has a complete theme")
        for preset in AppThemePreset.allCases {
        defaults.set(preset.rawValue, forKey: AppTheme.storageKey)
        try check(AppTheme.stored(defaults: defaults) == preset, "Every preset choice persists")
        for isDark in [false, true] {
            let chrome = WindowChrome(isDark: isDark, preset: preset)
            let colors = AppTheme.colors(isDark: isDark, preset: preset)
            let terminalBackground = RGBColor(ghosttyHex: colors.background)!
            try check(colors.ansi.count == 16, "Preset includes every ANSI slot")
            for color in colors.ansi {
                try check(RGBColor(ghosttyHex: color)!.contrastRatio(with: terminalBackground) >= 4.5,
                          "ANSI text remains readable: \(color), dark=\(isDark)")
            }
            // 默认主题也使用固定色板，一并校验浅深色下的正文、路径和选中态。
            let surfaces = [chrome.background, chrome.sidebarBackground, chrome.elevated, chrome.accentFill]
                + colors.gradientColors
            for surface in surfaces {
                for foreground in [chrome.text, chrome.secondary, chrome.accent] {
                    try check(rgb(foreground).contrastRatio(with: rgb(surface)) >= 4.5,
                              "Text and controls remain readable on every preset surface, preset=\(preset.id), dark=\(isDark)")
                }
            }
            for fill in [chrome.accent, chrome.accentHover, chrome.accentActive, chrome.danger] {
                try check(rgb(chrome.filledForeground(on: fill)).contrastRatio(with: rgb(fill)) >= 4.5,
                          "Filled controls retain readable labels")
            }
            try check(rgb(chrome.lineStrong).contrastRatio(with: rgb(chrome.background)) >= 3,
                      "Necessary control outlines remain identifiable")
            try check(rgb(chrome.text).contrastRatio(with: terminalBackground) >= 7,
                      "Reading text has strong contrast")
        }
        try check(saturation(rgb(WindowChrome(isDark: true, preset: preset).background)) < 0.12,
                  "Dark reading panels remain neutral charcoal instead of green")
        try check(AppTheme.colors(isDark: false, preset: preset).gradient.count > 1
                  && AppTheme.colors(isDark: true, preset: preset).gradient.count > 1,
                  "Both appearances retain the gradient")
        }
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func rgb(_ color: Color) -> RGBColor {
        let color = NSColor(color).usingColorSpace(.sRGB)!
        return RGBColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
    }

    static func saturation(_ color: RGBColor) -> Double {
        let channels = [color.red, color.green, color.blue]
        return (channels.max()! - channels.min()!) / channels.max()!
    }
}
