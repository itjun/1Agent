import AppKit
import Combine
import GhosttyTerminal
import ObjectiveC
import QuartzCore
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
        checkDiffReading()
        var windows: [NSWindow] = []
        var views: [SSHTerminalNSView] = []
        var sessions: [InMemoryTerminalSession] = []
        let sessionIDs = ["local", "remote"].map { "family-\($0)-\(UUID().uuidString)" }
        defer { sessionIDs.forEach { SSHTerminalRegistry.destroy($0) } }
        for index in sessionIDs.indices {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
            let view = SSHTerminalRegistry.view(for: sessionIDs[index]) { SSHTerminalNSView(frame: window.contentView!.bounds) }!
            view.sessionID = sessionIDs[index]
            view.controller = GhosttyRuntime.controller
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
            let expectedChrome = WindowChrome(isDark: uiDark, preset: AppTheme.stored())
            expect(WindowChrome.resolve(isDark: uiDark) == expectedChrome, context + ": selected preset palette")
            for (index, target) in ["local", "remote"].enumerated() {
                let runtime = GhosttyRuntime.controller
                let definition = AppTheme.colors(isDark: terminalDark)
                let value = Int(definition.background, radix: 16)!
                let expectedBackground = TerminalColor(red: UInt8((value >> 16) & 255), green: UInt8((value >> 8) & 255), blue: UInt8(value & 255))
                expect(runtime.backgroundColor == expectedBackground, context + ": actual engine background for " + target)
                let rendered = (terminalDark ? runtime.theme.dark : runtime.theme.light).rendered
                let colors = AppTheme.colors(isDark: terminalDark)
                expect(rendered.contains("selection-background = #" + colors.selection),
                       context + ": terminal text selection follows the theme")
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
        expect(views.allSatisfy { $0.controller === GhosttyRuntime.controller }, "all terminals share one theme controller")
        let legacyKeys = [TerminalAppearance.lightThemeKey, TerminalAppearance.darkThemeKey, TerminalAppearance.legacyThemeKey]
        let legacyValues = legacyKeys.map { defaults.string(forKey: $0) }
        for isDark in [true, false, true] {
            defaults.set(isDark ? "dark" : "light", forKey: TerminalAppearance.storageKey)
            driver.reapply()
            check(isDark, isDark, "mode changes the whole app without replacing sessions")
        }
        for preset in AppThemePreset.allCases + AppThemePreset.allCases.reversed() {
            driver.selectPreset(preset)
            expect(AppTheme.stored() == preset && driver.preset == preset, "preset choice persists and publishes")
            expect(ApplicationIcon.stored() == .original, "only the original icon remains")
            for isDark in [false, true] {
                defaults.set(isDark ? "dark" : "light", forKey: TerminalAppearance.storageKey)
                driver.reapply()
                check(isDark, isDark, "preset switches preserve native sessions in both modes")
            }
        }
        for icon in (1...12).map({ String(format: "M%02d", $0) }) {
            defaults.set(icon, forKey: ApplicationIcon.storageKey)
            defaults.set(icon, forKey: "appearance.sharedPalette")
            defaults.set(icon, forKey: "appearance.localPalette")
            defaults.set(icon, forKey: "appearance.remotePalette")
            driver.reapply()
            GhosttyRuntime.applySelectedThemes()
            check(true, true, "icons and legacy colors cannot change the preset")
        }
        defaults.set("background = #ff0000\nforeground = #000000\npalette = 2=#0000ff\ncursor-color = #ff0000\nselection-background = #ff0000\ntheme = Dracula\nfont-feature = ss01\n", forKey: TerminalSettings.customConfigKey)
        defaults.set(17.0, forKey: TerminalSettings.fontSizeKey)
        GhosttyRuntime.applyTerminalSettings()
        do {
            let rendered = GhosttyRuntime.controller.terminalConfiguration.rendered
            expect(rendered.contains("font-size = 17"), "font settings still apply")
            expect(!rendered.contains("#ff0000") && !rendered.contains("Dracula") && !rendered.contains("2=#0000ff"), "custom colors never reach the shared engine")
        }
        let parsedSnippet = TerminalSettings.parseCustomConfig(defaults.string(forKey: TerminalSettings.customConfigKey)!)
        expect(parsedSnippet.skippedLines.count == 6 && parsedSnippet.entries.contains { $0.key == "font-feature" },
               "snippet parser protects theme colors while retaining non-color entries")
        check(true, true, "blocked custom colors preserve preset and buffer")
        TerminalThemeTests.run(defaults: defaults, views: views, sessions: sessions)
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
        driver.selectPreset(.system)
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
        func findBackdrop(in view: NSView) -> ShellBackdropView? {
            if let backdrop = view as? ShellBackdropView { return backdrop }
            for child in view.subviews {
                if let backdrop = findBackdrop(in: child) { return backdrop }
            }
            return nil
        }
        for preset in AppThemePreset.allCases + [.system] {
            driver.selectPreset(preset)
            for isDark in [false, true] {
                defaults.set(isDark ? "dark" : "light", forKey: TerminalAppearance.storageKey)
                driver.reapply()
                for _ in 0..<5 { drain() }
                let material = findBackdrop(in: settingsWindow.contentView!)
                expect(material?.preset == preset && material?.isDark == isDark,
                       "settings refreshes its material for every selected preset and mode")
                expect(material?.isTransparent == driver.isShellTransparent,
                       "settings passes the underlying transparency policy into its material")
            }
        }
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
            do {
                let rendered = GhosttyRuntime.controller.terminalConfiguration.rendered
                // Metal 透明仅用于露出应用自己的实色底板，不代表窗口透出桌面。
                let opacityLines = rendered.split(separator: "\n").filter { $0.hasPrefix("background-opacity =") }
                expect(opacityLines == ["background-opacity = 0"],
                       "the shared engine expose the app-owned reading background without duplicate opacity overrides")
            }
            check(true, true, "legacy style preserves sessions")
        }
        let backdrop = ShellBackdropView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        expect(backdrop.isOpaque, "wallpaper backing must block other windows instead of sampling them")
        expect(!backdrop.subviews.contains { $0 is NSVisualEffectView },
               "reading background does not sample desktop or other windows")
        let shellWindow = NSWindow(contentRect: backdrop.bounds, styleMask: [], backing: .buffered, defer: false)
        shellWindow.contentView = backdrop
        for preset in AppThemePreset.allCases {
            backdrop.preset = preset
            for isDark in [false, true] {
                backdrop.isDark = isDark
                for isTransparent in [true, false, true] {
                    backdrop.isTransparent = isTransparent
                    for usesTerminalBackground in [false, true] {
                        backdrop.usesTerminalBackground = usesTerminalBackground
                        backdrop.applyStyle()
                        expect(backdrop.isOpaque && shellWindow.isOpaque,
                               "secondary-control transparency cannot make the reading window transparent")
                        guard let backing = backdrop.layer?.backgroundColor,
                              let gradient = backdrop.subviews.first?.layer?.sublayers?.first as? CAGradientLayer,
                              let colors = gradient.colors as? [CGColor] else {
                            expect(false, "theme backing and gradient exist"); return
                        }
                        let expected = NSColor(AppTheme.colors(isDark: isDark, preset: preset).color(
                            AppTheme.colors(isDark: isDark, preset: preset).background)).usingColorSpace(.sRGB)!
                        let actual = NSColor(cgColor: backing)!.usingColorSpace(.sRGB)!
                        expect(backing.alpha == 1 && colors.allSatisfy { $0.alpha == 1 },
                               "every preset keeps an opaque background in both accessibility modes")
                        expect(abs(actual.redComponent - expected.redComponent) < 0.001
                               && abs(actual.greenComponent - expected.greenComponent) < 0.001
                               && abs(actual.blueComponent - expected.blueComponent) < 0.001,
                               "reading backing matches the terminal theme in light and dark appearances")
                        expect(gradient.isHidden == usesTerminalBackground,
                               "terminal and inspector reading surfaces stay solid instead of showing a gradient")
                    }
                }
            }
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
        print("FamilyAppearanceTests passed: preset modes, legacy preference preservation, blocked overrides, import/undo, preset-owned icon, settings navigation, opaque reading backgrounds, two native surfaces and retained buffers")
    }

    @MainActor static func checkDiffReading() {
        let container = GitDiffContainer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        let patch = GitDiffDocument("@@ -1,3 +1,3 @@\n ABC abc\n-旧文字\n+新文字😀\n final\n")
        func codes(_ view: NSView) -> [GitDiffTextView] {
            (view as? GitDiffTextView).map { [$0] } ?? view.subviews.flatMap(codes)
        }
        for isDark in [false, true] {
            let chrome = WindowChrome.resolve(isDark: isDark)
            container.update(document: patch, chrome: chrome)
            container.layoutSubtreeIfNeeded()
            for code in codes(container) where !code.isHiddenOrHasHiddenAncestor {
                let range = (code.string as NSString).range(of: "final")
                code.setSelectedRange(NSRange(location: range.location, length: 0))
                expect(code.activeLine == 3, "Diff caret selects the actual current row, including aligned rows")
                expect(code.style.activeLine == PreviewThemeStyle(chrome: chrome).activeLine,
                       "Diff current row shares the file preview highlight color")
                expect(code.selectedTextAttributes[.backgroundColor] as? NSColor == PreviewThemeStyle(chrome: chrome).selection,
                       "Diff text selection uses the file preview selection style in both appearances")
                let layout = code.layoutManager!
                layout.ensureLayout(for: code.textContainer!)
                for start in PreviewTextIndex(code.string).lineStarts.dropLast() {
                    let glyph = layout.glyphIndexForCharacter(at: start)
                    let row = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let baseline = layout.location(forGlyphAt: glyph).y
                    let center = baseline - (GitDiffTextView.codeFont.ascender + GitDiffTextView.codeFont.descender) / 2
                    expect(abs(center - row.height / 2) < 0.5 && abs(row.height - GitDiffTextView.rowHeight) < 0.1,
                           "Diff Latin, Chinese, emoji and blank alignment rows have centered text in fixed highlight bands")
                }
                window.makeFirstResponder(code)
                expect(PreviewFind.target(in: window) === code, "Search follows the focused side of the diff")
            }
        }
        window.orderOut(nil)
        print("PASS diff reading: caret row, centered baseline, light/dark selection, focused-side search routing")
    }

    @MainActor static func checkSettingsPages(in window: NSWindow) {
        let pages = ["appearance", "font", "terminal", "shortcuts", "systemIntegration", "about"]
        for size in [SettingsLayout.windowMinimumSize, SettingsLayout.windowDefaultSize, CGSize(width: 1800, height: 1000)] {
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
                    expect(TerminalThemePreferences.shared.select("ghostty:TokyoNight", isDark: true),
                           "select a theme outside the first visible catalog rows")
                    for _ in 0..<5 { drain() }
                    for appearance in ["light", "dark"] {
                        let id = "themes.summary." + appearance
                        expect(identifiers.contains(id), "saved theme remains visible above the catalog: " + id)
                        if appearance == "dark" {
                            let summary = accessibilityElements(window).first {
                                accessibilityValue($0, "accessibilityIdentifier") as? String == id
                            }
                            expect(summary.map { (accessibilityValue($0, "accessibilityValue") as? String)?.contains("TokyoNight") == true } == true,
                                   "summary names the selected theme even when its card is off-screen")
                        }
                    }
                    expect(TerminalThemePreferences.shared.reset(), "restore theme after settings check")
                }
                if page != "appearance" {
                    expect(!accessibilityElements(window).contains {
                        accessibilityValue($0, "accessibilityRole") as? String == "AXScrollBar"
                    }, "form pages and sidebar expose no scrollbars: " + page)
                }
                if page == "appearance" {
                    expect(!identifiers.contains(where: { $0.hasPrefix("settings.preset.") }),
                           "appearance has no obsolete preset or colored icon picker")
                    expect(!identifiers.contains("settings.navigation.appIcon"), "no separate icon settings remain")
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
        print("CHECKED: all six independent settings pages at minimum, common and large window sizes; hidden pages excluded from accessibility; preset appearance retained")
    }

    @MainActor static func accessibilityValue(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
    }

    @MainActor static func accessibilityFrame(_ object: NSObject) -> CGRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        typealias Frame = @convention(c) (AnyObject, Selector) -> CGRect
        return unsafeBitCast(object.method(for: selector), to: Frame.self)(object, selector)
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
