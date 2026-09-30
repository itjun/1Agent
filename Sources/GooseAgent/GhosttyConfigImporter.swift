import Foundation

/// One `key = value` line read from a Ghostty config file.
struct GhosttyConfigLine: Equatable {
    let key: String
    /// Surrounding quotes removed, as Ghostty does before parsing.
    let value: String
    /// Value as written, quotes kept, so a line copied into the advanced snippet reads the same.
    let rawValue: String
    let file: URL

    var text: String {
        "\(key) = \(rawValue)"
    }
}

/// Every config file Ghostty would read, merged the way Ghostty merges them.
struct GhosttyLoadedConfig: Equatable {
    /// Files actually read, in load order: the default files first, then `config-file` includes.
    var files: [URL] = []
    /// Effective lines: a later single-value key replaces the earlier one, repeatable keys accumulate.
    var entries: [GhosttyConfigLine] = []
    /// Include problems and unparsable lines, already localized.
    var warnings: [String] = []
}

/// A theme name found in the user themes folder or the bundled catalog, or a theme file on disk.
struct GhosttyThemeLookup: Equatable {
    let isLightBackground: Bool
    let isUserTheme: Bool
}

/// What the plan compares against and how theme names resolve. The app fills it from UserDefaults
/// and the theme stores; tests pass fixed values.
struct GhosttyImportContext {
    var settings: TerminalSettings
    var lightTheme: String
    var darkTheme: String
    var userThemesDirectory: URL
    var home: URL
    var lookupTheme: (String) -> GhosttyThemeLookup?
    /// Parses a theme file outside the user themes folder; nil when it is not a valid theme.
    var lookupThemeFile: (URL) -> GhosttyThemeLookup?
}

struct GhosttySettingChange: Equatable {
    let key: String
    let oldValue: String
    let newValue: String

    var isUnchanged: Bool {
        oldValue == newValue
    }
}

struct GhosttyThemeSlotPlan: Equatable {
    enum Source: Equatable {
        case userTheme
        case builtinTheme
        /// A theme file outside the user themes folder; copied in on import.
        case importFile(URL)
    }

    /// Name stored in the slot. For `importFile` this is the file name; the copy may get a suffix.
    let name: String
    let source: Source
    let currentName: String

    var isUnchanged: Bool {
        if case .importFile = source {
            return false
        }
        return name == currentName
    }
}

struct GhosttyThemePlan: Equatable {
    var light: GhosttyThemeSlotPlan?
    var dark: GhosttyThemeSlotPlan?
    var warnings: [String] = []

    var isEmpty: Bool {
        light == nil && dark == nil && warnings.isEmpty
    }
}

/// Modifiers plus one key in Ghostty trigger syntax. `key` is a lowercase character or one of
/// `arrow_left` / `arrow_right` / `arrow_up` / `arrow_down`.
struct GhosttyTrigger: Equatable {
    var key: String
    var command = false
    var option = false
    var shift = false
    var control = false
}

/// A `keybind` line whose action is one of the app's own shortcuts.
struct GhosttyShortcutImport: Equatable {
    /// `AppShortcutID` raw value.
    let shortcutID: String
    let trigger: GhosttyTrigger
    let line: String
}

enum GhosttyIgnoreReason: Equatable {
    case window
    case platform
    case process
    case appLevel
    case blur
    case shader

    var message: String {
        switch self {
        case .window:
            return String(localized: "Windows, tabs and splits are managed by this app")
        case .platform:
            return String(localized: "Only applies to other platforms")
        case .process:
            return String(localized: "This app starts the shell itself")
        case .appLevel:
            return String(localized: "App-level feature this app does not have")
        case .blur:
            return String(localized: "This terminal engine does not support background blur")
        case .shader:
            return String(localized: "This terminal engine does not support custom shaders")
        }
    }
}

struct GhosttyIgnoredLine: Equatable {
    let line: String
    let reason: GhosttyIgnoreReason
}

struct GhosttyUnmigratedLine: Equatable {
    let line: String
    let reason: String
}

struct GhosttyImportPlan: Equatable {
    var files: [URL] = []
    /// The current settings with every importable line applied.
    var newSettings: TerminalSettings
    var settingsChanges: [GhosttySettingChange] = []
    var theme = GhosttyThemePlan()
    /// Lines appended to the advanced snippet; lines already in it are left out.
    var customLines: [String] = []
    var shortcuts: [GhosttyShortcutImport] = []
    var ignored: [GhosttyIgnoredLine] = []
    var unmigrated: [GhosttyUnmigratedLine] = []
    var warnings: [String] = []

    /// True when importing would write nothing.
    var changesNothing: Bool {
        let settingsChange = settingsChanges.contains { !$0.isUnchanged }
        let lightChange = theme.light.map { !$0.isUnchanged } ?? false
        let darkChange = theme.dark.map { !$0.isUnchanged } ?? false
        return !settingsChange && !lightChange && !darkChange && customLines.isEmpty && shortcuts.isEmpty
    }
}

/// Reads Ghostty's own config files and sorts every line into what the app can take over.
/// Load order and merge rules follow Ghostty's `Config.zig` (`loadDefaultFiles`, `loadRecursiveFiles`).
enum GhosttyConfigImporter {
    /// Ghostty's bundle identifier names its Application Support folder, whichever app reads it.
    static let appSupportFolderName = "com.mitchellh.ghostty"

    /// Keys whose lines accumulate instead of replacing each other; an empty value clears the list.
    static let repeatableKeys: Set<String> = [
        "font-family",
        "font-family-bold",
        "font-family-italic",
        "font-family-bold-italic",
        "font-feature",
        "font-variation",
        "font-variation-bold",
        "font-variation-italic",
        "font-variation-bold-italic",
        "font-codepoint-map",
        "clipboard-codepoint-map",
        "keybind",
        "palette",
        "env",
        "link",
        "command-palette-entry",
        "custom-shader",
        "gtk-custom-css",
    ]

    // MARK: - Files

    /// Load order on macOS: legacy XDG `config`, XDG `config.ghostty`, then the same two names in
    /// Application Support. Every existing file is read; later files override earlier ones.
    static func defaultConfigFiles(environment: [String: String], home: URL) -> [URL] {
        var configHome = home.appendingPathComponent(".config", isDirectory: true)
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            configHome = URL(fileURLWithPath: xdg, isDirectory: true)
        }
        let xdgFolder = configHome.appendingPathComponent("ghostty", isDirectory: true)
        let appSupportFolder = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(GhosttyConfigImporter.appSupportFolderName, isDirectory: true)
        return [
            xdgFolder.appendingPathComponent("config"),
            xdgFolder.appendingPathComponent("config.ghostty"),
            appSupportFolder.appendingPathComponent("config"),
            appSupportFolder.appendingPathComponent("config.ghostty"),
        ]
    }

    static func existingConfigFiles(environment: [String: String], home: URL) -> [URL] {
        var result: [URL] = []
        for url in GhosttyConfigImporter.defaultConfigFiles(environment: environment, home: home) {
            if GhosttyConfigImporter.isRegularFile(url) {
                result.append(url)
            }
        }
        return result
    }

    /// Reads the default files, then the `config-file` includes they (and their includes) name.
    /// Includes load after all default files, in the order they were written, as in Ghostty.
    /// A path loaded once through `config-file` is skipped the second time (cycle).
    static func loadConfig(files defaultFiles: [URL], home: URL) -> GhosttyLoadedConfig {
        var loaded = GhosttyLoadedConfig()
        var lines: [GhosttyConfigLine] = []
        var includes: [(url: URL, optional: Bool)] = []

        for url in defaultFiles {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                loaded.warnings.append(String(format: String(localized: "Could not read %@"), url.path))
                continue
            }
            loaded.files.append(url)
            GhosttyConfigImporter.read(text, from: url, home: home, into: &lines, includes: &includes, warnings: &loaded.warnings)
        }

        var includedPaths = Set<String>()
        var index = 0
        while index < includes.count {
            let include = includes[index]
            index += 1
            let path = include.url.standardizedFileURL.path
            if includedPaths.contains(path) {
                loaded.warnings.append(String(format: String(localized: "config-file %@: cycle detected, skipped"), path))
                continue
            }
            includedPaths.insert(path)
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                if !include.optional {
                    loaded.warnings.append(String(format: String(localized: "config-file %@: file not found"), path))
                }
                continue
            }
            if isDirectory.boolValue {
                loaded.warnings.append(String(format: String(localized: "config-file %@: not a file"), path))
                continue
            }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                loaded.warnings.append(String(format: String(localized: "Could not read %@"), path))
                continue
            }
            let url = URL(fileURLWithPath: path)
            loaded.files.append(url)
            GhosttyConfigImporter.read(text, from: url, home: home, into: &lines, includes: &includes, warnings: &loaded.warnings)
        }

        loaded.entries = GhosttyConfigImporter.merge(lines)
        return loaded
    }

    /// Ghostty's file syntax: trimmed lines, `#` only as the first character, `key = value`,
    /// one pair of surrounding double quotes removed from the value.
    private static func read(
        _ text: String,
        from file: URL,
        home: URL,
        into lines: inout [GhosttyConfigLine],
        includes: inout [(url: URL, optional: Bool)],
        warnings: inout [String]
    ) {
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            guard let equals = line.firstIndex(of: "=") else {
                warnings.append(String(format: String(localized: "%@: line without “=” skipped: %@"), file.lastPathComponent, line))
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let value = GhosttyConfigImporter.unquoted(rawValue)
            if key.isEmpty {
                warnings.append(String(format: String(localized: "%@: line without a key skipped: %@"), file.lastPathComponent, line))
                continue
            }
            if key == "config-file" {
                if let include = GhosttyConfigImporter.includePath(value, relativeTo: file, home: home) {
                    includes.append(include)
                }
                continue
            }
            lines.append(GhosttyConfigLine(key: key, value: value, rawValue: rawValue, file: file))
        }
    }

    /// `?` marks an optional include; quotes may follow it. Relative paths are relative to the
    /// including file's folder, `~/` is the home folder.
    private static func includePath(_ value: String, relativeTo file: URL, home: URL) -> (url: URL, optional: Bool)? {
        var path = value
        var optional = false
        if path.hasPrefix("?") {
            optional = true
            path.removeFirst()
        }
        path = GhosttyConfigImporter.unquoted(path)
        if path.isEmpty {
            return nil
        }
        return (GhosttyConfigImporter.expandedURL(path, relativeTo: file.deletingLastPathComponent(), home: home), optional)
    }

    private static func expandedURL(_ path: String, relativeTo folder: URL, home: URL) -> URL {
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return folder.appendingPathComponent(path).standardizedFileURL
    }

    /// Single-value keys keep only the last line; an empty value resets them to the engine default,
    /// which for the importer means "nothing to import". Repeatable keys keep every line in order.
    static func merge(_ lines: [GhosttyConfigLine]) -> [GhosttyConfigLine] {
        var result: [GhosttyConfigLine] = []
        for line in lines {
            if GhosttyConfigImporter.repeatableKeys.contains(line.key) {
                if line.value.isEmpty {
                    result.removeAll { $0.key == line.key }
                } else {
                    result.append(line)
                }
                continue
            }
            result.removeAll { $0.key == line.key }
            if !line.value.isEmpty {
                result.append(line)
            }
        }
        return result
    }

    // MARK: - Plan

    static func makePlan(config: GhosttyLoadedConfig, context: GhosttyImportContext) -> GhosttyImportPlan {
        var plan = GhosttyImportPlan(newSettings: context.settings)
        plan.files = config.files
        plan.warnings = config.warnings

        var changedKeys: [String] = []
        var sawFontFamily = false
        var existingSnippetLines = Set<String>()
        for line in context.settings.customConfig.components(separatedBy: .newlines) {
            existingSnippetLines.insert(line.trimmingCharacters(in: .whitespaces))
        }
        var shortcutsByID: [String: GhosttyShortcutImport] = [:]
        var shortcutOrder: [String] = []

        func addCustomLine(_ text: String) {
            if existingSnippetLines.contains(text) || plan.customLines.contains(text) {
                return
            }
            plan.customLines.append(text)
        }

        for entry in config.entries {
            if entry.key == "theme" {
                plan.theme = GhosttyConfigImporter.themePlan(entry.value, context: context)
                continue
            }
            if entry.key == "keybind" {
                switch GhosttyConfigImporter.classifyKeybind(entry.value) {
                case .appShortcut(let id, let trigger):
                    if shortcutsByID[id] == nil {
                        shortcutOrder.append(id)
                    }
                    shortcutsByID[id] = GhosttyShortcutImport(shortcutID: id, trigger: trigger, line: entry.text)
                case .customSnippet:
                    addCustomLine(entry.text)
                case .unmigrated(let reason):
                    plan.unmigrated.append(GhosttyUnmigratedLine(line: entry.text, reason: reason))
                }
                continue
            }
            if let reason = GhosttyConfigImporter.ignoreReason(forKey: entry.key) {
                plan.ignored.append(GhosttyIgnoredLine(line: entry.text, reason: reason))
                continue
            }
            if entry.key == "font-family" {
                if sawFontFamily {
                    plan.unmigrated.append(GhosttyUnmigratedLine(
                        line: entry.text,
                        reason: String(localized: "Only one font family can be set; fallback fonts are not imported")
                    ))
                    continue
                }
                sawFontFamily = true
            }
            if plan.newSettings.apply(ghosttyKey: entry.key, value: entry.value) {
                if !changedKeys.contains(entry.key) {
                    changedKeys.append(entry.key)
                }
                continue
            }
            if TerminalSettings.managedKeys.contains(entry.key) {
                plan.unmigrated.append(GhosttyUnmigratedLine(
                    line: entry.text,
                    reason: String(localized: "Value not understood, and this key is managed by the app")
                ))
                continue
            }
            addCustomLine(entry.text)
        }

        for key in changedKeys {
            plan.settingsChanges.append(GhosttySettingChange(
                key: key,
                oldValue: GhosttyConfigImporter.displayValue(forKey: key, in: context.settings),
                newValue: GhosttyConfigImporter.displayValue(forKey: key, in: plan.newSettings)
            ))
        }
        for id in shortcutOrder {
            if let shortcut = shortcutsByID[id] {
                plan.shortcuts.append(shortcut)
            }
        }
        if !plan.customLines.isEmpty {
            var snippet = context.settings.customConfig
            if !snippet.isEmpty && !snippet.hasSuffix("\n") {
                snippet += "\n"
            }
            snippet += plan.customLines.joined(separator: "\n") + "\n"
            plan.newSettings.customConfig = snippet
        }
        return plan
    }

    /// The value a setting shows in the preview, in Ghostty's own spelling.
    static func displayValue(forKey key: String, in settings: TerminalSettings) -> String {
        switch key {
        case "font-family":
            return settings.fontFamily
        case "font-size":
            return TerminalSettings.literal(settings.fontSize, maximumFractionDigits: 2)
        case "font-thicken":
            return String(settings.fontThicken)
        case "font-thicken-strength":
            return String(settings.fontThickenStrength)
        case "font-feature":
            if settings.fontLigatures {
                return String(localized: "Ligatures on")
            }
            return String(localized: "Ligatures off")
        case "adjust-cell-height":
            return "\(settings.cellHeightAdjust)%"
        case "cursor-style":
            return settings.cursorStyle.rawValue
        case "cursor-style-blink":
            return String(settings.cursorBlink)
        case "cursor-opacity":
            return TerminalSettings.literal(settings.cursorOpacity, maximumFractionDigits: 3)
        case "window-padding-x":
            return String(settings.paddingX)
        case "window-padding-y":
            return String(settings.paddingY)
        case "background-opacity":
            return TerminalSettings.literal(settings.backgroundOpacity, maximumFractionDigits: 3)
        case "minimum-contrast":
            return TerminalSettings.literal(settings.minimumContrast, maximumFractionDigits: 2)
        case "scrollback-limit", "scrollback-limit-bytes":
            return String(settings.scrollbackLimitMB * 1_000_000)
        case "copy-on-select":
            return settings.copyOnSelect.rawValue
        case "clipboard-paste-protection":
            return String(settings.clipboardPasteProtection)
        case "mouse-hide-while-typing":
            return String(settings.mouseHideWhileTyping)
        case "link-url":
            return String(settings.linkURL)
        case "macos-option-as-alt":
            return settings.optionAsAlt.rawValue
        case "shell-integration":
            return settings.shellIntegration.rawValue
        case "shell-integration-features":
            return TerminalSettings.featureList(
                settings.shellIntegrationFeatures,
                known: TerminalSettings.shellIntegrationFeatureNames
            )
        case "bell-features":
            return TerminalSettings.featureList(settings.bellFeatures, known: TerminalSettings.bellFeatureNames)
        default:
            return ""
        }
    }

    // MARK: - Theme

    /// Ghostty: a value with `,`, `:` or `=` is a `light:X,dark:Y` pair (both required), anything
    /// else is one theme for both slots. Names are trimmed.
    static func splitTheme(_ value: String) -> (light: String, dark: String)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return nil
        }
        if !trimmed.contains(",") && !trimmed.contains(":") && !trimmed.contains("=") {
            return (trimmed, trimmed)
        }
        var light: String?
        var dark: String?
        for part in trimmed.split(separator: ",") {
            guard let colon = part.firstIndex(of: ":") else { return nil }
            let name = part[..<colon].trimmingCharacters(in: .whitespaces)
            let theme = GhosttyConfigImporter.unquoted(part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            if name == "light" {
                light = theme
            } else if name == "dark" {
                dark = theme
            } else {
                return nil
            }
        }
        guard let light, let dark, !light.isEmpty, !dark.isEmpty else { return nil }
        return (light, dark)
    }

    static func themePlan(_ value: String, context: GhosttyImportContext) -> GhosttyThemePlan {
        var plan = GhosttyThemePlan()
        guard let pair = GhosttyConfigImporter.splitTheme(value) else {
            plan.warnings.append(String(format: String(localized: "theme = %@ could not be read"), value))
            return plan
        }
        plan.light = GhosttyConfigImporter.themeSlot(pair.light, dark: false, context: context, warnings: &plan.warnings)
        plan.dark = GhosttyConfigImporter.themeSlot(pair.dark, dark: true, context: context, warnings: &plan.warnings)
        return plan
    }

    /// A slot only takes a theme of its own brightness; the app would show the slot default otherwise.
    private static func themeSlot(
        _ requested: String,
        dark: Bool,
        context: GhosttyImportContext,
        warnings: inout [String]
    ) -> GhosttyThemeSlotPlan? {
        var currentName = context.lightTheme
        if dark {
            currentName = context.darkTheme
        }
        var name = requested
        var source = GhosttyThemeSlotPlan.Source.builtinTheme
        var lookup: GhosttyThemeLookup?

        if requested.hasPrefix("/") || requested.hasPrefix("~/") {
            let url = GhosttyConfigImporter.expandedURL(requested, relativeTo: context.home, home: context.home)
            name = url.lastPathComponent
            let folder = url.deletingLastPathComponent().standardizedFileURL.path
            if folder == context.userThemesDirectory.standardizedFileURL.path {
                lookup = context.lookupTheme(name)
                source = .userTheme
            } else if GhosttyConfigImporter.isRegularFile(url) {
                lookup = context.lookupThemeFile(url)
                source = .importFile(url)
                if lookup == nil {
                    warnings.append(String(format: String(localized: "%@ is not a valid Ghostty theme file"), url.path))
                    return nil
                }
            }
        } else {
            lookup = context.lookupTheme(requested)
            if lookup?.isUserTheme == true {
                source = .userTheme
            }
        }

        guard let lookup else {
            warnings.append(String(format: String(localized: "Theme “%@” was not found in your themes folder or the built-in themes"), requested))
            return nil
        }
        if lookup.isLightBackground == dark {
            if dark {
                warnings.append(String(format: String(localized: "“%@” is a light theme; the dark theme stays unchanged"), name))
            } else {
                warnings.append(String(format: String(localized: "“%@” is a dark theme; the light theme stays unchanged"), name))
            }
            return nil
        }
        return GhosttyThemeSlotPlan(name: name, source: source, currentName: currentName)
    }

    // MARK: - Keys the app has no use for

    private static let windowKeys: Set<String> = [
        "confirm-close-surface", "fullscreen", "maximize", "initial-window", "focus-follows-mouse",
        "split-preserve-zoom", "split-inherit-working-directory", "tab-inherit-working-directory",
        "title", "drag-handle", "macos-non-native-fullscreen",
    ]
    private static let windowPrefixes = [
        "window-", "resize-overlay", "unfocused-split", "split-divider", "macos-titlebar", "macos-window",
    ]
    private static let platformPrefixes = ["gtk-", "linux-", "adw-", "x11-"]
    private static let platformKeys: Set<String> = ["class", "async-backend"]
    private static let processKeys: Set<String> = [
        "command", "initial-command", "working-directory", "env", "input", "term",
        "wait-after-command", "abnormal-command-exit-runtime",
    ]
    private static let appLevelKeys: Set<String> = [
        "app-notifications", "desktop-notifications", "undo-timeout", "command-palette-entry",
        "quit-after-last-window-closed", "quit-after-last-window-closed-delay", "language",
    ]
    private static let appLevelPrefixes = ["quick-terminal", "auto-update", "notify-on-command-finish", "macos-"]
    /// Padding is a terminal setting even though the key starts with `window-`.
    private static let surfaceWindowKeys: Set<String> = [
        "window-padding-x", "window-padding-y", "window-padding-balance", "window-padding-color",
    ]

    /// Nil when the key belongs to the terminal itself and should be imported somewhere.
    static func ignoreReason(forKey key: String) -> GhosttyIgnoreReason? {
        if GhosttyConfigImporter.surfaceWindowKeys.contains(key) || key == "macos-option-as-alt" {
            return nil
        }
        if key == "background-blur" {
            return .blur
        }
        if key.hasPrefix("custom-shader") {
            return .shader
        }
        if GhosttyConfigImporter.windowKeys.contains(key) {
            return .window
        }
        for prefix in GhosttyConfigImporter.windowPrefixes where key.hasPrefix(prefix) {
            return .window
        }
        if GhosttyConfigImporter.platformKeys.contains(key) {
            return .platform
        }
        for prefix in GhosttyConfigImporter.platformPrefixes where key.hasPrefix(prefix) {
            return .platform
        }
        if GhosttyConfigImporter.processKeys.contains(key) {
            return .process
        }
        if GhosttyConfigImporter.appLevelKeys.contains(key) {
            return .appLevel
        }
        for prefix in GhosttyConfigImporter.appLevelPrefixes where key.hasPrefix(prefix) {
            return .appLevel
        }
        return nil
    }

    // MARK: - Keybinds

    enum KeybindOutcome: Equatable {
        case appShortcut(id: String, trigger: GhosttyTrigger)
        case customSnippet
        case unmigrated(reason: String)
    }

    /// Ghostty actions that are one of the app's shortcuts, keyed by the full action text.
    static let appShortcutActions: [String: String] = [
        "new_tab": "newTab",
        "close_surface": "closeTab",
        "close_tab": "closeTab",
        "new_split:right": "duplicateRight",
        "new_split:down": "duplicateDown",
        "goto_split:left": "paneLeft",
        "goto_split:right": "paneRight",
        "goto_split:up": "paneUp",
        "goto_split:top": "paneUp",
        "goto_split:down": "paneDown",
        "goto_split:bottom": "paneDown",
        "goto_split:previous": "previousPane",
        "goto_split:next": "nextPane",
        "open_config": "settings",
    ]

    /// Actions the terminal engine performs on its own, keyed by the action name before `:`.
    static let engineActions: Set<String> = [
        "increase_font_size", "decrease_font_size", "reset_font_size", "set_font_size",
        "clear_screen", "reset",
        "scroll_to_top", "scroll_to_bottom", "scroll_to_selection", "scroll_to_row",
        "scroll_page_up", "scroll_page_down", "scroll_page_fractional", "scroll_page_lines",
        "copy_to_clipboard", "paste_from_clipboard", "paste_from_selection", "copy_url_to_clipboard",
        "jump_to_prompt", "select_all", "adjust_selection",
        "text", "csi", "esc", "cursor_key", "unbind", "ignore",
    ]

    /// Splits `trigger=action`. An `=` right after `+` (or first) is the `=` key, not the separator.
    static func splitKeybind(_ value: String) -> (trigger: String, action: String)? {
        let characters = Array(value)
        for index in characters.indices where characters[index] == "=" {
            if index == 0 || characters[index - 1] == "+" {
                continue
            }
            let trigger = String(characters[..<index]).trimmingCharacters(in: .whitespaces)
            let action = String(characters[(index + 1)...]).trimmingCharacters(in: .whitespaces)
            if trigger.isEmpty || action.isEmpty {
                return nil
            }
            return (trigger, action)
        }
        return nil
    }

    static func classifyKeybind(_ value: String) -> KeybindOutcome {
        if value.trimmingCharacters(in: .whitespaces) == "clear" {
            return .unmigrated(reason: String(localized: "Would remove every built-in terminal key binding"))
        }
        guard let parts = GhosttyConfigImporter.splitKeybind(value) else {
            return .unmigrated(reason: String(localized: "Not a trigger=action key binding"))
        }
        var trigger = parts.trigger
        var appWide = false
        var stripped = true
        while stripped {
            stripped = false
            for prefix in ["global:", "all:", "unconsumed:", "performable:"] where trigger.hasPrefix(prefix) {
                if prefix == "global:" || prefix == "all:" {
                    appWide = true
                }
                trigger.removeFirst(prefix.count)
                stripped = true
            }
        }
        let action = parts.action.lowercased()

        if let shortcutID = GhosttyConfigImporter.appShortcutActions[action] {
            if appWide || trigger.contains(">") {
                return .unmigrated(reason: String(localized: "global:/all: prefixes and key sequences cannot become app shortcuts"))
            }
            guard let parsed = GhosttyConfigImporter.parseTrigger(trigger) else {
                return .unmigrated(reason: String(localized: "Key not supported for app shortcuts"))
            }
            return .appShortcut(id: shortcutID, trigger: parsed)
        }

        var actionName = action
        if let colon = action.firstIndex(of: ":") {
            actionName = String(action[..<colon])
        }
        if GhosttyConfigImporter.engineActions.contains(actionName) {
            if appWide {
                return .unmigrated(reason: String(localized: "global:/all: key bindings need the whole app, not one terminal"))
            }
            if TerminalSettings.keybindConflictsWithApp(value) {
                return .unmigrated(reason: String(localized: "⌘C is handled by the app: copy with a selection, otherwise sent to the shell"))
            }
            return .customSnippet
        }
        return .unmigrated(reason: String(localized: "This app has no matching feature"))
    }

    /// `super+shift+t` style. At least one modifier is required, as for every app shortcut.
    static func parseTrigger(_ text: String) -> GhosttyTrigger? {
        var trigger = GhosttyTrigger(key: "")
        var hasModifier = false
        for rawPart in text.split(separator: "+", omittingEmptySubsequences: false) {
            let part = rawPart.trimmingCharacters(in: .whitespaces).lowercased()
            switch part {
            case "super", "cmd", "command":
                trigger.command = true
                hasModifier = true
            case "alt", "opt", "option":
                trigger.option = true
                hasModifier = true
            case "ctrl", "control":
                trigger.control = true
                hasModifier = true
            case "shift":
                trigger.shift = true
                hasModifier = true
            default:
                if !trigger.key.isEmpty {
                    return nil
                }
                guard let key = GhosttyConfigImporter.chordKey(part) else { return nil }
                trigger.key = key
            }
        }
        if trigger.key.isEmpty || !hasModifier {
            return nil
        }
        return trigger
    }

    private static let namedKeys: [String: String] = [
        "left": "arrow_left", "arrow_left": "arrow_left",
        "right": "arrow_right", "arrow_right": "arrow_right",
        "up": "arrow_up", "arrow_up": "arrow_up",
        "down": "arrow_down", "arrow_down": "arrow_down",
        "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
        "minus": "-", "equal": "=", "semicolon": ";", "quote": "'", "backquote": "`",
        "bracket_left": "[", "bracket_right": "]", "space": " ",
    ]

    private static func chordKey(_ name: String) -> String? {
        if name.count == 1 {
            return name
        }
        if let named = GhosttyConfigImporter.namedKeys[name] {
            return named
        }
        if name.hasPrefix("key_"), name.count == 5 {
            return String(name.suffix(1))
        }
        if name.hasPrefix("digit_"), name.count == 7 {
            return String(name.suffix(1))
        }
        return nil
    }

    // MARK: - Helpers

    private static func unquoted(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }
}
