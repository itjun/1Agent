import AppKit
import SwiftUI
import ObjectiveC
@testable import GooseAgent

@main enum QuickCommandSidebarTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        Task { @MainActor in
            do { try await run(); print("QuickCommandSidebarTests passed"); exit(0) }
            catch { fputs("QuickCommandSidebarTests failed: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func run() async throws {
        let home = ProcessInfo.processInfo.environment["ONEAGENT_TEST_HOME"]!
        precondition(home.hasPrefix("/private/tmp/oneagent-quick-command-sidebar."))
        precondition(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == URL(fileURLWithPath: home).resolvingSymlinksInPath())
        let suite = "oneagent.command-sidebar.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let getter = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!
        let previous = method_getImplementation(getter)
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(getter, imp_implementationWithBlock(block))
        defer { method_setImplementation(getter, previous); defaults.removePersistentDomain(forName: suite) }

        let model = AppModel(), state = model.mainWindow
        MainWindowManager.shared.show(state, model: model)
        let native = MainWindowManager.shared.window(for: state)!
        native.contentViewController = nil
        native.contentView = NSView(frame: native.contentLayoutRect)
        defer { MainWindowManager.shared.close(state) }
        verifyScrolledCursorRegions(in: native)
        // 只挂载真实侧栏，不创建终端视图；脚本另由已有隔离 PTY 检查覆盖。
        model.openLocalTerminal(at: home, placement: .newTab, beside: UUID(), in: state)
        try await eventually { model.tabs.count == 1 }
        let original = model.tabs[0]
        let store = QuickCommandStore.shared
        precondition(store.url.resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/"))
        var item = QuickCommand(alias: "构建应用", command: "printf '%s\\n' 'sidebar fixture'", scope: .local)
        try store.save(item)
        native.setContentSize(NSSize(width: 260, height: 700))
        native.contentView = NSHostingView(rootView: QuickCommandSidebar(model: model, window: state, showsHeader: false)
            .environment(\.windowChrome, WindowChrome(isDark: false)))
        native.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await eventually { native.isKeyWindow && NSApp.isActive }
        try await eventually { element("quickCommand." + item.id.uuidString, in: native) != nil }
        precondition(element("quickCommands.destination", in: native) == nil, "There is no terminal destination selector")
        precondition(element("quickCommand.run." + item.id.uuidString, in: native) == nil, "Rows contain no execute buttons")
        try await eventually { descendants(native.contentView!).contains { $0 is QuickCommandPreviewAnchorView } }
        let anchor = descendants(native.contentView!).compactMap { $0 as? QuickCommandPreviewAnchorView }.first!
        let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: native.windowNumber, context: nil, eventNumber: 0,
                                            trackingNumber: 0, userData: nil)!
        anchor.mouseEntered(with: entered)
        try await Task.sleep(for: .milliseconds(450))
        precondition(anchor.previewPanel == nil, "Hover alone must never open the command preview")
        precondition(press(element("quickCommand." + item.id.uuidString, in: native)!))
        try await eventually { anchor.previewPanel != nil }
        precondition(native.isKeyWindow, "Opening preview must not take keyboard focus")
        precondition(state.quickCommandConfirmation == nil && model.tabs.count == 1, "Preview cannot execute or open confirmation")
        precondition(abs(anchor.previewPanel!.frame.width - SheetLayout.commandSidebarPreviewWidth) < 1)
        precondition(element("quickCommands.preview.copy", in: anchor.previewPanel!) != nil)
        precondition(element("quickCommands.preview.run", in: anchor.previewPanel!) != nil)
        let initialPreviewHeight = anchor.previewPanel!.frame.height
        let exited = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: native.windowNumber, context: nil, eventNumber: 0,
                                           trackingNumber: 0, userData: nil)!
        anchor.mouseExited(with: exited)
        try await Task.sleep(for: .milliseconds(250))
        precondition(anchor.previewPanel != nil, "Click preview stays open when the pointer leaves")
        let pasteboard = NSPasteboard.general
        let previousClipboard = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(previousClipboard.map { entries in
                let item = NSPasteboardItem()
                entries.forEach { item.setData($0.1, forType: $0.0) }
                return item
            })
        }
        precondition(press(element("quickCommands.preview.copy", in: anchor.previewPanel!)!))
        precondition(pasteboard.string(forType: .string) == item.command, "Preview copies the complete literal command")
        print("PASS click-only preview, persistent panel, full command copy, no row run or destination selector")

        let button = element("quickCommands.preview.run", in: anchor.previewPanel!)!
        precondition(press(button))
        precondition(state.quickCommandSidebarExecution.isSubmitting)
        precondition(!model.runSidebarQuickCommand(item.id, in: state), "Preview and drag share a submission guard")
        model.confirmQuickCommand(item, in: state)
        try await eventually { !state.quickCommandSidebarExecution.isSubmitting }
        precondition(state.quickCommandConfirmation == nil && model.tabs.count == 1)
        precondition(state.selectedTabID == original.id && model.takeLocalStartupCommand(for: original.id) == nil)
        precondition(state.quickCommandSidebarExecution.error != nil, "Unavailable current terminal reports an error")
        precondition(anchor.previewPanel != nil, "Failed execution stays in preview instead of opening a new terminal")
        try await eventually { element("quickCommands.preview.error", in: anchor.previewPanel!) != nil }
        precondition(anchor.previewPanel!.frame.height > initialPreviewHeight,
                     "A compact preview must grow to show execution errors without clipping")
        precondition(press(element("quickCommands.preview.run", in: anchor.previewPanel!)!))
        precondition(state.quickCommandSidebarExecution.isSubmitting, "Failure must allow an explicit retry")
        try await eventually { !state.quickCommandSidebarExecution.isSubmitting }
        precondition(model.tabs.count == 1)
        print("PASS preview execute, duplicate guard, current-terminal-only rejection, visible failure and retry")

        let reviewedItem = store.commands.first { $0.id == item.id }!
        let reviewedContext = model.quickCommandContext(in: state)
        item.command = "printf '%s\n' 'updated fixture'"
        try store.save(item)
        precondition(!model.runSidebarQuickCommand(item.id, in: state, expectedContext: reviewedContext, expectedItem: reviewedItem),
                     "Changed command must not execute from an old preview")
        model.openLocalTerminal(at: home, placement: .newTab, beside: original.id, in: state)
        try await eventually { model.tabs.count == 2 }
        try await eventually { anchor.previewPanel == nil }
        precondition(!model.runSidebarQuickCommand(item.id, in: state, expectedContext: reviewedContext),
                     "Switching terminals invalidates the preview target")
        try store.remove(item.id)
        precondition(!model.runSidebarQuickCommand(item.id, in: state))
        precondition(model.tabs.count == 2 && state.quickCommandSidebarExecution.error != nil)
        print("PASS command edits, target changes and deleted-command rejection")

        let execution = QuickCommandSidebarExecution()
        let request = try QuickCommandRunRequest(item: item, context: QuickCommandContext(directory: home), directory: home)
        var deliveries = 0
        execution.run(request, perform: { _ in
            deliveries += 1
            try await Task.sleep(for: .milliseconds(650))
            throw QuickCommandError.unavailable
        })
        execution.run(request, perform: { _ in deliveries += 1 })
        try await Task.sleep(for: .milliseconds(550))
        precondition(execution.isSubmitting && deliveries == 1, "Slow operations remain guarded beyond double-click interval")
        try await eventually { !execution.isSubmitting }
        precondition(execution.error != nil)
        execution.run(request, perform: { _ in deliveries += 1 })
        try await eventually { !execution.isSubmitting }
        precondition(deliveries == 2 && execution.error == nil)
        print("PASS slow submission guard, failure feedback and recovery")
    }

    @MainActor static func verifyScrolledCursorRegions(in window: NSWindow) {
        let clip = NSClipView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        clip.documentView = document
        window.contentView!.addSubview(clip)
        defer { clip.removeFromSuperview() }
        let controls: [NSView] = [TabDragHandleView(), QuickCommandDragHandleView(),
            FileTabHandleView(), PinnedLocationDragHandleView(), ClickableCursorView(), FamilyNativeButton()]
        for control in controls {
            control.frame = NSRect(x: 0, y: 0, width: 260, height: 40)
            document.addSubview(control)
        }
        for origin in [NSPoint(x: 0, y: 200), .zero, NSPoint(x: 0, y: 200)] {
            clip.scroll(to: origin)
            for control in controls {
                precondition(control.bounds.intersection(control.visibleRect).isEmpty == (origin.y > 0))
                // 直接调用真实 AppKit 路径；回归时无效矩形会抛异常并使测试进程退出。
                control.resetCursorRects()
            }
        }
        print("PASS native cursor regions survive scroll out, return and repeated clipping")
    }

    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func value(_ element: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
    }
    @MainActor static func element(_ id: String, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if value(object, "accessibilityIdentifier") as? String == id { return object }
            for child in value(object, "accessibilityChildren") as? [NSObject] ?? [] {
                if let match = find(child) { return match }
            }
            return nil
        }
        return find(root)
    }
    @MainActor static func press(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
    }
    @MainActor static func eventually(line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "QuickCommandSidebarTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for fixture state at line \(line)"])
    }
}
