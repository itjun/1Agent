import AppKit
import GhosttyTheme
import SwiftUI

enum Theme {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    static let sidebarRowTitle = Font.system(size: 13, weight: .medium)
    static let sidebarRowMeta = Font.system(size: 11)

    /// Dot colors for a host alias that is open more than once. No red: red means a broken connection.
    static let duplicateHostMarks: [Color] = [
        dynamic(hex(0x0052D9), hex(0x366EF4)),
        dynamic(hex(0xE37318), hex(0xE37318)),
        dynamic(hex(0x2BA471), hex(0x2BA471)),
        dynamic(hex(0x8E56DD), hex(0xAD75FE)),
        dynamic(hex(0x029CD4), hex(0x029CD4)),
        dynamic(hex(0xC9489B), hex(0xE06CB8)),
    ]

    static func duplicateHostMark(_ index: Int) -> Color {
        let palette = Theme.duplicateHostMarks
        let wrapped = ((index % palette.count) + palette.count) % palette.count
        return palette[wrapped]
    }
}

/// Colors for the whole terminal window. The sidebar, pane headers, and terminal share one set,
/// derived from whichever theme fills the current appearance slot.
struct WindowChrome: Equatable {
    var background: Color
    var elevated: Color
    var text: Color
    var secondary: Color
    var hairline: Color
    var accent: Color
    var danger: Color

    @MainActor
    static func resolve(isDark: Bool) -> WindowChrome {
        if isDark {
            return ThemePreview.shared.effectiveDark().chrome()
        }
        return ThemePreview.shared.effectiveLight().chrome()
    }

    init(theme: GhosttyThemeDefinition, preferredAccent: String? = nil) {
        let background = RGBColor(ghosttyHex: theme.background) ?? RGBColor(red: 0.06, green: 0.06, blue: 0.07)
        let foreground = RGBColor(ghosttyHex: theme.foreground) ?? RGBColor(red: 0.9, green: 0.9, blue: 0.9)
        let accent = RGBColor(ghosttyHex: preferredAccent ?? theme.palette[4] ?? theme.cursorColor ?? theme.foreground) ?? foreground
        let danger = RGBColor(ghosttyHex: theme.palette[1] ?? "E2726A") ?? RGBColor(red: 0.86, green: 0.32, blue: 0.28)
        self.background = background.color
        self.elevated = background.mixed(with: foreground, amount: 0.08).color
        self.text = foreground.color
        self.secondary = foreground.color.opacity(0.68)
        self.hairline = foreground.color.opacity(0.16)
        self.accent = accent.color
        self.danger = danger.color
    }
}

private struct RGBColor {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(ghosttyHex raw: String) {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    func mixed(with other: RGBColor, amount: Double) -> RGBColor {
        RGBColor(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount
        )
    }
}

private struct WindowChromeKey: EnvironmentKey {
    static let defaultValue = WindowChrome(theme: GhosttyThemeCatalog.theme(named: TerminalThemeChoice.defaultLightName)!)
}

extension EnvironmentValues {
    var windowChrome: WindowChrome {
        get { self[WindowChromeKey.self] }
        set { self[WindowChromeKey.self] = newValue }
    }
}
