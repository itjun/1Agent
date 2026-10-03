import Foundation

@main
enum WindowMaterialSettingsTests {
    static func main() {
        let suite = "WindowMaterialSettingsTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        expect(WindowMaterialSettings.load(from: store) == WindowMaterialSettings(), "new users get acrylic")

        store.set(0.85, forKey: TerminalSettings.backgroundOpacityKey)
        expect(WindowMaterialSettings.load(from: store).opacity == 0.85, "upgrade retains a translucent opacity")
        store.set(1.0, forKey: TerminalSettings.backgroundOpacityKey)
        expect(WindowMaterialSettings.load(from: store).opacity == 0.78, "opaque legacy settings do not hide acrylic")
        store.set(0.62, forKey: WindowMaterialSettings.opacityKey)
        store.set("solid", forKey: WindowMaterialSettings.styleKey)
        let solid = WindowMaterialSettings.load(from: store)
        expect(solid.effectiveOpacity(reduceTransparency: false) == 1, "solid is fully opaque")
        store.set("mica", forKey: WindowMaterialSettings.styleKey)
        let mica = WindowMaterialSettings.load(from: store)
        expect(mica.style == .mica, "Mica choice persists")
        expect(mica.effectiveOpacity(reduceTransparency: false) == 1, "Mica window is fully opaque")
        expect(mica.terminalOpacity(reduceTransparency: false) == 0, "Mica terminal reveals only the app's opaque foundation")
        expect(mica.terminalOpacity(reduceTransparency: true) == 1, "Mica accessibility fallback is solid")
        expect(mica.opacity == 0.62, "Mica retains the saved acrylic opacity")
        store.set("smoke", forKey: WindowMaterialSettings.styleKey)
        let smoke = WindowMaterialSettings.load(from: store)
        expect(smoke.style == .smoke && smoke.style.isTranslucent, "Smoke choice persists and is translucent")
        expect(smoke.effectiveOpacity(reduceTransparency: false) == 0.62, "Smoke shares the adjustable opacity")
        expect(smoke.effectiveOpacity(reduceTransparency: true) == 1, "Smoke accessibility fallback is solid")
        expect(smoke.terminalOpacity(reduceTransparency: false) == 0.62, "Smoke terminal blends with the dimmed backdrop")
        store.set("acrylic", forKey: WindowMaterialSettings.styleKey)
        let acrylic = WindowMaterialSettings.load(from: store)
        expect(acrylic.opacity == 0.62, "switching back retains acrylic opacity")
        expect(acrylic.effectiveOpacity(reduceTransparency: true) == 1, "accessibility takes precedence")
        expect(acrylic.effectiveOpacity(reduceTransparency: false) == 0.62, "accessibility fallback does not erase preferences")
        expect(store.double(forKey: TerminalSettings.backgroundOpacityKey) == 1, "legacy preferences are untouched")

        expect(WindowMaterialSettings.clampedOpacity(.nan) == 0.78, "invalid opacity is safe")
        expect(WindowMaterialSettings.clampedOpacity(0) == 0.5, "text retains a contrast floor")
        expect(WindowMaterialSettings.clampedOpacity(1) == 0.95, "acrylic always reveals its backdrop")
        store.set("invalid", forKey: WindowMaterialSettings.styleKey)
        expect(WindowMaterialSettings.load(from: store).style == .acrylic, "unknown material falls back")

        var terminal = TerminalSettings.defaults
        terminal.backgroundOpacity = 0.2
        let snippet = [TerminalConfigEntry(key: "background-opacity", value: "0.1"), TerminalConfigEntry(key: "cursor-color", value: "#ffffff")]
        for (profile, reduced, expected) in [(solid, false, "1"), (mica, false, "0"), (mica, true, "1"), (smoke, false, "0.62"), (acrylic, true, "1"), (acrylic, false, "0.62")] {
            let entries = profile.terminalEntries(settings: terminal, snippet: snippet, reduceTransparency: reduced)
            expect(entries.filter { $0.key == "background-opacity" } == [TerminalConfigEntry(key: "background-opacity", value: expected)], "renderer agrees with window material")
            expect(entries.contains(snippet[1]), "other advanced settings are preserved")
        }
        let parsed = TerminalSettings.parseCustomConfig("background-opacity = 0.1\ncursor-color = #ffffff")
        expect(parsed.skippedLines == ["background-opacity = 0.1"], "advanced settings explain the owned opacity")
        expect(parsed.entries == [snippet[1]], "other snippet lines remain usable")
        print("ok")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("FAIL \(message)\n", stderr)
            exit(1)
        }
    }
}
