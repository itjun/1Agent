import AppKit
import GhosttyTerminal
import ObjectiveC
@testable import GooseAgent

@main
enum TerminalRestorationTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                if CommandLine.arguments.contains("--save-output") || CommandLine.arguments.contains("--restore-output") {
                    try await persistedOutput()
                    exit(0)
                }
                try snapshots()
                try outputStore()
                try await terminalPreview()
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
                host.session.receive("\u{1b}[32mLOG_\(index)_BEGIN 中文日志\u{1b}[0m\r\n" + (0..<180).map { "第 \($0) 行\r\n" }.joined() + "LOG_\(index)_END\r\n")
            }
            host.session.waitForPendingOutput()
            let text = host.session.readScreenText()?.text ?? ""
            expect(text.contains("LOG_\(index)_BEGIN 中文日志") && text.contains("LOG_\(index)_END"), "Cold restore must preserve previous visible and scrolled-off logs")
            expect(text.components(separatedBy: "LOG_\(index)_BEGIN").count - 1 == 1, "Repeated launches must not duplicate previous output")
            expect(!text.contains("LOG_\(1 - index)_BEGIN"), "Terminal logs must never cross sessions")
            if !saving {
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
        model.isQuitting = true
        try await model.prepareForApplicationExit()
        try defaults.data(forKey: SessionSnapshot.storageKey)!.write(to: snapshotURL)
        print("PASS \(saving ? "save" : "cold restore"): two independent terminals, scrollback, Unicode, no duplication and no PTY replay")
    }

    @MainActor
    private final class PreviewProbe: TerminalSurfaceLifecycleDelegate, TerminalSurfaceGridResizeDelegate {
        var surface: TerminalSurface?
        var size: TerminalGridMetrics?
        func terminalDidResize(_ size: TerminalGridMetrics) { self.size = size }
        func terminalDidAttachSurface(_ surface: TerminalSurface) { self.surface = surface }
        func terminalDidDetachSurface() { surface = nil }
    }

    /// 真正的 Ghostty 源画布与预览画布，验证样式和原会话隔离。
    @MainActor static func terminalPreview() async throws {
        TerminalDefaults.registerBundledFonts()
        let sourceSession = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let source = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        let probe = PreviewProbe()
        source.delegate = probe
        source.configuration = TerminalSurfaceOptions(backend: .inMemory(sourceSession))
        source.controller = GhosttyRuntime.controller
        let sourceWindow = NSWindow(contentRect: source.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        sourceWindow.isReleasedWhenClosed = false
        sourceWindow.contentView = source
        sourceWindow.orderFront(nil)
        defer { source.controller = nil; sourceWindow.close() }
        for _ in 0..<100 {
            if sourceSession.hasAttachedSurface && probe.size != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        expect(sourceSession.hasAttachedSurface, "The source fixture must have a real Ghostty surface")
        // 新窗口的 backing scale 会异步到达，先等源网格稳定再记录隔离基线。
        var lastSize: TerminalGridMetrics?
        var stableSamples = 0
        for _ in 0..<50 {
            source.layoutSubtreeIfNeeded()
            if probe.size != nil && probe.size == lastSize { stableSamples += 1 } else { stableSamples = 0 }
            if stableSamples >= 4 { break }
            lastSize = probe.size
            try await Task.sleep(for: .milliseconds(50))
        }
        expect(stableSamples >= 4, "The source grid must settle before the preview isolation check")
        let prompt = "\u{1b}[38;2;20;24;30;48;2;220;140;160m\u{e0b6}\u{f179} itjun "
            + "\u{1b}[38;2;220;140;160;48;2;240;180;120m\u{e0b0} 中文 ~/1Agent "
            + "\u{1b}[38;2;240;180;120;48;2;150;200;160m\u{e0b0} \u{e0a0} main "
            + "\u{1b}[38;2;150;200;160;49m\u{e0b0} \u{f0320} v3.9.6\u{1b}[0m"
        sourceSession.receive(prompt + "\u{1b}[48;2;150;200;160m" + String(repeating: " ", count: 100)
                              + "\u{1b}[0m\r\nPREVIEW_END")
        sourceSession.waitForPendingOutput()
        let beforeText = sourceSession.readViewportText()
        let beforeSize = probe.size
        let beforeClipboard = NSPasteboard.general.changeCount
        expect(probe.surface?.hasSelection() == false, "The fixture begins without a selection")
        guard let snapshot = sourceSession.exportStyledScreen() else {
            throw NSError(domain: "PreviewTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Styled export failed"])
        }
        expect(snapshot.contains("\u{e0b0}") && snapshot.contains("\u{f0320}") && snapshot.contains("中文"),
               "Styled export preserves Powerline, supplementary Nerd Font characters and Chinese")
        expect(snapshot.contains("38;2;") && snapshot.contains("48;2;"), "Styled export retains true-color foreground and background")
        expect(probe.surface?.hasSelection() == false, "Reading a preview must not select the source screen")
        expect(probe.surface?.performBindingAction("select_all") == true, "The fixture can create a selection")
        let selected = probe.surface?.readSelection()
        expect(sourceSession.exportStyledScreen() != nil && probe.surface?.readSelection() == selected,
               "Reading a preview preserves an existing source selection")
        expect(NSPasteboard.general.changeCount == beforeClipboard, "Styled export never writes to the user's clipboard")

        let preview = TerminalPreviewView(output: snapshot + "\u{1b}]52;c;dW53YW50ZWQ=\u{7}\u{1b}[6n",
                                          controller: GhosttyRuntime.controller)
        preview.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let previewWindow = NSWindow(contentRect: preview.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        previewWindow.isReleasedWhenClosed = false
        previewWindow.contentView = preview
        previewWindow.orderFront(nil)
        defer { preview.controller = nil; previewWindow.close() }
        for _ in 0..<100 {
            preview.layoutSubtreeIfNeeded()
            preview.previewSession.waitForPendingOutput()
            if preview.previewSession.readScreenText()?.text.contains("PREVIEW_END") == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let text = preview.previewSession.readScreenText()?.text ?? ""
        expect(text.contains("PREVIEW_END") && text.contains("中文") && text.contains("\u{f0320}"),
               "The independent preview renders the exported display content")
        expect(!text.contains(String(repeating: " ", count: 50)),
               "Trailing colored grid padding must not wrap into extra preview bars")
        let styled = preview.previewSession.exportStyledScreen() ?? ""
        expect(styled.contains("38;2;") && styled.contains("48;2;"), "The native preview retains Starship color blocks")
        previewWindow.setContentSize(NSSize(width: 100, height: 100))
        preview.layoutSubtreeIfNeeded()
        previewWindow.setContentSize(NSSize(width: 600, height: 300))
        preview.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        preview.previewSession.waitForPendingOutput()
        let resized = preview.previewSession.readScreenText()?.text ?? ""
        expect(resized.contains("PREVIEW_END") && !resized.contains(String(repeating: " ", count: 10)),
               "Intermediate SwiftUI sizes must not leave colored reflow padding or duplicate content")
        expect(resized.components(separatedBy: "PREVIEW_END").count == 2, "Resizing replays exactly one snapshot")
        expect(!preview.acceptsFirstResponder, "The preview cannot acquire terminal keyboard focus")
        _ = preview.sendKey(.enter)
        preview.previewSession.sendInput(Data("never-send-to-source\n".utf8))
        let afterText = sourceSession.readViewportText()
        expect(afterText == beforeText, "Preview rendering and input must not alter source text")
        expect(probe.size == beforeSize, "Preview resize must not alter the source grid: before=\(String(describing: beforeSize)), after=\(String(describing: probe.size))")
        expect(probe.surface?.readSelection() == selected, "Preview rendering and input must preserve the source selection")
        expect(NSPasteboard.general.changeCount == beforeClipboard, "Preview replay must not execute clipboard escapes")
        print("ok: native Starship preview preserves RGB colors, Powerline, Nerd Font and Chinese; source selection/grid/input and clipboard remain isolated")
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
