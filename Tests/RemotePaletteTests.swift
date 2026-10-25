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

        for isDark in [false, true] {
            let local = WindowChrome(isDark: isDark, icon: LocalPalette.defaultPalette)
            let remote = WindowChrome(isDark: isDark, icon: RemotePalette.defaultPalette)
            try check(local.sidebarBackground != remote.sidebarBackground, "Local and remote chrome must differ (dark: \(isDark))")
            try check(local.accent != remote.accent, "Local and remote focus accents must differ (dark: \(isDark))")
        }
        for isDark in [false, true] {
            var backgrounds: [Color] = []
            for icon in ApplicationIcon.allCases {
                let chrome = WindowChrome(isDark: isDark, icon: icon)
                if icon != .original {
                    try check(!backgrounds.contains(chrome.sidebarBackground), "Each macaron appearance keeps its own surface: \(icon.rawValue)")
                    backgrounds.append(chrome.sidebarBackground)
                }
                for surface in [chrome.background, chrome.sidebarBackground, chrome.elevated, chrome.hairline, chrome.accentFill] {
                    for foreground in [chrome.text, chrome.secondary, chrome.accent] {
                        try check(rgb(foreground).contrastRatio(with: rgb(surface)) >= 4.5,
                                  "Text and selected icons stay readable on every surface: \(icon.rawValue), dark=\(isDark)")
                    }
                    try check(rgb(chrome.focus).contrastRatio(with: rgb(surface)) >= 3,
                              "Keyboard focus stays visible: \(icon.rawValue), dark=\(isDark)")
                }
                if isDark {
                    try check(rgb(chrome.sidebarBackground).relativeLuminance < rgb(chrome.background).relativeLuminance
                              && rgb(chrome.background).relativeLuminance < rgb(chrome.elevated).relativeLuminance
                              && rgb(chrome.elevated).relativeLuminance < rgb(chrome.hairline).relativeLuminance
                              && rgb(chrome.hairline).relativeLuminance < rgb(chrome.accentFill).relativeLuminance,
                              "Dark surfaces, hover and selection retain a clear luminance hierarchy: \(icon.rawValue)")
                }
            }
        }
        for icon in ApplicationIcon.macaronIcons {
            let palette = icon.palette!
            let background = RGBColor(ghosttyHex: palette.terminalBackground)!
            let foreground = RGBColor(ghosttyHex: palette.terminalForeground)!
            let accent = RGBColor(ghosttyHex: palette.terminalAccent)!
            try check(foreground.contrastRatio(with: background) >= 7,
                      "Terminal body text must remain readable for \(icon.rawValue)")
            try check(accent.contrastRatio(with: background) >= 4.5,
                      "Focus borders and identity labels must remain clear for \(icon.rawValue)")
            let light = WindowChrome(isDark: false, icon: icon)
            let dark = WindowChrome(isDark: true, icon: icon)
            try check(rgb(light.sidebarBackground).relativeLuminance > 0.8 && rgb(dark.sidebarBackground).relativeLuminance < 0.03,
                      "Every existing appearance has a light and dark counterpart: \(icon.rawValue)")
            try check(saturation(rgb(dark.background)) < saturation(background),
                      "Dark appearance softens the old highly tinted background: \(icon.rawValue)")
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
