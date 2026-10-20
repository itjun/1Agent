import AppKit
import GhosttyTerminal
@testable import GooseAgent

@main
enum TerminalRestorationTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
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

    static func snapshots() throws {
        let legacy = Data(#"{"tabs":[],"version":2}"#.utf8)
        let old = try JSONDecoder().decode(SessionSnapshot.self, from: legacy)
        expect(old.departedAt == nil, "Old snapshots must decode without inventing an exit time")
        let legacyTab = try JSONDecoder().decode(SessionSnapshot.Tab.self, from: Data("{\"id\":\"\(UUID())\",\"directory\":\"/tmp\"}".utf8))
        expect(legacyTab.agentConversation == nil, "Old terminal snapshots do not invent an Agent conversation")
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
