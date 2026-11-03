import AppKit
import Combine
import GhosttyTerminal
import GhosttyTheme
import ObjectiveC
@testable import GooseAgent

/// 完整预设、原生窗口与两个无进程终端；不启动 shell 或 SSH。
@main
enum FamilyAppearanceTests {
    @MainActor static func main() {
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
        let driver = AppearanceDriver.shared
        driver.reapply()
        let lightChrome = WindowChrome.resolve(isDark: false)
        let darkChrome = WindowChrome.resolve(isDark: true)
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
        func check(_ uiDark: Bool, _ terminalDark: Bool, _ context: String) {
            drain()
            expect(driver.interfaceIsDark == uiDark && driver.terminalIsDark == terminalDark, context + ": driver states")
            let expectedChrome = AppTheme.stored() == .mintCandy
                ? (uiDark ? darkChrome : lightChrome) : WindowChrome(isDark: uiDark, preset: AppTheme.stored())
            expect(WindowChrome.resolve(isDark: uiDark) == expectedChrome, context + ": selected preset palette")
            for (index, target) in TerminalThemeTarget.allCases.enumerated() {
                let runtime = GhosttyRuntime.controller(for: target)
                let definition = AppTheme.terminalDefinition(isDark: terminalDark)
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
        check(false, false, "light preset applies to both existing surfaces")
        expect(GhosttyRuntime.controller(for: .local) !== GhosttyRuntime.controller(for: .remote), "connection types retain separate controllers")
        let legacyKeys = [TerminalAppearance.lightThemeKey, TerminalAppearance.darkThemeKey, TerminalAppearance.legacyThemeKey]
        let legacyValues = legacyKeys.map { defaults.string(forKey: $0) }
        for isDark in [true, false, true] {
            defaults.set(isDark ? "dark" : "light", forKey: TerminalAppearance.storageKey)
            driver.reapply()
            check(isDark, isDark, "mode changes the whole app without replacing sessions")
        }
        for preset in AppThemePreset.allCases + AppThemePreset.allCases.reversed() + [.mintCandy] {
            driver.selectPreset(preset)
            expect(AppTheme.stored() == preset && driver.preset == preset, "preset choice persists and publishes")
            expect(ApplicationIcon.stored() == preset.icon, "changing appearance selects its paired icon")
            for isDark in [false, true] {
                defaults.set(isDark ? "dark" : "light", forKey: TerminalAppearance.storageKey)
                driver.reapply()
                check(isDark, isDark, "preset switches preserve native sessions in both modes")
            }
        }
        for icon in ApplicationIcon.allCases {
            defaults.set(icon.rawValue, forKey: ApplicationIcon.storageKey)
            defaults.set(icon.rawValue, forKey: SharedPalette.storageKey)
            defaults.set(icon.rawValue, forKey: LocalPalette.storageKey)
            defaults.set(icon.rawValue, forKey: RemotePalette.storageKey)
            driver.reapply()
            GhosttyRuntime.applySelectedThemes()
            check(true, true, "icons and legacy colors cannot change the preset")
        }
        defaults.set("background = #ff0000\nforeground = #000000\npalette = 2=#0000ff\ncursor-color = #ff0000\nselection-background = #ff0000\ntheme = Dracula\nfont-feature = ss01\n", forKey: TerminalSettings.customConfigKey)
        defaults.set(17.0, forKey: TerminalSettings.fontSizeKey)
        GhosttyRuntime.applyTerminalSettings()
        for target in TerminalThemeTarget.allCases {
            let rendered = GhosttyRuntime.controller(for: target).terminalConfiguration.rendered
            expect(rendered.contains("font-size = 17") && rendered.contains("font-feature = ss01"), "non-color custom settings still apply")
            expect(!rendered.contains("#ff0000") && !rendered.contains("Dracula") && !rendered.contains("2=#0000ff"), "custom colors never reach either engine")
        }
        expect(TerminalConfigDiagnostics.shared.skippedLines.count == 6, "advanced page reports every ignored color line")
        check(true, true, "blocked custom colors preserve preset and buffer")
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
        driver.selectPreset(.cocoaMilkTea)
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
        check(true, true, "settings navigation and closing preserve appearance")
        for legacyStyle in ["classic", "transparent", "automatic", "unknown"] {
            defaults.set(legacyStyle, forKey: "appearance.shellStyle")
            driver.reapply()
            let isTransparent = !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            expect(driver.isShellTransparent == isTransparent, "legacy style cannot disable the material")
            for target in TerminalThemeTarget.allCases {
                let rendered = GhosttyRuntime.controller(for: target).terminalConfiguration.rendered
                expect(rendered.contains(isTransparent ? "background-opacity = 0.96" : "background-opacity = 1"), "preset surface opacity reaches both engines")
            }
            check(true, true, "legacy style preserves sessions")
        }
        let backdrop = ShellBackdropView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        expect(backdrop.isOpaque, "wallpaper backing must block other windows instead of sampling them")
        let wallpaperMaterial = backdrop.subviews.compactMap { $0 as? NSVisualEffectView }.first
        expect(wallpaperMaterial?.blendingMode == .withinWindow,
               "material must blur the wallpaper supplied inside the window")
        expect(wallpaperMaterial?.state == .active, "wallpaper tint remains visible when the window loses focus")
        let shellWindow = NSWindow(contentRect: backdrop.bounds, styleMask: [], backing: .buffered, defer: false)
        shellWindow.contentView = backdrop
        for isTransparent in [true, false, true] {
            backdrop.isTransparent = isTransparent
            backdrop.applyStyle()
            expect(shellWindow.isOpaque == !isTransparent, "shell switch updates native window compositing")
            expect(shellWindow.backgroundColor.alphaComponent == (isTransparent ? 0 : 1), "native window backing does not block transparency")
            expect(wallpaperMaterial?.isHidden == !isTransparent, "reduce transparency hides the wallpaper material")
        }
        let wallpaperScreen = CGRect(x: -1920, y: 120, width: 1920, height: 1080)
        let squareWallpaper = CGSize(width: 1000, height: 1000)
        expect(DesktopWallpaperLayout.imageFrame(imageSize: squareWallpaper, screenFrame: wallpaperScreen,
            scaling: .scaleProportionallyUpOrDown, allowsClipping: true) == CGRect(x: -1920, y: -300, width: 1920, height: 1920),
               "fill wallpaper crops centrally and preserves the external screen origin")
        expect(DesktopWallpaperLayout.imageFrame(imageSize: squareWallpaper, screenFrame: wallpaperScreen,
            scaling: .scaleProportionallyUpOrDown, allowsClipping: false) == CGRect(x: -1500, y: 120, width: 1080, height: 1080),
               "fit wallpaper preserves desktop margins")
        expect(DesktopWallpaperLayout.imageFrame(imageSize: squareWallpaper, screenFrame: wallpaperScreen,
            scaling: .scaleAxesIndependently, allowsClipping: true) == wallpaperScreen, "stretch follows the desktop setting")
        expect(DesktopWallpaperLayout.imageFrame(imageSize: squareWallpaper, screenFrame: wallpaperScreen,
            scaling: .scaleNone, allowsClipping: false) == CGRect(x: -1460, y: 160, width: 1000, height: 1000),
               "center wallpaper keeps its original size")
        let content = CGRect(x: 80, y: 40, width: 400, height: 300)
        expect(ShellLayout.contentFrame(content, isFloating: false) == content, "accessibility fallback retains existing terminal geometry")
        let floating = ShellLayout.contentFrame(content, isFloating: true)
        expect(floating == content, "floating content fills its pane without extra outer spacing")
        expect(ShellLayout.contentFrame(CGRect(x: 0, y: 0, width: 1, height: 1), isFloating: true).width == 1, "collapsed geometry never produces a negative terminal size")
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
        check(false, false, "follow system light switches every surface")
        systemDark = true
        driver.reapply()
        check(true, true, "follow system dark switches every surface")
        var plan = GhosttyImportPlan(newSettings: TerminalSettings.load())
        plan.newSettings.fontSize = 19
        plan.theme.light = GhosttyThemeSlotPlan(name: "Ayu Light", currentName: "GitHub Light Default")
        plan.theme.dark = GhosttyThemeSlotPlan(name: "TokyoNight", currentName: "GitHub Dark Default")
        GhosttyConfigImport.applyPlan(plan)
        expect(TerminalSettings.load().fontSize == 19, "import still applies terminal behavior")
        expect(legacyKeys.map { defaults.string(forKey: $0) } == legacyValues, "even an old import plan cannot overwrite saved theme preferences")
        check(true, true, "import preserves preset colors and sessions")
        GhosttyConfigImport.undoLastImport()
        expect(TerminalSettings.load().fontSize == 17, "undo restores previous terminal settings")
        check(true, true, "undo preserves preset colors and sessions")
        expect(legacyKeys.map { defaults.string(forKey: $0) } == legacyValues, "old Ghostty preferences remain available for rollback")
        expect(defaults.string(forKey: "sidebar.material") == "liquidGlass", "obsolete preferences are retained")
        print("FamilyAppearanceTests passed: preset modes, legacy preference preservation, blocked overrides, import/undo, preset-owned icon, settings navigation, transparency fallback, two native surfaces and retained buffers")
    }

    @MainActor static func checkSettingsPages(in window: NSWindow) {
        let pages = ["appearance", "font", "terminal", "shortcuts", "systemIntegration", "advanced", "about"]
        for size in [SettingsLayout.windowMinimumSize, CGSize(width: 1200, height: 800), CGSize(width: 1800, height: 1000)] {
            window.setContentSize(size)
            for page in pages {
                for _ in 0..<5 { drain() }
                let navigationID = "settings.navigation." + page
                guard let button = accessibilityElements(window).first(where: {
                    accessibilityValue($0, "accessibilityIdentifier") as? String == navigationID
                }) else { expect(false, "settings category exists: " + page); return }
                let selector = NSSelectorFromString("accessibilityPerformPress")
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                expect(unsafeBitCast(button.method(for: selector), to: Press.self)(button, selector),
                       "settings category activates: " + page)
                for _ in 0..<5 { drain() }
                let identifiers = accessibilityElements(window).compactMap {
                    accessibilityValue($0, "accessibilityIdentifier") as? String
                }
                expect(Set(identifiers.filter { $0.hasPrefix("settings.section.") }) == ["settings.section." + page],
                       "only the selected page heading is exposed: " + page)
                expect(Set(identifiers.filter { $0.hasPrefix("settings.content.") }) == ["settings.content." + page],
                       "only the selected page scroll area is exposed: " + page)
                if page == "appearance" {
                    expect(identifiers.contains("settings.preset.identity"), "appearance includes the linked preset icon")
                    expect(Set(identifiers.filter { $0.hasPrefix("settings.preset.choice.") })
                           == Set(AppThemePreset.allCases.map { "settings.preset.choice." + $0.id }),
                           "every completed preset is directly selectable in the theme row")
                    expect(!identifiers.contains("settings.preset.picker"), "preset choices are visible without opening a menu")
                    expect(!identifiers.contains("settings.navigation.appIcon"), "icons cannot be selected separately")
                    expect(identifiers.contains("settings.preset.light") && identifiers.contains("settings.preset.dark"),
                           "appearance shows both matching preset samples")
                    expect(!identifiers.contains("settings.appearance.preview.save"), "no external theme transaction remains")
                }
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
        print("CHECKED: all seven independent settings pages at minimum, common and large window sizes; hidden pages excluded from accessibility; preset appearance retained")
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
