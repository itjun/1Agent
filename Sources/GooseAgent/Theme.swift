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
        /// 本机、远程等上级分类，用字重和留白区分列表层级。
        static let sidebarCategory = SwiftUI.Font.system(size: 13, weight: .semibold)
        /// Sidebar section and workspace header labels.
        static let sidebarSection = SwiftUI.Font.system(size: 12, weight: .semibold)
        /// One sidebar row (host alias or local path).
        static let row = SwiftUI.Font.system(size: 14)
        /// Secondary line under a row, or a small status label.
        static let rowMeta = SwiftUI.Font.system(size: 12)
        /// Pane title bar above each terminal; monospaced so paths align with the terminal.
        static let paneTitle = SwiftUI.Font.system(size: 12, weight: .medium, design: .monospaced)
        static let floatingPaneTitle = SwiftUI.Font.system(size: 12)
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
        static let row: CGFloat = 8
        static let control: CGFloat = 6
        static let card: CGFloat = 10
    }

    /// 工作区动效只改变呈现，不延后选择或键盘焦点。
    enum Motion {
        static let selectionDuration: TimeInterval = 0.14
        static let terminalDuration: TimeInterval = 0.16
    }

    /// 主窗口的共用排版尺寸。
    enum DefaultLayout {
        static let toolInset: CGFloat = 16
        static let commandTextHeight: CGFloat = 18
        static let iconWidth: CGFloat = 20
        static let badgeHeight: CGFloat = 22
    }

    enum Control {
        static let height: CGFloat = 32
        static let compactHeight: CGFloat = 28
    }

    /// 原生通栏内的标签、分支和操作按钮共用尺寸。
    enum Toolbar {
        static let height = Control.compactHeight
        static let textSize: CGFloat = 13
        static let iconFont = SwiftUI.Font.system(size: 13, weight: .medium)
        /// 右侧工具组前预留终端边界的留白，分支不能占用侧栏顶部。
        static let sectionInset = Space.l
        static let branchMaxWidth: CGFloat = 240
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
        static let titlebarAccessoryInset: CGFloat = 44
        /// Icon size next to the pane title (reconnecting / disconnected).
        static let statusIconSize: CGFloat = 11
        /// ⌘F find bar, under the title bar.
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

/// 保留旧偏好的读取边界；已移除的配色统一回到系统外观。
enum AppThemePreset: String, CaseIterable, Identifiable {
    case system
    var id: String { rawValue }
}

/// 在指定外观下解析系统颜色，避免预览和终端误用当前窗口的浅深色。
enum SystemTheme {
    static func appearance(isDark: Bool) -> NSAppearance {
        let isHighContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        return NSAppearance(named: isHighContrast
            ? (isDark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (isDark ? .darkAqua : .aqua))!
    }

    static func resolved(_ color: NSColor, isDark: Bool) -> NSColor {
        var resolved: NSColor!
        SystemTheme.appearance(isDark: isDark).performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)!
        }
        return resolved
    }

    static func color(_ color: NSColor, isDark: Bool) -> Color {
        Color(nsColor: SystemTheme.resolved(color, isDark: isDark))
    }

    /// 终端配置只接受不透明 RGB；先将语义色的透明度合成到对应背景上。
    static func hex(_ color: NSColor, isDark: Bool, over background: NSColor = .textBackgroundColor) -> String {
        let value = SystemTheme.resolved(color, isDark: isDark)
        let base = SystemTheme.resolved(background, isDark: isDark)
        let alpha = value.alphaComponent
        let channels = [
            value.redComponent * alpha + base.redComponent * (1 - alpha),
            value.greenComponent * alpha + base.greenComponent * (1 - alpha),
            value.blueComponent * alpha + base.blueComponent * (1 - alpha),
        ]
        return channels.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }
}

/// 窗口和终端共用系统语义色；旧主题偏好不参与取色。
enum AppTheme {
    static let storageKey = "appearance.preset"
    static let defaultPreset: AppThemePreset = .system

    static func stored(defaults: UserDefaults = .standard) -> AppThemePreset {
        AppThemePreset(rawValue: defaults.string(forKey: AppTheme.storageKey) ?? "") ?? AppTheme.defaultPreset
    }

    static var id: String { AppTheme.stored().rawValue }

    struct Colors {
        let gradient: [String]
        let glow: String
        let background: String
        let foreground: String
        let secondary: String
        let accent: String
        let selection: String
        let hover: String
        let border: String
        let outline: String
        let ansi: [String]

        func color(_ hex: String) -> Color { RGBColor(ghosttyHex: hex)!.color }
        var gradientColors: [Color] { gradient.map { color($0) } }
    }

    /// 聚焦保持实色底板；失焦使用轻微灰阶色差，文字和 ANSI 色保持清晰。
    static func terminalPaneBackground(isDark: Bool, isFocused: Bool,
                                       preset: AppThemePreset = AppTheme.stored()) -> RGBColor {
        let colors = AppTheme.colors(isDark: isDark, preset: preset)
        let base = RGBColor(ghosttyHex: colors.background)!
        guard !isFocused else { return base }
        // 系统窗口底色可能与终端底色完全相同，直接混合侧栏色无法区分分屏。
        let neutral = RGBColor(ghosttyHex: isDark ? "FFFFFF" : "000000")!
        return base.mixed(with: neutral, amount: isDark ? 0.06 : 0.05)
    }

    static var light: Colors { AppTheme.colors(isDark: false) }
    static var dark: Colors { AppTheme.colors(isDark: true) }

    static func colors(isDark: Bool, preset: AppThemePreset = AppTheme.stored()) -> Colors {
        let shell = SystemTheme.hex(.windowBackgroundColor, isDark: isDark)
        return Colors(
            gradient: [shell, shell, shell], glow: shell,
            background: SystemTheme.hex(.textBackgroundColor, isDark: isDark),
            foreground: SystemTheme.hex(.textColor, isDark: isDark),
            secondary: SystemTheme.hex(.secondaryLabelColor, isDark: isDark),
            accent: SystemTheme.hex(.controlAccentColor, isDark: isDark),
            selection: SystemTheme.hex(.selectedTextBackgroundColor, isDark: isDark),
            hover: SystemTheme.hex(.controlColor, isDark: isDark),
            border: SystemTheme.hex(.separatorColor, isDark: isDark),
            outline: SystemTheme.hex(.keyboardFocusIndicatorColor, isDark: isDark),
            // ANSI 槽位属于终端内容，保留在浅深底色上清晰可读的一组颜色。
            ansi: isDark
                ? ["B8B8B8", "E58D96", "9DCEA8", "D8C18B", "96B9DE", "C2A2D5", "8AC9C6", "B8B8B8",
                   "B8B8B8", "F3A4AC", "B4DFBB", "EAD5A4", "B0CDED", "D6BBE5", "A5DEDA", "E3EDF2"]
                : ["272727", "A54450", "416D53", "80601E", "0064E1", "79557F", "326F78", "666666",
                   "666666", "B13E50", "3D714F", "846116", "0064E1", "845183", "26737C", "272727"]
        )
    }

}

/// 所有窗口共用当前预设，终端读取同一组底色、文字和强调色。
struct WindowChrome: Equatable {
    let isDark: Bool
    let isSystem: Bool
    var background: Color
    var sidebarBackground: Color
    var elevated: Color
    var text: Color
    var secondary: Color
    var tertiary: Color
    var hairline: Color
    var accent: Color
    var accentFill: Color
    var selectionText: Color
    var panelHeader: Color
    var danger: Color
    var warning: Color
    var success: Color
    var accentHover: Color
    var accentActive: Color
    var focus: Color
    var selection: Color
    var lineStrong: Color

    /// 通知保留系统中性底色，浅色下比窗口标题背景更轻，深色下仍有清楚的层次。
    var notificationBackground: Color {
        Color(nsColor: NSColor(background).blended(withFraction: 0.35, of: NSColor(panelHeader)) ?? NSColor(background))
    }

    var hoverFill: Color { elevated }

    func rowSelection(active: Bool) -> Color {
        active ? accentFill : SystemTheme.color(.unemphasizedSelectedContentBackgroundColor, isDark: isDark)
    }

    func sessionSelection(isActive: Bool) -> Color {
        SystemTheme.color(isActive ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor,
                          isDark: isDark)
    }

    func sessionRowChrome(isSelected: Bool, isActive: Bool) -> WindowChrome {
        guard isSelected else { return self }
        var row = self
        row.text = SystemTheme.color(isActive ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor,
                                    isDark: isDark)
        row.secondary = row.text
        row.tertiary = row.text
        row.danger = row.text
        row.warning = row.text
        row.success = row.text
        return row
    }

    var inactiveIcon: Color { secondary }

    /// 实心控件根据系统强调色选择清晰的黑字或白字。
    func filledForeground(on fill: Color) -> Color {
        let resolved = NSColor(fill).usingColorSpace(.sRGB)!
        let background = RGBColor(red: resolved.redComponent, green: resolved.greenComponent, blue: resolved.blueComponent)
        let black = RGBColor(red: 0, green: 0, blue: 0)
        let white = RGBColor(red: 1, green: 1, blue: 1)
        return black.contrastRatio(with: background) >= white.contrastRatio(with: background) ? .black : .white
    }

    static func resolve(isDark: Bool) -> WindowChrome {
        WindowChrome(isDark: isDark, preset: AppTheme.stored())
    }

    init(isDark: Bool, preset: AppThemePreset = AppTheme.stored()) {
        self.isDark = isDark
        isSystem = preset == .system
        background = SystemTheme.color(.textBackgroundColor, isDark: isDark)
        // 新系统上窗口底色与文本底色相同；页底色在部分环境下是半透明灰，侧栏只能自行合成不透明的异色。
        let readingBackground = SystemTheme.resolved(.textBackgroundColor, isDark: isDark)
        sidebarBackground = Color(nsColor: readingBackground.blended(withFraction: 0.02,
                                                                     of: isDark ? .white : .black)!)
        elevated = SystemTheme.color(.controlColor, isDark: isDark)
        text = SystemTheme.color(.labelColor, isDark: isDark)
        secondary = SystemTheme.color(.secondaryLabelColor, isDark: isDark)
        tertiary = SystemTheme.color(.tertiaryLabelColor, isDark: isDark)
        hairline = SystemTheme.color(.separatorColor, isDark: isDark)
        accent = SystemTheme.color(.controlAccentColor, isDark: isDark)
        accentFill = SystemTheme.color(.selectedTextBackgroundColor, isDark: isDark)
        selectionText = SystemTheme.color(.selectedTextColor, isDark: isDark)
        panelHeader = SystemTheme.color(.windowBackgroundColor, isDark: isDark)
        danger = SystemTheme.color(.systemRed, isDark: isDark)
        warning = SystemTheme.color(.systemOrange, isDark: isDark)
        success = SystemTheme.color(.systemGreen, isDark: isDark)
        accentHover = accent.opacity(0.88)
        accentActive = accent.opacity(0.76)
        focus = SystemTheme.color(.keyboardFocusIndicatorColor, isDark: isDark)
        selection = accentFill
        lineStrong = SystemTheme.color(.controlTextColor, isDark: isDark)

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

extension Color {
    init?(ghosttyHex raw: String) {
        guard let rgb = RGBColor(ghosttyHex: raw) else { return nil }
        self = rgb.color
    }
}
