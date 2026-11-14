import AppKit
import GhosttyTerminal
@testable import GooseAgent

@MainActor
enum TerminalThemeTests {
    static func run(defaults: UserDefaults, views: [SSHTerminalNSView], sessions: [InMemoryTerminalSession]) {
        let expect = FamilyAppearanceTests.expect
        let catalog = TerminalThemeCatalog.shared
        expect(catalog.issue == nil && catalog.themes.count == 820, "819 bundled themes plus default")
        expect(Set(catalog.themes.map(\.id)).count == 820, "unique theme IDs")
        expect(Set(catalog.themes.dropFirst().map(\.name)).count == 819, "unique original names")
        expect(catalog.themes.first?.isDefault == true, "default is first")
        for theme in catalog.themes.dropFirst() {
            let colors = theme.palette!
            expect(colors.ansi.count == 16, "complete ANSI: " + theme.name)
            let hexes = [colors.background, colors.foreground, colors.cursor, colors.cursorText, colors.selection, colors.selectionText] + colors.ansi
            expect(hexes.allSatisfy { $0.count == 6 && UInt32($0, radix: 16) != nil }, "complete palette: " + theme.name)
            expect(theme.configuration.light == theme.configuration.dark, "fixed theme independent of app appearance")
        }
        expect(catalog.filtered(search: "", filter: .all).count == 820, "all includes both appearances and one default")
        expect(catalog.filtered(search: "", filter: .light).count == 183, "182 light themes plus default")
        expect(catalog.filtered(search: "", filter: .dark).count == 638, "637 dark themes plus default")
        expect(catalog.filtered(search: "tOkYoNiGhT", filter: .all).contains { $0.name == "TokyoNight" }, "case insensitive search")
        expect(catalog.filtered(search: "Default", filter: .dark).first?.isDefault == true, "default searches and ignores brightness filter")
        expect(catalog.filtered(search: "not-a-theme-938723", filter: .all).isEmpty, "empty search results")
        do {
            _ = try TerminalThemeCatalog.parse(name: "invalid", text: "background = #FFFFFF")
            expect(false, "incomplete theme rejected")
        } catch {}
        expect(SettingsLayout.themeColumnCount(width: 1280 - SidebarLayout.defaultWidth) == 4, "four columns at default window")
        expect(SettingsLayout.themeColumnCount(width: 880 - SidebarLayout.defaultWidth) < 4, "narrow window reduces columns")
        let prefs = TerminalThemePreferences.shared
        let light = catalog.theme(id: "ghostty:GitHub Light Default")!
        let otherLight = catalog.theme(id: "ghostty:Ayu Light")!
        let dark = catalog.theme(id: "ghostty:TokyoNight")!
        let otherDark = catalog.theme(id: "ghostty:Dracula")!
        for target in ["local", "remote"] {
            let legacyKey = "appearance.terminalTheme." + target
            defaults.set("Ayu Light", forKey: legacyKey + ".light")
            defaults.set("TokyoNight", forKey: legacyKey + ".dark")
            expect(TerminalThemePreferences.selected(isDark: false).isDefault
                   && TerminalThemePreferences.selected(isDark: true).isDefault,
                   "obsolete bare theme names do not reactivate")
            for theme in [light, dark] {
                defaults.set(theme.id, forKey: legacyKey)
                let isDark = theme.palette!.isDark
                expect(TerminalThemePreferences.selected(isDark: isDark).id == theme.id,
                       "existing theme is preserved in its matching appearance")
                expect(TerminalThemePreferences.selected(isDark: !isDark).isDefault,
                       "opposite appearance starts with default")
            }
            defaults.removeObject(forKey: legacyKey)
            defaults.removeObject(forKey: legacyKey + ".light")
            defaults.removeObject(forKey: legacyKey + ".dark")
        }
        defaults.set(light.id, forKey: "appearance.terminalTheme.local.light")
        defaults.set(dark.id, forKey: "appearance.terminalTheme.local.dark")
        defaults.set(otherLight.id, forKey: "appearance.terminalTheme.remote.light")
        defaults.set(otherDark.id, forKey: "appearance.terminalTheme.remote.dark")
        expect(TerminalThemePreferences.selected(isDark: false).id == light.id
               && TerminalThemePreferences.selected(isDark: true).id == dark.id,
               "merging prefers the existing local pair")
        defaults.removeObject(forKey: "appearance.terminalTheme.local.light")
        expect(TerminalThemePreferences.selected(isDark: false).id == otherLight.id,
               "remote choice is preserved if local choice is absent")
        for isDark in [false, true] {
            let key = TerminalThemePreferences.storageKey(isDark: isDark)
            for id in [TerminalThemeDescriptor.defaultID, "ghostty:missing", (isDark ? light : dark).id] {
                defaults.set(id, forKey: key)
                expect(TerminalThemePreferences.selected(isDark: isDark).isDefault,
                       "shared default or invalid choice cannot revive legacy settings")
            }
            defaults.removeObject(forKey: key)
            for target in ["local", "remote"] {
                defaults.removeObject(forKey: "appearance.terminalTheme." + target + (isDark ? ".dark" : ".light"))
            }
        }
        func check(_ theme: TerminalThemeDescriptor, uiDark: Bool) {
            FamilyAppearanceTests.drain()
            let terminalIsDark = theme.isDark(interfaceIsDark: uiDark)
            expect(AppearanceDriver.shared.interfaceIsDark == uiDark
                   && AppearanceDriver.shared.terminalIsDark == terminalIsDark,
                   "window and terminal brightness are resolved independently")
            for index in views.indices {
                let colors = theme.colors(interfaceIsDark: uiDark)
                let runtime = GhosttyRuntime.controller
                let rgb = Int(colors.background, radix: 16)!
                let expected = TerminalColor(red: UInt8((rgb >> 16) & 255), green: UInt8((rgb >> 8) & 255), blue: UInt8(rgb & 255))
                expect(runtime.backgroundColor == expected, "preview and running engine agree: " + String(index))
                expect((runtime.effectiveColorScheme == .dark) == terminalIsDark, "engine follows selected theme brightness")
                expect((views[index].effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) == terminalIsDark,
                       "native terminal appearance follows selected theme brightness")
                expect((views[index].window!.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) == uiDark,
                       "surrounding window retains the selected appearance")
                expect(runtime.theme == theme.configuration, "cursor, selection, foreground and ANSI share catalog data")
                expect(sessions[index].readScreenText()?.text.contains("family-session-marker") == true,
                       "theme switching keeps existing buffer and surface")
                expect(TerminalThemePreferences.selected().id == theme.id, "active selection follows appearance")
                let background = colors.paneBackground(isFocused: false)
                expect(abs(background.relativeLuminance - colors.paneBackground(isFocused: true).relativeLuminance) > 0.001,
                       "inactive pane retains subtle separation")
            }
        }
        func switchAppearance(_ isDark: Bool) {
            defaults.set(isDark ? "dark" : "light", forKey: TerminalAppearance.storageKey)
            AppearanceDriver.shared.reapply()
        }
        switchAppearance(false)
        expect(prefs.select(light.id), "save light theme before appearance switch")
        switchAppearance(true)
        expect(GhosttyRuntime.controller.effectiveColorScheme == .dark,
               "switching to dark appearance must not retain the light terminal theme")
        check(.system, uiDark: true)
        switchAppearance(false)
        check(light, uiDark: false)
        expect(prefs.select(dark.id, isDark: true), "save shared dark while light")
        check(light, uiDark: false)
        for isDark in [true, false, true, false] {
            switchAppearance(isDark)
            check(isDark ? dark : light, uiDark: isDark)
        }
        defaults.set("system", forKey: TerminalAppearance.storageKey)
        AppearanceDriver.shared.reapply()
        let isSystemDark = TerminalAppearance.systemIsDark
        check(isSystemDark ? dark : light, uiDark: isSystemDark)
        switchAppearance(true)
        views[1].isHidden = true
        expect(prefs.select(dark.id, isDark: true), "hidden terminal theme applies")
        expect(views[1].appliedDarkAppearance == 1, "hidden native view updates immediately")
        views[1].isHidden = false
        for theme in [dark, otherDark, dark, otherDark, dark] {
            expect(prefs.select(theme.id, isDark: true), "rapid switch succeeds")
        }
        check(dark, uiDark: true)
        expect(TerminalThemePreferences.selected(isDark: false).id == light.id,
               "rapid dark switches preserve light selection")
        let runtime = GhosttyRuntime.controller
        let previousTheme = runtime.theme
        let previousScheme = runtime.effectiveColorScheme
        let sharedKey = TerminalThemePreferences.storageKey(isDark: true)
        let previousID = defaults.string(forKey: sharedKey)
        let directory = TerminalController.managedConfigDirectory
        let backup = directory.appendingPathExtension("theme-test-backup-" + UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: directory, to: backup)
            defer {
                try? FileManager.default.removeItem(at: directory)
                try! FileManager.default.moveItem(at: backup, to: directory)
            }
            try Data("blocked".utf8).write(to: directory)
            expect(!prefs.select(otherDark.id, isDark: true), "engine write failure is reported")
            expect(!prefs.reset(), "failed reset leaves both selections intact")
            expect(runtime.theme == previousTheme && runtime.effectiveColorScheme == previousScheme,
                   "failed transaction preserves engine palette and scheme")
            expect(defaults.string(forKey: sharedKey) == previousID && prefs.error != nil,
                   "failure does not persist selection or show it as active")
            expect(TerminalThemePreferences.selected(isDark: false).id == light.id,
                   "failed reset preserves inactive appearance")
        } catch { expect(false, "failed to set up isolated failure case: " + error.localizedDescription) }
        expect(prefs.select(dark.id) && prefs.error == nil, "recovery clears error")
        expect(!prefs.select("ghostty:missing"), "unknown choice is rejected")
        expect(defaults.string(forKey: sharedKey) == previousID, "invalid choices preserve preference")
        expect(prefs.select(otherLight.id, isDark: false), "configure inactive appearance")
        check(dark, uiDark: true)
        switchAppearance(false)
        check(otherLight, uiDark: false)
        var importPlan = GhosttyImportPlan(newSettings: TerminalSettings.load())
        importPlan.theme.light = GhosttyThemeSlotPlan(name: "Ayu Light", currentName: "Default")
        importPlan.theme.dark = GhosttyThemeSlotPlan(name: "Dracula", currentName: "Default")
        GhosttyConfigImport.applyPlan(importPlan)
        GhosttyConfigImport.undoLastImport()
        expect(TerminalThemePreferences.selected(isDark: false).id == otherLight.id
               && TerminalThemePreferences.selected(isDark: true).id == dark.id,
               "config import and undo preserve the shared theme pair")
        defaults.set(dark.id, forKey: "appearance.terminalTheme.local")
        expect(prefs.reset(), "reset both shared appearances")
        for isDark in [false, true] {
            expect(TerminalThemePreferences.selected(isDark: isDark).isDefault,
                   "reset clears both appearances without reviving legacy choice")
        }
        check(.system, uiDark: false)
        defaults.synchronize()
        expect(defaults.string(forKey: TerminalThemePreferences.storageKey(isDark: true)) == TerminalThemeDescriptor.defaultID,
               "shared reset persists")
        switchAppearance(true)
        check(.system, uiDark: true)
        print("PASS terminal themes: 819 palettes, legacy preservation, shared appearance pair, live switching, retained buffers, failure and resets")
    }
}
