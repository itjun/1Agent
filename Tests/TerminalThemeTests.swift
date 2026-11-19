import AppKit
import GhosttyTerminal
import QuartzCore
import SwiftUI
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
        let frameBackdrop = ShellBackdropView(frame: CGRect(x: 0, y: 0, width: 64, height: 48))
        frameBackdrop.usesTerminalBackground = true
        // AppKit 首次显示后才把子视图的 backing layer 接入根层，离屏渲染也需完成这一步。
        let frameWindow = NSWindow(contentRect: frameBackdrop.bounds, styleMask: [], backing: .buffered, defer: false)
        frameWindow.isReleasedWhenClosed = false
        frameWindow.contentView = frameBackdrop
        frameWindow.orderFront(nil)
        FamilyAppearanceTests.drain()
        frameBackdrop.layoutSubtreeIfNeeded()
        frameBackdrop.displayIfNeeded()
        defer { frameWindow.close() }
        func checkSoftFrame(_ colors: TerminalThemeColors, name: String) {
            var chrome = colors.paneChrome(isFocused: true)
            chrome.gradientColors = colors.gradientColors.map(\.color)
            frameBackdrop.chrome = chrome
            frameBackdrop.isDark = !colors.isDark
            frameBackdrop.isTransparent = true
            frameBackdrop.applyStyle()
            let tint = frameBackdrop.subviews.first!.layer!
            let gradients = tint.sublayers!.compactMap { $0 as? CAGradientLayer }
            expect(tint.name == "workspace.gradientTint" && tint.allowsGroupOpacity
                   && tint.opacity > 0 && tint.opacity <= 0.55,
                   "the complete frame tint is softened once over its solid backing: " + name)
            expect(gradients.count == 2 && gradients.allSatisfy { $0.opacity == 1 && !$0.isHidden },
                   "linear and corner colors share one opacity instead of brightening each other: " + name)
            expect((frameBackdrop.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) == colors.isDark,
                   "frame material follows the palette brightness rather than a stale appearance: " + name)
            let base = GooseAgent.RGBColor(ghosttyHex: colors.background)!
            for source in colors.gradientColors {
                let composite = base.mixed(with: source, amount: Double(tint.opacity))
                let sourceChannels = [source.red, source.green, source.blue]
                let baseChannels = [base.red, base.green, base.blue]
                let visibleChannels = [composite.red, composite.green, composite.blue]
                for index in sourceChannels.indices {
                    let originalDifference = sourceChannels[index] - baseChannels[index]
                    let visibleDifference = visibleChannels[index] - baseChannels[index]
                    expect(visibleChannels[index].isFinite && (0...1).contains(visibleChannels[index])
                           && abs(visibleDifference) <= abs(originalDifference) * 0.55 + 0.000001
                           && visibleDifference * originalDifference >= 0,
                           "soft glass reduces color strength while preserving the theme's color direction: " + name)
                }
                if source.relativeLuminance > base.relativeLuminance + 0.000001 {
                    expect(composite.relativeLuminance < source.relativeLuminance,
                           "bright frame colors no longer retain their previous intensity: " + name)
                }
            }
            let sourceColors = gradients[0].colors as! [CGColor]
            expect(sourceColors.allSatisfy { $0.alpha == 1 }
                   && frameBackdrop.layer!.backgroundColor!.alpha == 1 && frameBackdrop.isOpaque,
                   "soft tint never makes the reading window transparent: " + name)
        }
        // 直接采样遮罩，把光源方向和主题自身各颜色的明暗差异分开验证。
        func checkLightDirection(_ backdrop: ShellBackdropView, name: String) {
            let tint = backdrop.subviews.first!.layer!
            guard let mask = tint.mask else {
                expect(false, "theme frame has a light mask: " + name)
                return
            }
            expect(mask.frame == tint.bounds, "light mask fills the complete frame: " + name)
            let width = Int(mask.bounds.width), height = Int(mask.bounds.height)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            mask.render(in: NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext)
            func strength(_ x: Int, _ y: Int) -> CGFloat { bitmap.colorAt(x: x, y: y)!.alphaComponent }
            let topLeft = strength(2, 2)
            let topRight = strength(width - 3, 2)
            let middleLeft = strength(2, height / 2)
            let bottomLeft = strength(2, height - 3)
            let bottomMiddle = strength(width / 2, height - 3)
            let bottomRight = strength(width - 3, height - 3)
            expect(topLeft > 0.9 && topLeft > topRight && topLeft > middleLeft && topLeft > bottomRight,
                   "top-left remains the strongest light source: " + name)
            expect([bottomLeft, bottomMiddle, bottomRight].allSatisfy { $0 > 0.75 },
                   "bottom fill reaches the entire lower gap: " + name)
        }
        func checkRenderedFrame(name: String, minimumBottomDifference: Double = 0.055) {
            let root = frameBackdrop.layer!
            let tint = frameBackdrop.subviews.first!.layer!
            let sheen = root.sublayers!.first { $0.name == "workspace.gradientSheen" }!
            let opacity = tint.opacity
            let isSheenHidden = sheen.isHidden
            expect(tint.superlayer === root, "rendered fixture includes the native tint layer: " + name)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sheen.isHidden = true
            defer {
                tint.opacity = opacity
                sheen.isHidden = isSheenHidden
                CATransaction.commit()
            }
            func samples() -> [NSColor] {
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                root.render(in: NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext)
                return [(2, 2), (32, 2), (61, 2), (2, 24), (61, 24), (2, 45), (32, 45), (61, 45)].map {
                    bitmap.colorAt(x: $0.0, y: $0.1)!.usingColorSpace(.sRGB)!
                }
            }
            let softened = samples()
            tint.opacity = 1
            let original = samples()
            let base = NSColor(cgColor: root.backgroundColor!)!.usingColorSpace(.sRGB)!
            func difference(_ color: NSColor) -> Double {
                abs(color.redComponent - base.redComponent)
                    + abs(color.greenComponent - base.greenComponent)
                    + abs(color.blueComponent - base.blueComponent)
            }
            expect(original.contains { difference($0) > 0.03 },
                   "rendered fixture includes visible frame color: " + name)
            let weakestBottomDifference = softened.suffix(3).map(difference).min()!
            expect(weakestBottomDifference >= minimumBottomDifference,
                   "bottom gap remains visible across the frame: \(name), measured \(weakestBottomDifference)")
            for index in original.indices {
                let visibleDifference = difference(softened[index])
                expect(visibleDifference >= difference(original[index]) * 0.22 - 0.01
                       && visibleDifference >= 0.055,
                       "frame stays distinct from the island background at perimeter sample \(index): " + name)
                expect(difference(softened[index]) <= difference(original[index]) * 0.60 + 0.025,
                       "rendered frame and teal corner lose their former color intensity together: " + name)
                expect(softened[index].alphaComponent == 1,
                       "rendered glass frame remains opaque over the theme backing: " + name)
            }
        }
        for theme in catalog.themes.dropFirst() {
            let colors = theme.palette!
            expect(colors.ansi.count == 16, "complete ANSI: " + theme.name)
            let hexes = [colors.background, colors.foreground, colors.cursor, colors.cursorText, colors.selection, colors.selectionText] + colors.ansi
            expect(hexes.allSatisfy { $0.count == 6 && UInt32($0, radix: 16) != nil }, "complete palette: " + theme.name)
            expect(theme.configuration.light == theme.configuration.dark, "fixed theme independent of app appearance")
            let chrome = colors.applicationChrome()
            func rgb(_ color: NSColor) -> GooseAgent.RGBColor {
                let value = color.usingColorSpace(.sRGB)!
                return GooseAgent.RGBColor(red: value.redComponent, green: value.greenComponent, blue: value.blueComponent)
            }
            for surface in [chrome.background, chrome.sidebarBackground, chrome.elevated, chrome.accentFill] {
                expect(rgb(NSColor(chrome.text)).contrastRatio(with: rgb(NSColor(surface))) >= 4.5,
                       "application text stays readable on every surface: " + theme.name)
            }
            expect(chrome.isDark == colors.isDark, "native controls follow theme brightness: " + theme.name)
            let base = GooseAgent.RGBColor(ghosttyHex: colors.background)!
            expect(colors.gradientColors.count == 4, "theme supplies frame and corner colors")
            checkSoftFrame(colors, name: theme.name)
            let focused = colors.paneBackground(isFocused: true)
            expect(focused.red == base.red && focused.green == base.green && focused.blue == base.blue,
                   "focused terminal keeps the original theme background")
            let inactive = colors.paneBackground(isFocused: false)
            expect(abs(inactive.red - base.red * 0.92) < 0.0001
                   && abs(inactive.green - base.green * 0.92) < 0.0001
                   && abs(inactive.blue - base.blue * 0.92) < 0.0001,
                   "inactive terminal dims every theme equally without a blue or white tint")
        }
        for isDark in [false, true] {
            let name = isDark ? "Default Dark" : "Default Light"
            checkSoftFrame(.system(isDark: isDark), name: name)
            checkRenderedFrame(name: name)
        }
        for name in ["Spring", "Argonaut"] {
            let colors = catalog.themes.first { $0.name == name }!.palette!
            checkSoftFrame(colors, name: name)
            checkRenderedFrame(name: name, minimumBottomDifference: colors.isDark ? 0.24 : 0.055)
        }
        for background in ["000000", "FFFFFF", "FF0000", "00FF00"] {
            var ansi = Array(repeating: "808080", count: 16)
            ansi[4] = "0000FF"
            ansi[5] = "FF00FF"
            ansi[6] = "00FFFF"
            let colors = TerminalThemeColors(background: background, foreground: "000000", cursor: "FFFFFF",
                cursorText: "000000", selection: "FF00FF", selectionText: "FFFFFF", ansi: ansi)
            checkSoftFrame(colors, name: "Saturated " + background)
            checkRenderedFrame(name: "Saturated " + background)
            checkLightDirection(frameBackdrop, name: "Saturated " + background)
        }
        expect(catalog.filtered(search: "", isDark: false).count == 183, "182 light themes plus default")
        expect(catalog.filtered(search: "", isDark: true).count == 638, "637 dark themes plus default")
        for isDark in [false, true] {
            expect(catalog.filtered(search: "", isDark: isDark).allSatisfy {
                $0.isDefault || $0.palette!.isDark == isDark
            }, "catalog never offers a theme from the opposite appearance")
            expect(catalog.filtered(search: "Default", isDark: isDark).first?.isDefault == true,
                   "adaptive default is available in both appearances")
        }
        expect(catalog.filtered(search: "tOkYoNiGhT", isDark: true).contains { $0.name == "TokyoNight" }, "case insensitive search")
        expect(catalog.filtered(search: "Aardvark Ink", isDark: false).isEmpty, "search cannot bypass appearance matching")
        expect(catalog.filtered(search: "not-a-theme-938723", isDark: true).isEmpty, "empty search results")
        do {
            _ = try TerminalThemeCatalog.parse(name: "invalid", text: "background = #FFFFFF")
            expect(false, "incomplete theme rejected")
        } catch {}
        // 同一张未选中卡片更换候选主题时，外框也必须跟随卡片更新。
        let preview = NSHostingView(rootView: TerminalThemePreview(colors: .system(isDark: false)))
        let previewSize = CGSize(width: SettingsLayout.themeMinimumWidth, height: SettingsLayout.themePreviewHeight)
        let previewWindow = NSWindow(contentRect: CGRect(origin: .zero, size: previewSize),
                                     styleMask: [], backing: .buffered, defer: false)
        previewWindow.isReleasedWhenClosed = false
        previewWindow.contentView = preview
        previewWindow.orderFront(nil)
        func findBackdrop(in view: NSView) -> ShellBackdropView? {
            if let backdrop = view as? ShellBackdropView { return backdrop }
            return view.subviews.lazy.compactMap { findBackdrop(in: $0) }.first
        }
        for themeID in ["ghostty:Afterimage", "ghostty:Aura"] {
            let candidate = catalog.theme(id: themeID)!.palette!
            preview.rootView = TerminalThemePreview(colors: candidate)
            FamilyAppearanceTests.drain()
            preview.layoutSubtreeIfNeeded()
            let backdrop = findBackdrop(in: preview)
            expect(backdrop?.chrome == candidate.workspaceChrome && backdrop?.usesTerminalBackground == true,
                   "preview shows the candidate's workspace backdrop: " + themeID)
            expect(backdrop?.bounds.size == previewSize, "preview backdrop fills the thumbnail: " + themeID)
            if let backdrop { checkLightDirection(backdrop, name: themeID) }
        }
        previewWindow.close()
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
            for id in [TerminalThemeDescriptor.defaultID, "ghostty:missing"] {
                defaults.set(id, forKey: key)
                expect(TerminalThemePreferences.selected(isDark: isDark).isDefault,
                       "shared default or invalid choice cannot revive legacy settings")
            }
            let oppositeTheme = isDark ? light : dark
            defaults.set(oppositeTheme.id, forKey: key)
            expect(TerminalThemePreferences.selected(isDark: isDark).isDefault,
                   "old mixed-brightness choices fall back to default without reviving legacy settings")
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
                   "appearance, theme and complete window have matching brightness")
            expect(terminalIsDark == uiDark, "theme cannot override the selected appearance")
            let chrome = WindowChrome.resolve(isDark: uiDark)
            var expectedChrome = theme.palette?.applicationChrome() ?? WindowChrome(isDark: uiDark)
            expectedChrome.gradientColors = theme.colors(interfaceIsDark: uiDark).gradientColors.map(\.color)
            expect(chrome == expectedChrome,
                   "whole application refreshes for same-brightness theme switches")
            for index in views.indices {
                let colors = theme.colors(interfaceIsDark: uiDark)
                let runtime = GhosttyRuntime.controller
                let rgb = Int(colors.background, radix: 16)!
                let expected = TerminalColor(red: UInt8((rgb >> 16) & 255), green: UInt8((rgb >> 8) & 255), blue: UInt8(rgb & 255))
                expect(runtime.backgroundColor == expected, "preview and running engine agree: " + String(index))
                expect((runtime.effectiveColorScheme == .dark) == terminalIsDark, "engine follows selected theme brightness")
                expect((views[index].effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) == terminalIsDark,
                       "native terminal appearance follows selected theme brightness")
                expect((views[index].window!.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) == terminalIsDark,
                       "surrounding window follows the active theme brightness")
                expect(runtime.theme == theme.configuration, "cursor, selection, foreground and ANSI share catalog data")
                expect(sessions[index].readScreenText()?.text.contains("family-session-marker") == true,
                       "theme switching keeps existing buffer and surface")
                expect(TerminalThemePreferences.selected().id == theme.id, "active selection follows appearance")
                let background = colors.paneBackground(isFocused: false)
                expect(background.relativeLuminance <= colors.paneBackground(isFocused: true).relativeLuminance,
                       "inactive pane never becomes brighter, including pure-black themes")
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
            expect(!prefs.select(otherLight.id), "opposite-brightness theme is rejected before engine writes")
            expect(TerminalAppearance.stored() == .dark && AppearanceDriver.shared.interfaceIsDark,
                   "failed activation preserves the saved and visible appearance")
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
        for mode in [TerminalAppearance.light, .dark, .system] {
            defaults.set(mode.rawValue, forKey: TerminalAppearance.storageKey)
            AppearanceDriver.shared.reapply()
            let isDark = mode.resolvesDark()
            for theme in [dark, light, otherLight, otherDark] {
                let previous = TerminalThemePreferences.selected()
                let previousRevision = prefs.revision
                let previousConfiguration = GhosttyRuntime.controller.theme
                let inactiveID = TerminalThemePreferences.selected(isDark: !isDark).id
                let isMatching = theme.palette!.isDark == isDark
                expect(prefs.select(theme.id) == isMatching, "only matching themes can be selected in every appearance mode")
                if !isMatching {
                    expect(prefs.error != nil && prefs.revision == previousRevision,
                           "rejected choice reports an error without publishing a selection")
                    expect(GhosttyRuntime.controller.theme == previousConfiguration,
                           "rejected choice leaves the running engine unchanged")
                }
                expect(TerminalAppearance.stored() == mode, "theme selection preserves light, dark and follow system modes")
                expect(TerminalThemePreferences.selected(isDark: !isDark).id == inactiveID,
                       "theme selection preserves the other appearance's theme")
                AppearanceDriver.shared.reapply()
                check(isMatching ? theme : previous, uiDark: isDark)
            }
        }
        switchAppearance(false)
        let inactiveDarkID = TerminalThemePreferences.selected(isDark: true).id
        expect(!prefs.select(light.id, isDark: true), "inactive dark appearance also rejects a light theme")
        expect(TerminalThemePreferences.selected(isDark: true).id == inactiveDarkID,
               "invalid inactive choice preserves its saved theme")
        expect(prefs.select(TerminalThemeDescriptor.defaultID), "default restores the current appearance's palette")
        expect(TerminalAppearance.stored() == .light, "default preserves the current appearance")
        check(.system, uiDark: false)
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
        defaults.set(false, forKey: "appearance.gradientEnabled")
        defaults.synchronize()
        AppearanceDriver.shared.reapply()
        expect(WindowChrome.resolve(isDark: true).isGradientEnabled, "obsolete off preference cannot disable the default frame gradient")
        let backdrop = ShellBackdropView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        backdrop.usesTerminalBackground = true
        backdrop.isTransparent = true
        var previousGradient: [CGColor]?
        for theme in [dark, otherDark, light, otherLight, .system] {
            let isDark = theme.palette?.isDark ?? false
            switchAppearance(isDark)
            expect(prefs.select(theme.id), "gradient theme selection succeeds")
            let chrome = WindowChrome.resolve(isDark: isDark)
            expect(chrome.isGradientEnabled, "gradient remains enabled across appearance and theme switches")
            backdrop.chrome = chrome
            backdrop.applyStyle()
            let layer = backdrop.subviews.first!.layer!.sublayers!.first as! CAGradientLayer
            let colors = layer.colors as! [CGColor]
            expect(!layer.isHidden && backdrop.isOpaque && colors.allSatisfy { $0.alpha == 1 },
                   "frame retains opaque source colors over a solid backing without exposing the desktop")
            let tint = backdrop.subviews.first!.layer!
            expect(tint.opacity > 0 && tint.opacity <= 0.55,
                   "live theme switches preserve the softened frame tint")
            let sheen = backdrop.layer!.sublayers!.first { $0.name == "workspace.gradientSheen" } as! CAGradientLayer
            let reflections = sheen.colors as! [CGColor]
            expect(reflections.first!.alpha > 0 && reflections.first!.alpha <= (isDark ? 0.03 : 0.12)
                   && reflections.dropFirst().allSatisfy { $0.alpha == 0 },
                   "the reflection remains faint and fades away from its source")
            expect(sheen.type == .radial && sheen.startPoint == CGPoint(x: 0, y: 1),
                   "the reflection shares the top-left light source")
            expect(sheen.isHidden == NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
                   "increased contrast removes the decorative reflection")
            backdrop.isTransparent = false
            backdrop.applyStyle()
            expect(sheen.isHidden && tint.opacity > 0 && tint.opacity <= 0.55,
                   "reduced transparency removes reflections without restoring the bright frame")
            backdrop.isTransparent = true
            backdrop.setFrameSize(NSSize(width: 960, height: 640))
            backdrop.layoutSubtreeIfNeeded()
            backdrop.applyStyle()
            expect(tint.frame == backdrop.bounds && sheen.frame == backdrop.bounds
                   && tint.sublayers!.allSatisfy { $0.frame == tint.bounds },
                   "resizing keeps one continuous gradient and reflection across the whole window")
            checkLightDirection(backdrop, name: theme.name)
            expect(chrome.readingBackground == chrome.background,
                   "reading surfaces stay solid while the frame follows the theme")
            if let previousGradient {
                expect(colors != previousGradient, "switching themes updates the visible gradient")
            }
            previousGradient = colors
            for index in sessions.indices {
                expect(sessions[index].hasAttachedSurface && views[index].controller === runtime,
                       "gradient switches retain the existing terminal surface")
                expect(sessions[index].readScreenText()?.text.contains("family-session-marker") == true,
                       "gradient switches retain existing terminal output")
            }
        }
        defaults.removeObject(forKey: "appearance.gradientEnabled")
        expect(prefs.reset(), "restore themes after gradient coverage")
        switchAppearance(true)
        print("PASS terminal themes: 819 palettes, soft frame tint, extreme palettes, legacy preservation, shared appearance pair, live switching, retained buffers, failure and resets")
    }
}
