import AppKit
import ObjectiveC
import SwiftUI
@testable import GooseAgent

/// 通栏和左右侧栏共用不透明主题底色，不启动终端或 SSH。
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
                    let actual = color.usingColorSpace(.sRGB)!
                    let chrome = WindowChrome(isDark: isDark, preset: preset)
                    SidebarAppearanceTests.expect(actual.alphaComponent > 0.99,
                        "\(preset.rawValue)/\(section), dark=\(isDark): navigation uses an opaque background")
                    SidebarAppearanceTests.expect(split.splitView.dividerColor.alphaComponent == 0
                        && split.splitView.dividerThickness == 1,
                        "navigation hides its separator while preserving the resize geometry")
                    SidebarAppearanceTests.expect(SidebarAppearanceTests.matches(window.backgroundColor, NSColor(chrome.sidebarBackground)),
                        "toolbar and navigation share one opaque background")
                    if section == .terminals {
                        guard let inspector = SidebarAppearanceTests.navigationSplit(in: host.view, identifier: "workspace.inspectorSplit")?.splitViewItems.last?.viewController.view,
                              let inspectorImage = inspector.bitmapImageRepForCachingDisplay(in: inspector.bounds) else {
                            fatalError("cannot render production inspector")
                        }
                        inspector.cacheDisplay(in: inspector.bounds, to: inspectorImage)
                        let right = inspectorImage.colorAt(x: inspectorImage.pixelsWide / 2,
                            y: inspectorImage.pixelsHigh - 20)!
                        SidebarAppearanceTests.expect(SidebarAppearanceTests.matches(actual, right),
                            "\(preset.rawValue): both sidebars share the same opaque background, dark=\(isDark)")
                    }
                }
            }
        }
        defaults.set("system", forKey: TerminalAppearance.storageKey)
        driver.reapply()
        SidebarAppearanceTests.expect(driver.isDark == TerminalAppearance.systemIsDark, "follow system appearance")
        print("SidebarAppearanceTests passed: macOS system colors share opaque toolbar and sidebar backgrounds across light/dark and terminal/files/commands; hidden navigation divider retains its resize geometry")
    }

    static func matches(_ first: NSColor, _ second: NSColor) -> Bool {
        let a = first.usingColorSpace(.sRGB)!
        let b = second.usingColorSpace(.sRGB)!
        return a.alphaComponent > 0.99 && b.alphaComponent > 0.99
            && abs(a.redComponent - b.redComponent) < 0.01
            && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }

    @MainActor static func navigationSplit(in view: NSView, identifier: String = "workspace.navigationSplit") -> NSSplitViewController? {
        if let split = view as? NSSplitView,
           split.identifier?.rawValue == identifier { return split.delegate as? NSSplitViewController }
        for child in view.subviews {
            if let split = SidebarAppearanceTests.navigationSplit(in: child, identifier: identifier) { return split }
        }
        return nil
    }

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
