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
        /// 本机、远程等上级分类，字号高于下属终端组和会话。
        static let sidebarCategory = SwiftUI.Font.system(size: 12, weight: .semibold)
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

    /// 使用持久 ID 分色，重命名、拖动或重启都不会改变文件夹的色系。
    static func folderPalette(for id: UUID) -> ApplicationIcon {
        let palettes: [ApplicationIcon] = [
            .apricotCream, .taroMilkshake, .vanillaCustard,
            .strawberryCream, .cloudSoda, .coralPeach,
        ]
        let hash = id.uuidString.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return palettes[Int(hash % UInt64(palettes.count))]
    }
}

/// 完整马卡龙预设，共用名称、图标以及浅深色外观。
enum AppThemePreset: String, CaseIterable, Identifiable {
    case strawberryCream = "M01"
    case apricotCream = "M02"
    case vanillaCustard = "M03"
    case pistachioGreen = "M04"
    case mintCandy = "M05"
    case cloudSoda = "M06"
    case clearSkyBlue = "M07"
    case taroMilkshake = "M08"
    case coralPeach = "M09"
    case cocoaMilkTea = "M10"

    var id: String { rawValue }
    var icon: ApplicationIcon {
        switch self {
        case .strawberryCream: .strawberryCream
        case .apricotCream: .apricotCream
        case .mintCandy: .mintCandy
        case .vanillaCustard: .vanillaCustard
        case .pistachioGreen: .pistachioGreen
        case .cloudSoda: .cloudSoda
        case .clearSkyBlue: .clearSkyBlue
        case .taroMilkshake: .taroMilkshake
        case .coralPeach: .coralPeach
        case .cocoaMilkTea: .cocoaMilkTea
        }
    }
}

/// 一套完整预设同时决定窗口、终端和应用图标；旧 Ghostty 偏好不参与取色。
enum AppTheme {
    static let storageKey = "appearance.preset"
    static let defaultPreset: AppThemePreset = .mintCandy

    static func stored(defaults: UserDefaults = .standard) -> AppThemePreset {
        AppThemePreset(rawValue: defaults.string(forKey: AppTheme.storageKey) ?? "") ?? AppTheme.defaultPreset
    }

    static var icon: ApplicationIcon { AppTheme.stored().icon }
    static var id: String { AppTheme.icon.rawValue }
    static var title: String { AppTheme.icon.title }

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

    // 渐变按 OKLCH 统一感知明度与彩度，保留各主题色相。
    // 浅色 L: 0.93 → 0.95 → 0.965，C: 0.035 → 0.017 → 0.006；
    // 深色 L: 0.34 → 0.31 → 0.29，C: 0.025 → 0.012 → 0.004。
    // 蓝色降低彩度以留在 sRGB 色域，可可保留更低彩度，避免与杏色趋同。
    // 底部收敛到暖中性色；深色单独配制，不反转浅色或在底部重新提亮。
    private static let mintLight = Colors(
        gradient: ["D5F0E0", "E5F2EA", "F5F3EF"], glow: "A5D7B4",
        background: "F7FAF6", foreground: "243A2D", secondary: "53675A",
        accent: "356F4A", selection: "D4E9DA", hover: "E8F2E9", border: "D7E5DA", outline: "78877C",
        ansi: ["243A2D", "B4434D", "34754B", "82651D", "466AA5", "8C5790", "287477", "5D7062",
               "53675A", "BB3548", "287A46", "896511", "3E6CB1", "945195", "167B7C", "344D3C"]
    )
    private static let mintDark = Colors(
        gradient: ["2D3C33", "2C322E", "2C2B29"], glow: "A5D7B4",
        background: "27292B", foreground: "E6E8E7", secondary: "ABB2AE",
        accent: "A5D7B4", selection: "36473D", hover: "303633", border: "3A3E3B", outline: "7D8982",
        ansi: ["84978B", "E58D96", "9DCEA8", "D8C18B", "96B9DE", "C2A2D5", "8AC9C6", "C3D7CA",
               "95AA9D", "F3A4AC", "B4DFBB", "EAD5A4", "B0CDED", "D6BBE5", "A5DEDA", "E6E8E7"]
    )

    private static let strawberryLight = Colors(
        gradient: ["FBDFEC", "F8EAF0", "F5F3EF"], glow: "EDAFC9",
        background: "FCF8FA", foreground: "432D37", secondary: "705764",
        accent: "884963", selection: "EED2DF", hover: "F5E8EF", border: "E7D7E0", outline: "8C7882",
        ansi: ["432D37", "B4434D", "34754B", "82651D", "466AA5", "8C5790", "287477", "705764",
               "705764", "BB3548", "287A46", "896511", "3E6CB1", "945195", "167B7C", "573B49"]
    )
    private static let strawberryDark = Colors(
        gradient: ["41333C", "352E32", "2C2B29"], glow: "EDAFC9",
        background: "29272B", foreground: "EEE7EB", secondary: "B9ABB3",
        accent: "E5A8C4", selection: "4A3641", hover: "393137", border: "493D44", outline: "96828D",
        ansi: ["A18B97", "E58D96", "9DCEA8", "D8C18B", "96B9DE", "C2A2D5", "8AC9C6", "D7C3CE",
               "B9ABB3", "F3A4AC", "B4DFBB", "EAD5A4", "B0CDED", "D6BBE5", "A5DEDA", "EEE7EB"]
    )

    private static let apricotLight = Colors(
        gradient: ["F8E4D0", "F7EDE3", "F5F3EF"], glow: "EFC394",
        background: "FCF9F5", foreground: "40332A", secondary: "6D5C4D",
        accent: "85522F", selection: "EEDBC5", hover: "F5EBDD", border: "E6D9C9", outline: "897C70",
        ansi: ["40332A", "B4434D", "34754B", "82651D", "466AA5", "8C5790", "287477", "6D5C4D",
               "6D5C4D", "BB3548", "287A46", "896511", "3E6CB1", "945195", "167B7C", "554333"]
    )
    private static let apricotDark = Colors(
        gradient: ["42352B", "352F2A", "2C2B29"], glow: "EFC394",
        background: "292827", foreground: "EDE8E2", secondary: "B8AEA3",
        accent: "E7B887", selection: "4B3D31", hover: "39342F", border: "494139", outline: "968878",
        ansi: ["A39485", "E58D96", "9DCEA8", "D8C18B", "96B9DE", "C2A2D5", "8AC9C6", "D7C9BA",
               "B8AEA3", "F3A4AC", "B4DFBB", "EAD5A4", "B0CDED", "D6BBE5", "A5DEDA", "EDE8E2"]
    )

    private static let vanillaCustardLight = Colors(
        gradient: ["EEE8CE", "F1EFE2", "F5F3EF"], glow: "EEDB8D",
        background: "FCFAF3", foreground: "3E3825", secondary: "696149",
        accent: "78601F", selection: "EAE0B8", hover: "F3EEDC", border: "E4DEC5", outline: "877F65",
        ansi: ["3E3825", "B4434D", "34754B", "82651D", "466AA5", "8C5790", "287477", "696149",
               "696149", "BB3548", "287A46", "896511", "3E6CB1", "945195", "167B7C", "3E3825"]
    )

    private static let vanillaCustardDark = Colors(
        gradient: ["3C3829", "32302A", "2C2B29"], glow: "EEDB8D",
        background: "292927", foreground: "EEEBDD", secondary: "B8B29D",
        accent: "E5D18D", selection: "47432F", hover: "38372F", border: "464435", outline: "928B72",
        ansi: ["B8B29D", "E58D96", "9DCEA8", "D8C18B", "96B9DE", "C2A2D5", "8AC9C6", "B8B29D",
               "B8B29D", "F3A4AC", "B4DFBB", "EAD5A4", "B0CDED", "D6BBE5", "A5DEDA", "EEEBDD"]
    )

    private static let pistachioGreenLight = Colors(
        gradient: ["E5ECD2", "EDF0E4", "F5F3EF"], glow: "C8D98F",
        background: "F9FBF4", foreground: "303B25", secondary: "59664A",
        accent: "536A2C", selection: "DCE6BF", hover: "EDF2DF", border: "DCE4CA", outline: "7B8568",
        ansi: ["303B25", "B4434D", "34754B", "82651D", "466AA5", "8C5790", "287477", "59664A",
               "59664A", "BB3548", "287A46", "896511", "3E6CB1", "945195", "167B7C", "303B25"]
    )

    private static let pistachioGreenDark = Colors(
        gradient: ["343A2C", "2F312B", "2C2B29"], glow: "C8D98F",
        background: "282A27", foreground: "E9EDDF", secondary: "ADB79E",
        accent: "C5D58E", selection: "3F482F", hover: "343A30", border: "404735", outline: "879477",
        ansi: ["ADB79E", "E58D96", "9DCEA8", "D8C18B", "96B9DE", "C2A2D5", "8AC9C6", "ADB79E",
               "ADB79E", "F3A4AC", "B4DFBB", "EAD5A4", "B0CDED", "D6BBE5", "A5DEDA", "E9EDDF"]
    )

    private static let cloudSodaLight = Colors(
        gradient: ["CEEFF2", "E2F2F3", "F5F3EF"], glow: "96D4D8",
        background: "F4FAFA", foreground: "263B3E", secondary: "4C6669",
        accent: "2F6970", selection: "CDE4E5", hover: "E3F0F0", border: "CEE2E3", outline: "6F8487",
        ansi: ["263B3E", "B4434D", "34754B", "82651D", "466AA5", "8C5790", "287477", "4C6669",
               "4C6669", "BB3548", "287A46", "896511", "3E6CB1", "945195", "167B7C", "263B3E"]
    )

    private static let cloudSodaDark = Colors(
        gradient: ["293C3F", "2A3233", "2C2B29"], glow: "96D4D8",
        background: "272A2B", foreground: "E1ECEE", secondary: "A2B5B8",
        accent: "96D4D8", selection: "30474B", hover: "2E393C", border: "35474B", outline: "799195",
        ansi: ["A2B5B8", "E58D96", "9DCEA8", "D8C18B", "96B9DE", "C2A2D5", "8AC9C6", "A2B5B8",
               "A2B5B8", "F3A4AC", "B4DFBB", "EAD5A4", "B0CDED", "D6BBE5", "A5DEDA", "E1ECEE"]
    )

    private static let clearSkyBlueLight = Colors(
        gradient: ["DCE9FB", "E8EFF8", "F5F3EF"], glow: "A8C4EB",
        background: "F7F9FD", foreground: "29374B", secondary: "53637B",
        accent: "41658F", selection: "D5E1F1", hover: "E7EEF7", border: "D4DFED", outline: "758399",
        ansi: ["29374B", "B4434D", "34754B", "82651D", "466AA5", "8C5790", "287477", "53637B",
               "53637B", "BB3548", "287A46", "896511", "3E6CB1", "945195", "167B7C", "29374B"]
    )

    private static let clearSkyBlueDark = Colors(
        gradient: ["303945", "2D3136", "2C2B29"], glow: "A8C4EB",
        background: "282A2D", foreground: "E5EBF3", secondary: "AAB5C5",
        accent: "A8C4EB", selection: "344257", hover: "313741", border: "3B4554", outline: "8190A6",
        ansi: ["AAB5C5", "E58D96", "9DCEA8", "D8C18B", "96B9DE", "C2A2D5", "8AC9C6", "AAB5C5",
               "AAB5C5", "F3A4AC", "B4DFBB", "EAD5A4", "B0CDED", "D6BBE5", "A5DEDA", "E5EBF3"]
    )

    private static let taroMilkshakeLight = Colors(
        gradient: ["EEE2FA", "F2ECF8", "F5F3EF"], glow: "C6ACE0",
        background: "FAF7FC", foreground: "3A2F46", secondary: "665771",
        accent: "70518A", selection: "E0D4EB", hover: "F0E8F5", border: "E0D5E9", outline: "877891",
        ansi: ["3A2F46", "B4434D", "34754B", "82651D", "466AA5", "8C5790", "287477", "665771",
               "665771", "BB3548", "287A46", "896511", "3E6CB1", "945195", "167B7C", "3A2F46"]
    )

    private static let taroMilkshakeDark = Colors(
        gradient: ["3B3542", "322F35", "2C2B29"], glow: "C6ACE0",
        background: "2A282C", foreground: "ECE5F3", secondary: "B6ABBF",
        accent: "C6ACE0", selection: "45364F", hover: "37303E", border: "46394F", outline: "93839F",
        ansi: ["B6ABBF", "E58D96", "9DCEA8", "D8C18B", "96B9DE", "C2A2D5", "8AC9C6", "B6ABBF",
               "B6ABBF", "F3A4AC", "B4DFBB", "EAD5A4", "B0CDED", "D6BBE5", "A5DEDA", "ECE5F3"]
    )

    private static let coralPeachLight = Colors(
        gradient: ["FDE1D5", "F9EBE5", "F5F3EF"], glow: "EDA99A",
        background: "FCF8F5", foreground: "453129", secondary: "73594F",
        accent: "8A4E3E", selection: "EED4C9", hover: "F7E9E1", border: "E9D6CC", outline: "92796D",
        ansi: ["453129", "B4434D", "34754B", "82651D", "466AA5", "8C5790", "287477", "73594F",
               "73594F", "BB3548", "287A46", "896511", "3E6CB1", "945195", "167B7C", "453129"]
    )

    private static let coralPeachDark = Colors(
        gradient: ["44342E", "362E2C", "2C2B29"], glow: "EDA99A",
        background: "2B2827", foreground: "F1E6E0", secondary: "C0ADA3",
        accent: "EDA99A", selection: "4E3932", hover: "3D332F", border: "4E3D35", outline: "9E867B",
        ansi: ["C0ADA3", "E58D96", "9DCEA8", "D8C18B", "96B9DE", "C2A2D5", "8AC9C6", "C0ADA3",
               "C0ADA3", "F3A4AC", "B4DFBB", "EAD5A4", "B0CDED", "D6BBE5", "A5DEDA", "F1E6E0"]
    )

    private static let cocoaMilkTeaLight = Colors(
        gradient: ["F2E5DA", "F3EDE8", "F5F3EF"], glow: "CDB59F",
        background: "FBF8F4", foreground: "3C332C", secondary: "675C50",
        accent: "71543E", selection: "E4D7C9", hover: "F0E9E0", border: "E0D6C9", outline: "877B6C",
        ansi: ["3C332C", "B4434D", "34754B", "82651D", "466AA5", "8C5790", "287477", "675C50",
               "675C50", "BB3548", "287A46", "896511", "3E6CB1", "945195", "167B7C", "3C332C"]
    )

    private static let cocoaMilkTeaDark = Colors(
        gradient: ["3E362F", "33302C", "2C2B29"], glow: "CDB59F",
        background: "292827", foreground: "EBE6DF", secondary: "B6ADA1",
        accent: "CDB59F", selection: "453C32", hover: "35322E", border: "443E35", outline: "918675",
        ansi: ["B6ADA1", "E58D96", "9DCEA8", "D8C18B", "96B9DE", "C2A2D5", "8AC9C6", "B6ADA1",
               "B6ADA1", "F3A4AC", "B4DFBB", "EAD5A4", "B0CDED", "D6BBE5", "A5DEDA", "EBE6DF"]
    )

    static var light: Colors { AppTheme.colors(isDark: false) }
    static var dark: Colors { AppTheme.colors(isDark: true) }

    static func colors(isDark: Bool, preset: AppThemePreset = AppTheme.stored()) -> Colors {
        switch preset {
        case .mintCandy: isDark ? AppTheme.mintDark : AppTheme.mintLight
        case .strawberryCream: isDark ? AppTheme.strawberryDark : AppTheme.strawberryLight
        case .apricotCream: isDark ? AppTheme.apricotDark : AppTheme.apricotLight
        case .vanillaCustard: isDark ? AppTheme.vanillaCustardDark : AppTheme.vanillaCustardLight
        case .pistachioGreen: isDark ? AppTheme.pistachioGreenDark : AppTheme.pistachioGreenLight
        case .cloudSoda: isDark ? AppTheme.cloudSodaDark : AppTheme.cloudSodaLight
        case .clearSkyBlue: isDark ? AppTheme.clearSkyBlueDark : AppTheme.clearSkyBlueLight
        case .taroMilkshake: isDark ? AppTheme.taroMilkshakeDark : AppTheme.taroMilkshakeLight
        case .coralPeach: isDark ? AppTheme.coralPeachDark : AppTheme.coralPeachLight
        case .cocoaMilkTea: isDark ? AppTheme.cocoaMilkTeaDark : AppTheme.cocoaMilkTeaLight
        }
    }
}

/// 所有窗口共用当前预设，终端读取同一组底色、文字和强调色。
struct WindowChrome: Equatable {
    let isDark: Bool
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

    var inactiveIcon: Color { isDark ? RGBColor(ghosttyHex: "878B92")!.color : secondary }

    /// 沿用马卡龙色板，并混入当前主题；文字在普通、悬停和选中背景上均可辨认。
    func folderColor(_ icon: ApplicationIcon) -> Color {
        guard let palette = icon.palette else { return accent }
        func rgb(_ color: Color) -> RGBColor {
            let value = NSColor(color).usingColorSpace(.sRGB)!
            return RGBColor(red: value.redComponent, green: value.greenComponent, blue: value.blueComponent)
        }
        var tone = RGBColor(ghosttyHex: isDark ? palette.fill : palette.ink)!
            .mixed(with: rgb(accent), amount: 0.12)
        let target = RGBColor(red: isDark ? 1 : 0, green: isDark ? 1 : 0, blue: isDark ? 1 : 0)
        for background in [sidebarBackground, hairline, accentFill] {
            tone = RGBColor.ensureContrast(tone, against: rgb(background), toward: target, minimum: 4.5)
        }
        return tone.color
    }

    /// 实心控件根据填充选择黑字或白字，避免马卡龙色上的白字失去对比。
    func filledForeground(on fill: Color) -> Color {
        let resolved = NSColor(fill).usingColorSpace(.sRGB)!
        let background = RGBColor(red: resolved.redComponent, green: resolved.greenComponent, blue: resolved.blueComponent)
        let black = RGBColor(red: 0, green: 0, blue: 0)
        let white = RGBColor(red: 1, green: 1, blue: 1)
        return black.contrastRatio(with: background) >= white.contrastRatio(with: background) ? .black : .white
    }

    static func resolve(isDark: Bool) -> WindowChrome {
        WindowChrome(isDark: isDark)
    }

    init(isDark: Bool, preset: AppThemePreset = AppTheme.stored()) {
        self.isDark = isDark
        let colors = AppTheme.colors(isDark: isDark, preset: preset)
        background = colors.color(colors.background)
        sidebarBackground = colors.color(colors.gradient[1])
        elevated = colors.color(colors.hover)
        text = colors.color(colors.foreground)
        secondary = colors.color(colors.secondary)
        tertiary = secondary
        hairline = colors.color(colors.border)
        accent = colors.color(colors.accent)
        accentFill = colors.color(colors.selection)
        panelHeader = background
        danger = colors.color(colors.ansi[1])
        warning = colors.color(colors.ansi[3])
        success = colors.color(colors.ansi[2])
        let tone = RGBColor(ghosttyHex: colors.accent)!
        accentHover = tone.mixed(with: RGBColor(red: 1, green: 1, blue: 1), amount: 0.12).color
        accentActive = tone.mixed(with: RGBColor(red: 0, green: 0, blue: 0), amount: 0.12).color
        focus = accent
        selection = accentFill
        lineStrong = colors.color(colors.outline)
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
