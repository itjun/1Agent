import AppKit
import ObjectiveC
import SwiftUI
@testable import GooseAgent

/// 主导航使用原生材质，工具箱不占主窗口列；不启动终端或 SSH。
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
                    let materials = SidebarAppearanceTests.materials(in: split.splitView)
                    SidebarAppearanceTests.expect(!materials.isEmpty, "主导航必须实际使用原生磨砂")
                    SidebarAppearanceTests.expect(materials.contains { $0.material == .sidebar && $0.blendingMode == .behindWindow },
                        "导航使用 AppKit 自带的原生侧栏材质")
                    SidebarAppearanceTests.expect(!materials.contains { $0.identifier?.rawValue == "workspace.sidebarMaterial" },
                        "主导航不叠加自绘材质背景")
                    SidebarAppearanceTests.expect(split.splitView.dividerColor.alphaComponent == 0
                        && split.splitView.dividerThickness == 1,
                        "navigation hides its separator while preserving the resize geometry")
                    SidebarAppearanceTests.expect(SidebarAppearanceTests.navigationSplit(in: host.view,
                        identifier: "workspace.inspectorSplit") == nil, "旧右栏没有保留隐藏占位")
                    SidebarAppearanceTests.expect(split.splitView.arrangedSubviews.count == 2,
                        "主窗口仅有导航和内容两列")
                    if section == .terminals {
                        SidebarAppearanceTests.expect(window.toolbar == nil, "终端标题不再使用重复通栏")
                    }
                }
            }
        }
        defaults.set("system", forKey: TerminalAppearance.storageKey)
        driver.reapply()
        SidebarAppearanceTests.expect(driver.isDark == TerminalAppearance.systemIsDark, "follow system appearance")
        print("SidebarAppearanceTests passed: native sidebar material, no right column, integrated terminal titles, light/dark and terminal/files/commands")
    }

    @MainActor static func materials(in view: NSView) -> [NSVisualEffectView] {
        let own = view as? NSVisualEffectView
        return (own.map { [$0] } ?? []) + view.subviews.flatMap(materials)
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
