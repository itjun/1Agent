import Foundation

@main
enum GhosttyConfigImporterTests {
    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GhosttyConfigImporterTests-\(UUID().uuidString)", isDirectory: true)

    static func main() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        testDefaultFileOrder()
        testLineSyntax()
        testOverrideOrderAcrossFiles()
        testConfigFileIncludes()
        testIncludeCycleAndOptional()
        testRepeatableKeys()
        testThemeSplit()
        testThemePlan()
        testKeyClassification()
        testKeybindClassification()
        testTriggerParsing()
        print("ok")
    }

    // MARK: - Files

    static func testDefaultFileOrder() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let files = GhosttyConfigImporter.defaultConfigFiles(environment: [:], home: home).map(\.path)
        expect(files == [
            "/Users/someone/.config/ghostty/config",
            "/Users/someone/.config/ghostty/config.ghostty",
            "/Users/someone/Library/Application Support/com.mitchellh.ghostty/config",
            "/Users/someone/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ], "default order: \(files)")

        let xdg = GhosttyConfigImporter.defaultConfigFiles(environment: ["XDG_CONFIG_HOME": "/tmp/xdg"], home: home).map(\.path)
        expect(xdg.first == "/tmp/xdg/ghostty/config", "XDG_CONFIG_HOME wins: \(xdg)")

        let fakeHome = folder("home")
        write("", to: fakeHome.appendingPathComponent(".config/ghostty/config.ghostty"))
        write("", to: fakeHome.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config"))
        let existing = GhosttyConfigImporter.existingConfigFiles(environment: [:], home: fakeHome).map(\.lastPathComponent)
        expect(existing == ["config.ghostty", "config"], "only existing files: \(existing)")
    }

    static func testLineSyntax() {
        let dir = folder("syntax")
        let file = dir.appendingPathComponent("config")
        write("""
        # comment
          font-family = "Maple Mono NF CN"

        font-size=14\r
        cursor-style =  bar  
           # indented comment
        not a pair
        title = "a # b"
        """, to: file)
        let loaded = GhosttyConfigImporter.loadConfig(files: [file], home: dir)
        let pairs = loaded.entries.map { "\($0.key)|\($0.value)" }
        expect(pairs == ["font-family|Maple Mono NF CN", "font-size|14", "cursor-style|bar", "title|a # b"], "pairs: \(pairs)")
        expect(loaded.entries[0].rawValue == "\"Maple Mono NF CN\"", "raw value keeps quotes")
        expect(loaded.warnings.count == 1, "line without = warns: \(loaded.warnings)")
    }

    static func testOverrideOrderAcrossFiles() {
        let dir = folder("override")
        let first = dir.appendingPathComponent("config")
        let second = dir.appendingPathComponent("config.ghostty")
        write("font-size = 12\ncursor-style = bar\n", to: first)
        write("font-size = 16\ncursor-style =\n", to: second)
        let loaded = GhosttyConfigImporter.loadConfig(files: [first, second], home: dir)
        let pairs = loaded.entries.map { "\($0.key)|\($0.value)" }
        expect(pairs == ["font-size|16"], "later file wins, empty value resets: \(pairs)")
        expect(loaded.files == [first, second], "both files read")
    }

    static func testConfigFileIncludes() {
        let dir = folder("include")
        let main = dir.appendingPathComponent("config")
        write("config-file = extra/more\nfont-size = 12\ncursor-style = block\n", to: main)
        write("font-size = 20\nconfig-file = \"../last\"\n", to: dir.appendingPathComponent("extra/more"))
        write("cursor-style = underline\n", to: dir.appendingPathComponent("last"))
        let loaded = GhosttyConfigImporter.loadConfig(files: [main], home: dir)
        let pairs = loaded.entries.map { "\($0.key)|\($0.value)" }
        // Includes load after the including file, so their values win even though written first.
        expect(pairs == ["font-size|20", "cursor-style|underline"], "include order: \(pairs)")
        expect(loaded.files.map(\.lastPathComponent) == ["config", "more", "last"], "files: \(loaded.files)")
        expect(loaded.warnings.isEmpty, "no warnings: \(loaded.warnings)")

        let homeInclude = dir.appendingPathComponent("home-include")
        write("config-file = ~/last\n", to: homeInclude)
        let fromHome = GhosttyConfigImporter.loadConfig(files: [homeInclude], home: dir)
        expect(fromHome.entries.map(\.value) == ["underline"], "~/ is the home folder")
    }

    static func testIncludeCycleAndOptional() {
        let dir = folder("cycle")
        let main = dir.appendingPathComponent("config")
        write("config-file = a\nconfig-file = ?missing\nconfig-file = gone\n", to: main)
        write("font-size = 11\nconfig-file = b\n", to: dir.appendingPathComponent("a"))
        write("cursor-style = bar\nconfig-file = a\n", to: dir.appendingPathComponent("b"))
        let loaded = GhosttyConfigImporter.loadConfig(files: [main], home: dir)
        let pairs = loaded.entries.map { "\($0.key)|\($0.value)" }
        expect(pairs == ["font-size|11", "cursor-style|bar"], "cycle loads each file once: \(pairs)")
        expect(loaded.warnings.count == 2, "cycle + required missing warn, optional does not: \(loaded.warnings)")
        expect(loaded.warnings.contains { $0.contains("cycle") }, "cycle warning")
        expect(loaded.warnings.contains { $0.contains("gone") }, "missing required include warning")
    }

    static func testRepeatableKeys() {
        let file = URL(fileURLWithPath: "/tmp/x")
        func line(_ key: String, _ value: String) -> GhosttyConfigLine {
            GhosttyConfigLine(key: key, value: value, rawValue: value, file: file)
        }
        let merged = GhosttyConfigImporter.merge([
            line("keybind", "super+a=select_all"),
            line("font-family", "A"),
            line("keybind", ""),
            line("keybind", "super+k=clear_screen"),
            line("font-family", "B"),
            line("palette", "0=#000000"),
            line("palette", "1=#ff0000"),
            line("font-size", "12"),
            line("font-size", "13"),
        ]).map { "\($0.key)|\($0.value)" }
        expect(merged == [
            "font-family|A",
            "keybind|super+k=clear_screen",
            "font-family|B",
            "palette|0=#000000",
            "palette|1=#ff0000",
            "font-size|13",
        ], "repeatable merge: \(merged)")
    }

    // MARK: - Theme

    static func testThemeSplit() {
        expectPair(GhosttyConfigImporter.splitTheme("light:Claude Paper,dark:Claude Ink"), "Claude Paper", "Claude Ink")
        expectPair(GhosttyConfigImporter.splitTheme(" dark: Night , light: Day "), "Day", "Night")
        expectPair(GhosttyConfigImporter.splitTheme("TokyoNight"), "TokyoNight", "TokyoNight")
        expectPair(GhosttyConfigImporter.splitTheme("  Rose Pine  "), "Rose Pine", "Rose Pine")
        expect(GhosttyConfigImporter.splitTheme("light:Only") == nil, "pair needs both slots")
        expect(GhosttyConfigImporter.splitTheme("light:A,dusk:B") == nil, "unknown slot name")
        expect(GhosttyConfigImporter.splitTheme("") == nil, "empty theme")
    }

    static func testThemePlan() {
        let dir = folder("themes")
        let userThemes = dir.appendingPathComponent("user-themes", isDirectory: true)
        let outside = dir.appendingPathComponent("elsewhere/My Night")
        write("background = #000000\nforeground = #ffffff\n", to: outside)
        var context = makeContext(home: dir, userThemes: userThemes)
        context.lookupThemeFile = { _ in GhosttyThemeLookup(isLightBackground: false, isUserTheme: false) }

        let pair = GhosttyConfigImporter.themePlan("light:Claude Paper,dark:Claude Ink", context: context)
        expect(pair.light == GhosttyThemeSlotPlan(name: "Claude Paper", source: .userTheme, currentName: "GitHub Light Default"), "light slot: \(String(describing: pair.light))")
        expect(pair.dark == GhosttyThemeSlotPlan(name: "Claude Ink", source: .userTheme, currentName: "GitHub Dark Default"), "dark slot")
        expect(pair.warnings.isEmpty, "no theme warnings: \(pair.warnings)")

        let single = GhosttyConfigImporter.themePlan("GitHub Dark Default", context: context)
        expect(single.light == nil && single.dark?.isUnchanged == true, "single dark theme only fills the dark slot")
        expect(single.warnings.count == 1, "light slot mismatch warns: \(single.warnings)")

        let missing = GhosttyConfigImporter.themePlan("light:Nope,dark:Claude Ink", context: context)
        expect(missing.light == nil && missing.dark != nil && missing.warnings.count == 1, "missing theme warns")

        let file = GhosttyConfigImporter.themePlan("light:Claude Paper,dark:\(outside.path)", context: context)
        expect(file.dark == GhosttyThemeSlotPlan(name: "My Night", source: .importFile(outside.standardizedFileURL), currentName: "GitHub Dark Default"), "absolute path imports: \(String(describing: file.dark))")

        let inFolder = GhosttyConfigImporter.themePlan("light:\(userThemes.path)/Claude Paper,dark:Claude Ink", context: context)
        expect(inFolder.light?.source == .userTheme && inFolder.light?.name == "Claude Paper", "path inside the themes folder is a name")
    }

    // MARK: - Classification

    static func testKeyClassification() {
        let dir = folder("classify")
        let file = dir.appendingPathComponent("config")
        write("""
        font-family = "Maple Mono NF CN"
        font-family = Symbols Nerd Font
        font-size = 14
        cursor-style = bar
        background-opacity = 0.95
        window-padding-x = 18
        window-padding-balance = true
        font-feature = -calt
        font-feature = ss01
        selection-background = #333333
        clipboard-write = deny
        window-save-state = always
        macos-titlebar-style = tabs
        background-blur = 20
        gtk-single-instance = true
        custom-shader = foo.glsl
        command = /bin/zsh
        quick-terminal-position = top
        auto-update = off
        cursor-style-blink = true
        theme = light:Claude Paper,dark:Claude Ink
        """, to: file)
        var context = makeContext(home: dir, userThemes: dir.appendingPathComponent("t"))
        context.settings.customConfig = "selection-background = #333333"
        let plan = GhosttyConfigImporter.makePlan(
            config: GhosttyConfigImporter.loadConfig(files: [file], home: dir),
            context: context
        )

        let changes = plan.settingsChanges.map { "\($0.key)|\($0.oldValue)|\($0.newValue)" }
        expect(changes == [
            "font-family|SF Mono|Maple Mono NF CN",
            "font-size|14|14",
            "cursor-style|block|bar",
            "background-opacity|1|0.95",
            "window-padding-x|8|18",
            "font-feature|Ligatures on|Ligatures off",
            "cursor-style-blink|true|true",
        ], "settings changes: \(changes)")
        expect(plan.settingsChanges[1].isUnchanged, "same font size is marked unchanged")
        expect(plan.newSettings.fontFamily == "Maple Mono NF CN" && plan.newSettings.paddingX == 18, "new settings applied")

        expect(plan.customLines == [
            "window-padding-balance = true",
            "font-feature = ss01",
        ], "custom lines (existing snippet line not repeated): \(plan.customLines)")
        expect(plan.newSettings.customConfig == "selection-background = #333333\nwindow-padding-balance = true\nfont-feature = ss01\n", "snippet appended: \(plan.newSettings.customConfig)")

        let ignored = plan.ignored.map { "\($0.line)|\($0.reason)" }
        expect(ignored == [
            "window-save-state = always|window",
            "macos-titlebar-style = tabs|window",
            "background-blur = 20|blur",
            "gtk-single-instance = true|platform",
            "custom-shader = foo.glsl|shader",
            "command = /bin/zsh|process",
            "quick-terminal-position = top|appLevel",
            "auto-update = off|appLevel",
        ], "ignored: \(ignored)")

        let unmigrated = plan.unmigrated.map(\.line)
        expect(unmigrated == ["font-family = Symbols Nerd Font", "clipboard-write = deny"], "unmigrated: \(unmigrated)")
        expect(plan.theme.light?.name == "Claude Paper" && plan.theme.dark?.name == "Claude Ink", "theme planned")
        expect(!plan.changesNothing, "plan changes something")

        expect(GhosttyConfigImporter.ignoreReason(forKey: "window-padding-y") == nil, "padding is imported")
        expect(GhosttyConfigImporter.ignoreReason(forKey: "macos-option-as-alt") == nil, "option-as-alt is imported")
        expect(GhosttyConfigImporter.ignoreReason(forKey: "macos-icon") == .appLevel, "macos-icon ignored")
        expect(GhosttyConfigImporter.ignoreReason(forKey: "confirm-close-surface") == .window, "confirm-close ignored")
        expect(GhosttyConfigImporter.ignoreReason(forKey: "working-directory") == .process, "working-directory ignored")
    }

    static func testKeybindClassification() {
        func outcome(_ value: String) -> GhosttyConfigImporter.KeybindOutcome {
            GhosttyConfigImporter.classifyKeybind(value)
        }
        expect(outcome("super+shift+t=new_tab") == .appShortcut(id: "newTab", trigger: GhosttyTrigger(key: "t", command: true, shift: true)), "new_tab maps")
        expect(outcome("cmd+d=new_split:right") == .appShortcut(id: "duplicateRight", trigger: GhosttyTrigger(key: "d", command: true)), "split right maps")
        expect(outcome("ctrl+alt+left=goto_split:left") == .appShortcut(id: "paneLeft", trigger: GhosttyTrigger(key: "arrow_left", option: true, control: true)), "goto_split maps")
        expect(outcome("super+comma=open_config") == .appShortcut(id: "settings", trigger: GhosttyTrigger(key: ",", command: true)), "open_config maps")
        expect(outcome("super+w=close_surface") == .appShortcut(id: "closeTab", trigger: GhosttyTrigger(key: "w", command: true)), "close_surface maps")

        expect(outcome("super+equal=increase_font_size") == .customSnippet, "font size action goes to snippet")
        expect(outcome("super+k=clear_screen") == .customSnippet, "clear_screen goes to snippet")
        expect(outcome("shift+enter=text:\\n") == .customSnippet, "text: goes to snippet")
        expect(outcome("ctrl+a>n=scroll_page_down") == .customSnippet, "engine sequences go to snippet")
        expect(outcome("super+==increase_font_size") == .customSnippet, "the = key splits correctly")

        if case .unmigrated = outcome("global:super+t=new_tab") {} else { fail("global: app shortcut is unmigrated") }
        if case .unmigrated = outcome("ctrl+a>t=new_tab") {} else { fail("sequence app shortcut is unmigrated") }
        if case .unmigrated = outcome("t=new_tab") {} else { fail("app shortcut without modifier is unmigrated") }
        if case .unmigrated = outcome("super+c=copy_to_clipboard") {} else { fail("⌘C stays with the app") }
        if case .unmigrated = outcome("cmd+shift+r=prompt_tab_title") {} else { fail("unknown app action is unmigrated") }
        if case .unmigrated = outcome("clear") {} else { fail("clear is unmigrated") }
        if case .unmigrated = outcome("global:super+k=clear_screen") {} else { fail("global engine action is unmigrated") }

        let split = GhosttyConfigImporter.splitKeybind("super+shift+t=new_split:right")
        expect(split?.trigger == "super+shift+t" && split?.action == "new_split:right", "split trigger/action")
    }

    static func testTriggerParsing() {
        expect(GhosttyConfigImporter.parseTrigger("super+shift+t") == GhosttyTrigger(key: "t", command: true, shift: true), "super+shift+t")
        expect(GhosttyConfigImporter.parseTrigger("Opt+Ctrl+key_a") == GhosttyTrigger(key: "a", option: true, control: true), "aliases and key_a")
        expect(GhosttyConfigImporter.parseTrigger("command+bracket_left") == GhosttyTrigger(key: "[", command: true), "named punctuation")
        expect(GhosttyConfigImporter.parseTrigger("super+digit_1") == GhosttyTrigger(key: "1", command: true), "digit_1")
        expect(GhosttyConfigImporter.parseTrigger("super+up") == GhosttyTrigger(key: "arrow_up", command: true), "arrow")
        expect(GhosttyConfigImporter.parseTrigger("t") == nil, "needs a modifier")
        expect(GhosttyConfigImporter.parseTrigger("super+a+b") == nil, "one key only")
        expect(GhosttyConfigImporter.parseTrigger("super+f13") == nil, "unsupported key")
    }

    // MARK: - Helpers

    static func makeContext(home: URL, userThemes: URL) -> GhosttyImportContext {
        let themes: [String: GhosttyThemeLookup] = [
            "Claude Paper": GhosttyThemeLookup(isLightBackground: true, isUserTheme: true),
            "Claude Ink": GhosttyThemeLookup(isLightBackground: false, isUserTheme: true),
            "GitHub Light Default": GhosttyThemeLookup(isLightBackground: true, isUserTheme: false),
            "GitHub Dark Default": GhosttyThemeLookup(isLightBackground: false, isUserTheme: false),
        ]
        return GhosttyImportContext(
            settings: TerminalSettings.defaults,
            lightTheme: "GitHub Light Default",
            darkTheme: "GitHub Dark Default",
            userThemesDirectory: userThemes,
            home: home,
            lookupTheme: { themes[$0] },
            lookupThemeFile: { _ in nil }
        )
    }

    static func folder(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func expectPair(_ pair: (light: String, dark: String)?, _ light: String, _ dark: String) {
        expect(pair?.light == light && pair?.dark == dark, "theme pair \(String(describing: pair)) == \(light)/\(dark)")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    static func fail(_ message: String) {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}
