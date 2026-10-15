import AppKit
import Foundation
import GhosttyTerminal

/// Run against the real vendored wrapper and pinned binary. No PTY, shell, SSH,
/// clipboard or user document is involved; the NSWindow is never ordered onscreen.
@main
enum TerminalHistoryEngineTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let controller = TerminalController()
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = AppTerminalView(frame: window.contentView!.bounds)
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(3)
        while !session.hasAttachedSurface, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        expect(session.hasAttachedSurface, "native surface attaches without a running shell")
        session.receive((0..<500).map { "archive-row-\($0)\r\n" }.joined())
        session.waitForPendingOutput()
        let all = session.readScreenText()!
        expect(all.text.contains("archive-row-0"), "full export includes offscreen scrollback")
        expect(all.text.contains("archive-row-499"), "full export includes newest text without scrollbar event")
        let small = session.readScreenText(maxRows: 10, maxBytes: 1024)!
        expect(small.text.split(separator: "\n", omittingEmptySubsequences: false).count <= 10, "row bound")
        expect(small.text.utf8.count <= 1024, "byte bound")
        expect(small.firstRow > 0 && small.text.contains("archive-row-499"), "bounds retain newest physical rows")
        let payloadCases: [(String, Bool)] = [
            ("\u{1b}]2;title [?1049h\u{07}", false),
            ("\u{1b}Pignored\u{07}[?1049h\u{1b}\\", false),
            // Ghostty terminates the string on ESC and recognizes a following CSI,
            // even without a string-terminator '\\'. The archive parser must agree.
            ("\u{1b}]2;title \u{1b}[?1049h\u{07}", true),
            ("\u{1b}Pignored\u{07}\u{1b}[?1049h\u{1b}\\", true),
            ("\u{1b}[?001049h", true),
            ("\u{1b}[?10\u{07}49h", true),
        ]
        for (control, switches) in payloadCases {
            session.receive(control)
            session.waitForPendingOutput()
            let engineAlternate = session.readScreenText()?.text.contains("archive-row-499") == false
            expect(engineAlternate == switches, "actual engine string/ESC transition matches pinned behavior")
            for split in 0...control.utf8.count {
                var parser = TerminalHistoryBoundaryParser()
                let bytes = Data(control.utf8)
                _ = parser.scan(bytes.prefix(split))
                _ = parser.scan(bytes.suffix(bytes.count - split))
                expect(parser.alternate == engineAlternate, "archive parser agrees with engine at every payload split")
            }
            session.receive("\u{1b}[?1049l")
            session.waitForPendingOutput()
        }
        session.receive("\u{1b}[?1049h\u{1b}[2J\u{1b}[HSTATIC-TUI")
        session.waitForPendingOutput()
        expect(session.readViewportText()?.contains("STATIC-TUI") == true, "alternate is a separate static screen")
        expect(session.readScreenText()?.text.contains("archive-row-499") == false, "inactive main is not silently claimed readable")
        session.receive("\u{1b}[?1049l")
        session.waitForPendingOutput()
        expect(session.readScreenText()?.text.contains("archive-row-499") == true, "primary survives alternate exit")
        session.receive("\u{1b}[2J\u{1b}[H" + String(repeating: "x", count: 300) + "\r\nwrap-end")
        session.waitForPendingOutput()
        let history = session.readScreenText()!.text
        expect(history.contains(String(repeating: "x", count: 300)), "logical export retains all soft-wrapped text")
        let viewport = session.readViewportText()!.split(separator: "\n", omittingEmptySubsequences: false)
        expect(viewport.filter { $0.contains("x") }.count > 1, "last-screen export preserves physical soft-wrapped rows")
        print("ok terminal history engine")
        // NSWindow owns a Metal surface. Let process teardown release it after pending
        // output is drained, rather than ordering a native window or running a shell.
    }

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
