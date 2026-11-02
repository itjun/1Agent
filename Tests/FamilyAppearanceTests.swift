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
        checkLegacyPaletteIgnored()
        let suite = "oneagent.family.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let getter = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(getter, imp_implementationWithBlock(block))
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        defaults.set("liquidGlass", forKey: "sidebar.material")
        defaults.set("light", forKey: TerminalAppearance.storageKey)
        defaults.set("GitHub Light Default", forKey: TerminalAppearance.lightThemeKey)
        defaults.set("GitHub Dark Default", forKey: TerminalAppearance.darkThemeKey)
        defaults.set("legacy-custom-theme", forKey: TerminalAppearance.legacyThemeKey)
        TerminalThemeChoice.migrateIfNeeded()
        expect(TerminalThemeChoice.storedLight() == .slotDefault(dark: false), "migration restores the shared light theme")
        expect(TerminalThemeChoice.storedDark() == .slotDefault(dark: true), "migration restores the shared dark theme")
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

        func check(_ uiDark: Bool, _ terminalDark: Bool, _ context: String) {
            drain()
            expect(driver.interfaceIsDark == uiDark && driver.terminalIsDark == terminalDark, context + ": driver states")
            expect(WindowChrome.resolve(isDark: uiDark) == (uiDark ? darkChrome : lightChrome), context + ": fixed palette")
            for (index, target) in TerminalThemeTarget.allCases.enumerated() {
                let runtime = GhosttyRuntime.controller(for: target)
                let choice = terminalDark ? preview.effectiveDark() : preview.effectiveLight()
                let definition = choice.definition
                let value = Int(definition.background, radix: 16)!
                let expectedBackground = TerminalColor(red: UInt8((value >> 16) & 255), green: UInt8((value >> 8) & 255), blue: UInt8(value & 255))
                expect(runtime.backgroundColor == expectedBackground, context + ": actual engine background for " + target.rawValue)
                expect((runtime.effectiveColorScheme == .dark) == terminalDark, context + ": shared engine scheme")
                expect((windows[index].effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) == uiDark,
                       context + ": window chrome")
                expect((views[index].effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) == terminalDark,
                       context + ": native terminal appearance")
                expect(windows[index].contentView === views[index], context + ": stable view identity")
                expect(sessions[index].readScreenText()?.text.contains("family-session-marker") == true, context + ": retained buffer")
            }
        }
        check(false, false, "initial independent palettes")
        expect(GhosttyRuntime.controller(for: .local) !== GhosttyRuntime.controller(for: .remote), "connection types own distinct controllers")
        expect(GhosttyRuntime.controller(for: .local).backgroundColor == GhosttyRuntime.controller(for: .remote).backgroundColor,
               "the same terminal theme has the same colors regardless of connection appearance")
        preview.show(darkTheme)
        check(false, true, "dark preview applies to local and remote")
        expect(NSDictionary(dictionary: defaults.persistentDomain(forName: suite)!).isEqual(to: saved), "preview never persists preferences")
        preview.show(lightTheme)
        check(false, false, "light preview applies to both and preserves the dark draft")
        expect(preview.light?.name == lightTheme.name && preview.dark?.name == darkTheme.name, "both shared slots retain their drafts")
        preview.cancel()
        check(false, false, "cancel restores both saved slots")
        preview.show(darkTheme)
        preview.save()
        check(false, false, "saving opposite slot returns to light")
        expect(defaults.string(forKey: TerminalAppearance.darkThemeKey) == darkTheme.name, "save writes the shared dark slot")
        expect(TerminalThemeChoice.storedLight() == .slotDefault(dark: false), "saving dark preserves the shared light theme")
        TerminalThemeChoice.migrateIfNeeded()
        expect(defaults.string(forKey: TerminalAppearance.darkThemeKey) == darkTheme.name, "migration never resets a saved shared theme")
        defaults.set("dark", forKey: TerminalAppearance.storageKey)
        driver.reapply()
        preview.show(lightTheme)
        check(true, false, "shared light preview in dark UI")
        let settingsModel = AppModel()
        let state = settingsModel.mainWindow
        state.section = .files
        state.presentation.filesVisible = true
        let savedPresentation = state.presentation
        MainWindowManager.shared.show(state, model: settingsModel)
        let settingsOwner = MainWindowManager.shared.window(for: state)!
        settingsOwner.setContentSize(MainWindowFrame.minimumSize)
        for _ in 0..<5 { drain() }
        let savedFrame = settingsOwner.frame
        settingsModel.showSettings()
        let settingsWindow = SettingsWindowController.shared.window!
        expect(settingsModel.showingSettings && settingsWindow !== settingsOwner
               && settingsWindow.identifier == SettingsWindowController.windowID,
               "settings opens in its own native window")
        expect(settingsOwner.isVisible && settingsOwner.frame == savedFrame,
               "opening settings leaves the main window visible and unchanged")
        let mainIdentifiers = accessibilityElements(settingsOwner).compactMap {
            accessibilityValue($0, "accessibilityIdentifier") as? String
        }
        expect(!mainIdentifiers.contains(where: { $0.hasPrefix("settings.") }),
               "settings is no longer embedded in the main workspace")
        settingsModel.showSettings()
        expect(SettingsWindowController.shared.window === settingsWindow
               && NSApp.windows.filter { $0.identifier == SettingsWindowController.windowID }.count == 1,
               "opening settings again reuses one window")
        checkSettingsPages(in: settingsWindow)
        expect(settingsOwner.isVisible && settingsOwner.frame == savedFrame,
               "resizing settings never resizes or hides the workspace: visible=\(settingsOwner.isVisible), before=\(savedFrame), after=\(settingsOwner.frame)")
        settingsModel.dismissSettings()
        expect(!settingsModel.showingSettings && state.section == .files && state.presentation == savedPresentation,
               "closing settings preserves the files workspace")
        expect(settingsOwner.frame == savedFrame, "settings does not resize the main window")
        settingsModel.showSettings()
        expect(settingsModel.showingSettings && SettingsWindowController.shared.window === settingsWindow,
               "settings reopens the retained window")
        let reopenedIdentifiers = accessibilityElements(settingsWindow).compactMap {
            accessibilityValue($0, "accessibilityIdentifier") as? String
        }
        expect(reopenedIdentifiers.contains("settings.section.about"), "reopening settings retains the selected page")
        expect(!reopenedIdentifiers.contains("settings.back"), "standalone settings uses native window closing")
        settingsModel.dismissSettings()
        expect(!settingsModel.showingSettings && settingsOwner.isVisible,
               "closing settings again leaves the main window open")
        check(true, true, "closing settings cancels preview")
        expect(TerminalThemeChoice.storedLight() == .slotDefault(dark: false), "closing settings does not save")
        preview.showDefaults()
        check(true, true, "restore defaults is a preview")
        expect(preview.effectiveDark() == .slotDefault(dark: true), "independent default theme sample applied")
        expect(!preview.previewedNames.joined().contains("follow-palette"), "preview summary never exposes a storage identifier")
        preview.cancel()
        expect(preview.effectiveDark().name == darkTheme.name, "cancel restores the shared dark theme")
        preview.show(lightTheme)
        let themeKeys = [TerminalAppearance.lightThemeKey, TerminalAppearance.darkThemeKey]
        let savedThemes = themeKeys.map { defaults.string(forKey: $0) }
        let backgrounds = TerminalThemeTarget.allCases.map { GhosttyRuntime.controller(for: $0).backgroundColor }
        for icon in ApplicationIcon.macaronIcons {
            defaults.set(icon.rawValue, forKey: ApplicationIcon.storageKey)
            defaults.set(icon.rawValue, forKey: "appearance.localPalette")
            defaults.set(icon.rawValue, forKey: "appearance.remotePalette")
            lightChrome = WindowChrome.resolve(isDark: false)
            darkChrome = WindowChrome.resolve(isDark: true)
            driver.reapply()
            check(true, false, "appearance color changes preserve terminal themes and buffers")
            expect(TerminalThemeTarget.allCases.map { GhosttyRuntime.controller(for: $0).backgroundColor } == backgrounds,
                   "actual terminal engine colors are unchanged by appearance colors")
            expect(preview.isActive && preview.effectiveLight().name == lightTheme.name,
                   "appearance colors preserve pending terminal previews")
        }
        expect(themeKeys.map { defaults.string(forKey: $0) } == savedThemes, "appearance colors never overwrite saved terminal theme slots")
        preview.cancel()
        check(true, true, "cancel restores saved themes after appearance changes")
        defaults.set(17.0, forKey: TerminalSettings.fontSizeKey)
        GhosttyRuntime.applyTerminalSettings()
        let localConfiguration = GhosttyRuntime.controller(for: .local).terminalConfiguration
        expect(localConfiguration == GhosttyRuntime.controller(for: .remote).terminalConfiguration, "font and terminal settings apply to both runtimes")
        expect(localConfiguration.rendered.contains("font-size = 17"), "shared font change reaches the engine")
        check(true, true, "shared settings preserve themes and buffers for both connection types")
        // 旧版任意外壳选择都归到同一种材质；终端主题、缓冲区保持原样。
        for legacyStyle in ["classic", "transparent", "automatic", "unknown"] {
            defaults.set(legacyStyle, forKey: "appearance.shellStyle")
            driver.reapply()
            for target in TerminalThemeTarget.allCases {
                let rendered = GhosttyRuntime.controller(for: target).terminalConfiguration.rendered
                expect(rendered.contains("background-opacity = 1"), "unified shell opacity reaches both terminal engines")
            }
            check(true, true, "legacy shell choices preserve both live sessions")
        }
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
        check(false, true, "system light with shared dark preview")
        systemDark = true
        driver.reapply()
        check(true, true, "system switches while preview remains")
        preview.show(lightTheme)
        check(true, false, "system dark with shared light preview")
        preview.cancel()
        check(true, true, "cancel follows current system")
        preview.show(lightTheme)
        preview.show(darkTheme)
        preview.save()
        expect(TerminalThemeChoice.storedLight().name == lightTheme.name && TerminalThemeChoice.storedDark().name == darkTheme.name,
               "saving both drafts persists the shared pair")
        check(true, true, "saving both drafts restores the system appearance for both runtimes")
        preview.showDefaults()
        preview.save()
        expect(preview.showsDefaults && !preview.isActive, "saving restored defaults commits both shared slots")
        check(true, true, "saved defaults apply to both runtimes")
        var plan = GhosttyImportPlan(newSettings: TerminalSettings.load())
        plan.theme.light = GhosttyThemeSlotPlan(name: lightTheme.name, currentName: TerminalThemeChoice.defaultLightName)
        plan.theme.dark = GhosttyThemeSlotPlan(name: darkTheme.name, currentName: TerminalThemeChoice.defaultDarkName)
        GhosttyConfigImport.applyPlan(plan)
        expect(TerminalThemeChoice.storedLight().name == lightTheme.name && TerminalThemeChoice.storedDark().name == darkTheme.name,
               "Ghostty import writes both shared theme slots")
        check(true, true, "imported themes apply to both runtimes")
        GhosttyConfigImport.undoLastImport()
        expect(preview.showsDefaults, "undo import restores the shared pair")
        check(true, true, "undo import updates both runtimes")
        defaults.set(["values": [
            "appearance.terminalTheme.local.light": "Ayu Light",
            "appearance.terminalTheme.local.dark": "TokyoNight",
            "appearance.terminalTheme.remote.dark": "GitHub Dark Default",
            TerminalAppearance.lightThemeKey: "GitHub Light Default",
            TerminalAppearance.darkThemeKey: "GitHub Dark Default",
        ], "absent": []] as [String: Any], forKey: GhosttyConfigImport.backupKey)
        GhosttyConfigImport.undoLastImport()
        expect(TerminalThemeChoice.storedLight().name == "Ayu Light" && TerminalThemeChoice.storedDark().name == "TokyoNight",
               "undoing an older import merges its restored local choices into the shared slots")
        check(true, true, "legacy import undo updates both runtimes and preserves buffers")
        expect(defaults.string(forKey: "sidebar.material") == "liquidGlass", "obsolete preference is ignored, not erased")
        print("FamilyAppearanceTests passed: shared terminal themes independent of appearance colors, legacy theme recovery, ignored legacy palettes, preview/save/cancel/close/defaults/system, shared settings, two process-free native surfaces and buffer preservation")
    }

    static func checkIndependentTerminalThemes() {
        let suite = "oneagent.family.shared.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Ayu Light", forKey: TerminalAppearance.lightThemeKey)
        defaults.set("TokyoNight", forKey: TerminalAppearance.darkThemeKey)
        for target in ["local", "remote"] {
            for slot in ["light", "dark"] {
                defaults.set("follow-palette", forKey: "appearance.terminalTheme.\(target).\(slot)")
            }
        }
        TerminalThemeChoice.migrateIfNeeded(defaults: defaults)
        expect(TerminalThemeChoice(raw: "follow-palette") == nil, "terminal themes never follow icon colors")
        expect(TerminalThemeChoice.storedLight(defaults: defaults).name == "Ayu Light", "restore the previous shared light theme")
        expect(TerminalThemeChoice.storedDark(defaults: defaults).name == "TokyoNight", "restore the previous shared dark theme")
        let lightConfiguration = TerminalThemeChoice.storedLight(defaults: defaults).terminalConfiguration()
        let darkConfiguration = TerminalThemeChoice.storedDark(defaults: defaults).terminalConfiguration()
        for icon in ApplicationIcon.macaronIcons {
            defaults.set(icon.rawValue, forKey: ApplicationIcon.storageKey)
            defaults.set(icon.rawValue, forKey: "appearance.localPalette")
            defaults.set(icon.rawValue, forKey: "appearance.remotePalette")
            TerminalThemeChoice.migrateIfNeeded(defaults: defaults)
            expect(TerminalThemeChoice.storedLight(defaults: defaults).terminalConfiguration() == lightConfiguration
                   && TerminalThemeChoice.storedDark(defaults: defaults).terminalConfiguration() == darkConfiguration,
                   "icon and appearance colors never change terminal colors, cursor, selection or ANSI palette")
        }

        defaults.removePersistentDomain(forName: suite)
        defaults.set("Ayu Light", forKey: "appearance.terminalTheme.local.light")
        defaults.set("TokyoNight", forKey: "appearance.terminalTheme.local.dark")
        defaults.set("GitHub Light Default", forKey: "appearance.terminalTheme.remote.light")
        defaults.set("GitHub Dark Default", forKey: "appearance.terminalTheme.remote.dark")
        defaults.set("GitHub Light Default", forKey: TerminalAppearance.lightThemeKey)
        defaults.set("GitHub Dark Default", forKey: TerminalAppearance.darkThemeKey)
        TerminalThemeChoice.migrateIfNeeded(defaults: defaults)
        expect(TerminalThemeChoice.storedLight(defaults: defaults).name == "Ayu Light"
               && TerminalThemeChoice.storedDark(defaults: defaults).name == "TokyoNight",
               "current local choices take priority over remote choices and stale shared slots")
        expect(defaults.string(forKey: "appearance.terminalTheme.remote.dark") == "GitHub Dark Default",
               "old connection preferences remain available for recovery")
        defaults.set("GitHub Dark Default", forKey: TerminalAppearance.darkThemeKey)
        TerminalThemeChoice.migrateIfNeeded(defaults: defaults)
        expect(TerminalThemeChoice.storedDark(defaults: defaults).name == "GitHub Dark Default",
               "repeated migration never replaces a newly saved shared choice")

        defaults.removePersistentDomain(forName: suite)
        defaults.set("TokyoNight", forKey: "appearance.terminalTheme.local.light")
        defaults.set("unknown-theme", forKey: "appearance.terminalTheme.local.dark")
        defaults.set("Ayu Light", forKey: "appearance.terminalTheme.remote.light")
        defaults.set("TokyoNight", forKey: "appearance.terminalTheme.remote.dark")
        TerminalThemeChoice.migrateIfNeeded(defaults: defaults)
        expect(TerminalThemeChoice.storedLight(defaults: defaults).name == "Ayu Light"
               && TerminalThemeChoice.storedDark(defaults: defaults).name == "TokyoNight",
               "invalid or mismatched local themes fall back to valid remote choices")

        defaults.removePersistentDomain(forName: suite)
        defaults.set("TokyoNight", forKey: TerminalAppearance.legacyThemeKey)
        TerminalThemeChoice.migrateIfNeeded(defaults: defaults)
        expect(TerminalThemeChoice.storedLight(defaults: defaults) == .slotDefault(dark: false)
               && TerminalThemeChoice.storedDark(defaults: defaults).name == "TokyoNight",
               "a legacy single theme populates only its matching appearance slot")

        defaults.removePersistentDomain(forName: suite)
        TerminalThemeChoice.migrateIfNeeded(defaults: defaults)
        expect(TerminalThemeChoice.storedLight(defaults: defaults) == .slotDefault(dark: false)
               && TerminalThemeChoice.storedDark(defaults: defaults) == .slotDefault(dark: true),
               "a fresh install receives the default shared pair")
    }

    static func checkLegacyPaletteIgnored() {
        let suite = "oneagent.native-migration.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ApplicationIcon.mintCandy.rawValue, forKey: "appearance.localPalette")
        defaults.set(ApplicationIcon.vanillaCustard.rawValue, forKey: "appearance.remotePalette")
        defaults.set("GitHub Dark Default", forKey: TerminalAppearance.darkThemeKey)
        TerminalThemeChoice.migrateIfNeeded(defaults: defaults)
        expect(defaults.string(forKey: TerminalAppearance.darkThemeKey) == "GitHub Dark Default", "native migration preserves terminal themes")
        expect(WindowChrome(isDark: false, icon: .mintCandy) == WindowChrome(isDark: false, icon: .vanillaCustard), "icons no longer recolor application controls")
        let snapshot = defaults.persistentDomain(forName: suite)!
        TerminalThemeChoice.migrateIfNeeded(defaults: defaults)
        expect(NSDictionary(dictionary: defaults.persistentDomain(forName: suite)!).isEqual(to: snapshot), "migration is idempotent")
    }

    /// Exercise the production settings hierarchy with isolated preferences and no shell/SSH.
    @MainActor static func checkSettingsPages(in window: NSWindow) {
        let pages = ["appearance", "appIcon", "font", "terminal", "shortcuts", "systemIntegration", "advanced", "about"]
        for size in [SettingsLayout.windowMinimumSize, CGSize(width: 1200, height: 800), CGSize(width: 1800, height: 1000)] {
            window.setContentSize(size)
            for page in pages {
                for _ in 0..<5 { drain() }
                func outline(in view: NSView) -> NSOutlineView? {
                    if let list = view as? NSOutlineView { return list }
                    return view.subviews.compactMap { outline(in: $0) }.first
                }
                guard let list = window.contentView.flatMap({ outline(in: $0) }),
                      let row = pages.firstIndex(of: page) else {
                    expect(false, "native settings sidebar exists"); return
                }
                expect(list.numberOfRows == pages.count, "native sidebar exposes all settings categories")
                list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                for _ in 0..<5 { drain() }
                let identifiers = accessibilityElements(window).compactMap {
                    accessibilityValue($0, "accessibilityIdentifier") as? String
                }
                expect(Set(identifiers.filter { $0.hasPrefix("settings.section.") }) == ["settings.section." + page],
                       "only the selected page heading is exposed: " + page)
                expect(Set(identifiers.filter { $0.hasPrefix("settings.content.") }) == ["settings.content." + page],
                       "only the selected page scroll area is exposed: " + page)
                expect(ThemePreview.shared.isActive, "category switching retains theme preview")
                if let output = ProcessInfo.processInfo.environment["ONEAGENT_SETTINGS_QA_DIR"],
                   let view = window.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let directory = URL(fileURLWithPath: output, isDirectory: true)
                    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let file = directory.appendingPathComponent("\(page)-\(Int(size.width))x\(Int(size.height))-dark.png")
                    try! bitmap.representation(using: .png, properties: [:])!.write(to: file)
                }
            }
        }
        print("CHECKED: all eight independent settings pages at minimum, common and large window sizes; hidden pages excluded from accessibility; theme preview retained")
    }

    @MainActor static func accessibilityValue(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
    }

    @MainActor static func accessibilityElements(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let children = accessibilityValue(object, "accessibilityChildren") as? [NSObject] ?? []
            return [object] + children.flatMap(walk)
        }
        return walk(root)
    }

    @MainActor static func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
