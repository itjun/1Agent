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
            try check(local.sidebarBackground == remote.sidebarBackground, "Local and remote share neutral surfaces (dark: \(isDark))")
            try check(local.accent != remote.accent, "Local and remote focus accents must differ (dark: \(isDark))")
        }
        for isDark in [false, true] {
            let neutral = WindowChrome(isDark: isDark, icon: .original)
            for icon in ApplicationIcon.allCases {
                let chrome = WindowChrome(isDark: isDark, icon: icon)
                try check(chrome.background == neutral.background && chrome.sidebarBackground == neutral.sidebarBackground
                          && chrome.elevated == neutral.elevated && chrome.hairline == neutral.hairline,
                          "Every palette shares neutral surfaces: \(icon.rawValue)")
                try check(chrome.text == neutral.text && chrome.secondary == neutral.secondary
                          && chrome.inactiveIcon == neutral.inactiveIcon && chrome.lineStrong == neutral.lineStrong,
                          "Ordinary text, icons and controls stay neutral: \(icon.rawValue)")
                for background in [chrome.background, chrome.elevated] {
                    try check(rgb(chrome.lineStrong).contrastRatio(with: rgb(background)) >= 3,
                              "Necessary control outlines remain identifiable: \(icon.rawValue)")
                }
                for surface in [chrome.background, chrome.sidebarBackground, chrome.elevated, chrome.hairline, chrome.accentFill] {
                    for foreground in [chrome.text, chrome.secondary, chrome.accent] {
                        try check(rgb(foreground).contrastRatio(with: rgb(surface)) >= 4.5,
                                  "Text and selected icons stay readable on every surface: \(icon.rawValue), dark=\(isDark)")
                    }
                    try check(rgb(chrome.focus).contrastRatio(with: rgb(surface)) >= 3,
                              "Keyboard focus stays visible: \(icon.rawValue), dark=\(isDark)")
                }
                try check(rgb(chrome.inactiveIcon).contrastRatio(with: rgb(chrome.sidebarBackground)) >= 3,
                          "Unselected icons remain identifiable: \(icon.rawValue), dark=\(isDark)")
                for fill in [chrome.accent, chrome.accentHover, chrome.accentActive, chrome.danger] {
                    try check(rgb(chrome.filledForeground(on: fill)).contrastRatio(with: rgb(fill)) >= 4.5,
                              "Black or white control labels stay readable in every state: \(icon.rawValue), dark=\(isDark)")
                }
                if isDark {
                    try check(chrome.inactiveIcon == WindowChrome(isDark: true, icon: .original).inactiveIcon,
                              "Unselected terminal icons stay neutral across all palettes")
                    try check(rgb(chrome.inactiveIcon).relativeLuminance < rgb(chrome.accent).relativeLuminance,
                              "Only the active terminal icon gets the brighter accent")
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
