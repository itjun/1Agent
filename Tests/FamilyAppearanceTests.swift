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
        let driver = AppearanceDriver.shared
        let preview = ThemePreview.shared
        driver.reapply()
        let lightChrome = WindowChrome.resolve(isDark: false)
        let darkChrome = WindowChrome.resolve(isDark: true)
        var windows: [NSWindow] = []
        var views: [SSHTerminalNSView] = []
        var sessions: [InMemoryTerminalSession] = []
        for _ in 0..<2 {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
            let view = SSHTerminalNSView(frame: window.contentView!.bounds)
            view.controller = GhosttyRuntime.controller
            view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
            view.applyTerminalAppearance(dark: driver.terminalIsDark)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            windows.append(window); views.append(view); sessions.append(session)
        }
        let observer = driver.$terminalIsDark.sink { dark in
            for view in views { view.applyTerminalAppearance(dark: dark) }
        }
        defer { observer.cancel() }
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
            expect((GhosttyRuntime.controller.effectiveColorScheme == .dark) == terminalDark, context + ": actual engine scheme")
            expect(WindowChrome.resolve(isDark: uiDark) == (uiDark ? darkChrome : lightChrome), context + ": fixed palette")
            for (index, window) in windows.enumerated() {
                expect((window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) == uiDark,
                       context + ": window chrome")
                expect((views[index].effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) == terminalDark,
                       context + ": native terminal appearance")
                expect(window.contentView === views[index], context + ": stable view identity")
                expect(sessions[index].readScreenText()?.text.contains("family-session-marker") == true, context + ": retained buffer")
            }
        }
        preview.show(darkTheme)
        check(false, true, "dark preview in light UI")
        expect(NSDictionary(dictionary: defaults.persistentDomain(forName: suite)!).isEqual(to: saved), "preview never persists preferences")
        preview.cancel()
        check(false, false, "cancel restores saved slot")
        preview.show(darkTheme)
        preview.save()
        check(false, false, "saving opposite slot returns to light")
        expect(defaults.string(forKey: TerminalAppearance.darkThemeKey) == darkTheme.name, "save writes previewed dark slot")
        expect(defaults.string(forKey: TerminalAppearance.lightThemeKey) == "GitHub Light Default", "save preserves other slot")
        defaults.set("dark", forKey: TerminalAppearance.storageKey)
        driver.reapply()
        preview.show(lightTheme)
        check(true, false, "light preview in dark UI")
        SettingsWindowController.shared.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: windows[0]))
        check(true, true, "closing settings cancels preview")
        expect(defaults.string(forKey: TerminalAppearance.lightThemeKey) == "GitHub Light Default", "closing settings does not save")
        preview.showDefaults()
        check(true, true, "restore defaults is a preview")
        expect(preview.effectiveDark().name == "GitHub Dark Default", "default sample applied")
        preview.cancel()
        expect(preview.effectiveDark().name == darkTheme.name, "cancel restores chosen dark theme")
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
        check(false, true, "system light with dark preview")
        systemDark = true
        driver.reapply()
        check(true, true, "system switches while preview remains")
        preview.show(lightTheme)
        check(true, false, "system dark with light preview")
        preview.cancel()
        check(true, true, "cancel follows current system")
        expect(defaults.string(forKey: "sidebar.material") == "liquidGlass", "obsolete preference is ignored, not erased")
        print("FamilyAppearanceTests passed: preview/save/cancel/close/defaults/system, two live native surfaces, palette and buffer preservation")
    }

    @MainActor static func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
