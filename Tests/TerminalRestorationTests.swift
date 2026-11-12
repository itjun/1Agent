import AppKit
import GhosttyTerminal
import ObjectiveC
@testable import GooseAgent

@main
enum TerminalRestorationTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        Task { @MainActor in
            do {
                if CommandLine.arguments.contains("--save-output") || CommandLine.arguments.contains("--restore-output") {
                    try await persistedOutput()
                    exit(0)
                }
                try snapshots()
                try outputStore()
                try await terminal(restoration: TerminalRestoration(departedAt: Date(timeIntervalSince1970: 0)))
                try await terminal(restoration: nil)
                print("TerminalRestorationTests passed: legacy/dated snapshots, timezone, unknown departure, deferred startup, one-time output, PTY input, reconnect and new terminals")
                exit(0)
            } catch {
                fputs("TerminalRestorationTests failed: \(error)\n", stderr)
                exit(1)
            }
        }
        NSApp.run()
    }

    static func outputStore() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oneagent-output-store-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TerminalOutputStore(directory: folder)
        let first = UUID(), second = UUID()
        expect(store.load(first) == nil, "Old sessions without a log archive must still open")
        try store.save("中文日志\ncommand text\u{1b}]52;c;payload\u{7}\u{9b}2J\n", for: first)
        let text = store.load(first)!
        expect(text.contains("中文日志") && !text.contains("\u{1b}") && !text.contains("\u{7}") && !text.contains("\u{9b}"), "Archives must contain inert display text only")
        try store.save("\u{1b}]11;rgb:00/00/00\u{1b}\\\u{1b}[38;2;240;160;180;48;5;3mprompt\u{1b}[0m\u{1b}[2J\u{1b}[?1049h\u{1b}Ptmux\u{1b}\\\u{1b}(Bdone\n", for: first)
        expect(store.load(first) == "\u{1b}[38;2;240;160;180;48;5;3mprompt\u{1b}[0mdone",
               "Archives keep only SGR colors; color changes, screen control and string sequences are dropped")
        let file = folder.appendingPathComponent(first.uuidString + ".txt")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Saved logs must be private")
        let long = String(repeating: "中文", count: TerminalOutputStore.byteLimit / 6 + 100)
        try store.save(long, for: first)
        expect(store.load(first)!.utf8.count <= TerminalOutputStore.byteLimit && store.load(first)!.hasSuffix("中文"), "Byte limits must keep the newest complete UTF-8 characters")
        try store.save((0..<(TerminalOutputStore.lineLimit + 5)).map { "line_\($0)" }.joined(separator: "\n"), for: first)
        expect(store.load(first)!.components(separatedBy: "\n").count == TerminalOutputStore.lineLimit && store.load(first)!.hasPrefix("line_5\n"), "Line limits must retain the newest output")
        try store.save("second terminal", for: second)
        store.prune(keeping: [second])
        expect(store.load(first) == nil && store.load(second) == "second terminal", "Cleanup must preserve every saved terminal, including unmounted ones")
        try Data([0xff]).write(to: folder.appendingPathComponent(second.uuidString + ".txt"))
        expect(store.load(second) == nil, "A corrupt archive must not prevent startup")
        let blocked = folder.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        do {
            try TerminalOutputStore(directory: blocked).save("logs", for: UUID())
            throw NSError(domain: "RestorationTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Save failure was hidden"])
        } catch let error as NSError { expect(error.domain != "RestorationTests", "Write failures must reach the quit flow") }
    }

    /// Two separate processes exercise the production quit snapshot and cold launch.
    @MainActor static func persistedOutput() async throws {
        guard let home = ProcessInfo.processInfo.environment["ONEAGENT_TEST_HOME"], home.hasPrefix("/private/tmp/oneagent-restoration.") else {
            throw NSError(domain: "RestorationTests", code: 1)
        }
        let defaults = UserDefaults(suiteName: "oneagent.output-restoration.tests")!
        let getter = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard))!
        let old = method_setImplementation(getter, imp_implementationWithBlock({ _ in defaults } as @convention(block) (AnyObject) -> UserDefaults))
        defer { method_setImplementation(getter, old) }
        let saving = CommandLine.arguments.contains("--save-output")
        let snapshotURL = URL(fileURLWithPath: home).appendingPathComponent("snapshot.json")
        let ids = (1...2).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
        let windowID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        if saving {
            let initial = SessionSnapshot(tabs: ids.map { .init(id: $0, directory: home) }, workspaces: [], windows: [
                .init(id: windowID, blocks: [.localGroup, .ungrouped], localGroup: ids, ungrouped: [], selected: ids[0])
            ], keyWindow: windowID)
            defaults.set(try JSONEncoder().encode(initial), forKey: SessionSnapshot.storageKey)
        } else { defaults.set(try Data(contentsOf: snapshotURL), forKey: SessionSnapshot.storageKey) }
        var views: [UUID: SSHTerminalNSView] = [:]
        for id in ids {
            views[id] = SSHTerminalRegistry.view(for: "\(id.uuidString)#0") {
                let host = TerminalProcessHost()
                let view = SSHTerminalNSView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
                view.sessionID = "\(id.uuidString)#0"
                view.processHost = host
                view.eventRelay.terminal = view
                view.delegate = view.eventRelay
                view.controller = GhosttyRuntime.controller
                view.configuration = TerminalSurfaceOptions(backend: .inMemory(host.session))
                return view
            }
        }
        let model = AppModel()
        MainWindowManager.shared.attach(model: model)
        model.restoreLastSession()
        for _ in 0..<250 { if model.tabs.count == ids.count { break }; try await Task.sleep(for: .milliseconds(20)) }
        expect(model.tabs.count == ids.count, "All saved terminals must reopen")
        let state = model.window(for: windowID)!
        let native = MainWindowManager.shared.window(for: state)!
        native.setContentSize(NSSize(width: 1000, height: 600))
        defer { for id in ids { SSHTerminalRegistry.destroy("\(id.uuidString)#0") }; native.orderOut(nil) }
        for id in ids {
            let host = views[id]!.processHost!
            host.start(TerminalLaunch(executable: "/bin/cat", args: [], environment: ["PATH=/usr/bin:/bin"], directory: home),
                       restoration: model.tabs.first(where: { $0.id == id })!.restoration)
        }
        for _ in 0..<250 { if views.values.allSatisfy({ $0.processHost!.process.shellPid > 0 }) { break }; try await Task.sleep(for: .milliseconds(20)) }
        for (index, id) in ids.enumerated() {
            let host = views[id]!.processHost!
            expect(host.process.shellPid > 0, "Restored terminal must accept input")
            if saving {
                // The begin marker scrolls offscreen; logs include color and CJK text.
                host.session.receive("\u{1b}[32mLOG_\(index)_BEGIN 中文日志\u{1b}[0m\r\n" + (0..<1000).map { "第 \($0) 行\r\n" }.joined() + "SOFT_WRAP_" + String(repeating: "中文🙂", count: 180) + "_END\r\nLOG_\(index)_END\r\n")
            }
            host.session.waitForPendingOutput()
            let text = host.session.readScreenText()?.text ?? ""
            expect(text.contains("LOG_\(index)_BEGIN 中文日志") && text.contains("LOG_\(index)_END"), "Cold restore must preserve previous visible and scrolled-off logs")
            expect(text.contains("SOFT_WRAP_" + String(repeating: "中文🙂", count: 180) + "_END"), "History export must preserve a logical line spanning many physical rows")
            expect(text.components(separatedBy: "LOG_\(index)_BEGIN").count - 1 == 1, "Repeated launches must not duplicate previous output")
            expect(!text.contains("LOG_\(1 - index)_BEGIN"), "Terminal logs must never cross sessions")
            if !saving {
                if index == 0 {
                    expect((0..<3).allSatisfy { text.contains("FILE_PREVIEW_\($0)") },
                           "Output received during file preview survives repeated cold restores")
                }
                let styled = host.session.readScreenStyledText() ?? ""
                expect(styled.range(of: "\u{1b}\\[[0-9;:]*38;[0-9;:]*mLOG_\(index)_BEGIN", options: .regularExpression) != nil,
                       "Cold restore must keep the previous output's colors")
                expect(text.range(of: "LOG_\(index)_END")!.lowerBound < text.range(of: String(localized: "Restored at %@").components(separatedBy: "%@")[0], options: .backwards)!.lowerBound,
                       "Old output must precede the current restoration notice")
                host.startWhenReady()
                host.session.waitForPendingOutput()
                expect(host.session.readScreenText()!.text.components(separatedBy: "LOG_\(index)_BEGIN").count - 1 == 1, "Startup callbacks must replay history only once")
                let revision = host.process.commandInputRevision
                expect(revision == 0, "Restoration must not send historical commands to the PTY")
                host.process.write(Data("FRESH_INPUT_\(index)\n".utf8))
                for _ in 0..<100 {
                    host.session.waitForPendingOutput()
                    if host.session.readScreenText()?.text.contains("FRESH_INPUT_\(index)") == true { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                expect(host.session.readScreenText()?.text.contains("FRESH_INPUT_\(index)") == true, "Input must work after old output is restored")
            }
        }
        if saving { try await filePreviewContinuity(model: model, state: state, window: native, terminal: views[ids[0]]!, home: home) }
        model.isQuitting = true
        try await model.prepareForApplicationExit()
        try defaults.data(forKey: SessionSnapshot.storageKey)!.write(to: snapshotURL)
        print("PASS \(saving ? "save" : "cold restore"): two independent terminals, scrollback, Unicode, no duplication and no PTY replay")
    }

    /// 在真实文件页反复预览、调整宽度及切回终端；隔离的 cat PTY 全程持续收发。
    @MainActor static func filePreviewContinuity(model: AppModel, state: WindowState, window: NSWindow,
                                                terminal: SSHTerminalNSView, home: String) async throws {
        let file = URL(fileURLWithPath: home).appendingPathComponent("reading-fixture.txt")
        let source = "阅读测试\nsecond line\n"
        try Data(source.utf8).write(to: file)
        let entry = try await LocalFileSystem().list(home).first { $0.path == file.path }!
        state.presentation.sidebarCollapsed = false
        window.setContentSize(NSSize(width: 1440, height: 900))
        try await Task.sleep(for: .milliseconds(300))
        let host = terminal.processHost!
        let pid = host.process.shellPid
        let identity = host.process.identity
        let terminalSize = terminal.bounds.size
        let workspace = model.fileWorkspace(for: state)
        model.showFiles(for: state.selectedTabID, in: state)
        let column = workspace.localColumn
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func value(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        func element(_ id: String) -> NSObject? {
            var visited = Set<ObjectIdentifier>()
            func find(_ object: NSObject) -> NSObject? {
                guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
                if value(object, "accessibilityIdentifier") as? String == id { return object }
                return (value(object, "accessibilityChildren") as? [NSObject] ?? []).compactMap(find).first
            }
            return find(window)
        }
        func frame(_ object: NSObject) -> NSRect {
            let selector = NSSelectorFromString("accessibilityFrame")
            typealias Getter = @convention(c) (AnyObject, Selector) -> NSRect
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
        func press(_ id: String) {
            guard let object = element(id) else { expect(false, "Missing preview action: " + id); return }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            typealias Action = @convention(c) (AnyObject, Selector) -> Bool
            expect(unsafeBitCast(object.method(for: selector), to: Action.self)(object, selector), "Preview action activates: " + id)
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }
        func eventually(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NSError(domain: "RestorationTests", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
        }
        try await eventually("File browser finishes loading the terminal directory") {
            !column.loading && column.entries.contains { $0.path == entry.path }
        }
        let directory = column.directory
        let layout = workspace.layout
        let previewID = "files.preview.\(column.id)"
        func previewFrame() -> NSRect { frame(element(previewID)!) }
        func previewDivider() -> PaneDividerView? {
            let edge = previewFrame().minX
            return descendants(window.contentView!).compactMap { $0 as? PaneDividerView }.first {
                abs(window.convertToScreen($0.convert($0.bounds, to: nil)).midX - edge) < 4
            }
        }
        func checkDivider() {
            guard let divider = previewDivider() else { expect(false, "File preview has a native resize handle"); return }
            let content = window.contentView!
            let rect = divider.convert(divider.bounds, to: nil)
            for delta: CGFloat in [-2, 0, 2] {
                let point = content.superview!.convert(NSPoint(x: rect.midX + delta, y: rect.midY), from: nil)
                expect(content.hitTest(point) === divider, "Both sides of the preview divider receive resize hits")
            }
        }
        for cycle in 0..<3 {
            workspace.open(entry, in: column, window: window)
            try await eventually("File preview loads its literal contents") {
                column.preview?.decoded?.text == source && element(previewID) != nil
            }
            try await settle()
            let normalFrame = previewFrame()
            expect(normalFrame.width > 0 && element("files.localLocation") != nil,
                   "Preview keeps file navigation visible")
            expect(!terminal.canRestoreModalFocus, "The terminal cannot reclaim focus from the Files page")
            let hiddenTerminalSize = terminal.bounds.size
            checkDivider()
            previewDivider()!.onDragChanged(40)
            previewDivider()!.onDragEnded()
            try await settle()
            expect(abs(previewFrame().width - (normalFrame.width - 40)) < 1,
                   "Dragging the file preview boundary changes its width")
            checkDivider()
            expect(terminal.bounds.size == hiddenTerminalSize, "Preview resizing does not resize the retained terminal")
            expect(SSHTerminalRegistry.automationView(terminal.sessionID!) === terminal,
                   "File preview retains the same native terminal surface")
            let marker = "FILE_PREVIEW_\(cycle)"
            host.process.write(Data((marker + "\n").utf8))
            try await eventually("Original PTY receives output while the Files page is visible") {
                host.session.waitForPendingOutput()
                return host.session.readScreenText()?.text.contains(marker) == true
            }
            expect(host.process.shellPid == pid && host.process.identity == identity, "Preview never restarts the terminal")
            press("files.preview.find")
            try await settle()
            let code = descendants(window.contentView!).compactMap { $0 as? PreviewTextView }.first { $0.string == source }!
            expect(code.enclosingScrollView?.isFindBarVisible == true, "Find opens in the real preview")
            press("files.preview.close")
            try await eventually("Close removes the preview") { column.preview == nil && element(previewID) == nil }
            expect(column.directory == directory && workspace.layout == layout, "Close preserves browsing and pane layout")
            model.showSection(.terminals, in: state)
            try await settle()
            expect(terminal.canRestoreModalFocus && terminal.bounds.size == terminalSize,
                   "Returning to Terminals restores focus eligibility and its original grid")
            model.showSection(.files, in: state)
            try await settle()
            workspace.open(entry, in: column, window: window)
            try await eventually("Preview reopens") { element(previewID) != nil && column.preview?.decoded != nil }
            try await settle()
            expect(previewFrame() == normalFrame, "Reopening restores the default preview geometry")
            let reopened = descendants(window.contentView!).compactMap { $0 as? PreviewTextView }.first { $0.string == source }!
            expect(reopened.enclosingScrollView?.isFindBarVisible == false, "A reopened preview does not replay Find")
            press("files.preview.close")
            try await settle()
        }
        workspace.open(entry, in: column, window: window)
        try await eventually("Preview reopens for window resizing") { element(previewID) != nil }
        for width: CGFloat in [1100, 1800, 1440] {
            window.setContentSize(NSSize(width: width, height: 900))
            try await settle()
            let card = previewFrame()
            expect(card.width > 0 && window.convertToScreen(window.contentLayoutRect).contains(card),
                   "Preview remains inside the resized file workspace")
            expect(element("files.preview.find") != nil && element("files.preview.close") != nil,
                   "Preview actions remain available after window resizing")
        }
        press("files.preview.close")
        model.showSection(.terminals, in: state)
        try await settle()
        expect(terminal.canRestoreModalFocus && terminal.bounds.size == terminalSize,
               "Leaving Files restores the terminal layout")
        expect(host.process.shellPid == pid && host.process.identity == identity, "Leaving Files retains the original session")
        print("PASS file preview: native resize handle, find/close/reopen, page navigation, window resizing, unchanged PTY and live output")
    }

    static func snapshots() throws {
        let legacy = Data(#"{"tabs":[],"version":2}"#.utf8)
        let old = try JSONDecoder().decode(SessionSnapshot.self, from: legacy)
        expect(old.departedAt == nil, "Old snapshots must decode without inventing an exit time")
        let legacyTab = try JSONDecoder().decode(SessionSnapshot.Tab.self, from: Data("{\"id\":\"\(UUID())\",\"directory\":\"/tmp\"}".utf8))
        expect(legacyTab.directory == "/tmp", "Old terminal snapshots retain their directory")
        let agentTab = try JSONDecoder().decode(SessionSnapshot.Tab.self, from: Data("{\"id\":\"\(UUID())\",\"directory\":\"/tmp\",\"agentConversation\":{\"kind\":\"pi\",\"sessionID\":\"legacy\"}}".utf8))
        let encodedTab = try JSONEncoder().encode(agentTab)
        expect(!String(decoding: encodedTab, as: UTF8.self).contains("agentConversation"), "Legacy Agent metadata is ignored and never restored or persisted")
        let date = Date(timeIntervalSince1970: 0)
        var saved = SessionSnapshot(tabs: [], workspaces: [], windows: [], keyWindow: nil, departedAt: date)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(saved))
        expect(decoded.departedAt == date, "Departure must survive persistence")
        saved.departedAt = nil
        let cleared = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(saved))
        expect(cleared.departedAt == nil, "A running-session save must clear the previous exit")
        let notice = TerminalRestoration(departedAt: date).notice(restoredAt: date.addingTimeInterval(300), timeZone: TimeZone(secondsFromGMT: 28800)!)
        expect(notice.contains("01/01 08:00") && notice.contains("01/01 08:05"), "Both dates must use the local timezone")
        let unknown = TerminalRestoration(departedAt: nil).notice(restoredAt: date)
        expect(unknown.contains(String(localized: "Left at unknown time")), "Legacy exit time must be explicitly unknown")
    }

    @MainActor static func terminal(restoration: TerminalRestoration?) async throws {
        let host = TerminalProcessHost()
        let launch = TerminalLaunch(executable: "/bin/cat", args: [], environment: ["PATH=/usr/bin:/bin"], directory: "/tmp")
        host.start(launch, restoration: restoration)
        expect(host.process.shellPid == 0, "Startup must wait for the native surface")
        let view = SSHTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.processHost = host
        view.eventRelay.terminal = view
        view.delegate = view.eventRelay
        view.controller = GhosttyRuntime.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(host.session))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { host.terminate(); window.close() }
        for _ in 0..<100 {
            if host.process.shellPid > 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        expect(host.process.shellPid > 0, "A mounted surface must start the PTY")
        host.startWhenReady()
        host.startWhenReady()
        host.process.write(Data("RESTORATION_INPUT_OK\n".utf8))
        var text = ""
        for _ in 0..<100 {
            host.session.waitForPendingOutput()
            text = host.session.readScreenText()?.text ?? ""
            if text.contains("RESTORATION_INPUT_OK") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        expect(text.contains("RESTORATION_INPUT_OK"), "Input must work after the notice")
        let expected = restoration == nil ? 0 : 4 // Two divider ends on each of two lines.
        expect(text.components(separatedBy: "──").count - 1 == expected, "Restoration must print exactly once; new terminals must have no marker")
        if restoration != nil {
            expect(text.range(of: "──")!.lowerBound < text.range(of: "RESTORATION_INPUT_OK")!.lowerBound,
                   "The notice must precede process output")
        }
        host.cancelConnectionAttempt()
        host.startWhenReady()
        expect(host.process.shellPid == 0, "Cancel stops the local process without restarting on focus")
        host.session.waitForPendingOutput()
        expect(host.session.readScreenText()?.text.contains("RESTORATION_INPUT_OK") == true,
               "Cancel keeps terminal output available")
        let processIdentity = host.process.identity
        host.restart(notice: "TEST_RECONNECT")
        expect(host.process.identity != processIdentity, "Reconnect must invalidate confirmed quick-command targets even when the terminal surface is retained")
        host.session.waitForPendingOutput()
        let restarted = host.session.readScreenText()?.text ?? ""
        expect(restarted.components(separatedBy: "──").count - 1 == expected, "Reconnect must not repeat the startup marker")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
