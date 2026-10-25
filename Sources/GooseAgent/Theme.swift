import AppKit
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

    static let sidebarRowTitle = SwiftUI.Font.system(size: 14, weight: .medium)
    static let sidebarRowMeta = Theme.Font.rowMeta

    /// Type scale shared by the sidebar, pane headers, and sheets.
    enum Font {
        /// Sidebar section and workspace header labels.
        static let sidebarSection = SwiftUI.Font.system(size: 12, weight: .semibold)
        /// One sidebar row (host alias or local path).
        static let row = SwiftUI.Font.system(size: 14)
        /// Secondary line under a row, or a small status label.
        static let rowMeta = SwiftUI.Font.system(size: 12)
        /// Pane title bar above each terminal; monospaced so paths align with the terminal.
        static let paneTitle = SwiftUI.Font.system(size: 12, weight: .medium, design: .monospaced)
        /// Section headline inside settings and sheets.
        static let sectionTitle = SwiftUI.Font.system(size: 14, weight: .semibold)
        /// Default body text.
        static let body = SwiftUI.Font.system(size: 14)
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
        static let tag: CGFloat = 3
        static let row: CGFloat = 4
        static let control: CGFloat = 4
        static let card: CGFloat = 6
    }

    /// 工作区动效只改变呈现，不延后选择或键盘焦点。
    enum Motion {
        static let selectionDuration: TimeInterval = 0.14
        static let terminalDuration: TimeInterval = 0.16
        static let overviewInDuration: TimeInterval = 0.22
        static let overviewOutDuration: TimeInterval = 0.16
        static let overviewInitialScale: CGFloat = 0.97
        static let overviewOffset: CGFloat = 8
    }

    enum Control {
        static let height: CGFloat = 32
        static let compactHeight: CGFloat = 28
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
        static let headerHeight: CGFloat = 28
        static let focusRailWidth: CGFloat = 3
        static let focusRailHeight: CGFloat = 36
        static let focusRailInset: CGFloat = 2
        static let focusRailTopInset: CGFloat = 8
        static let titlebarAccessoryInset: CGFloat = 44
        /// Disconnected / reconnecting banner shown under the title bar.
        static let bannerHeight: CGFloat = 48
        /// Icon size next to the pane title (reconnecting / disconnected).
        static let statusIconSize: CGFloat = 11
        /// Opacity of the warning / danger tint over the banner background.
        static let bannerTintOpacity: Double = 0.14
        /// ⌘F find bar, under the title bar and any banner.
        static let findBarHeight: CGFloat = 36
        /// Query field inside the find bar.
        static let findFieldHeight: CGFloat = 28
        static let findFieldMaxWidth: CGFloat = 280
        /// Hit area of the previous / next / close buttons in the find bar.
        static let findButtonSize: CGFloat = 28
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

/// Fixed family chrome. Terminal themes own only the terminal rendering surface.
struct WindowChrome: Equatable {
    var background: Color
    var sidebarBackground: Color
    var elevated: Color
    var text: Color
    var secondary: Color
    var tertiary: Color
    var hairline: Color
    var accent: Color
    var accentFill: Color
    var panelHeader: Color
    var danger: Color
    var warning: Color
    var success: Color
    var accentHover: Color
    var accentActive: Color
    var focus: Color
    var selection: Color
    var lineStrong: Color

    static func resolve(isDark: Bool, icon: ApplicationIcon = LocalPalette.stored()) -> WindowChrome {
        WindowChrome(isDark: isDark, icon: icon)
    }

    init(isDark: Bool, icon: ApplicationIcon = LocalPalette.stored()) {
        func rgb(_ light: String, _ dark: String) -> RGBColor {
            RGBColor(ghosttyHex: isDark ? dark : light)!
        }
        func color(_ light: String, _ dark: String) -> Color {
            rgb(light, dark).color
        }
        // 外观深色以各自马卡龙色相配灰，不再借用独立终端主题的背景。
        let paletteBackground = switch icon {
        case .original: "20242B"
        case .strawberryCream: "2B2429"
        case .apricotCream: "2C2620"
        case .vanillaCustard: "2B2920"
        case .pistachioGreen: "262A21"
        case .mintCandy: "222B26"
        case .cloudSoda: "202A2D"
        case .clearSkyBlue: "232830"
        case .taroMilkshake: "292530"
        case .coralPeach: "2D2422"
        case .cocoaMilkTea: "2A2623"
        }
        let white = RGBColor(red: 1, green: 1, blue: 1)
        let black = RGBColor(red: 0, green: 0, blue: 0)
        let backgroundRGB = rgb("FFFFFF", paletteBackground)
        let sidebarRGB = isDark
            ? backgroundRGB.mixed(with: black, amount: 0.08)
            : rgb("F2F3F5", "12161F")
        background = backgroundRGB.color
        sidebarBackground = sidebarRGB.color
        let elevatedRGB = isDark ? backgroundRGB.mixed(with: white, amount: 0.035) : rgb("F3F4F6", "232A38")
        let hairlineRGB = isDark ? backgroundRGB.mixed(with: white, amount: 0.065) : rgb("E5E7EB", "2C3445")
        elevated = elevatedRGB.color
        text = color("1F2937", "EEF0F3")
        secondary = color("5B626D", "B0B3BA")
        tertiary = secondary
        hairline = hairlineRGB.color
        accent = color("0052D9", "8CB8FF")
        accentFill = color("E8EFFF", "313D50")
        panelHeader = sidebarBackground
        danger = color("D54941", "F06C63")
        warning = color("D35A00", "F29A4A")
        success = color("1A7F52", "56C08D")
        accentHover = color("366EF4", "A3C6FF")
        accentActive = color("003CAB", "779CD9")
        focus = color("0052D9", "8CB8FF")
        selection = color("C9DAFF", "274A8C")
        lineStrong = color("9CA3AF", "5A6478")

        guard let palette = icon.palette else { return }
        let fill = RGBColor(ghosttyHex: palette.fill)!
        let ring = RGBColor(ghosttyHex: palette.ring)!
        let ink = RGBColor(ghosttyHex: palette.ink)!
        let selectedRGB = isDark ? backgroundRGB.mixed(with: fill, amount: 0.14) : fill.mixed(with: white, amount: 0.55)
        let contrastBackground = isDark ? selectedRGB : hairlineRGB.mixed(with: fill, amount: 0.4)
        // 按最不利的选中／悬停背景校正；浅色保留奶白底，深色保留各自色相。
        let tone = RGBColor.ensureContrast(
            isDark ? ring : ink,
            against: contrastBackground,
            toward: isDark ? white : black,
            minimum: 4.5
        )
        accent = tone.color
        accentHover = tone.mixed(with: white, amount: 0.2).color
        accentActive = tone.mixed(with: black, amount: isDark ? 0.15 : 0.2).color
        accentFill = selectedRGB.color
        focus = tone.color
        secondary = RGBColor.ensureContrast(rgb("636A76", "B0B3BA"), against: contrastBackground,
                                            toward: isDark ? white : black, minimum: 4.5).color
        tertiary = secondary
        if isDark {
            selection = ring.mixed(with: backgroundRGB, amount: 0.45).color
        } else {
            selection = fill.mixed(with: ring, amount: 0.3).color
            sidebarBackground = sidebarRGB.mixed(with: fill, amount: 0.18).color
            elevated = elevatedRGB.mixed(with: fill, amount: 0.25).color
            hairline = hairlineRGB.mixed(with: fill, amount: 0.4).color
        }
        panelHeader = sidebarBackground
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
    static let defaultValue = WindowChrome(isDark: false)
}

extension EnvironmentValues {
    var windowChrome: WindowChrome {
        get { self[WindowChromeKey.self] }
        set { self[WindowChromeKey.self] = newValue }
    }
}

struct CompactToolbarLabelStyle: LabelStyle {
    var compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            if !compact { configuration.title }
        }
    }
}
