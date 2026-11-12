import AppKit
import ObjectiveC
import SwiftUI
@testable import GooseAgent

@main
enum HostInformationTests {
    @MainActor static func main() {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        Task { @MainActor in
            do { try await run(); print("HostInformationTests passed"); exit(0) }
            catch { fputs("HostInformationTests failed: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func run() async throws {
        let home = ProcessInfo.processInfo.environment["ONEAGENT_TEST_HOME"]!
        precondition(home.hasPrefix("/private/tmp/oneagent-host-information."))
        precondition(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path == URL(fileURLWithPath: home).resolvingSymlinksInPath().path)
        let defaults = UserDefaults(suiteName: "oneagent.host-information.\(UUID())")!
        let pasteboard = NSPasteboard.general
        let savedPasteboard = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedPasteboard.map { contents in
                let item = NSPasteboardItem()
                for (type, data) in contents { item.setData(data, forType: type) }
                return item
            })
        }
        let getter = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!
        let previous = method_getImplementation(getter)
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(getter, imp_implementationWithBlock(block))
        defer { method_setImplementation(getter, previous) }

        let config = URL(fileURLWithPath: home).appendingPathComponent(".ssh/config")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Host fixture-host\n HostName 192.0.2.10\n User fixture-user\n Port 2222\n".write(to: config, atomically: true, encoding: .utf8)
        let model = AppModel(), state = model.mainWindow
        model.reloadHosts()
        model.openRemoteTerminal("fixture-host", at: "/srv/fixture", placement: .newTab, beside: UUID(), in: state)
        try await until("remote model") { model.tabs.count == 1 }
        let remote = model.tabs[0]
        model.openLocalTerminal(at: home, placement: .newTab, beside: remote.id, in: state)
        try await until("local model") { model.tabs.count == 2 }
        let local = model.tabs.first { $0.id != remote.id }!

        // Exercise the production sheet modifier without mounting terminal surfaces or starting PTYs.
        let host = NSHostingView(rootView: Color.clear.modifier(HostInformationPresentation(model: model, window: state,
            resolver: SSHConfigurationResolver(configurationFile: config), configurationEnvironment: ["PATH=/usr/bin:/bin"])))
        let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        owner.contentView = host
        owner.makeKeyAndOrderFront(nil)
        let terminal = SSHTerminalNSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        terminal.sessionID = remote.sessionID
        host.addSubview(terminal)
        defer { FamilyMenuPresenter.shared.dismiss(); owner.close() }
        await settle()

        func open(_ tab: TerminalTab) async throws -> NSWindow {
            terminal.sessionID = tab.sessionID
            terminal.paneMenuItems = { TerminalPaneActions.items(tab: tab, model: model, window: state, includingFind: false) }
            let point = terminal.convert(NSPoint(x: 200, y: 200), to: nil)
            func pointer(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: owner.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let probe = NativeMenuProbe()
            defer { probe.stop() }
            terminal.rightMouseDown(with: pointer(.rightMouseDown))
            terminal.rightMouseUp(with: pointer(.rightMouseUp))
            let presenter = FamilyMenuPresenter.shared
            guard let menu = probe.menu else { fatalError("right-button release must open a native menu") }
            precondition(!menu.items.contains { $0.title == String(localized: "Copy Info") }, "host copying must be inside Host Information")
            let actions = menu.items.enumerated().filter { $0.element.title == String(localized: "Host Information") }
            precondition(actions.count == 1, "the real menu must contain exactly one Host Information action")
            menu.performActionForItem(at: actions[0].offset)
            try await until("host information dialog") { owner.attachedSheet?.identifier?.rawValue == "family.dialog" }
            precondition(state.hostInformationTabID == tab.id, "the dialog must retain the right-clicked pane")
            precondition(presenter.activeMenu == nil, "choosing Host Information must dismiss native menu tracking")
            let dialog = owner.attachedSheet!
            await settle()
            dialog.contentView?.layoutSubtreeIfNeeded()
            try await until("dialog accessibility content") {
                elements(dialog.contentView!).contains { value($0, "accessibilityIdentifier") as? String == "hostInformation.close" }
            }
            return dialog
        }

        model.selectOnly(local.id, in: state, focusTerminal: false)
        state.presentation.toolSidebarOpen = false
        let dialog = try await open(remote)
        try await until("resolved host") {
            elements(dialog.contentView!).contains { value($0, "accessibilityValue") as? String == "192.0.2.10" || value($0, "accessibilityLabel") as? String == "192.0.2.10" }
        }
        let values = elements(dialog.contentView!).flatMap { object -> [String] in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap {
                let item = value(object, $0)
                return (item as? String) ?? (item as? NSAttributedString)?.string
            }
        }.joined(separator: "\n")
        for expected in [String(localized: "Host Information"), "fixture-host", "192.0.2.10", "fixture-user", "2222", "/srv/fixture"] {
            precondition(values.contains(expected), "dialog must show the clicked remote host field: \(expected); actual: \(values)")
        }
        precondition(state.selectedTabID == local.id && !state.presentation.toolSidebarOpen, "opening information must not switch panes or require the sidebar")
        for (field, expected) in [
            ("name", "fixture-host"), ("address", "192.0.2.10"), ("user", "fixture-user"),
            ("port", "2222"), ("directory", "/srv/fixture"), ("sshCommand", "ssh -- 'fixture-host'")
        ] {
            let button = elements(dialog.contentView!).first { value($0, "accessibilityIdentifier") as? String == "hostInformation.copy." + field }!
            precondition(invoke(button, "accessibilityPerformPress"), "the field's actual copy button must activate")
            try await until("copy " + field) { pasteboard.string(forType: .string) == expected }
        }
        let copyInfo = elements(dialog.contentView!).first { value($0, "accessibilityIdentifier") as? String == "hostInformation.copyConnectionInfo" }!
        precondition(invoke(copyInfo, "accessibilityPerformPress"), "the connection information button must activate")
        try await until("copy connection information") { pasteboard.string(forType: .string) == "fixture-host\n192.0.2.10\nfixture-user" }
        precondition(state.selectedTabID == local.id, "copying must retain the clicked host without switching the selected terminal")
        print("PASS: native buttons copy each clicked host field and connection information")
        let close = elements(dialog.contentView!).first { value($0, "accessibilityIdentifier") as? String == "hostInformation.close" }!
        precondition(invoke(close, "accessibilityPerformPress"), "the actual SwiftUI Close button must activate")
        try await until("Close button dismissal") { state.hostInformationTabID == nil && owner.attachedSheet == nil && owner.firstResponder === terminal }
        precondition(!dialog.isVisible && owner.firstResponder === terminal, "closing must remove the native sheet and restore terminal focus")
        print("PASS: right-click → Host Information → remote fields → Close; captured target and focus preserved")

        try "InvalidConfigurationDirective yes\n".write(to: config, atomically: true, encoding: .utf8)
        model.reloadHosts()
        let missingDialog = try await open(remote)
        let missingUser = elements(missingDialog.contentView!).first { value($0, "accessibilityIdentifier") as? String == "hostInformation.copy.user" }!
        precondition(missingUser.responds(to: NSSelectorFromString("isAccessibilityEnabled")) && !invoke(missingUser, "isAccessibilityEnabled"),
                     "an unknown value cannot copy the placeholder")
        let missingClose = elements(missingDialog.contentView!).first { value($0, "accessibilityIdentifier") as? String == "hostInformation.close" }!
        precondition(invoke(missingClose, "accessibilityPerformPress"))
        try await until("missing-field dialog dismissal") { owner.attachedSheet == nil }

        let localDialog = try await open(local)
        let localValues = elements(localDialog.contentView!).flatMap { object in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap {
                let item = value(object, $0)
                return (item as? String) ?? (item as? NSAttributedString)?.string
            }
        }.joined(separator: "\n")
        precondition(localValues.contains(String(localized: "This Mac")) && localValues.contains(local.directory!) && localValues.contains(LocalTerminal.shellExecutable), "local information must show the local directory and shell; actual: \(localValues), directory: \(local.directory!), shell: \(LocalTerminal.shellExecutable)")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: localDialog.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        localDialog.keyDown(with: escape)
        try await until("Escape dismissal") { state.hostInformationTabID == nil && owner.attachedSheet == nil && owner.firstResponder === terminal }
        precondition(!localDialog.isVisible && owner.firstResponder === terminal, "Escape must remove the dialog and restore terminal focus")
        precondition(terminal.processHost == nil && model.tabs.count == 2, "verification must not launch processes or change sessions")
        print("PASS: reopen → local host information → Escape; no leftover overlay or terminal process")
    }

    @MainActor static func settle() async { try? await Task.sleep(for: .milliseconds(100)) }
    @MainActor static func until(_ description: String, condition: () -> Bool) async throws {
        for _ in 0..<50 { if condition() { return }; await settle() }
        throw NSError(domain: "HostInformationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out: \(description)"])
    }
    @MainActor static func value(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
    @MainActor static func invoke(_ object: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method, to: Action.self)(object, selector)
    }
    @MainActor static func elements(_ object: Any) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        func walk(_ object: Any) -> [NSObject] {
            guard let object = object as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            let children = (value(object, "accessibilityChildren") as? [Any] ?? []) + ((object as? NSView)?.subviews ?? [])
            return [object] + children.flatMap(walk)
        }
        return walk(object)
    }
}

/// NSMenu tracks synchronously; observe and close it from its tracking run loop.
@MainActor
private final class NativeMenuProbe {
    var menu: NSMenu?
    private var timer: Timer?
    init() {
        timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let menu = FamilyMenuPresenter.shared.activeMenu else { return }
                self.menu = menu
                menu.cancelTracking()
                timer.invalidate()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        RunLoop.main.add(timer!, forMode: .eventTracking)
    }
    func stop() { timer?.invalidate() }
}
