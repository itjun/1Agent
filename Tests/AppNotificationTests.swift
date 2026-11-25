import AppKit
import ObjectiveC
import SwiftUI
@testable import Natty

@main enum AppNotificationTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            await run()
            exit(0)
        }
        NSApp.run()
    }

    @MainActor static func run() async {
        let suite = "natty.notifications.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        let getter = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!
        let previous = method_getImplementation(getter)
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(getter, imp_implementationWithBlock(block))
        defer { method_setImplementation(getter, previous); defaults.removePersistentDomain(forName: suite) }
        let store = AppNotificationStore()
        let progress = AppNotificationItem(id: "upload", title: "文件", message: "上传中", level: .progress)
        store.show(progress)
        store.dismiss(progress.id)
        store.show(progress, isNewEvent: false)
        expect(store.current == nil, "dismissed transfer progress stays hidden")
        store.show(AppNotificationItem(id: "upload", title: "文件", message: "完成", level: .success), expiresAfter: 0.08)
        expect(store.current?.level == .success, "completion is a new event")
        let expiryDeadline = Date().addingTimeInterval(2)
        while store.current != nil && Date() < expiryDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        expect(store.current == nil, "success expires")
        store.show(progress, expiresAfter: 0.08)
        store.show(AppNotificationItem(id: "upload", title: "文件", message: "失败", level: .error))
        try? await Task.sleep(for: .milliseconds(120))
        expect(store.current?.level == .error, "stale timer cannot dismiss replacement error")
        store.show(AppNotificationItem(id: "connection", title: "主机", message: "失败", level: .error))
        store.show(progress, isNewEvent: false)
        expect(store.current?.id == "connection", "older progress cannot steal newer notification")
        store.dismiss("connection")
        expect(store.current == nil, "dismissal never resurrects a replaced notification")
        let error = AppNotificationItem(id: "failure", title: "", message: "找不到文件 cp。，", level: .error)
        expect(error.text == "找不到文件 cp", "notification has no trailing sentence punctuation")
        store.show(error, expiresAfter: 0.08)
        store.setHovered(true)
        try? await Task.sleep(for: .milliseconds(350))
        expect(store.current != nil && !store.isFading, "hover pauses expiry")
        store.setHovered(false)
        try? await Task.sleep(for: .milliseconds(120))
        expect(store.isFading, "leaving restarts countdown and begins fade")
        store.show(progress)
        try? await Task.sleep(for: .milliseconds(230))
        expect(store.current?.id == progress.id && !store.isFading, "replacement cancels an in-flight fade")
        store.reset()
        let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError,
                              userInfo: [NSFilePathErrorKey: "/tmp/cp"])
        expect(FileError.notificationMessage(for: missing) == String(format: String(localized: "Cannot find file %@"), "cp"),
               "missing-file notice uses the filename without system error punctuation")

        let model = AppModel()
        MainWindowManager.shared.show(model.mainWindow, model: model)
        let commandWindow = MainWindowManager.shared.window(for: model.mainWindow)!
        // 隔离终端进程，只从生产事件入口验证通知投递。
        commandWindow.contentView = NSView()
        TerminalActivity.shared.model = model
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<100 {
            if NSApp.isActive { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        expect(NSApp.isActive, "command notification fixture is foreground")
        model.openRemoteTerminal("notification-fixture", at: "/tmp", placement: .newTab, beside: UUID(), in: model.mainWindow)
        for _ in 0..<100 {
            if !model.tabs.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let tabID = model.tabs.first!.id
        let terminal = SSHTerminalNSView(frame: .zero)
        terminal.sessionID = model.tabs.first!.sessionID
        terminal.eventRelay.terminal = terminal
        let commandStore = AppNotifications.presenter(for: commandWindow).store
        expect(TerminalActivity.shared.isAttended(model.tabs.first!), "failed build fixture is on screen")
        terminal.eventRelay.terminalDidFinishCommand(exitCode: 1, durationNanos: 51_300_000_000)
        expect(commandStore.current?.level == .error, "foreground build failure must show an error notification")
        expect(commandStore.current?.terminalSessionID == terminal.sessionID, "notification retains its originating terminal")
        commandStore.dismiss(commandStore.current!.id)
        terminal.eventRelay.terminalDidFinishCommand(exitCode: 127, durationNanos: 10_000_000)
        expect(commandStore.current?.level == .error, "immediate command-not-found failure must notify")
        expect(commandStore.current!.message.contains("127"), "failure notification includes the exit code")
        commandStore.dismiss(commandStore.current!.id)
        terminal.eventRelay.terminalDidFinishCommand(exitCode: 0, durationNanos: 10_000_000)
        terminal.eventRelay.terminalDidFinishCommand(exitCode: nil, durationNanos: 10_000_000)
        expect(commandStore.current == nil, "short successful or unknown results stay quiet")
        model.markClosed(tabID, lived: 10)
        expect(model.tabs.first!.connectionNotice == .waiting(0), "transport loss waits in orange before automatic retry")
        try? await Task.sleep(for: .milliseconds(1200))
        expect(model.tabs.first!.connectionNotice == .connecting(1), "automatic retry becomes gray progress")
        model.noteWorkingDirectory("invalid-relative-path", forSession: model.tabs.first!.sessionID)
        expect(model.tabs.first!.connectionNotice == .connecting(1), "invalid shell reports cannot claim restored")
        model.noteWorkingDirectory("/tmp", forSession: model.tabs.first!.sessionID)
        expect(model.tabs.first!.connectionNotice == .recovered, "confirmed shell becomes green")
        model.markClosed(tabID, lived: 0)
        expect(model.tabs.first!.connectionNotice == .waiting(1), "brief retry failure waits for the next attempt")
        model.closeTab(tabID)
        commandWindow.close()
        TerminalActivity.shared.model = nil

        let owner = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 900, height: 600),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        owner.contentView = editor
        owner.makeKeyAndOrderFront(nil)
        owner.makeFirstResponder(editor)
        let presenter = AppNotifications.presenter(for: owner)
        let messages: [AppNotificationLevel: String] = [.information: "后台任务已开始", .progress: "正在重连（1/3）", .success: "连接已恢复", .warning: "连接已断开，等待重试", .error: "重连失败，已重试 3 次"]
        let screenshotDirectory = ProcessInfo.processInfo.environment["NATTY_NOTIFICATION_SNAPSHOT_DIR"]
        for isDark in [false, true] {
            defaults.set(isDark ? "dark" : "light", forKey: TerminalAppearance.storageKey)
            AppearanceDriver.shared.reapply()
            for level in AppNotificationLevel.allCases {
                var item = AppNotificationItem(id: "fixture", title: "cdcp-nginx", message: messages[level]!, level: level)
                if level != .success {
                    item.actionTitle = level == .progress ? "取消" : level == .information ? "查看详情" : "重新连接"
                    item.action = {}
                }
                presenter.store.show(item)
                presenter.layout()
                try? await Task.sleep(for: .milliseconds(100))
                let panel = owner.childWindows!.first { $0.identifier?.rawValue == "app.notification" }!
                expect(!panel.canBecomeKey && owner.firstResponder === editor, "notification never steals terminal focus")
                let bounds = owner.convertToScreen(owner.contentView!.convert(owner.contentView!.bounds, to: nil))
                expect(abs(panel.frame.midX - bounds.midX) < 1 && abs(panel.frame.maxY - bounds.maxY + AppNotificationLayout.inset) < 1,
                       "banner is top centered below the window chrome")
                expect(!panel.hasShadow, "flat notification has no floating window shadow")
                if let directory = screenshotDirectory, let view = panel.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("\(isDark ? "dark" : "light")-\(level.rawValue).png"))
                }
            }
        }
        // 分屏和侧栏不改变横向中心 缩放窗口后按新的内容宽度换行
        presenter.store.show(AppNotificationItem(id: "terminal-fixture", title: "", message: "找不到文件 cp", level: .error,
                                                 terminalSessionID: "split-terminal"))
        presenter.layout()
        try? await Task.sleep(for: .milliseconds(100))
        let terminalPanel = owner.childWindows!.first!
        expect(terminalPanel.frame.width < 220 && terminalPanel.frame.height == 40, "short banner fits its text in one row: \(terminalPanel.frame)")
        owner.setContentSize(CGSize(width: 300, height: 300))
        presenter.store.show(AppNotificationItem(id: "long", title: "", message: String(repeating: "长文件名", count: 20), level: .error))
        presenter.layout()
        try? await Task.sleep(for: .milliseconds(100))
        let bounds = owner.convertToScreen(owner.contentLayoutRect)
        expect(terminalPanel.frame.width <= bounds.width - 32 && abs(terminalPanel.frame.midX - bounds.midX) < 1,
               "narrow banners stay inside and centered on their window")
        let second = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        second.isReleasedWhenClosed = false
        let firstTransfer = TransferToast.shared.begin("first", in: owner)
        let secondTransfer = TransferToast.shared.begin("second", in: second)
        TransferToast.shared.finish(firstTransfer, "first done")
        expect(presenter.store.current?.message == "first done", "transfer completes in its originating window")
        expect(AppNotifications.presenter(for: second).store.current?.message == "second", "other window unaffected")
        TransferToast.shared.finish(secondTransfer, "second done")
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("cp")
        do {
            try await LocalFileSystem().delete([absent.path])
            fatalError("missing file deletion must report an error")
        } catch {
            TransferToast.shared.fail(nil, FileError.notificationMessage(for: error), in: owner)
        }
        let expected = String(format: String(localized: "Cannot find file %@"), "cp")
        expect(presenter.store.current?.text == expected, "real file error becomes one short sentence ending in cp")
        try? await Task.sleep(for: .milliseconds(2600))
        expect(presenter.store.current?.level == .error, "file failure stays long enough to read")
        try? await Task.sleep(for: .milliseconds(850))
        expect(presenter.store.current == nil && terminalPanel.parent == nil, "file failure automatically fades and hides")
        owner.close()
        second.close()
        expect(presenter.store.current == nil, "closing window clears notifications and timers")
        print("AppNotificationTests passed: dismissal, expiry races, priority, five states, light/dark, geometry, focus, multiwindow transfers, cleanup")
    }
    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
}
