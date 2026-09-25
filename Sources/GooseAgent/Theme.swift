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
    static let sidebarGroupHeader = Font.system(size: 13, weight: .semibold)

    static let text = dynamic(hex(0x242424), hex(0xE2E2E2))
    static let textSecondary = dynamic(hex(0x666666), hex(0xA3A3A3))
    static let danger = dynamic(hex(0xC94F44), hex(0xE2726A))

    private static let accentLightValue: UInt32 = 0xC85F44
    private static let accentDarkValue: UInt32 = 0xE2795B
    static let accent = dynamic(hex(accentLightValue), hex(accentDarkValue))

    static func accentHex(dark: Bool) -> String {
        String(format: "#%06X", dark ? accentDarkValue : accentLightValue)
    }

    static let terminalBackground = dynamic(hex(0xFFFFFF), hex(0x101012))
    static let statusBarBackground = dynamic(hex(0xF1F1F2), hex(0x141416))
    static let hairline = dynamic(hex(0x000000, alpha: 0.08), hex(0xFFFFFF, alpha: 0.06))
}

/// Colors for the whole terminal window. A selected Ghostty theme paints the
/// sidebar, header, and terminal together; otherwise the built-in light or dark set is used.
struct WindowChrome: Equatable {
    var background: Color
    var elevated: Color
    var text: Color
    var secondary: Color
    var hairline: Color
    var accent: Color
    var danger: Color

    init(
        background: Color,
        elevated: Color,
        text: Color,
        secondary: Color,
        hairline: Color,
        accent: Color,
        danger: Color
    ) {
        self.background = background
        self.elevated = elevated
        self.text = text
        self.secondary = secondary
        self.hairline = hairline
        self.accent = accent
        self.danger = danger
    }

    static func resolve(isDark: Bool) -> WindowChrome {
        let family = TerminalThemeFamily.current()
        if isDark, let paint = family.darkPaint { return paint.chrome() }
        if !isDark, let paint = family.lightPaint { return paint.chrome() }
        let name = isDark ? family.darkName : family.lightName
        if let name, let theme = GhosttyThemeCatalog.theme(named: name) {
            return WindowChrome(theme: theme)
        }
        return isDark ? builtinDark : builtinLight
    }

    init(theme: GhosttyThemeDefinition) {
        let background = RGBColor(ghosttyHex: theme.background) ?? RGBColor(red: 0.06, green: 0.06, blue: 0.07)
        let foreground = RGBColor(ghosttyHex: theme.foreground) ?? RGBColor(red: 0.9, green: 0.9, blue: 0.9)
        let accent = RGBColor(ghosttyHex: theme.palette[4] ?? theme.cursorColor ?? theme.foreground) ?? foreground
        let danger = RGBColor(ghosttyHex: theme.palette[1] ?? "E2726A") ?? RGBColor(red: 0.86, green: 0.32, blue: 0.28)
        self.background = background.color
        self.elevated = background.mixed(with: foreground, amount: 0.08).color
        self.text = foreground.color
        self.secondary = foreground.color.opacity(0.68)
        self.hairline = foreground.color.opacity(0.16)
        self.accent = accent.color
        self.danger = danger.color
    }

    static let builtinLight = WindowChrome(
        background: Color(red: 1, green: 1, blue: 1),
        elevated: Color(red: 0.945, green: 0.945, blue: 0.949),
        text: Color(red: 0.141, green: 0.141, blue: 0.141),
        secondary: Color(red: 0.4, green: 0.4, blue: 0.4),
        hairline: Color.black.opacity(0.08),
        accent: Color(red: 0.784, green: 0.373, blue: 0.267),
        danger: Color(red: 0.788, green: 0.310, blue: 0.267)
    )

    static let builtinDark = WindowChrome(
        background: Color(red: 0.063, green: 0.063, blue: 0.071),
        elevated: Color(red: 0.078, green: 0.078, blue: 0.086),
        text: Color(red: 0.886, green: 0.886, blue: 0.886),
        secondary: Color(red: 0.639, green: 0.639, blue: 0.639),
        hairline: Color.white.opacity(0.08),
        accent: Color(red: 0.886, green: 0.475, blue: 0.357),
        danger: Color(red: 0.886, green: 0.447, blue: 0.416)
    )
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
    static let defaultValue = WindowChrome.builtinLight
}

extension EnvironmentValues {
    var windowChrome: WindowChrome {
        get { self[WindowChromeKey.self] }
        set { self[WindowChromeKey.self] = newValue }
    }
}
