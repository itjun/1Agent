import AppKit
import SwiftUI

@main
enum RemotePaletteTests {
    static func main() {
        _ = NSApplication.shared
        let suite = "oneagent.system-theme.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        expect(AppThemePreset.allCases == [.system], "Only the system theme is available")
        for oldID in (1...12).map({ String(format: "M%02d", $0) }) + ["unknown"] {
            defaults.set(oldID, forKey: AppTheme.storageKey)
            defaults.set(oldID, forKey: ApplicationIcon.storageKey)
            expect(AppTheme.stored(defaults: defaults) == .system, "Old theme resolves to macOS: \(oldID)")
        }
        for isDark in [false, true] {
            let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)!
            appearance.performAsCurrentDrawingAppearance {
                let chrome = WindowChrome(isDark: isDark)
                let pairs: [(Color, NSColor)] = [
                    (chrome.background, .textBackgroundColor),
                    (chrome.sidebarBackground, .windowBackgroundColor),
                    (chrome.text, .labelColor), (chrome.secondary, .secondaryLabelColor),
                    (chrome.accent, .controlAccentColor), (chrome.hairline, .separatorColor),
                    (chrome.selectionText, .selectedTextColor),
                    (chrome.sessionSelection(isActive: true), .selectedContentBackgroundColor),
                    (chrome.sessionSelection(isActive: false), .unemphasizedSelectedContentBackgroundColor),
                    (chrome.sessionRowChrome(isSelected: true, isActive: true).text, .alternateSelectedControlTextColor),
                    (chrome.sessionRowChrome(isSelected: true, isActive: false).text, .unemphasizedSelectedTextColor),
                ]
                for (actual, expected) in pairs {
                    expect(matches(NSColor(actual), expected), "Native semantic colors match macOS, dark=\(isDark)")
                }
                expect(chrome.panelHeader == chrome.sidebarBackground, "Toolbar and sidebars share their background")
                let colors = AppTheme.colors(isDark: isDark)
                expect(matches(NSColor(colors.color(colors.background)), .textBackgroundColor), "Terminal uses the native reading background")
                expect(colors.ansi.count == 16, "All terminal ANSI slots remain available")
                for isFocused in [false, true] {
                    let background = AppTheme.terminalPaneBackground(isDark: isDark, isFocused: isFocused)
                    expect(RGBColor(ghosttyHex: colors.foreground)!.contrastRatio(with: background) >= 7,
                           "Terminal output stays readable in active and inactive panes")
                    for hex in colors.ansi {
                        expect(RGBColor(ghosttyHex: hex)!.contrastRatio(with: background) >= 4.5,
                               "ANSI output stays readable: \(hex)")
                    }
                }
            }
        }
        expect(AppTheme.light.background != AppTheme.dark.background, "Light and dark resolve independently")
        print("RemotePaletteTests passed: native semantic colors, old palette migration, ANSI readability")
    }

    static func matches(_ actual: NSColor, _ expected: NSColor) -> Bool {
        let a = actual.usingColorSpace(.sRGB)!, b = expected.usingColorSpace(.sRGB)!
        return abs(a.redComponent - b.redComponent) < 0.005
            && abs(a.greenComponent - b.greenComponent) < 0.005
            && abs(a.blueComponent - b.blueComponent) < 0.005
            && abs(a.alphaComponent - b.alphaComponent) < 0.005
    }

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
