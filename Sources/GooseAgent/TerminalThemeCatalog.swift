import AppKit
import GhosttyTerminal
import SwiftUI

extension WindowChrome {
    /// 工作区与设置沿用聚焦终端的底色和整窗渐变。
    @MainActor static func workspace(isDark: Bool) -> WindowChrome {
        let colors = TerminalThemePreferences.selected(isDark: isDark).colors(interfaceIsDark: isDark)
        return colors.workspaceChrome
    }
}

/// 预览与实际终端共用配色，避免两处各自猜测主题颜色。
struct TerminalThemeColors: Equatable {
    let background: String
    let foreground: String
    let cursor: String
    let cursorText: String
    let selection: String
    let selectionText: String
    let ansi: [String]

    /// 与 Ghostty list-themes 的明暗筛选一致，不使用 WCAG 的线性化亮度。
    var isDark: Bool {
        let rgb = RGBColor(ghosttyHex: background)!
        return 0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue < 0.5
    }

    var configuration: TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withBackground("#" + background)
            builder.withForeground("#" + foreground)
            builder.withCursorColor("#" + cursor)
            builder.withCursorText("#" + cursorText)
            builder.withSelectionBackground("#" + selection)
            builder.withSelectionForeground("#" + selectionText)
            for (index, color) in ansi.enumerated() {
                builder.withPalette(index, color: "#" + color)
            }
        }
    }

    /// 窗口底层渐变取当前主题的蓝、紫、青槽位。
    var gradientColors: [RGBColor] {
        let base = RGBColor(ghosttyHex: background)!
        func tint(_ index: Int, amount: Double) -> RGBColor {
            let accent = RGBColor(ghosttyHex: ansi[index])!
            return base.mixed(with: accent, amount: amount)
        }
        return [tint(4, amount: isDark ? 0.55 : 0.30),
                tint(5, amount: isDark ? 0.35 : 0.18),
                tint(5, amount: isDark ? 0.65 : 0.35),
                tint(6, amount: isDark ? 0.55 : 0.30)]
    }

    func paneBackground(isFocused: Bool) -> RGBColor {
        let base = RGBColor(ghosttyHex: background)!
        guard !isFocused else { return base }
        return base.mixed(with: RGBColor(red: 0, green: 0, blue: 0), amount: ShellLayout.inactivePaneDimming)
    }

    /// 主题卡片和实际工作区都用同一套终端底色与外框渐变。
    var workspaceChrome: WindowChrome {
        var chrome = paneChrome(isFocused: true)
        chrome.gradientColors = gradientColors.map(\.color)
        return chrome
    }

    /// 标题、搜索和命令栏保留终端原色。
    func paneChrome(isFocused: Bool) -> WindowChrome {
        var chrome = applicationChrome()
        let base = paneBackground(isFocused: isFocused)
        let themeText = RGBColor(ghosttyHex: foreground)!
        let black = RGBColor(red: 0, green: 0, blue: 0)
        let white = RGBColor(red: 1, green: 1, blue: 1)
        let contrastTarget = black.contrastRatio(with: base) > white.contrastRatio(with: base) ? black : white
        let text = RGBColor.ensureContrast(themeText, against: base, toward: contrastTarget, minimum: 4.5)
        chrome.background = base.color
        chrome.sidebarBackground = base.color
        chrome.panelHeader = base.color
        chrome.text = text.color
        chrome.secondary = RGBColor.ensureContrast(text.mixed(with: base, amount: 0.35),
                                                   against: base, toward: contrastTarget, minimum: 4.5).color
        chrome.tertiary = chrome.secondary
        chrome.elevated = base.mixed(with: text, amount: 0.08).color
        chrome.hairline = base.mixed(with: text, amount: 0.15).color
        chrome.lineStrong = text.color
        return chrome
    }

    /// 正文保留主题色；导航与控件向中性色收敛，强饱和主题仍有清晰层次。
    func applicationChrome() -> WindowChrome {
        var chrome = WindowChrome(isDark: isDark)
        chrome.isThemeTinted = true
        chrome.syntaxPalette = ansi
        let base = RGBColor(ghosttyHex: background)!
        let neutral = RGBColor(ghosttyHex: isDark ? "18191C" : "F7F7F9")!
        let surface = base.mixed(with: neutral, amount: isDark ? 0.18 : 0.72)
        let sidebar = base.mixed(with: neutral, amount: isDark ? 0.30 : 0.82)
        let black = RGBColor(red: 0, green: 0, blue: 0)
        let white = RGBColor(red: 1, green: 1, blue: 1)
        let target = black.contrastRatio(with: surface) > white.contrastRatio(with: surface) ? black : white
        func readable(_ color: RGBColor, minimum: Double = 4.5) -> RGBColor {
            var result = RGBColor.ensureContrast(color, against: surface, toward: target, minimum: minimum)
            result = RGBColor.ensureContrast(result, against: sidebar, toward: target, minimum: minimum)
            return result
        }
        let accent = readable(RGBColor(ghosttyHex: ansi[4])!)
        let elevated = sidebar.mixed(with: target, amount: 0.06)
        let selection = sidebar.mixed(with: accent, amount: isDark ? 0.18 : 0.12)
        func readableOnControls(_ color: RGBColor) -> RGBColor {
            var result = readable(color)
            for background in [elevated, selection] {
                result = RGBColor.ensureContrast(result, against: background, toward: target, minimum: 4.5)
            }
            return result
        }
        let text = readableOnControls(RGBColor(ghosttyHex: foreground)!)
        chrome.background = surface.color
        chrome.sidebarBackground = sidebar.color
        chrome.panelHeader = sidebar.color
        chrome.text = text.color
        chrome.secondary = readableOnControls(text.mixed(with: surface, amount: 0.32)).color
        chrome.tertiary = chrome.secondary
        chrome.elevated = elevated.color
        chrome.hairline = sidebar.mixed(with: text, amount: 0.18).color
        chrome.accent = accent.color
        chrome.accentFill = selection.color
        chrome.selectionText = text.color
        chrome.selection = chrome.accentFill
        chrome.accentHover = chrome.accent.opacity(0.88)
        chrome.accentActive = chrome.accent.opacity(0.76)
        chrome.focus = chrome.accent
        chrome.lineStrong = text.color
        chrome.danger = readable(RGBColor(ghosttyHex: ansi[1])!).color
        chrome.warning = readable(RGBColor(ghosttyHex: ansi[3])!).color
        chrome.success = readable(RGBColor(ghosttyHex: ansi[2])!).color
        return chrome
    }

    static func system(isDark: Bool) -> TerminalThemeColors {
        let colors = AppTheme.colors(isDark: isDark)
        return TerminalThemeColors(
            background: colors.background, foreground: colors.foreground,
            cursor: colors.accent, cursorText: colors.background,
            selection: colors.selection,
            selectionText: SystemTheme.hex(.selectedTextColor, isDark: isDark, over: .selectedTextBackgroundColor),
            ansi: colors.ansi
        )
    }
}

struct TerminalThemeDescriptor: Identifiable, Equatable {
    static let defaultID = "default"
    static let system = TerminalThemeDescriptor(id: TerminalThemeDescriptor.defaultID, name: "", palette: nil)

    let id: String
    let name: String
    let palette: TerminalThemeColors?
    var isDefault: Bool { id == TerminalThemeDescriptor.defaultID }
    var displayName: String { isDefault ? String(localized: "Default") : name }

    func colors(interfaceIsDark: Bool) -> TerminalThemeColors {
        palette ?? TerminalThemeColors.system(isDark: interfaceIsDark)
    }

    func isDark(interfaceIsDark: Bool) -> Bool {
        palette?.isDark ?? interfaceIsDark
    }

    func matchesAppearance(isDark: Bool) -> Bool {
        palette == nil || palette?.isDark == isDark
    }

    var configuration: TerminalTheme {
        if let palette {
            return TerminalTheme(light: palette.configuration, dark: palette.configuration)
        }
        return TerminalTheme(light: TerminalThemeColors.system(isDark: false).configuration,
                             dark: TerminalThemeColors.system(isDark: true).configuration)
    }
}

struct TerminalThemeCatalog {
    static let shared: TerminalThemeCatalog = {
        do {
            guard let directory = Bundle.main.url(forResource: "GhosttyThemes", withExtension: nil) else {
                throw CatalogError.invalid("GhosttyThemes")
            }
            return try TerminalThemeCatalog(directory: directory)
        } catch {
            return TerminalThemeCatalog(themes: [.system], issue: error.localizedDescription)
        }
    }()

    let themes: [TerminalThemeDescriptor]
    let issue: String?
    private let byID: [String: TerminalThemeDescriptor]

    private init(themes: [TerminalThemeDescriptor], issue: String? = nil) {
        self.themes = themes
        self.issue = issue
        byID = Dictionary(uniqueKeysWithValues: themes.map { ($0.id, $0) })
    }

    init(directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "ghostty" }
        guard !files.isEmpty else { throw CatalogError.invalid("GhosttyThemes") }
        let parsed = try files.map { file in
            try TerminalThemeCatalog.parse(name: file.deletingPathExtension().lastPathComponent,
                                           text: String(contentsOf: file, encoding: .utf8))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.init(themes: [.system] + parsed)
    }

    func theme(id: String) -> TerminalThemeDescriptor? { byID[id] }

    func filtered(search: String, isDark: Bool) -> [TerminalThemeDescriptor] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return themes.filter { theme in
            let isMatch = query.isEmpty || theme.displayName.localizedStandardContains(query)
                || (theme.isDefault && "Default".localizedStandardContains(query))
            guard isMatch else { return false }
            return theme.matchesAppearance(isDark: isDark)
        }
    }

    static func parse(name: String, text: String) throws -> TerminalThemeDescriptor {
        var values: [String: String] = [:]
        var palette: [Int: String] = [:]
        let keys: Set<String> = ["background", "foreground", "cursor-color", "cursor-text", "selection-background", "selection-foreground"]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { throw CatalogError.invalid(name) }
            if parts[0] == "palette" {
                let entry = parts[1].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard entry.count == 2, let index = Int(entry[0]), (0..<16).contains(index), palette[index] == nil,
                      let color = TerminalThemeCatalog.hex(entry[1]) else { throw CatalogError.invalid(name) }
                palette[index] = color
            } else {
                guard keys.contains(parts[0]), values[parts[0]] == nil,
                      let color = TerminalThemeCatalog.hex(parts[1]) else { throw CatalogError.invalid(name) }
                values[parts[0]] = color
            }
        }
        guard Set(values.keys) == keys, palette.count == 16 else { throw CatalogError.invalid(name) }
        return TerminalThemeDescriptor(id: "ghostty:" + name, name: name, palette: TerminalThemeColors(
            background: values["background"]!, foreground: values["foreground"]!,
            cursor: values["cursor-color"]!, cursorText: values["cursor-text"]!,
            selection: values["selection-background"]!, selectionText: values["selection-foreground"]!,
            ansi: (0..<16).map { palette[$0]! }
        ))
    }

    private static func hex(_ value: String) -> String? {
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return hex.uppercased()
    }

    private enum CatalogError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let name): String(format: String(localized: "Could not load theme %@."), name)
            }
        }
    }
}

@MainActor
final class TerminalThemePreferences: ObservableObject {
    static let shared = TerminalThemePreferences()
    @Published private(set) var revision = 0
    @Published private(set) var error: String?

    static func storageKey(isDark: Bool) -> String {
        "appearance.terminalTheme.shared." + (isDark ? "dark" : "light")
    }

    static func selected(isDark: Bool? = nil,
                         defaults: UserDefaults = .standard) -> TerminalThemeDescriptor {
        let isDark = isDark ?? TerminalAppearance.stored(defaults: defaults).resolvesDark()
        func matchingTheme(_ id: String?) -> TerminalThemeDescriptor? {
            guard let id, let theme = TerminalThemeCatalog.shared.theme(id: id),
                  theme.matchesAppearance(isDark: isDark) else { return nil }
            return theme
        }
        // 共用配置一旦保存（包括默认），就不再读取旧的本地／远程选择。
        if let id = defaults.string(forKey: TerminalThemePreferences.storageKey(isDark: isDark)) {
            // 旧版本允许混用；不匹配的选择回到该外观的默认主题。
            return matchingTheme(id) ?? .system
        }
        // 合并时优先沿用本地配置；没有匹配选择时再读取远程配置。
        for target in ["local", "remote"] {
            let key = "appearance.terminalTheme." + target
            let savedID = defaults.string(forKey: key + (isDark ? ".dark" : ".light"))
            // 更早版本保存的裸主题名不参与迁移，避免复活已废弃的选择。
            let configuredID = savedID.flatMap { $0 == TerminalThemeDescriptor.defaultID || $0.hasPrefix("ghostty:") ? $0 : nil }
            if let theme = matchingTheme(configuredID ?? defaults.string(forKey: key)) {
                return theme
            }
        }
        return .system
    }

    @discardableResult
    func select(_ id: String, isDark: Bool? = nil) -> Bool {
        let interfaceIsDark = TerminalAppearance.stored().resolvesDark()
        let isDark = isDark ?? interfaceIsDark
        guard let theme = TerminalThemeCatalog.shared.theme(id: id) else {
            error = String(format: String(localized: "Could not load theme %@."), id)
            return false
        }
        guard theme.matchesAppearance(isDark: isDark) else {
            error = isDark
                ? String(localized: "Choose a dark theme for Dark Appearance.")
                : String(localized: "Choose a light theme for Light Appearance.")
            return false
        }
        // 主题必须匹配目标外观；配置另一种外观时只保存选择。
        if isDark == interfaceIsDark,
           let issue = GhosttyRuntime.applyTheme(theme, interfaceIsDark: isDark) {
            error = issue
            return false
        }
        UserDefaults.standard.set(theme.id, forKey: TerminalThemePreferences.storageKey(isDark: isDark))
        if isDark == interfaceIsDark {
            AppearanceDriver.shared.reapply()
        }
        error = nil
        revision += 1
        return true
    }

    @discardableResult
    func reset() -> Bool {
        if let issue = GhosttyRuntime.applyTheme(.system,
                                                interfaceIsDark: TerminalAppearance.stored().resolvesDark()) {
            error = issue
            return false
        }
        for isDark in [false, true] {
            UserDefaults.standard.set(TerminalThemeDescriptor.defaultID,
                                      forKey: TerminalThemePreferences.storageKey(isDark: isDark))
        }
        AppearanceDriver.shared.reapply()
        error = nil
        revision += 1
        return true
    }

    func report(_ issue: String?) {
        if error != issue { error = issue }
    }
}
