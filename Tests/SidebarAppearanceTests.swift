import AppKit
import ObjectiveC
import SwiftUI
@testable import GooseAgent

/// 默认侧栏使用稳定阅读底色；其他预设保留材质。不启动终端或 SSH。
@main enum SidebarAppearanceTests {
    @MainActor static func main() {
        let suite = "oneagent.sidebar-appearance.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let getter = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!
        let previous = method_getImplementation(getter)
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(getter, imp_implementationWithBlock(block))
        defer {
            method_setImplementation(getter, previous)
            defaults.removePersistentDomain(forName: suite)
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let model = AppModel()
        let state = model.mainWindow
        state.presentation.sidebarCollapsed = false
        state.presentation.toolSidebarOpen = true
        let host = NSHostingController(rootView: RootView(model: model, window: state))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let driver = AppearanceDriver.shared
        for isDark in [false, true] {
            defaults.set(isDark ? "dark" : "light", forKey: TerminalAppearance.storageKey)
            var glassImages: [AppSection: NSBitmapImageRep] = [:]
            for preset in AppThemePreset.allCases {
                driver.selectPreset(preset)
                for section in [AppSection.terminals, .files, .commands] {
                    state.section = section
                    for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
                    window.contentView?.layoutSubtreeIfNeeded()
                    guard let split = SidebarAppearanceTests.navigationSplit(in: host.view),
                          let item = split.splitViewItems.first else { fatalError("missing production navigation split") }
                    SidebarAppearanceTests.expect(item.behavior == .sidebar, "native sidebar behavior")
                    let view = item.viewController.view
                    guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        fatalError("cannot render sidebar")
                    }
                    view.cacheDisplay(in: view.bounds, to: image)
                    let color = image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh - 20)!
                    if preset == .system {
                        // 比较两个已挂载的生产视图，保持位图色彩空间与外观一致。
                        guard let backdrop = SidebarAppearanceTests.readingBackdrop(in: host.view),
                              let reference = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else {
                            fatalError("cannot render production reading background")
                        }
                        backdrop.cacheDisplay(in: backdrop.bounds, to: reference)
                        let expected = reference.colorAt(x: reference.pixelsWide / 2,
                            y: reference.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
                        let actual = color.usingColorSpace(.sRGB)!
                        let isSameBackground = abs(actual.redComponent - expected.redComponent) < 0.01
                            && abs(actual.greenComponent - expected.greenComponent) < 0.01
                            && abs(actual.blueComponent - expected.blueComponent) < 0.01
                        let isLightGraySidebar = [actual.redComponent, actual.greenComponent, actual.blueComponent].allSatisfy { $0 > 0.9 }
                            && actual.redComponent < expected.redComponent - 0.01
                            && actual.greenComponent < expected.greenComponent - 0.01
                            && actual.blueComponent < expected.blueComponent - 0.01
                            && abs(actual.redComponent - actual.blueComponent) < 0.03
                        SidebarAppearanceTests.expect(actual.alphaComponent > 0.99
                            && (isDark ? isSameBackground : isLightGraySidebar),
                            "default/\(section), dark=\(isDark): light navigation is neutral gray beside white reading content; dark navigation retains its reading background; actual=\(actual), reading=\(expected)")
                        if section == .terminals {
                            guard let inspector = SidebarAppearanceTests.navigationSplit(in: host.view, identifier: "workspace.inspectorSplit")?.splitViewItems.last?.viewController.view,
                                  let inspectorImage = inspector.bitmapImageRepForCachingDisplay(in: inspector.bounds) else {
                                fatalError("cannot render production inspector")
                            }
                            inspector.cacheDisplay(in: inspector.bounds, to: inspectorImage)
                            let right = inspectorImage.colorAt(x: inspectorImage.pixelsWide / 2,
                                y: inspectorImage.pixelsHigh - 20)!.usingColorSpace(.sRGB)!
                            SidebarAppearanceTests.expect(right.alphaComponent > 0.99
                                && abs(actual.redComponent - right.redComponent) < 0.01
                                && abs(actual.greenComponent - right.greenComponent) < 0.01
                                && abs(actual.blueComponent - right.blueComponent) < 0.01,
                                "default sidebars share the same opaque background, dark=\(isDark)")
                        }
                    } else {
                        SidebarAppearanceTests.expect(color.alphaComponent < 0.01,
                            "\(preset.rawValue)/\(section), dark=\(isDark): other presets retain native material")
                        if let reference = glassImages[section] {
                            SidebarAppearanceTests.expect(SidebarAppearanceTests.navigationMatches(image, reference),
                                "\(preset.rawValue)/\(section), dark=\(isDark): other presets retain shared navigation colors")
                        } else {
                            glassImages[section] = image
                        }
                    }
                }
            }
        }
        defaults.set("system", forKey: TerminalAppearance.storageKey)
        driver.reapply()
        SidebarAppearanceTests.expect(driver.isDark == TerminalAppearance.systemIsDark, "follow system appearance")
        print("SidebarAppearanceTests passed: default sidebars share the opaque sidebar palette; other presets retain native material across light/dark and terminal/files/commands; appearance follows macOS")
    }

    static func navigationMatches(_ image: NSBitmapImageRep, _ reference: NSBitmapImageRep) -> Bool {
        guard image.pixelsWide == reference.pixelsWide, image.pixelsHigh == reference.pixelsHigh else { return false }
        let scale = CGFloat(image.pixelsWide) / image.size.width
        var difference: CGFloat = 0
        var samples = 0
        for y in stride(from: 0, to: min(image.pixelsHigh, Int(180 * scale)), by: 3) {
            for x in stride(from: 0, to: image.pixelsWide, by: 3) {
                guard let a = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let b = reference.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                difference += abs(a.redComponent * a.alphaComponent - b.redComponent * b.alphaComponent)
                    + abs(a.greenComponent * a.alphaComponent - b.greenComponent * b.alphaComponent)
                    + abs(a.blueComponent * a.alphaComponent - b.blueComponent * b.alphaComponent)
                    + abs(a.alphaComponent - b.alphaComponent)
                samples += 4
            }
        }
        return difference / CGFloat(samples) < 0.002
    }

    @MainActor static func navigationSplit(in view: NSView, identifier: String = "workspace.navigationSplit") -> NSSplitViewController? {
        if let split = view as? NSSplitView,
           split.identifier?.rawValue == identifier { return split.delegate as? NSSplitViewController }
        for child in view.subviews {
            if let split = SidebarAppearanceTests.navigationSplit(in: child, identifier: identifier) { return split }
        }
        return nil
    }

    @MainActor static func readingBackdrop(in view: NSView) -> ShellBackdropView? {
        if let backdrop = view as? ShellBackdropView, backdrop.usesTerminalBackground { return backdrop }
        for child in view.subviews {
            if let backdrop = SidebarAppearanceTests.readingBackdrop(in: child) { return backdrop }
        }
        return nil
    }

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
