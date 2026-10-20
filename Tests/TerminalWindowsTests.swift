import AppKit
import Carbon
import Darwin
import Foundation
import GhosttyTerminal
import ObjectiveC
@testable import GooseAgent

/// Runs AppKit's real resize/layout callbacks, including callbacks outside a Swift task.
@main enum TerminalWindowsTests {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--password-fixture") {
            var attributes = termios()
            guard tcgetattr(STDIN_FILENO, &attributes) == 0 else { exit(2) }
            let original = attributes
            attributes.c_lflag &= ~tcflag_t(ECHO)
            attributes.c_lflag |= tcflag_t(ICANON)
            guard tcsetattr(STDIN_FILENO, TCSANOW, &attributes) == 0 else { exit(2) }
            var buffer = [UInt8](repeating: 0, count: 32)
            _ = read(STDIN_FILENO, &buffer, buffer.count)
            var restored = original
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &restored)
            while true { pause() }
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                if CommandLine.arguments.contains(where: { $0.hasSuffix("compatibility") }) {
                    try await TerminalCompatibilityTests.run()
                    print("TerminalCompatibilityTests passed")
                } else {
                    try await run()
                    print("TerminalWindowsTests passed: saved windows merge into one, 24 terminals, 720 AppKit resizes, ownership, recovery and secure input lifecycle")
                }
                exit(0)
            }
            catch {
                let name = CommandLine.arguments.contains(where: { $0.hasSuffix("compatibility") }) ? "TerminalCompatibilityTests" : "TerminalWindowsTests"
                fputs("\(name) failed: \(error)\n", stderr)
                exit(1)
            }
        }
        NSApp.run()
    }
    struct Failure: Error { let message: String }
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    @MainActor static func run() async throws {
        guard let home = ProcessInfo.processInfo.environment["ONEAGENT_TEST_HOME"] else {
            throw Failure(message: "Missing isolated test home")
        }
        let homeURL = URL(fileURLWithPath: home).resolvingSymlinksInPath()
        let temporaryURL = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()
        try check(homeURL.deletingLastPathComponent().deletingLastPathComponent() == temporaryURL && homeURL.deletingLastPathComponent().lastPathComponent.hasPrefix("oneagent-terminal-windows."), "Test home must be isolated")
        try check(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == homeURL, "Foundation must use the isolated test home")
        let suite = "oneagent.window-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let getter = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard))!
        let old = method_setImplementation(getter, imp_implementationWithBlock({ _ in defaults } as @convention(block) (AnyObject) -> UserDefaults))
        defer { method_setImplementation(getter, old); defaults.removePersistentDomain(forName: suite) }
        let firstTab = UUID(), firstWindow = UUID(), secondTab = UUID(), secondWindow = UUID()
        installTerminal(firstTab, home: home)
        installTerminal(secondTab, home: home)
        let fixture = SessionSnapshot(tabs: [.init(id: firstTab, directory: home), .init(id: secondTab, directory: home)], workspaces: [], windows: [
            .init(id: firstWindow, blocks: [.localGroup, .ungrouped], localGroup: [firstTab], ungrouped: [], selected: firstTab),
            .init(id: secondWindow, blocks: [.localGroup, .ungrouped], localGroup: [secondTab], ungrouped: [], selected: secondTab)
        ], keyWindow: firstWindow)
        defaults.set(try JSONEncoder().encode(fixture), forKey: SessionSnapshot.storageKey)
        let model = AppModel()
        TerminalAutomation.model = model
        MainWindowManager.shared.attach(model: model)
        model.restoreLastSession()
        for _ in 0..<500 { if model.tabs.count == 2 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try check(model.windows.count == 1, "Saved windows merge into the one 1Agent window")
        let main = model.mainWindow
        try check(main.id == firstWindow && model.keyWindow?.id == firstWindow, "The merged window keeps the first saved window identity")
        try check(Set(model.sidebarOrder(in: main)) == [firstTab, secondTab], "Every saved terminal is listed in the one sidebar")
        let scriptWindow = TerminalAutomation.window(firstWindow)
        try check(scriptWindow.objectSpecifier?.descriptor != nil, "A returned script window must serialize to a real Apple event object reference")
        try check((scriptWindow.objectSpecifier?.objectsByEvaluatingSpecifier as? ScriptTerminalWindow)?.uuid == firstWindow, "Returned script object references must resolve by stable ID")
        model.createWorkspace(from: [firstTab, secondTab], atBlockIndex: 0, in: main)
        let grouped = model.workspaces.first(where: \.isGrouped)!
        try check(Set(model.sidebarOrder(in: main)) == [firstTab, secondTab], "A group owns both complete rows")
        model.dissolveWorkspace(grouped.id)
        let native = MainWindowManager.shared.window(for: main)!
        for iteration in 0..<24 {
            let config = try TerminalCreationConfiguration(record: ["workingDirectory": home])
            let terminal = try await model.createScriptTerminal(configuration: config, in: main)
            installTerminal(terminal, home: home)
            try check(model.windows.count == 1 && model.window(containing: terminal)?.id == main.id, "A new terminal joins the one window")
            for frame in 0..<30 {
                native.setContentSize(NSSize(width: 900 + (frame * 17) % 300, height: 560 + (frame * 11) % 180))
                native.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            model.closeTab(terminal)
            try await Task.sleep(nanoseconds: 10_000_000)
            try check(model.tabs.contains { $0.id == firstTab } && model.tabs.contains { $0.id == secondTab }, "Closing terminal \(iteration) must preserve unrelated sessions")
            try check(!model.tabs.contains { $0.id == terminal }, "Closed terminal \(iteration) must be released")
        }
        model.persistSessionIfReady()
        let saved = SessionSnapshot.load()!
        try check(saved.windows?.count == 1 && saved.tabs.count == 2, "The saved session has one window with the two original sessions")
        try await secureInput(model, home: home)
        native.orderOut(nil)
    }

    @MainActor static func secureInput(_ model: AppModel, home: String) async throws {
        let state = model.mainWindow
        let terminal = try await model.createScriptTerminal(configuration: TerminalCreationConfiguration(record: ["workingDirectory": home]), in: state)
        installTerminal(terminal, home: home, passwordFixture: true)
        guard let native = MainWindowManager.shared.window(for: state) else { throw Failure(message: "Missing main window") }
        let view = SSHTerminalRegistry.automationView("\(terminal.uuidString)#0")!
        for _ in 0..<100 {
            if view.processHost?.process.isPasswordInput == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let process = view.processHost!.process
        try check(process.isPasswordInput, "The fixture must have ECHO off and canonical input")
        native.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        native.makeFirstResponder(view)
        TerminalSecureInput.shared.start()
        try await Task.sleep(for: .milliseconds(150))
        TerminalSecureInput.shared.refresh()
        try check(TerminalSecureInput.shared.isEnabled && IsSecureEventInputEnabled(), "Password input enables the native secure input reference (active=\(NSApp.isActive), key=\(native.isKeyWindow), focused=\(native.firstResponder === view), hidden=\(view.isHiddenOrHasHiddenAncestor), current=\(FocusedTerminal.current === view))")
        let field = NSTextField(frame: .zero)
        native.contentView?.addSubview(field)
        native.makeFirstResponder(field)
        TerminalSecureInput.shared.refresh()
        try check(!TerminalSecureInput.shared.isEnabled, "Text-field focus releases secure input")
        native.makeFirstResponder(view)
        process.write(Data("fixture\n".utf8))
        for _ in 0..<100 {
            if !process.isPasswordInput { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        TerminalSecureInput.shared.refresh()
        try check(!TerminalSecureInput.shared.isEnabled, "Restoring ECHO releases automatic secure input")
        TerminalSecureInput.shared.manual = true
        try check(TerminalSecureInput.shared.isEnabled, "Manual secure input applies to the focused terminal")
        native.makeFirstResponder(field)
        TerminalSecureInput.shared.refresh()
        try check(!TerminalSecureInput.shared.isEnabled, "Manual secure input is released outside a terminal")
        native.makeFirstResponder(view)
        TerminalSecureInput.shared.refresh()
        try check(TerminalSecureInput.shared.isEnabled, "Manual input resumes when terminal focus returns")
        field.removeFromSuperview()
        TerminalSecureInput.shared.stop()
        TerminalSecureInput.shared.manual = false
        try check(!TerminalSecureInput.shared.isEnabled, "Quit releases secure input")
        model.closeTab(terminal)
        try check(!model.tabs.contains { $0.id == terminal }, "Closing the fixture terminal releases it")
    }

    /// Real renderer and PTY, with cat instead of the user's login shell/configuration.
    @MainActor static func installTerminal(_ id: UUID, home: String, passwordFixture: Bool = false) {
        _ = SSHTerminalRegistry.view(for: "\(id.uuidString)#0") {
            let host = TerminalProcessHost()
            let view = SSHTerminalNSView(frame: .zero)
            view.sessionID = "\(id.uuidString)#0"
            view.processHost = host
            view.eventRelay.terminal = view
            view.delegate = view.eventRelay
            view.controller = GhosttyRuntime.controller
            view.configuration = TerminalSurfaceOptions(backend: .inMemory(host.session))
            host.start(TerminalLaunch(executable: passwordFixture ? CommandLine.arguments[0] : "/bin/cat", args: passwordFixture ? ["--password-fixture"] : [], environment: ["PATH=/usr/bin:/bin"], directory: home))
            return view
        }
    }
}
