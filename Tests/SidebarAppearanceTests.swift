import AppKit
import ObjectiveC
import SwiftUI
@testable import agent

/// 切换工作区时，各栏共用整窗渐变；不启动终端或 SSH。
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
        checkTerminalCardFill()
        for isDark in [false, true] {
            defaults.set(isDark ? "dark" : "light", forKey: TerminalAppearance.storageKey)
            for preset in AppThemePreset.allCases {
                driver.selectPreset(preset)
                for section in [AppSection.terminals, .files, .commands] {
                    model.showSection(section, in: state)
                    for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
                    window.contentView?.layoutSubtreeIfNeeded()
                    guard let split = SidebarAppearanceTests.navigationSplit(in: host.view),
                          let item = split.splitViewItems.first else { fatalError("missing production navigation split") }
                    SidebarAppearanceTests.expect(item.canCollapse, "工作区导航仍可折叠")
                    let backdrops = views(of: ShellBackdropView.self, in: host.view)
                    expect(backdrops.count == 1 && backdrops.first?.showsTerminalCards == true,
                           "\(section) 使用一张与终端相同强度的整窗渐变")
                    let materials = views(of: NSVisualEffectView.self, in: split.splitView.arrangedSubviews[0])
                    SidebarAppearanceTests.expect(!materials.contains { $0.material == .sidebar && $0.blendingMode == .behindWindow },
                        "导航底下没有遮挡整窗渐变的独立侧栏材质")
                    SidebarAppearanceTests.expect(split.splitView.dividerColor.alphaComponent == 0
                        && split.splitView.dividerThickness == 5,
                        "navigation hides its separator while preserving the resize geometry: section=\(section), width=\(split.splitView.dividerThickness), alpha=\(split.splitView.dividerColor.alphaComponent)")
                    SidebarAppearanceTests.expect(SidebarAppearanceTests.navigationSplit(in: host.view,
                        identifier: "workspace.inspectorSplit") == nil, "旧右栏没有保留隐藏占位")
                    SidebarAppearanceTests.expect(split.splitView.arrangedSubviews.count == 2,
                        "主窗口仅有导航和内容两列")
                    do {
                        SidebarAppearanceTests.expect(window.toolbar == nil, "各页标题与操作留在各自的岛内")
                        SidebarAppearanceTests.expect(split.splitView.arrangedSubviews.first?.layer?.cornerRadius == 10
                            && split.splitView.arrangedSubviews.first?.layer?.masksToBounds == true,
                            "navigation is clipped to the rounded island")
                        let content = window.contentView!
                        let frame = split.splitView.convert(split.splitView.bounds, to: content)
                        SidebarAppearanceTests.expect(abs(frame.minX - content.bounds.minX - 5) < 1
                            && abs(frame.minY - content.bounds.minY - 5) < 1
                            && abs(content.bounds.maxX - frame.maxX - 5) < 1
                            && abs(content.bounds.maxY - frame.maxY - 5) < 1,
                            "terminal, files and commands keep the same 5pt gap on all four window edges")
                    }
                }
            }
        }
        defaults.set("system", forKey: TerminalAppearance.storageKey)
        driver.reapply()
        SidebarAppearanceTests.expect(driver.isDark == TerminalAppearance.systemIsDark, "follow system appearance")
        print("SidebarAppearanceTests passed: translucent reading cards, accessibility fallback, rounded navigation and native split geometry")
    }

    @MainActor static func checkTerminalCardFill() {
        let fill = TerminalCardFill(color: .white).frame(width: 16, height: 16)
        let image = ImageRenderer(content: fill).cgImage!
        let pixel = NSBitmapImageRep(cgImage: image).colorAt(x: 8, y: 8)!
        let workspace = NSWorkspace.shared
        let expected = ShellLayout.terminalCardOpacity(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            contrast: workspace.accessibilityDisplayShouldIncreaseContrast ? .increased : .standard)
        expect(abs(pixel.alphaComponent - expected) < 0.01, "卡片材质实际绘制一次主题底色")
        expect((0.5..<0.7).contains(ShellLayout.terminalCardOpacity(reduceTransparency: false, contrast: .standard)),
               "透色同时保留圆角卡片与间隙的明度差")
        expect(ShellLayout.terminalCardOpacity(reduceTransparency: true, contrast: .standard) == 1 &&
               ShellLayout.terminalCardOpacity(reduceTransparency: false, contrast: .increased) == 1,
               "减少透明度和增强对比度均使用实色阅读底板")
    }

    @MainActor static func views<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        let children = view.subviews.flatMap { views(of: type, in: $0) }
        return (view as? T).map { [$0] + children } ?? children
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
