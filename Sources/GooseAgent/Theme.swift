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

    static let sidebarRowTitle = SwiftUI.Font.system(size: 13, weight: .medium)
    static let sidebarRowMeta = Theme.Font.rowMeta

    /// Type scale shared by the sidebar, pane headers, and sheets.
    enum Font {
        /// Sidebar section and workspace header labels.
        static let sidebarSection = SwiftUI.Font.system(size: 11, weight: .semibold)
        /// One sidebar row (host alias or local path).
        static let row = SwiftUI.Font.system(size: 13)
        /// Secondary line under a row, or a small status label.
        static let rowMeta = SwiftUI.Font.system(size: 11)
        /// Pane title bar above each terminal; monospaced so paths align with the terminal.
        static let paneTitle = SwiftUI.Font.system(size: 12, weight: .medium, design: .monospaced)
        /// Section headline inside settings and sheets.
        static let sectionTitle = SwiftUI.Font.system(size: 15, weight: .semibold)
        /// Default body text.
        static let body = SwiftUI.Font.system(size: 13)
        /// Headline of an empty state ("No open terminals").
        static let emptyTitle = SwiftUI.Font.system(size: 17, weight: .semibold)
        /// Large SF Symbol above an empty-state headline.
        static let emptySymbol = SwiftUI.Font.system(size: 40)
    }

    /// Spacing steps. Use these instead of ad-hoc padding values.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Corner radii, from a selected row up to a card.
    enum Radius {
        static let row: CGFloat = 6
        static let control: CGFloat = 8
        static let card: CGFloat = 10
    }

    /// Geometry of the title bar and status banner above each terminal pane.
    enum PaneStyle {
        /// Divider line between panes, at rest and while hovered or dragged.
        static let dividerLineWidth: CGFloat = 1
        static let dividerActiveLineWidth: CGFloat = 2
        /// Height of the system title bar band; the traffic lights sit centered in it.
        /// A lone pane gets a strip this tall instead of a title bar, and the sidebar header matches it.
        static let titlebarHeight: CGFloat = 32
        /// Strip above a lone pane. Shorter than the title bar band so the terminal starts close under the title.
        static let stripHeight: CGFloat = 26
        /// Vertical center of the traffic lights from the window top; the lone pane's title sits on it.
        static let trafficLightCenterY: CGFloat = 16
        /// Kept free on both sides of the lone pane's centered title, so it never runs under the zoom button.
        static let stripTitleInset: CGFloat = 40
        /// Title bar of each pane in a split. Dragging the title text merges panes; the terminal starts right below.
        static let headerHeight: CGFloat = 22
        /// Disconnected / reconnecting banner shown under the title bar.
        static let bannerHeight: CGFloat = 28
        /// Icon size next to the pane title (reconnecting / disconnected).
        static let statusIconSize: CGFloat = 11
        /// Opacity of the warning / danger tint over the banner background.
        static let bannerTintOpacity: Double = 0.14
        /// ⌘F find bar, under the title bar and any banner.
        static let findBarHeight: CGFloat = 32
        /// Query field inside the find bar.
        static let findFieldHeight: CGFloat = 22
        static let findFieldMaxWidth: CGFloat = 280
        /// Hit area of the previous / next / close buttons in the find bar.
        static let findButtonSize: CGFloat = 22
        /// Magnifying glass and button symbols in the find bar.
        static let findIconSize: CGFloat = 12
        /// Border flashed around a terminal when its bell rings (`bell-features = border`).
        static let bellBorderWidth: CGFloat = 3
        static let bellFlashDuration: Double = 0.6
        /// OSC 9;4 progress bar along the bottom of the title bar (or of the lone pane's strip).
        static let progressBarHeight: CGFloat = 2
        static let progressFadeDuration: Double = 0.3
        /// Indeterminate progress: a segment this share of the width sweeps back and forth.
        static let progressSweepWidthRatio: CGFloat = 0.25
        static let progressSweepDuration: Double = 1.2
        /// URL shown bottom left while the pointer is over a link.
        static let linkBannerFontSize: CGFloat = 11
        /// The banner never takes more than this share of the terminal's width.
        static let linkBannerMaxWidthRatio: CGFloat = 0.75
        /// Accent outline while files are dragged over a terminal.
        static let dropHighlightWidth: CGFloat = 2
        static let dropHighlightFillOpacity: Double = 0.08
        /// Hit area of a button in the title bar (the zoom mark).
        static let headerButtonSize: CGFloat = 20
    }

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
    /// Sidebar surface: background nudged 3.5% toward the foreground so it reads as its own layer.
    var sidebarBackground: Color
    var elevated: Color
    var text: Color
    /// Muted text. Opaque mix of foreground into background, kept at ≥ 3.0 contrast with background.
    var secondary: Color
    /// Fainter than secondary, for hints and timestamps. Kept at ≥ 2.0 contrast with background.
    var tertiary: Color
    /// Separator lines. Opaque mix of background toward foreground, kept at ≥ 1.25 contrast with background.
    var hairline: Color
    /// palette[4], pulled toward the foreground until it reaches ≥ 3.0 contrast with background.
    var accent: Color
    /// Opaque selection fill: background mixed with accent at 16%.
    var accentFill: Color
    /// palette[1] (broken connection), same contrast guard as accent.
    var danger: Color
    /// palette[3] (reconnecting), same contrast guard as accent.
    var warning: Color
    /// palette[2] (healthy), same contrast guard as accent.
    var success: Color

    /// Text on top of the background must reach this WCAG ratio to stay legible.
    static let textContrastFloor: Double = 3.0

    @MainActor
    static func resolve(isDark: Bool) -> WindowChrome {
        if isDark {
            return ThemePreview.shared.effectiveDark().chrome()
        }
        return ThemePreview.shared.effectiveLight().chrome()
    }

    /// System semantic colors remain legible on AppKit's adaptive sidebar glass.
    var nativeSidebar: WindowChrome {
        var result = self
        result.sidebarBackground = .clear
        result.text = Color(nsColor: .labelColor)
        result.secondary = Color(nsColor: .secondaryLabelColor)
        result.tertiary = Color(nsColor: .tertiaryLabelColor)
        result.hairline = Color(nsColor: .separatorColor)
        result.accent = Color(nsColor: .controlAccentColor)
        result.accentFill = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        result.danger = Color(nsColor: .systemRed)
        result.warning = Color(nsColor: .systemOrange)
        result.success = Color(nsColor: .systemGreen)
        return result
    }

    init(theme: GhosttyThemeDefinition, preferredAccent: String? = nil) {
        let background = RGBColor(ghosttyHex: theme.background) ?? RGBColor(red: 0.06, green: 0.06, blue: 0.07)
        let foreground = RGBColor(ghosttyHex: theme.foreground) ?? RGBColor(red: 0.9, green: 0.9, blue: 0.9)
        let rawAccent = RGBColor(ghosttyHex: preferredAccent ?? theme.palette[4] ?? theme.cursorColor ?? theme.foreground) ?? foreground
        let rawDanger = RGBColor(ghosttyHex: theme.palette[1] ?? "E2726A") ?? RGBColor(red: 0.86, green: 0.32, blue: 0.28)
        let rawWarning = RGBColor(ghosttyHex: theme.palette[3] ?? "D9A500") ?? RGBColor(red: 0.85, green: 0.65, blue: 0.0)
        let rawSuccess = RGBColor(ghosttyHex: theme.palette[2] ?? "4CAF50") ?? RGBColor(red: 0.3, green: 0.69, blue: 0.31)
        let floor = WindowChrome.textContrastFloor
        let accent = RGBColor.ensureContrast(rawAccent, against: background, toward: foreground, minimum: floor)
        // 0.32 toward background matches the old 68% opacity, so themes that already pass look the same.
        let secondary = RGBColor.ensureContrast(foreground.mixed(with: background, amount: 0.32), against: background, toward: foreground, minimum: floor)
        let tertiary = RGBColor.ensureContrast(foreground.mixed(with: background, amount: 0.5), against: background, toward: foreground, minimum: 2.0)
        let hairline = RGBColor.ensureContrast(background.mixed(with: foreground, amount: 0.14), against: background, toward: foreground, minimum: 1.25)
        self.background = background.color
        self.sidebarBackground = background.mixed(with: foreground, amount: 0.035).color
        self.elevated = background.mixed(with: foreground, amount: 0.08).color
        self.text = foreground.color
        self.secondary = secondary.color
        self.tertiary = tertiary.color
        self.hairline = hairline.color
        self.accent = accent.color
        self.accentFill = background.mixed(with: accent, amount: 0.16).color
        self.danger = RGBColor.ensureContrast(rawDanger, against: background, toward: foreground, minimum: floor).color
        self.warning = RGBColor.ensureContrast(rawWarning, against: background, toward: foreground, minimum: floor).color
        self.success = RGBColor.ensureContrast(rawSuccess, against: background, toward: foreground, minimum: floor).color
    }
}

struct RGBColor {
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

    /// WCAG relative luminance: sRGB channels linearized, then weighted.
    var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            if channel <= 0.04045 {
                return channel / 12.92
            }
            return pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, from 1 (same color) to 21 (black on white).
    func contrastRatio(with other: RGBColor) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Nudges `color` 10% toward `target` until it reaches `minimum` contrast against `background`.
    /// Bounded so a target that itself lacks contrast cannot loop forever.
    static func ensureContrast(_ color: RGBColor, against background: RGBColor, toward target: RGBColor, minimum: Double) -> RGBColor {
        var adjusted = color
        var steps = 0
        while adjusted.contrastRatio(with: background) < minimum && steps < 30 {
            adjusted = adjusted.mixed(with: target, amount: 0.1)
            steps += 1
        }
        return adjusted
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
