import AppKit
import GhosttyTerminal
import SwiftUI

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

    func paneBackground(isFocused: Bool) -> RGBColor {
        let base = RGBColor(ghosttyHex: background)!
        guard !isFocused else { return base }
        let neutral = RGBColor(ghosttyHex: isDark ? "FFFFFF" : "000000")!
        return base.mixed(with: neutral, amount: isDark ? 0.06 : 0.05)
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

    var configuration: TerminalTheme {
        if let palette {
            return TerminalTheme(light: palette.configuration, dark: palette.configuration)
        }
        return TerminalTheme(light: TerminalThemeColors.system(isDark: false).configuration,
                             dark: TerminalThemeColors.system(isDark: true).configuration)
    }
}

enum TerminalThemeFilter: String, CaseIterable {
    case all, light, dark

    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .light: "Light"
        case .dark: "Dark"
        }
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

    func filtered(search: String, filter: TerminalThemeFilter) -> [TerminalThemeDescriptor] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return themes.filter { theme in
            let isMatch = query.isEmpty || theme.displayName.localizedStandardContains(query)
                || (theme.isDefault && "Default".localizedStandardContains(query))
            guard isMatch else { return false }
            guard let palette = theme.palette else { return true }
            return filter == .all || (filter == .dark && palette.isDark) || (filter == .light && !palette.isDark)
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
                  theme.isDefault || theme.isDark(interfaceIsDark: isDark) == isDark else { return nil }
            return theme
        }
        // 共用配置一旦保存（包括默认），就不再读取旧的本地／远程选择。
        if let id = defaults.string(forKey: TerminalThemePreferences.storageKey(isDark: isDark)) {
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
        guard theme.isDefault || theme.isDark(interfaceIsDark: isDark) == isDark else {
            error = String(localized: "Choose a theme matching this appearance.")
            return false
        }
        // 配置另一种外观时只保存选择。
        if isDark == interfaceIsDark,
           let issue = GhosttyRuntime.applyTheme(theme, interfaceIsDark: isDark) {
            error = issue
            return false
        }
        UserDefaults.standard.set(theme.id, forKey: TerminalThemePreferences.storageKey(isDark: isDark))
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
        error = nil
        revision += 1
        return true
    }

    func report(_ issue: String?) {
        if error != issue { error = issue }
    }
}
