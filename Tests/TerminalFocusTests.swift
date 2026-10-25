import AppKit
import ObjectiveC
@testable import GooseAgent

/// Exercises the production AppKit focus bridge with native, process-free terminal views.
/// The runner also denies network and process execution and gives this app an isolated home.
@main
enum TerminalFocusTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try await run()
                print("TerminalFocusTests passed: delayed mounting/layout, modal dismissal, current selection, hidden panes, keyboard focus preservation, explicit refocus and live input indicators")
                exit(0)
            } catch {
                fputs("TerminalFocusTests failed: \(error)\n", stderr)
                exit(1)
            }
        }
        // Use an actual application loop: key-window notifications and modal transitions
        // must run through AppKit instead of an async-main queue drain.
        NSApp.run()
    }

    @MainActor
    private static func run() async throws {
        guard let home = ProcessInfo.processInfo.environment["ONEAGENT_TEST_HOME"],
              home.hasPrefix("/private/tmp/oneagent-terminal-focus."),
              URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
                == URL(fileURLWithPath: home).resolvingSymlinksInPath(),
              FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
                == URL(fileURLWithPath: home).resolvingSymlinksInPath() else {
            throw Failure(description: "A temporary isolated home is required")
        }
        let suite = "oneagent.terminal-focus.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let getter = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!
        let previous = method_getImplementation(getter)
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(getter, imp_implementationWithBlock(block))
        defer {
            method_setImplementation(getter, previous)
            defaults.removePersistentDomain(forName: suite)
        }
        try require(UserDefaults.standard === defaults, "Preferences must use the isolated suite")

        try await delayedMountAndLayout()
        try await modalDismissal(ownerAlreadyKey: false)
        try await modalDismissal(ownerAlreadyKey: true)
        try await modalDoesNotRestoreStalePane()
        try await staleSelection()
        try await hiddenAndFilesCancellation()
        try await rapidPresentationKeepsFocusAndGeometry()
        try await successfulFocusIsConsumed()
        try await focusWhenWindowBecomesKey()
        try await inputIndicatorLifecycle()
    }

    @MainActor
    private final class Fixture {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 820, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 820, height: 60))

        init() {
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.addSubview(editor)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeFirstResponder(editor)
        }

        func close() {
            window.orderOut(nil)
            window.contentView = nil
        }

        func mount(_ host: TerminalHostView, frame: NSRect = NSRect(x: 0, y: 60, width: 820, height: 460)) {
            host.frame = frame
            root.addSubview(host)
            host.needsLayout = true
            root.layoutSubtreeIfNeeded()
        }

        func modal() -> FamilyModalPresentation {
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
            let modal = FamilyModalPresentation(content: editor, size: editor.frame.size, owner: window, onCancel: {})
            modal.show(initialFirstResponder: editor)
            return modal
        }
    }

    @MainActor
    private static func makeTerminal() throws -> SSHTerminalNSView {
        let terminal = SSHTerminalNSView(frame: .zero)
        // With no controller or process host, native first-responder behavior remains real
        // while mounting the terminal cannot construct a PTY, shell, or SSH process.
        try require(terminal.controller == nil && terminal.processHost == nil,
                    "The focus fixture must not own a terminal process")
        return terminal
    }

    @MainActor
    private static func rapidPresentationKeepsFocusAndGeometry() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try await eventually("The fixture must become key") { fixture.window.isKeyWindow }
        let host = TerminalHostView(frame: .zero)
        let terminal = try makeTerminal()
        host.attach(terminal)
        fixture.mount(host)
        let originalFrame = terminal.frame

        for _ in 0..<6 {
            host.setPresented(false)
            host.setFocusTarget(false)
            fixture.window.makeFirstResponder(fixture.editor)
            host.setPresented(true)
            host.setFocusTarget(true)
            host.requestFocus()
            try require(fixture.window.firstResponder === terminal,
                        "Revealing must accept terminal input before its animation completes")
            try require(terminal.superview === host && terminal.frame == originalFrame,
                        "Rapid switches must preserve the terminal view and PTY geometry")
        }
        host.setPresented(false)
        await settle()
        try require(host.isHidden && terminal.superview === host,
                    "An interrupted reveal must leave the hidden terminal attached and invisible")
        host.setPresented(true)
        host.setFocusTarget(true)
        host.requestFocus()
        try await Task.sleep(for: .milliseconds(300))
        try require(!host.isHidden && fixture.window.firstResponder === terminal && host.alphaValue == 1,
                    "The last reveal must remain visible and focused after earlier animations expire")
    }

    @MainActor
    private static func delayedMountAndLayout() async throws {
        let host = TerminalHostView(frame: .zero)
        let terminal = try makeTerminal()
        host.attach(terminal)
        host.setFocusTarget(true)
        host.requestFocus()
        await settle()
        try require(terminal.window == nil, "The request must survive before a window exists")

        let fixture = Fixture()
        defer { fixture.close() }
        try await eventually("The fixture must become key") { fixture.window.isKeyWindow }
        fixture.mount(host, frame: .zero)
        await settle()
        try require(fixture.window.firstResponder === fixture.editor,
                    "A zero-size terminal must wait for a usable layout")
        host.frame = NSRect(x: 0, y: 60, width: 820, height: 460)
        host.needsLayout = true
        fixture.root.layoutSubtreeIfNeeded()
        try await eventually("A pending terminal must focus after mounting and receiving a usable layout") {
            fixture.window.firstResponder === terminal
        }
    }

    @MainActor
    private static func modalDismissal(ownerAlreadyKey: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try await eventually("The fixture must become key") { fixture.window.isKeyWindow }
        let modal = fixture.modal()
        defer { modal.close() }
        try await eventually("The family modal must become key") { modal.window.isKeyWindow }
        let modalResponder = modal.window.firstResponder
        let host = TerminalHostView(frame: .zero)
        let terminal = try makeTerminal()
        var focused = 0
        terminal.onFocus = { focused += 1 }
        host.setFocusTarget(true)
        host.attach(terminal)
        fixture.mount(host)
        if ownerAlreadyKey {
            // The close notification must work even if no didBecomeKey notification
            // follows dismissal; a visible FamilyModal still blocks owner focus.
            fixture.window.makeKeyAndOrderFront(nil)
            try await eventually("The modal owner must already be key") { fixture.window.isKeyWindow }
            host.requestFocus()
        }
        await settle()
        try require(focused == 0 && fixture.window.firstResponder === fixture.editor,
                    "Opening a terminal must not take keyboard focus while a family modal is visible")
        try require(modal.window.firstResponder === modalResponder,
                    "The visible modal must retain its input responder")
        modal.close()
        try await eventually("Closing the family modal must deliver pending terminal focus") {
            fixture.window.firstResponder === terminal
        }
        try require(focused == 1, "Modal dismissal must fulfill the selected terminal request once")
    }

    @MainActor
    private static func staleSelection() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try await eventually("The fixture must become key") { fixture.window.isKeyWindow }
        let modal = fixture.modal()
        defer { modal.close() }
        var currentSelection = "A"
        let firstHost = TerminalHostView(frame: .zero)
        let first = try makeTerminal()
        var firstFocusCount = 0
        first.onFocus = { firstFocusCount += 1 }
        firstHost.canFocus = { currentSelection == "A" }
        firstHost.setFocusTarget(true)
        firstHost.attach(first)
        fixture.mount(firstHost, frame: NSRect(x: 0, y: 60, width: 410, height: 460))
        await settle()

        let secondHost = TerminalHostView(frame: .zero)
        let second = try makeTerminal()
        secondHost.canFocus = { currentSelection == "B" }
        currentSelection = "B"
        secondHost.setFocusTarget(true)
        secondHost.attach(second)
        fixture.mount(secondHost, frame: NSRect(x: 410, y: 60, width: 410, height: 460))
        // Leave A's representable stale deliberately. The live canFocus check must
        // reject its queued callback before SwiftUI propagates setFocusTarget(false).
        modal.close()
        try await eventually("Only the latest selected pane may receive deferred focus") {
            fixture.window.firstResponder === second
        }
        firstHost.setFocusTarget(false)
        firstHost.requestFocus()
        firstHost.needsLayout = true
        fixture.root.layoutSubtreeIfNeeded()
        await settle()
        try require(firstFocusCount == 0 && fixture.window.firstResponder === second,
                    "A stale or explicitly unselected pane must never steal focus from B")
    }

    @MainActor
    private static func modalDoesNotRestoreStalePane() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        var currentSelection = "A"
        let firstHost = TerminalHostView(frame: .zero)
        let first = try makeTerminal()
        var firstFocusCount = 0
        first.onFocus = {
            firstFocusCount += 1
            currentSelection = "A"
        }
        firstHost.canFocus = { currentSelection == "A" }
        firstHost.setFocusTarget(true)
        firstHost.attach(first)
        fixture.mount(firstHost, frame: NSRect(x: 0, y: 60, width: 410, height: 460))
        try await eventually("The first split must initially own keyboard focus") {
            fixture.window.firstResponder === first
        }
        let initialFocusCount = firstFocusCount
        let modal = fixture.modal()
        defer { modal.close() }
        try await eventually("The split fixture modal must become key") { modal.window.isKeyWindow }

        let secondHost = TerminalHostView(frame: .zero)
        let second = try makeTerminal()
        second.onFocus = { currentSelection = "B" }
        secondHost.canFocus = { currentSelection == "B" }
        currentSelection = "B"
        secondHost.setFocusTarget(true)
        secondHost.attach(second)
        fixture.mount(secondHost, frame: NSRect(x: 410, y: 60, width: 410, height: 460))
        // Both split panes remain visible. AppKit may drop the old responder while
        // a modal opens a new pane. Restoring the saved responder would run A.onFocus
        // and overwrite the user's newer selection before B's queued request runs.
        fixture.window.makeFirstResponder(nil)
        await settle()
        modal.close()
        try await eventually("Modal close must focus the newly selected split") {
            fixture.window.firstResponder === second
        }
        try require(currentSelection == "B" && firstFocusCount == initialFocusCount,
                    "Restoring a modal must not reactivate its stale terminal or overwrite the newer selection")
        try require(!firstHost.isHidden && !secondHost.isHidden,
                    "Stale responder protection must work for two visible split panes")
    }

    @MainActor
    private static func hiddenAndFilesCancellation() async throws {
        for filesSelection in [false, true] {
            let fixture = Fixture()
            defer { fixture.close() }
            try await eventually("The fixture must become key") { fixture.window.isKeyWindow }
            let modal = fixture.modal()
            defer { modal.close() }
            let host = TerminalHostView(frame: .zero)
            let terminal = try makeTerminal()
            var terminalSection = true
            host.canFocus = { terminalSection }
            host.setFocusTarget(true)
            host.attach(terminal)
            fixture.mount(host)
            await settle()
            host.setPresented(false)
            if filesSelection {
                terminalSection = false
                host.setFocusTarget(false)
            }
            modal.close()
            await settle()
            try require(fixture.window.firstResponder === fixture.editor,
                        "Hidden terminals and the Files section must cancel pending terminal focus")
            host.setPresented(true)
            host.needsLayout = true
            fixture.root.layoutSubtreeIfNeeded()
            await settle()
            try require(fixture.window.firstResponder === fixture.editor,
                        "Showing the native subtree alone must not revive a cancelled request")
            terminalSection = true
            host.setFocusTarget(true)
            host.requestFocus()
            try await eventually("Returning explicitly to the terminal must support immediate input") {
                fixture.window.firstResponder === terminal
            }
        }
    }

    @MainActor
    private static func successfulFocusIsConsumed() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let host = TerminalHostView(frame: .zero)
        let terminal = try makeTerminal()
        host.setFocusTarget(true)
        host.attach(terminal)
        fixture.mount(host)
        try await eventually("A newly selected terminal must take first responder") {
            fixture.window.firstResponder === terminal
        }
        try require(fixture.window.makeFirstResponder(fixture.editor), "A text editor must accept deliberate focus")
        for _ in 0..<3 {
            host.setPresented(true)
            host.setFocusTarget(true)
            host.attach(terminal)
            host.needsLayout = true
            fixture.root.layoutSubtreeIfNeeded()
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
            await settle()
        }
        try require(fixture.window.firstResponder === fixture.editor,
                    "Later view updates, layout, and key notifications must preserve intentional text editing")
        host.requestFocus()
        try await eventually("An explicit terminal request must restore keyboard focus") {
            fixture.window.firstResponder === terminal
        }
    }

    @MainActor
    private static func focusWhenWindowBecomesKey() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try await eventually("The first fixture must become key") { fixture.window.isKeyWindow }
        let other = Fixture()
        defer { other.close() }
        try await eventually("The second fixture must become key") { other.window.isKeyWindow }
        let host = TerminalHostView(frame: .zero)
        let terminal = try makeTerminal()
        host.setFocusTarget(true)
        host.attach(terminal)
        fixture.mount(host)
        await settle()
        try require(fixture.window.firstResponder === fixture.editor,
                    "A background window must defer its terminal focus request")
        fixture.window.makeKeyAndOrderFront(nil)
        try await eventually("Becoming key must deliver the retained request") {
            fixture.window.firstResponder === terminal
        }
    }

    @MainActor
    private static func inputIndicatorLifecycle() async throws {
        // Drain the previous fixture's deferred window-close notifications before activating again.
        await settle()
        let fixture = Fixture()
        defer { fixture.close() }
        try await eventually("The input-indicator fixture must become active and key") {
            NSApp.isActive && fixture.window.isKeyWindow
        }
        let focus = FocusedTerminal.shared
        let state = WindowState()
        var firstTab = TerminalTab(id: UUID(), alias: "test-a", generation: 0, exited: false)
        let secondTab = TerminalTab(id: UUID(), alias: "test-b", generation: 0, exited: false)
        let first = try makeTerminal()
        let second = try makeTerminal()
        first.sessionID = firstTab.sessionID
        second.sessionID = secondTab.sessionID
        first.frame = NSRect(x: 0, y: 60, width: 410, height: 460)
        second.frame = NSRect(x: 410, y: 60, width: 410, height: 460)
        fixture.root.addSubview(first)
        fixture.root.addSubview(second)
        state.selectedTabID = firstTab.id
        fixture.window.makeFirstResponder(first)
        try await eventually("The input indicator must identify the native first responder") {
            focus.receivesInput(firstTab, in: state)
        }

        // Styling may not become an input target, move the terminal, or resize its contents.
        let originalBounds = first.bounds
        first.setFocusRail(color: .systemBlue)
        first.layoutSubtreeIfNeeded()
        let rail = first.subviews.first { $0 is TerminalOverlayView && !$0.isHidden }
        try require(rail != nil && rail?.hitTest(.zero) == nil,
                    "The focus rail must pass mouse selection, hover and drag events through")
        try require(first.bounds == originalBounds && fixture.window.firstResponder === first,
                    "Focus styling must not change the terminal geometry or first responder")
        first.setFocusRail(color: nil)
        try require(rail?.isHidden == true, "Zooming or leaving a split must remove its rail")

        firstTab.reconnecting = true
        try require(!focus.receivesInput(firstTab, in: state), "Reconnecting terminals cannot advertise current input")
        firstTab.reconnecting = false
        firstTab.exited = true
        try require(!focus.receivesInput(firstTab, in: state), "Disconnected terminals cannot advertise current input")
        firstTab.exited = false
        state.section = .files
        try require(!focus.receivesInput(firstTab, in: state), "File mode cannot advertise terminal input")
        state.section = .terminals

        fixture.window.makeFirstResponder(fixture.editor)
        try await eventually("Search/editor focus must clear the input marker without clearing selection") {
            focus.inputSessionID == nil
        }
        try require(state.selectedTabID == firstTab.id, "A passive focus marker must preserve selected terminal")
        fixture.window.makeFirstResponder(first)
        try await eventually("Returning to a terminal must restore its input marker") {
            focus.inputSessionID == first.sessionID
        }
        state.selectedTabID = secondTab.id
        fixture.window.makeFirstResponder(second)
        try await eventually("Switching between two terminals must publish the new session even while availability remains true") {
            focus.receivesInput(secondTab, in: state) && !focus.receivesInput(firstTab, in: state)
        }
        let modal = fixture.modal()
        try await eventually("An open dialog must clear all terminal input markers") { focus.inputSessionID == nil }
        modal.close()
        try await eventually("Dismissing the dialog restores the actual input destination") { focus.receivesInput(secondTab, in: state) }
        NSApp.deactivate()
        try await eventually("Switching applications must clear the input marker") { focus.inputSessionID == nil }
        // macOS may refuse a background test executable's request to reactivate
        // itself. Verify foreground return using the installed app, not a fake
        // activation notification while NSApp.isActive is still false.
    }

    @MainActor
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(60))
    }

    @MainActor
    private static func eventually(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { await settle() }
        try require(condition(), "\(message) [active=\(NSApp.isActive), key=\(String(describing: NSApp.keyWindow)), responder=\(String(describing: NSApp.keyWindow?.firstResponder)), input=\(String(describing: FocusedTerminal.shared.inputSessionID))]")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
}
