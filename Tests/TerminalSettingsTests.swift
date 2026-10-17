import Foundation

@main
enum TerminalSettingsTests {
    static func main() {
        testDefaultsRenderLegacyLines()
        testLoadAndSave()
        testApplyGhosttyKeys()
        testRenderNonDefaults()
        testCustomConfigParse()
        testSnippetFit()
        testStoredFeatureList()
        print("ok")
    }

    /// Exactly the lines `fontConfiguration()` produced before settings existed, plus the unbinds
    /// for the actions the Terminal menu owns.
    static func testDefaultsRenderLegacyLines() {
        let legacy = [
            "font-size = 14",
            "window-padding-x = 8",
            "window-padding-y = 2,6",
            "window-padding-balance = false",
            "cursor-style = block",
            "cursor-style-blink = true",
            "font-thicken = false",
            "font-family = SF Mono",
            "macos-option-as-alt = true",
            "keybind = super+c=unbind",
            "keybind = super+shift+l=unbind",
            "keybind = super+shift+p=unbind",
            "keybind = super+shift+a=unbind",
            "keybind = super+==unbind",
            "keybind = super+plus=unbind",
            "keybind = super+-=unbind",
            "keybind = super+0=unbind",
            "keybind = super+k=unbind",
            "keybind = super+a=unbind",
            "keybind = super+home=unbind",
            "keybind = super+end=unbind",
            "keybind = super+page_up=unbind",
            "keybind = super+page_down=unbind",
            "keybind = super+arrow_up=unbind",
            "keybind = super+arrow_down=unbind",
            "keybind = super+shift+arrow_up=unbind",
            "keybind = super+shift+arrow_down=unbind",
            "keybind = super+f=unbind",
            "keybind = super+g=unbind",
            "keybind = super+shift+g=unbind",
            "keybind = super+e=unbind",
            "keybind = super+shift+enter=unbind",
            "keybind = super+enter=unbind",
            "keybind = super+ctrl+f=unbind",
            "keybind = super+shift+[=unbind",
            "keybind = super+shift+]=unbind",
            "keybind = super+1=unbind",
            "keybind = super+digit_1=unbind",
            "keybind = super+2=unbind",
            "keybind = super+digit_2=unbind",
            "keybind = super+3=unbind",
            "keybind = super+digit_3=unbind",
            "keybind = super+4=unbind",
            "keybind = super+digit_4=unbind",
            "keybind = super+5=unbind",
            "keybind = super+digit_5=unbind",
            "keybind = super+6=unbind",
            "keybind = super+digit_6=unbind",
            "keybind = super+7=unbind",
            "keybind = super+digit_7=unbind",
            "keybind = super+8=unbind",
            "keybind = super+digit_8=unbind",
            "keybind = super+9=unbind",
            "clipboard-write = allow",
            "mouse-shift-capture = never",
            "font-codepoint-map = U+E000-U+F8FF=Symbols Nerd Font Mono",
            "font-codepoint-map = U+F0000-U+FFFFD=Symbols Nerd Font Mono",
            "font-codepoint-map = U+100000-U+10FFFD=Symbols Nerd Font Mono",
        ]
        let rendered = TerminalSettings.defaults.configEntries().map { "\($0.key) = \($0.value)" }
        expect(rendered == legacy, "defaults render the legacy lines: \(rendered)")

        let empty = UserDefaults(suiteName: "TerminalSettingsTests.empty")!
        empty.removePersistentDomain(forName: "TerminalSettingsTests.empty")
        expect(TerminalSettings.load(from: empty) == TerminalSettings.defaults, "empty defaults load as defaults")
    }

    static func testLoadAndSave() {
        let suite = "TerminalSettingsTests.roundTrip"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)

        store.set("  ", forKey: "appearance.terminalFontFamily")
        store.set(99.0, forKey: "appearance.terminalFontSize")
        store.set("wide", forKey: "terminal.cursorStyle")
        let fallback = TerminalSettings.load(from: store)
        expect(fallback.fontFamily == "SF Mono", "blank family falls back")
        expect(fallback.fontSize == 28, "size clamps to the maximum")
        expect(fallback.cursorStyle == .block, "unknown cursor style falls back")

        var settings = TerminalSettings.defaults
        settings.fontFamily = "Menlo"
        settings.fontSize = 16
        settings.fontThicken = true
        settings.fontThickenStrength = 80
        settings.fontLigatures = false
        settings.cellHeightAdjust = 10
        settings.cursorStyle = .blockHollow
        settings.cursorBlink = false
        settings.cursorOpacity = 0.5
        settings.paddingX = 2
        settings.paddingY = 3
        settings.backgroundOpacity = 0.9
        settings.minimumContrast = 1.5
        settings.scrollbackLimitMB = 20
        settings.copyOnSelect = .clipboard
        settings.clipboardPasteProtection = false
        settings.mouseHideWhileTyping = true
        settings.linkURL = false
        settings.optionAsAlt = .left
        settings.shellIntegration = .zsh
        settings.shellIntegrationFeatures = ["sudo", "path"]
        settings.bellFeatures = []
        settings.customConfig = "cursor-color = #ff0000\n"
        settings.save(to: store)
        expect(TerminalSettings.load(from: store) == settings, "save then load round-trips every field")
        expect(store.string(forKey: "terminal.shellIntegrationFeatures") == "sudo,path", "features stored in Ghostty order")
        expect(store.double(forKey: "appearance.terminalFontSize") == 16, "font size keeps its old key")
        store.removePersistentDomain(forName: suite)
    }

    static func testApplyGhosttyKeys() {
        var s = TerminalSettings.defaults
        expect(s.apply(ghosttyKey: "font-family", value: "\"JetBrains Mono\""), "font-family")
        expect(s.fontFamily == "JetBrains Mono", "quotes are stripped")
        expect(!s.apply(ghosttyKey: "font-family", value: ""), "empty font-family is not a value")
        expect(s.apply(ghosttyKey: "font-size", value: "13.5") && s.fontSize == 13.5, "font-size")
        expect(s.apply(ghosttyKey: "font-size", value: "40") && s.fontSize == 28, "font-size clamps")
        expect(!s.apply(ghosttyKey: "font-size", value: "big"), "bad font-size")
        expect(s.apply(ghosttyKey: "font-thicken", value: "true") && s.fontThicken, "font-thicken")
        expect(!s.apply(ghosttyKey: "font-thicken", value: "yes"), "bad bool")
        expect(s.apply(ghosttyKey: "font-thicken-strength", value: "120") && s.fontThickenStrength == 120, "strength")
        expect(!s.apply(ghosttyKey: "font-thicken-strength", value: "300"), "strength out of range")
        expect(s.apply(ghosttyKey: "font-feature", value: "-calt, -liga") && !s.fontLigatures, "ligatures off")
        expect(!s.apply(ghosttyKey: "font-feature", value: "ss01"), "other font features are not modeled")
        expect(s.apply(ghosttyKey: "adjust-cell-height", value: "15%") && s.cellHeightAdjust == 15, "cell height")
        expect(!s.apply(ghosttyKey: "adjust-cell-height", value: "2"), "point cell height is not modeled")
        expect(s.apply(ghosttyKey: "cursor-style", value: "block_hollow") && s.cursorStyle == .blockHollow, "cursor-style")
        expect(!s.apply(ghosttyKey: "cursor-style", value: "beam"), "bad cursor-style")
        expect(s.apply(ghosttyKey: "cursor-style-blink", value: "false") && !s.cursorBlink, "cursor blink")
        expect(s.apply(ghosttyKey: "cursor-opacity", value: "0.7") && s.cursorOpacity == 0.7, "cursor opacity")
        expect(s.apply(ghosttyKey: "window-padding-x", value: "4") && s.paddingX == 4, "padding x")
        expect(s.apply(ghosttyKey: "window-padding-y", value: "5") && s.paddingY == 5, "padding y")
        expect(!s.apply(ghosttyKey: "window-padding-x", value: "2,4"), "split padding is not modeled")
        expect(s.apply(ghosttyKey: "background-opacity", value: "0.85") && s.backgroundOpacity == 0.85, "bg opacity")
        expect(s.apply(ghosttyKey: "minimum-contrast", value: "3") && s.minimumContrast == 3, "contrast")
        expect(!s.apply(ghosttyKey: "minimum-contrast", value: "30"), "contrast out of range")
        expect(s.apply(ghosttyKey: "scrollback-limit", value: "10000000") && s.scrollbackLimitMB == 10, "scrollback-limit")
        expect(s.apply(ghosttyKey: "scrollback-limit-bytes", value: "25000000") && s.scrollbackLimitMB == 25, "scrollback bytes")
        expect(s.apply(ghosttyKey: "copy-on-select", value: "true") && s.copyOnSelect == .clipboard, "copy true")
        expect(s.apply(ghosttyKey: "copy-on-select", value: "false") && s.copyOnSelect == .none, "copy false")
        expect(s.apply(ghosttyKey: "copy-on-select", value: "both") && s.copyOnSelect == .both, "copy both")
        expect(s.apply(ghosttyKey: "clipboard-paste-protection", value: "false") && !s.clipboardPasteProtection, "paste")
        expect(s.apply(ghosttyKey: "mouse-hide-while-typing", value: "true") && s.mouseHideWhileTyping, "mouse hide")
        expect(s.apply(ghosttyKey: "link-url", value: "false") && !s.linkURL, "link-url")
        expect(s.apply(ghosttyKey: "macos-option-as-alt", value: "right") && s.optionAsAlt == .right, "option")
        expect(s.apply(ghosttyKey: "macos-option-as-alt", value: "false") && s.optionAsAlt == .off, "option false")
        expect(s.apply(ghosttyKey: "shell-integration", value: "fish") && s.shellIntegration == .fish, "shell")
        expect(!s.apply(ghosttyKey: "shell-integration", value: "tcsh"), "unknown shell")
        expect(s.apply(ghosttyKey: "shell-integration-features", value: "sudo,no-cursor"), "shell features")
        expect(s.shellIntegrationFeatures == ["sudo", "title", "path"], "omitted features take engine defaults")
        expect(s.apply(ghosttyKey: "shell-integration-features", value: "false") && s.shellIntegrationFeatures.isEmpty, "all off")
        expect(!s.apply(ghosttyKey: "shell-integration-features", value: "teleport"), "unknown feature")
        expect(s.apply(ghosttyKey: "bell-features", value: "system,no-title"), "bell features")
        expect(s.bellFeatures == ["system", "attention"], "bell features parsed")
        expect(!s.apply(ghosttyKey: "theme", value: "Dracula"), "theme is not a field")
        expect(!s.apply(ghosttyKey: "cursor-color", value: "#fff"), "unknown key")
    }

    static func testRenderNonDefaults() {
        var s = TerminalSettings.defaults
        s.fontLigatures = false
        s.cellHeightAdjust = -5
        s.fontThickenStrength = 64
        s.cursorOpacity = 0.75
        s.backgroundOpacity = 0.9
        s.minimumContrast = 1.1
        s.scrollbackLimitMB = 10
        s.copyOnSelect = .clipboard
        s.clipboardPasteProtection = false
        s.mouseHideWhileTyping = true
        s.linkURL = false
        s.shellIntegration = .none
        s.shellIntegrationFeatures = ["cursor", "sudo"]
        s.bellFeatures = ["system"]
        s.fontSize = 13.5
        let lines = Set(s.configEntries().map { "\($0.key) = \($0.value)" })
        let expected = [
            "font-size = 13.5",
            "font-feature = -calt",
            "font-feature = -liga",
            "adjust-cell-height = -5%",
            "font-thicken-strength = 64",
            "cursor-opacity = 0.75",
            "background-opacity = 0.9",
            "minimum-contrast = 1.1",
            "scrollback-limit-bytes = 10000000",
            "copy-on-select = clipboard",
            "clipboard-paste-protection = false",
            "mouse-hide-while-typing = true",
            "link-url = false",
            "shell-integration = none",
            "shell-integration-features = cursor,sudo,no-title,no-ssh-env,no-ssh-terminfo,no-path",
            "bell-features = system,no-audio,no-attention,no-title,no-border",
        ]
        for line in expected {
            expect(lines.contains(line), "renders \(line)")
        }
    }

    static func testCustomConfigParse() {
        let text = "cursor-style = bar\n# c\n\n  font-size = 30  \nbogus\n = 3\nkeybind = super+t=new_tab\nfont-feature=ss01\n"
            + "keybind = cmd+c=copy_to_clipboard\nkeybind = clear\nkeybind =\nkeybind = super+shift+c=copy_to_clipboard\n"
        let parsed = TerminalSettings.parseCustomConfig(text)
        expect(parsed.entries == [
            TerminalConfigEntry(key: "cursor-style", value: "bar"),
            TerminalConfigEntry(key: "keybind", value: "super+t=new_tab"),
            TerminalConfigEntry(key: "font-feature", value: "ss01"),
            TerminalConfigEntry(key: "keybind", value: "super+shift+c=copy_to_clipboard"),
        ], "entries: \(parsed.entries)")
        expect(parsed.skippedLines == [
            "font-size = 30",
            "keybind = cmd+c=copy_to_clipboard",
            "keybind = clear",
            "keybind =",
        ], "skipped: \(parsed.skippedLines)")
        expect(TerminalSettings.keybindConflictsWithApp("unconsumed:super+c>x=text:a"), "sequence starting with ⌘C conflicts")
        expect(!TerminalSettings.keybindConflictsWithApp("ctrl+c=text:a"), "⌃C does not conflict")
        expect(parsed.invalidLines == ["bogus", "= 3"], "invalid: \(parsed.invalidLines)")
        expect(TerminalSettings.parseCustomConfig("") == TerminalCustomConfigParse(), "empty snippet")
    }

    /// A fake engine that refuses any configuration containing a key from `bad`.
    static func testSnippetFit() {
        let cursor = TerminalConfigEntry(key: "cursor-style", value: "bar")
        let bogus = TerminalConfigEntry(key: "not-a-real-key", value: "1")
        let font = TerminalConfigEntry(key: "font-feature", value: "ss01")
        var calls: [[TerminalConfigEntry]] = []
        var applied: [TerminalConfigEntry] = []
        func engine(bad: Set<String>, baseFails: Bool = false) -> ([TerminalConfigEntry]) -> String? {
            return { entries in
                calls.append(entries)
                if baseFails {
                    return "base broken"
                }
                if let refused = entries.first(where: { bad.contains($0.key) }) {
                    return "unknown field: \(refused.key)"
                }
                applied = entries
                return nil
            }
        }

        let clean = TerminalSnippetFit.fit([cursor, font], tryApply: engine(bad: []))
        expect(clean == TerminalSnippetFit(accepted: [cursor, font]), "clean: \(clean)")
        expect(calls.count == 1, "clean snippet is tried once, not line by line: \(calls.count)")

        calls = []
        let mixed = TerminalSnippetFit.fit([cursor, bogus, font], tryApply: engine(bad: ["not-a-real-key"]))
        expect(mixed.accepted == [cursor, font], "mixed accepted: \(mixed.accepted)")
        expect(mixed.rejected == [TerminalConfigRejection(line: "not-a-real-key = 1", issue: "unknown field: not-a-real-key")],
               "mixed rejected: \(mixed.rejected)")
        expect(mixed.baseIssue == nil, "mixed base ok")
        expect(applied == [cursor, font], "last accepted call leaves settings + good lines applied: \(applied)")

        let lastBad = TerminalSnippetFit.fit([cursor, bogus], tryApply: engine(bad: ["not-a-real-key"]))
        expect(lastBad.accepted == [cursor] && applied == [cursor], "a rejected last line leaves the earlier ones applied")

        let allBad = TerminalSnippetFit.fit([bogus], tryApply: engine(bad: ["not-a-real-key"]))
        expect(allBad.accepted.isEmpty && allBad.rejected.count == 1 && applied.isEmpty, "only bad line: settings alone applied")

        let base = TerminalSnippetFit.fit([cursor], tryApply: engine(bad: [], baseFails: true))
        expect(base == TerminalSnippetFit(baseIssue: "base broken"), "settings refused: no line blamed: \(base)")
    }

    static func testStoredFeatureList() {
        let known = TerminalSettings.bellFeatureNames
        expect(TerminalSettings.storedFeatureList("attention,title", setting: "system", enabled: true, known: known)
            == "system,attention,title", "switched on in Ghostty order")
        expect(TerminalSettings.storedFeatureList("attention,title", setting: "title", enabled: false, known: known)
            == "attention", "switched off")
        expect(TerminalSettings.storedFeatureList("title", setting: "title", enabled: false, known: known)
            == "", "last one off stores empty")
        expect(TerminalSettings.storedFeatureList("bogus,title", setting: "border", enabled: true, known: known)
            == "title,border", "unknown names dropped")
        expect(TerminalSettings.storedFeatureListContains("attention,title", "title", known: known), "contains")
        expect(!TerminalSettings.storedFeatureListContains("attention", "title", known: known), "does not contain")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    static func fail(_ message: String) {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}
