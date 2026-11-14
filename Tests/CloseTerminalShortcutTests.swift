import AppKit
import ObjectiveC
@testable import GooseAgent

/// 使用生产快捷键入口和原生菜单，所有会话都是不启动进程的临时预览。
@main enum CloseTerminalShortcutTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            await run()
            print("CloseTerminalShortcutTests passed")
            exit(0)
        }
        NSApp.run()
    }

    @MainActor static func run() async {
        let suite = "oneagent.close-shortcut.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let getter = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard))!
        let previous = method_setImplementation(getter,
            imp_implementationWithBlock({ _ in defaults } as @convention(block) (AnyObject) -> UserDefaults))
        defer { method_setImplementation(getter, previous); defaults.removePersistentDomain(forName: suite) }

        let delegate = AppDelegate()
        FamilyMenuPresenter.shared.applicationShortcut = delegate.contextMenuCloseItem
        defer { FamilyMenuPresenter.shared.applicationShortcut = nil }
        let model = delegate.model, state = model.mainWindow
        MainWindowManager.shared.show(state, model: model)
        let window = MainWindowManager.shared.window(for: state)!
        window.contentViewController = nil
        window.contentView = NSView(frame: window.contentLayoutRect)
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<100 {
            if window.isKeyWindow { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        expect(window.isKeyWindow, "fixture must own the keyboard")
        defer { window.close() }

        for chord in [AppShortcutID.closeTab.defaultChord, KeyChord(key: "w", modifiers: [.command, .control])] {
            AppShortcuts.setChords([.closeTab: chord], store: defaults)
            for isSplit in [false, true] {
                for menuKind in ["none", "sidebar", "pane", "native-pane"] {
                    model.open(.preview(path: "/tmp/close-selected"), placement: .newTab, beside: UUID(), in: state)
                    let selected = state.selectedTabID!
                    model.open(.preview(path: "/tmp/keep-hovered"), placement: isSplit ? .split(.right) : .newTab,
                               beside: selected, in: state)
                    let other = state.selectedTabID!
                    // 菜单记住非选中会话；随后选中另一终端，菜单目标不能接管快捷键。
                    let items = menuKind == "sidebar"
                        ? SidebarActions.panelItems(model.panelRow(for: other, in: state)!, model: model, window: state, onRename: {})
                        : TerminalPaneActions.items(tab: model.tabs.first { $0.id == other }!, model: model, window: state)
                    model.selectOnly(selected, in: state, focusTerminal: false)
                    if menuKind == "none" {
                        expect(delegate.handleShortcut(keyEvent(chord, in: window)) == nil, "close shortcut must be consumed")
                    } else {
                        let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
                            MainActor.assumeIsolated {
                                guard let menu = FamilyMenuPresenter.shared.activeMenu else { return }
                                timer.invalidate()
                                _ = menu.performKeyEquivalent(with: keyEvent(chord, in: window))
                                FamilyMenuPresenter.shared.dismiss()
                            }
                        }
                        RunLoop.main.add(timer, forMode: .eventTracking)
                        let timeout = Timer(timeInterval: 3, repeats: false) { _ in
                            MainActor.assumeIsolated { FamilyMenuPresenter.shared.dismiss() }
                        }
                        RunLoop.main.add(timeout, forMode: .eventTracking)
                        if menuKind == "native-pane" {
                            let terminal = SSHTerminalNSView(frame: .zero)
                            terminal.paneMenuItems = { items }
                            let click = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 25, y: 200),
                                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                eventNumber: 1, clickCount: 1, pressure: 1)!
                            FamilyMenuPresenter.shared.show(terminal.selectionContextMenu(), with: click, for: window.contentView!)
                        } else {
                            FamilyMenuPresenter.shared.show(items, at: window.frame.origin, owner: window)
                        }
                        timer.invalidate()
                        timeout.invalidate()
                    }
                    expect(model.tabs.count == 1, "\(menuKind): native key event must dispatch exactly one close (remaining: \(model.tabs.count))")
                    expect(!model.tabs.contains { $0.id == selected } && model.tabs.contains { $0.id == other },
                           "\(menuKind), split=\(isSplit): close shortcut must close selected terminal and preserve hovered/menu terminal")
                    expect(FamilyMenuPresenter.shared.activeMenu == nil, "close shortcut dismisses the stale context menu")
                    model.closeTab(other)
                }
            }
        }
    }

    @MainActor static func keyEvent(_ chord: KeyChord, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: NSPoint(x: 25, y: 200),
            modifierFlags: chord.menuModifierMask, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: chord.key, charactersIgnoringModifiers: chord.key,
            isARepeat: false, keyCode: 13)!
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
}
