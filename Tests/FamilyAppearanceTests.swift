import AppKit
import Combine
import GhosttyTerminal
import GhosttyTheme
import ObjectiveC
@testable import GooseAgent

/// Production driver, preview transactions and native in-memory surfaces. No shell or SSH.
@main
enum FamilyAppearanceTests {
    @MainActor static func main() {
        checkIndependentTerminalThemes()
        checkLocalPaletteMigration()
        checkFocusBorderContrast()
        let suite = "oneagent.family.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let getter = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(getter, imp_implementationWithBlock(block))
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        defaults.set("liquidGlass", forKey: "sidebar.material")
        defaults.set("light", forKey: TerminalAppearance.storageKey)
        defaults.set("GitHub Light Default", forKey: TerminalAppearance.lightThemeKey)
        defaults.set("GitHub Dark Default", forKey: TerminalAppearance.darkThemeKey)
        defaults.set("legacy-custom-theme", forKey: TerminalAppearance.legacyThemeKey)
        TerminalThemeChoice.migrateIfNeeded()
        expect(TerminalThemeChoice.storedLight() == .slotDefault(dark: false), "migration restores the local light theme")
        expect(TerminalThemeChoice.storedDark(for: .remote) == .slotDefault(dark: true), "migration restores the remote dark theme")
        expect(defaults.string(forKey: TerminalAppearance.lightThemeKey) == "GitHub Light Default", "migration preserves the previous light theme")
        expect(defaults.string(forKey: TerminalAppearance.darkThemeKey) == "GitHub Dark Default", "migration preserves the previous dark theme")
        expect(defaults.string(forKey: TerminalAppearance.legacyThemeKey) == "legacy-custom-theme", "migration preserves even unknown legacy values")
        let driver = AppearanceDriver.shared
        let preview = ThemePreview.shared
        driver.reapply()
        var lightChrome = WindowChrome.resolve(isDark: false)
        var darkChrome = WindowChrome.resolve(isDark: true)
        var windows: [NSWindow] = []
        var views: [SSHTerminalNSView] = []
        var sessions: [InMemoryTerminalSession] = []
        let sessionIDs = TerminalThemeTarget.allCases.map { "family-\($0.rawValue)-\(UUID().uuidString)" }
        defer { sessionIDs.forEach { SSHTerminalRegistry.destroy($0) } }
        for (index, target) in TerminalThemeTarget.allCases.enumerated() {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
            let view = SSHTerminalRegistry.view(for: sessionIDs[index]) { SSHTerminalNSView(frame: window.contentView!.bounds) }!
            view.sessionID = sessionIDs[index]
            view.themeTarget = target
            view.controller = GhosttyRuntime.controller(for: target)
            view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
            view.applyTerminalAppearance(dark: driver.terminalIsDark)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            windows.append(window); views.append(view); sessions.append(session)
        }
        let deadline = Date().addingTimeInterval(3)
        while sessions.contains(where: { !$0.hasAttachedSurface }), Date() < deadline { drain() }
        expect(sessions.allSatisfy(\.hasAttachedSurface), "two native surfaces attach without processes")
        for session in sessions {
            session.receive("family-session-marker\r\n中文输入保留\r\n")
            session.waitForPendingOutput()
        }
        let darkTheme = GhosttyThemeCatalog.allThemes.first { !$0.isLightBackground && $0.name != "GitHub Dark Default" }!
        let lightTheme = GhosttyThemeCatalog.allThemes.first { $0.isLightBackground && $0.name != "GitHub Light Default" }!
        let saved = defaults.persistentDomain(forName: suite)!

        func check(_ uiDark: Bool, _ localDark: Bool, _ remoteDark: Bool, _ context: String) {
            drain()
            expect(driver.interfaceIsDark == uiDark && driver.terminalIsDark == localDark, context + ": driver states")
            expect(WindowChrome.resolve(isDark: uiDark) == (uiDark ? darkChrome : lightChrome), context + ": fixed palette")
            for (index, target) in TerminalThemeTarget.allCases.enumerated() {
                let terminalDark = target == .local ? localDark : remoteDark
                let runtime = GhosttyRuntime.controller(for: target)
                let choice = terminalDark ? preview.effectiveDark(for: target) : preview.effectiveLight(for: target)
                let definition = choice.definition
                let value = Int(definition.background, radix: 16)!
                let expectedBackground = TerminalColor(red: UInt8((value >> 16) & 255), green: UInt8((value >> 8) & 255), blue: UInt8(value & 255))
                expect(runtime.backgroundColor == expectedBackground, context + ": actual engine background for " + target.rawValue)
                expect((runtime.effectiveColorScheme == .dark) == terminalDark, context + ": independent engine scheme")
                expect((windows[index].effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) == uiDark,
                       context + ": window chrome")
                expect((views[index].effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) == terminalDark,
                       context + ": native terminal appearance")
                expect(windows[index].contentView === views[index], context + ": stable view identity")
                expect(sessions[index].readScreenText()?.text.contains("family-session-marker") == true, context + ": retained buffer")
            }
        }
        check(false, false, false, "initial independent palettes")
        expect(GhosttyRuntime.controller(for: .local) !== GhosttyRuntime.controller(for: .remote), "connection types own distinct controllers")
        expect(GhosttyRuntime.controller(for: .local).backgroundColor == GhosttyRuntime.controller(for: .remote).backgroundColor,
               "the same terminal theme has the same colors regardless of connection appearance")
        preview.show(darkTheme, for: .local)
        check(false, true, false, "local dark preview leaves remote light")
        expect(NSDictionary(dictionary: defaults.persistentDomain(forName: suite)!).isEqual(to: saved), "preview never persists preferences")
        preview.show(lightTheme, for: .remote)
        check(false, true, false, "opposite previews coexist")
        preview.cancel()
        check(false, false, false, "cancel restores both saved slots")
        preview.show(darkTheme, for: .remote)
        preview.save()
        check(false, false, false, "saving opposite slot returns to light")
        let remoteDarkKey = TerminalAppearance.themeKey(for: .remote, dark: true)
        expect(defaults.string(forKey: remoteDarkKey) == darkTheme.name, "save writes only the remote dark slot")
        expect(TerminalThemeChoice.storedDark(for: .local) == .slotDefault(dark: true), "remote save preserves local theme")
        TerminalThemeChoice.migrateIfNeeded()
        expect(defaults.string(forKey: remoteDarkKey) == darkTheme.name, "migration never resets a saved connection theme")
        defaults.set("dark", forKey: TerminalAppearance.storageKey)
        driver.reapply()
        preview.show(lightTheme, for: .local)
        check(true, false, true, "local light preview in dark UI")
        SettingsWindowController.shared.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: windows[0]))
        check(true, true, true, "closing settings cancels preview")
        expect(TerminalThemeChoice.storedLight(for: .local) == .slotDefault(dark: false), "closing settings does not save")
        preview.showDefaults(for: .remote)
        check(true, true, true, "restore defaults is a preview")
        expect(preview.effectiveDark(for: .remote) == .slotDefault(dark: true), "independent default theme sample applied")
        expect(!preview.previewedNames.joined().contains("follow-palette"), "preview summary never exposes a storage identifier")
        preview.cancel()
        expect(preview.effectiveDark(for: .remote).name == darkTheme.name, "cancel restores chosen remote dark theme")
        preview.show(lightTheme, for: .local)
        let savedThemes = TerminalThemeTarget.allCases.flatMap { target in
            [false, true].map { TerminalAppearance.themeKey(for: target, dark: $0) }
        }.map { defaults.string(forKey: $0) }
        let backgrounds = TerminalThemeTarget.allCases.map { GhosttyRuntime.controller(for: $0).backgroundColor }
        for icon in ApplicationIcon.macaronIcons {
            defaults.set(icon.rawValue, forKey: ApplicationIcon.storageKey)
            defaults.set(icon.rawValue, forKey: LocalPalette.storageKey)
            defaults.set(icon.rawValue, forKey: RemotePalette.storageKey)
            lightChrome = WindowChrome.resolve(isDark: false)
            darkChrome = WindowChrome.resolve(isDark: true)
            driver.reapply()
            check(true, false, true, "appearance color changes preserve terminal themes and buffers")
            expect(TerminalThemeTarget.allCases.map { GhosttyRuntime.controller(for: $0).backgroundColor } == backgrounds,
                   "actual terminal engine colors are unchanged by appearance colors")
            expect(preview.isActive && preview.effectiveLight(for: .local).name == lightTheme.name,
                   "appearance colors preserve pending terminal previews")
        }
        expect(TerminalThemeTarget.allCases.flatMap { target in
            [false, true].map { defaults.string(forKey: TerminalAppearance.themeKey(for: target, dark: $0)) }
        } == savedThemes, "appearance colors never overwrite saved terminal theme slots")
        preview.cancel()
        check(true, true, true, "cancel restores saved themes after appearance changes")
        defaults.set(17.0, forKey: TerminalSettings.fontSizeKey)
        GhosttyRuntime.applyTerminalSettings()
        let localConfiguration = GhosttyRuntime.controller(for: .local).terminalConfiguration
        expect(localConfiguration == GhosttyRuntime.controller(for: .remote).terminalConfiguration, "font and terminal settings apply to both runtimes")
        expect(localConfiguration.rendered.contains("font-size = 17"), "shared font change reaches the engine")
        check(true, true, true, "shared settings preserve per-type themes and buffers")
        defaults.set("system", forKey: TerminalAppearance.storageKey)
        defaults.set("Dark", forKey: "AppleInterfaceStyle")
        // Override only this isolated UserDefaults object's global-domain read for system-mode cases.
        let method = class_getInstanceMethod(UserDefaults.self, #selector(UserDefaults.persistentDomain(forName:)))!
        let original = method_getImplementation(method)
        typealias DomainGetter = @convention(c) (AnyObject, Selector, NSString) -> NSDictionary?
        let originalGetter = unsafeBitCast(original, to: DomainGetter.self)
        var systemDark = false
        let domainBlock: @convention(block) (AnyObject, NSString) -> NSDictionary? = { object, name in
            if name as String == UserDefaults.globalDomain { return systemDark ? ["AppleInterfaceStyle": "Dark"] : [:] }
            return originalGetter(object, #selector(UserDefaults.persistentDomain(forName:)), name)
        }
        method_setImplementation(method, imp_implementationWithBlock(domainBlock))
        defer { method_setImplementation(method, original) }
        driver.reapply()
        preview.show(darkTheme)
        check(false, true, false, "system light with local dark preview")
        systemDark = true
        driver.reapply()
        check(true, true, true, "system switches while preview remains")
        preview.show(lightTheme)
        check(true, false, true, "system dark with local light preview")
        preview.cancel()
        check(true, true, true, "cancel follows current system")
        expect(defaults.string(forKey: "sidebar.material") == "liquidGlass", "obsolete preference is ignored, not erased")
        print("FamilyAppearanceTests passed: independent terminal themes and appearance colors, legacy theme recovery, ten-palette focus contrast, icon-to-local migration, preview/save/cancel/close/defaults/system, shared settings, two process-free native surfaces and buffer preservation")
    }

    static func checkIndependentTerminalThemes() {
        let suite = "oneagent.family.independent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Ayu Light", forKey: TerminalAppearance.lightThemeKey)
        defaults.set("TokyoNight", forKey: TerminalAppearance.darkThemeKey)
        defaults.set(true, forKey: "appearance.terminalTheme.connectionDefaults.v1")
        for target in ["local", "remote"] {
            for isDark in [false, true] {
                defaults.set("follow-palette", forKey: "appearance.terminalTheme.\(target).\(isDark ? "dark" : "light")")
            }
        }
        TerminalThemeChoice.migrateIfNeeded(defaults: defaults)
        expect(TerminalThemeChoice(raw: "follow-palette") == nil, "terminal themes never follow icon colors")
        for target in ["local", "remote"] {
            for isDark in [false, true] {
                let key = "appearance.terminalTheme.\(target).\(isDark ? "dark" : "light")"
                let expected = isDark ? "TokyoNight" : "Ayu Light"
                expect(defaults.string(forKey: key) == expected, "restore previous terminal theme instead of following icon colors")
                let configuration = TerminalThemeChoice(raw: expected)!.definition.terminalConfiguration()
                for icon in ApplicationIcon.macaronIcons {
                    defaults.set(icon.rawValue, forKey: ApplicationIcon.storageKey)
                    defaults.set(icon.rawValue, forKey: "appearance.localPalette")
                    defaults.set(icon.rawValue, forKey: RemotePalette.storageKey)
                    TerminalThemeChoice.migrateIfNeeded(defaults: defaults)
                    let choice = TerminalThemeChoice(raw: defaults.string(forKey: key))!
                    expect(choice.definition.terminalConfiguration() == configuration,
                           "icon and appearance colors never change terminal colors, cursor, selection or ANSI palette")
                }
            }
        }
        defaults.set("GitHub Dark Default", forKey: "appearance.terminalTheme.remote.dark")
        TerminalThemeChoice.migrateIfNeeded(defaults: defaults)
        expect(defaults.string(forKey: "appearance.terminalTheme.remote.dark") == "GitHub Dark Default",
               "recovery preserves an explicitly selected connection theme")
    }

    static func checkLocalPaletteMigration() {
        let suite = "oneagent.family.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for isPreviouslyMigrated in [false, true] {
            for icon in ApplicationIcon.macaronIcons {
                defaults.removePersistentDomain(forName: suite)
                defaults.set(icon.rawValue, forKey: ApplicationIcon.storageKey)
                defaults.set(ApplicationIcon.vanillaCustard.rawValue, forKey: RemotePalette.storageKey)
                defaults.set(isPreviouslyMigrated, forKey: TerminalThemeChoice.migrationKey)
                TerminalThemeChoice.migrateIfNeeded(defaults: defaults)
                expect(LocalPalette.stored(defaults: defaults) == icon, "saved icon becomes the missing local palette, including previously migrated installations")
                expect(ApplicationIcon.stored(defaults: defaults) == icon, "palette migration preserves the app icon")
                expect(RemotePalette.stored(defaults: defaults) == .vanillaCustard, "local migration preserves remote palette")
            }
        }
        for savedIcon in [nil, ApplicationIcon.original.rawValue, "unknown-icon"] as [String?] {
            defaults.removePersistentDomain(forName: suite)
            if let savedIcon { defaults.set(savedIcon, forKey: ApplicationIcon.storageKey) }
            TerminalThemeChoice.migrateIfNeeded(defaults: defaults)
            expect(LocalPalette.stored(defaults: defaults) == LocalPalette.defaultPalette, "original, missing and unknown icons resolve to default local palette")
            expect(defaults.string(forKey: ApplicationIcon.storageKey) == savedIcon, "fallback does not rewrite saved icon data")
        }
        for isPreviouslyMigrated in [false, true] {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(ApplicationIcon.strawberryCream.rawValue, forKey: ApplicationIcon.storageKey)
            defaults.set(ApplicationIcon.mintCandy.rawValue, forKey: LocalPalette.storageKey)
            defaults.set(isPreviouslyMigrated, forKey: TerminalThemeChoice.migrationKey)
            let darkKey = TerminalAppearance.themeKey(for: .local, dark: true)
            defaults.set("GitHub Dark Default", forKey: darkKey)
            TerminalThemeChoice.migrateIfNeeded(defaults: defaults)
            expect(LocalPalette.stored(defaults: defaults) == .mintCandy, "an existing independent local choice is never replaced by the app icon")
            expect(defaults.string(forKey: darkKey) == "GitHub Dark Default", "palette migration preserves an existing catalog theme")
            let snapshot = defaults.persistentDomain(forName: suite)!
            TerminalThemeChoice.migrateIfNeeded(defaults: defaults)
            expect(NSDictionary(dictionary: defaults.persistentDomain(forName: suite)!).isEqual(to: snapshot), "repeated migration does not change persisted preferences")
        }
    }

    static func checkFocusBorderContrast() {
        let suite = "oneagent.family.border.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalogNames = ["GitHub Light Default", "GitHub Dark Default", "Gruvbox Light", "Hot Dog Stand"]
        let catalogChoices = catalogNames.map { name -> TerminalThemeChoice in
            guard let choice = TerminalThemeChoice(raw: name) else {
                preconditionFailure("Missing bundled theme fixture: \(name)")
            }
            return choice
        }
        for target in TerminalThemeTarget.allCases {
            let key = target == .local ? LocalPalette.storageKey : RemotePalette.storageKey
            for icon in ApplicationIcon.macaronIcons {
                defaults.set(icon.rawValue, forKey: key)
                for choice in catalogChoices {
                    let background = RGBColor(ghosttyHex: choice.definition.background)!
                    let border = choice.focusBorderColor(for: target, defaults: defaults)
                    expect(border.contrastRatio(with: background) >= 3,
                           "Focus border must contrast with the actual background: \(target.rawValue), \(icon.rawValue), \(choice.name)")
                }
            }
        }
    }

    @MainActor static func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
