import AppKit
import Darwin
import Foundation
import GhosttyTerminal
import GhosttyKit
import ObjectiveC
@testable import GooseAgent

/// Uses the shipped engine and the application's real PTY, without the user's rc files.
@MainActor enum TerminalCompatibilityTests {
    final class Bytes: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ value: Data) { lock.lock(); data.append(value); lock.unlock() }
        func clear() { lock.lock(); data.removeAll(keepingCapacity: true); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
        var text: String { String(decoding: value, as: UTF8.self) }
    }
    final class Metrics: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: InMemoryTerminalViewport?
        func set(_ value: InMemoryTerminalViewport) { lock.lock(); latest = value; lock.unlock() }
        var value: InMemoryTerminalViewport? { lock.lock(); defer { lock.unlock() }; return latest }
    }
    final class ScaleWindow: NSWindow {
        var simulatedScale: CGFloat = 2
        override var backingScaleFactor: CGFloat { simulatedScale }
    }
    final class Callbacks: TerminalSurfaceClipboardConfirmationDelegate, TerminalSurfaceTitleDelegate,
        TerminalSurfacePwdDelegate, TerminalSurfaceProgressReportDelegate, TerminalSurfaceColorChangeDelegate, TerminalSurfaceHoverLinkDelegate {
        var allowRead = false
        var clipboardReads = 0
        var title = "", directory = ""
        var progress: Int?
        var colors: [TerminalColorChange] = []
        var hoveredURL: String?
        func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
            if case .osc52Read = request.kind { clipboardReads += 1; request.respond(allow: allowRead) }
            else { request.respond(allow: false) }
        }
        func terminalDidChangeTitle(_ title: String) { self.title = title }
        func terminalDidChangeWorkingDirectory(_ path: String) { directory = path }
        func terminalDidReportProgress(state: TerminalProgressState, percent: Int?) { progress = percent }
        func terminalDidChangeColor(_ change: TerminalColorChange) { colors.append(change) }
        func terminalDidUpdateHoverLink(_ url: String?) { hoveredURL = url }
    }
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message) }
    }
    static func wait(_ message: @autoclosure () -> String, seconds: Double = 8, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() >= deadline { throw Failure(message()) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    @MainActor final class Fixture {
        let incoming = Bytes(), outgoing = Bytes()
        let metrics = Metrics()
        let process: TerminalProcess?
        let session: InMemoryTerminalSession
        let view: AppTerminalView
        let window: NSWindow
        init(process: TerminalProcess? = nil, simulatedDisplay: Bool = false) {
            self.process = process
            let outgoing = self.outgoing, metrics = self.metrics
            session = InMemoryTerminalSession(write: { data in outgoing.append(data); process?.write(data) }, resize: { size in
                metrics.set(size)
                process?.resize(columns: size.columns, rows: size.rows, widthPixels: size.widthPixels, heightPixels: size.heightPixels)
            })
            view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 940, height: 600))
            view.controller = GhosttyRuntime.controller
            view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
            window = (simulatedDisplay ? ScaleWindow.self : NSWindow.self).init(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "1Agent 兼容性验收"
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeFirstResponder(view)
            let incoming = self.incoming, session = self.session
            process?.onOutput = { data in incoming.append(data); session.receive(data) }
        }
        func ready() async throws { try await wait("Engine surface did not attach") { session.hasAttachedSurface } }
        func feed(_ text: String) async throws {
            session.receive(text)
            try await Task.sleep(for: .milliseconds(80))
        }
        func close() { process?.terminate(); window.close() }
    }

    static func run() async throws {
        guard let home = ProcessInfo.processInfo.environment["ONEAGENT_TEST_HOME"], home.contains("oneagent-terminal-windows.") else { throw Failure("Missing isolated test home") }
        let suite = "oneagent.compatibility.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let getter = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard))!
        let old = method_setImplementation(getter, imp_implementationWithBlock({ _ in defaults } as @convention(block) (AnyObject) -> UserDefaults))
        defer { method_setImplementation(getter, old); defaults.removePersistentDomain(forName: suite) }
        let args = CommandLine.arguments
        if args.contains("--shell-compatibility") || args.contains("--compatibility") { try await shells(home: home) }
        if args.contains("--protocol-compatibility") || args.contains("--compatibility") {
            try await protocols()
            try await tui(home: home)
            try await sustainedOutput()
        }
        if args.contains("--display-compatibility") || args.contains("--compatibility") { try await displays() }
        if args.contains("--tui-compatibility") { try await tui(home: home) }
        if args.contains("--stress-compatibility") { try await sustainedOutput(rounds: 120, interval: .milliseconds(500)) }
    }

    static func shells(home: String) async throws {
        guard let resources = Bundle.main.resourcePath else { throw Failure("Missing bundled resources") }
        let names = ProcessInfo.processInfo.environment["ONEAGENT_COMPATIBILITY_SHELLS"]?.components(separatedBy: ",") ?? ["zsh", "bash", "fish", "elvish", "nu"]
        for name in names {
            let executable = name == "zsh" ? "/bin/zsh" : "/opt/homebrew/bin/\(name)"
            try check(FileManager.default.isExecutableFile(atPath: executable), "Missing runtime \(executable)")
            let folder = URL(fileURLWithPath: home).appendingPathComponent(name)
            let changed = folder.appendingPathComponent("中文 空格's")
            try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
            let environment = ["HOME=\(folder.path)", "XDG_CONFIG_HOME=\(folder.path)/config", "XDG_DATA_HOME=\(folder.path)/data", "XDG_CACHE_HOME=\(folder.path)/cache", "XDG_DATA_DIRS=/usr/local/share:/usr/share", "PATH=/opt/homebrew/bin:/usr/bin:/bin", "TERM=xterm-256color", "LANG=en_US.UTF-8", "SHELL=\(executable)", "GHOSTTY_SHELL_FEATURES=title,ssh-env"]
            var settings = TerminalSettings.defaults
            if ProcessInfo.processInfo.environment["ONEAGENT_COMPATIBILITY_NO_FEATURES"] == "1" { settings.shellIntegrationFeatures = [] }
            let variables = ShellIntegrationEnvironment.variables(settings: settings, shellPath: executable, resourcesPath: resources, environment: environment)
            let process = TerminalProcess()
            let terminal = Fixture(process: process)
            defer { terminal.close() }
            try await terminal.ready()
            try check(process.start(executable: executable, args: ShellIntegrationEnvironment.launchArguments(settings: settings, shellPath: executable, variables: variables), environment: ShellIntegrationEnvironment.merged(environment, overrides: variables), directory: folder.path, columns: 100, rows: 30), "\(name): PTY start failed")
            if name == "elvish" {
                // Upstream's Elvish integration exposes a module, imported by the user's rc.
                // The clean fixture imports it explicitly, preserving the same startup contract.
                try await wait("Elvish did not reach its interactive editor") { terminal.incoming.text.contains("\u{1b}[?2004h") }
                process.write(Data("use ghostty-integration\r".utf8))
            }
            try await wait("\(name): no semantic prompt marker; tail=\(String(terminal.incoming.text.suffix(500)).debugDescription)") { terminal.incoming.text.contains("\u{1b}]133;A") }
            let prefix = name == "nu" ? "^/usr/bin/printf" : "/usr/bin/printf"
            let token = UUID().uuidString
            process.write(Data("\(prefix) '%s%s\\n' 'RUNTIME_' '\(token)'\r".utf8))
            try await wait("\(name): interactive command output missing") { terminal.incoming.text.contains("RUNTIME_" + token + "\r\n") }
            let quotedDirectory = "'" + changed.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            // Nu and Elvish use doubled apostrophes rather than POSIX quote concatenation.
            let directory = name == "nu" ? String(data: try JSONEncoder().encode(changed.path), encoding: .utf8)!
                : name == "elvish" ? "'" + changed.path.replacingOccurrences(of: "'", with: "''") + "'" : quotedDirectory
            terminal.incoming.clear()
            process.write(Data("cd \(directory)\r".utf8))
            try await wait("\(name): cd did not preserve Unicode, space and apostrophe") { process.currentWorkingDirectory == changed.path }
            try await wait("\(name): directory reporting missing after cd") { terminal.incoming.text.contains("\u{1b}]7;") || terminal.incoming.text.contains("\u{1b}]1337;CurrentDir=") }
            terminal.incoming.clear()
            process.write(Data("/bin/sh -c 'exit 7'\r".utf8))
            try await wait("\(name): exit status 7 not reported; tail=\(String(terminal.incoming.text.suffix(500)).debugDescription)") { terminal.incoming.text.contains("\u{1b}]133;D;7") }
            terminal.incoming.clear()
            let envCommand: String
            switch name {
            case "fish": envCommand = "printf '%s\\n' $XDG_DATA_DIRS"
            case "elvish": envCommand = "printf '%s\\n' $E:XDG_DATA_DIRS"
            case "nu": envCommand = "print ($env.XDG_DATA_DIRS | str join ':')"
            default: envCommand = "printf '%s\\n' \"$XDG_DATA_DIRS\""
            }
            process.write(Data((envCommand + "\r").utf8))
            try await wait("\(name): original XDG_DATA_DIRS was lost") { terminal.incoming.text.contains("/usr/local/share:/usr/share") }
            try check(!terminal.incoming.text.contains("/shell-integration:/usr/local/share"), "\(name): injection leaked into inherited XDG_DATA_DIRS")
            if name == "nu" {
                terminal.incoming.clear()
                process.write(Data("ssh -V\r".utf8))
                try await wait("Nushell's inherited ssh command failed with disabled integration features: \(String(terminal.incoming.text.suffix(1500)).debugDescription)") { terminal.incoming.text.contains("OpenSSH_") }
            }
            print("PASS shell \(name)\(settings.shellIntegrationFeatures.isEmpty ? " (features disabled)" : "")\(name == "elvish" ? " (explicit upstream module import)" : ""): real PTY, semantic prompt, command, Unicode cwd, directory reporting, exit status and XDG restoration")
        }
    }

    static func protocols() async throws {
        let fixture = Fixture()
        let callbacks = Callbacks()
        fixture.view.delegate = callbacks
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.feed("\u{1b}[2J\u{1b}[H\u{1b}[5n\u{1b}[6n\u{1b}[c\u{1b}[>c")
        try await wait("DSR status/cursor replies missing: \(fixture.outgoing.text.debugDescription); viewport=\(fixture.session.readViewportText().debugDescription)") { fixture.outgoing.text.contains("\u{1b}[0n") && fixture.outgoing.text.contains("\u{1b}[1;1R") }
        try check(fixture.outgoing.text.contains("\u{1b}[?62;") && fixture.outgoing.text.contains("\u{1b}[>"), "Device attributes missing")
        fixture.outgoing.clear()
        try await fixture.feed("\u{1b}[?2004h")
        try check(fixture.view.paste(text: "中文 paste"), "Paste not delivered")
        try await wait("Bracketed paste bytes missing") { fixture.outgoing.text.contains("\u{1b}[200~中文 paste\u{1b}[201~") }
        fixture.outgoing.clear()
        try await fixture.feed("\u{1b}[>3u")
        try check(fixture.view.sendKey(.a, modifiers: .ctrl), "Kitty key not delivered")
        try await wait("Kitty Ctrl-A press/release missing: \(fixture.outgoing.text.debugDescription)") { fixture.outgoing.text.contains("\u{1b}[97;5u") && fixture.outgoing.text.contains("\u{1b}[97;5:3u") }
        try await fixture.feed("\u{1b}[<u\u{1b}[?2004l\u{1b}[?1000h\u{1b}[?1006h")
        fixture.outgoing.clear()
        fixture.view.sendMousePos(x: 20, y: 20)
        _ = fixture.view.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
        _ = fixture.view.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
        try await wait("SGR mouse press/release missing: \(fixture.outgoing.text.debugDescription)") { fixture.outgoing.text.contains("\u{1b}[<0;") && fixture.outgoing.text.contains("M") && fixture.outgoing.text.contains("m") }
        try await fixture.feed("\u{1b}[?1000l\u{1b}[?1006l\u{1b}[2J\u{1b}[HMAIN_SCREEN\u{1b}[?1049h\u{1b}[2J\u{1b}[HALTERNATE_SCREEN")
        try check(fixture.session.readViewportText()?.contains("ALTERNATE_SCREEN") == true && fixture.session.readViewportText()?.contains("MAIN_SCREEN") == false, "Alternate screen not isolated")
        try await fixture.feed("\u{1b}[?1049l")
        try check(fixture.session.readViewportText()?.contains("MAIN_SCREEN") == true && fixture.session.readViewportText()?.contains("ALTERNATE_SCREEN") == false, "Primary screen not restored")
        fixture.outgoing.clear()
        try await fixture.feed("\u{1b}[2J\u{1b}[H中e\u{301}👩‍💻\u{1b}[6n")
        try check(fixture.outgoing.text.contains("\u{1b}[1;6R"), "Unicode cell widths incorrect: \(fixture.outgoing.text.debugDescription)")
        fixture.outgoing.clear()
        try await fixture.feed("\u{1b}[?2026hSYNCED_FRAME\u{1b}[?2026l\u{1b}[?2026$p")
        try check(fixture.session.readViewportText()?.contains("SYNCED_FRAME") == true && fixture.outgoing.text.contains("\u{1b}[?2026;2$y"), "Synchronized update completion/query failed")
        fixture.outgoing.clear()
        try await fixture.feed("\u{1b}_Ga=q,i=42,s=1,v=1,f=24;AP8A\u{1b}\\")
        try check(fixture.outgoing.text.contains("\u{1b}_Gi=42;OK\u{1b}\\"), "Kitty graphics query failed: \(fixture.outgoing.text.debugDescription)")
        fixture.outgoing.clear()
        try await fixture.feed("\u{1b}]2;1Agent 协议验收\u{7}\u{1b}]7;file://localhost/tmp/oneagent-protocol\u{7}\u{1b}]9;4;1;37\u{7}\u{1b}]10;#123456\u{7}\u{1b}]10;?\u{7}")
        try await wait("OSC title, cwd, progress or truecolor callbacks failed") { callbacks.title == "1Agent 协议验收" && callbacks.directory == "/tmp/oneagent-protocol" && callbacks.progress == 37 && !callbacks.colors.isEmpty }
        try check(fixture.outgoing.text.contains("rgb:1212/3434/5656"), "Truecolor query must retain all channels: \(fixture.outgoing.text.debugDescription)")
        fixture.outgoing.clear()
        try await fixture.feed("\u{1b}[?1004h")
        let field = NSTextField(frame: .zero)
        fixture.view.addSubview(field)
        fixture.window.makeFirstResponder(field)
        fixture.window.makeFirstResponder(fixture.view)
        try await wait("Focus reporting lost input transitions") { fixture.outgoing.text.contains("\u{1b}[O") && fixture.outgoing.text.contains("\u{1b}[I") }
        fixture.outgoing.clear()
        fixture.view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try check(fixture.view.hasMarkedText() && !fixture.outgoing.text.contains("中"), "IME preedit must remain uncommitted")
        fixture.view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        fixture.view.insertText("中文✓", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await wait("IME commit was lost") { fixture.outgoing.text.contains("中文✓") }
        try check(!fixture.view.hasMarkedText() && fixture.outgoing.text.components(separatedBy: "中文✓").count == 2, "IME commit must clear composition and emit once")
        try await fixture.feed("\u{1b}[2J\u{1b}[H\u{1b}]8;;https://example.org/oneagent\u{7}LINKLABEL\u{1b}]8;;\u{7}")
        fixture.view.sendMousePos(x: 20, y: 10, modifiers: .super_)
        try await wait("OSC8 hyperlink hover lost its URL") { callbacks.hoveredURL == "https://example.org/oneagent" }
        try await clipboard(fixture, callbacks: callbacks)
        // Split a multibyte sequence across transport chunks, as SSH/PTY reads routinely do.
        try await fixture.feed("\u{1b}[2J\u{1b}[H")
        let fragmented = Array("中🙂e\u{301}尾".utf8)
        for byte in fragmented { fixture.session.receive(Data([byte])) }
        try await wait("Chunked UTF-8 was corrupted") { fixture.session.readViewportText()?.contains("中🙂e\u{301}尾") == true }
        print("PASS protocols: DA/DSR, paste, Kitty keys, SGR mouse, alternate screen, Unicode/chunking, native IME composition, synchronized output, Kitty graphics ACK, OSC8/title/cwd/progress/truecolor, focus and OSC52 permission decisions")
    }

    static func clipboard(_ fixture: Fixture, callbacks: Callbacks) async throws {
        let board = NSPasteboard.general
        let original = board.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        let marker = "1Agent OSC52 " + UUID().uuidString
        defer {
            // Never overwrite a concurrent clipboard change from another application.
            if board.string(forType: .string) == marker { board.clearContents(); board.writeObjects(original) }
        }
        let encoded = Data(marker.utf8).base64EncodedString()
        try await fixture.feed("\u{1b}]52;c;\(encoded)\u{7}")
        try await wait("OSC52 write did not reach the system clipboard") { board.string(forType: .string) == marker }
        fixture.outgoing.clear()
        try await fixture.feed("\u{1b}]52;c;?\u{7}")
        try await wait("OSC52 read permission was not requested") { callbacks.clipboardReads == 1 }
        try check(!fixture.outgoing.text.contains(encoded), "Denied OSC52 read leaked clipboard data")
        callbacks.allowRead = true
        try await fixture.feed("\u{1b}]52;c;?\u{7}")
        try await wait("Allowed OSC52 read did not return the owned marker") { fixture.outgoing.text.contains(encoded) }
    }

    static func displays() async throws {
        let model = AppModel()
        MainWindowManager.shared.attach(model: model)
        for rect in [CGRect(x: 10000, y: 500, width: 1100, height: 720), CGRect(x: -10000, y: 10000, width: 3000, height: 2000)] {
            let state = model.mainWindow
            state.frame = rect
            MainWindowManager.shared.show(state, model: model)
            guard let native = MainWindowManager.shared.window(for: state) else { throw Failure("Missing restored window") }
            defer { MainWindowManager.shared.closeImmediately(state) }
            try await Task.sleep(for: .milliseconds(100))
            let titlebar = CGRect(x: native.frame.minX, y: native.frame.maxY - 28, width: native.frame.width, height: 28)
            try check(NSScreen.screens.contains { $0.visibleFrame.intersection(titlebar).width >= min(200, native.frame.width) }, "Disconnected-display restoration leaves titlebar unreachable: \(native.frame)")
        }
        let fixture = Fixture(simulatedDisplay: true)
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.feed("\u{1b}[2J\u{1b}[HRETAIN_ON_DISPLAY_CHANGE")
        let native = fixture.window as! ScaleWindow
        try await wait("Missing initial display metrics") { fixture.metrics.value != nil }
        let initialWidth = Double(fixture.metrics.value!.widthPixels) / Double(native.simulatedScale)
        for scale: CGFloat in [1, 2, 1, 2] {
            native.simulatedScale = scale
            fixture.view.viewDidChangeBackingProperties()
            NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: native)
            try await wait("Backing-scale change did not update Metal and PTY pixels: expected=\(scale), layer=\(fixture.view.layer?.contentsScale.description ?? "nil"), width=\(fixture.metrics.value?.widthPixels.description ?? "nil"), bounds=\(fixture.view.bounds)") {
                guard let value = fixture.metrics.value else { return false }
                // HostManaged reports the cell-aligned viewport, excluding padding/remainder.
                return fixture.view.layer?.contentsScale == scale && abs(Double(value.widthPixels) / Double(scale) - initialWidth) <= Double(value.cellWidthPixels)
            }
            try check(fixture.session.readViewportText()?.contains("RETAIN_ON_DISPLAY_CHANGE") == true, "Display migration rebuilt the surface and discarded content")
        }
        let second = ScaleWindow(contentRect: NSRect(x: 50, y: 70, width: 1000, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        second.isReleasedWhenClosed = false
        defer { second.close() }
        second.simulatedScale = 1
        second.contentView = fixture.view
        second.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: second)
        try await wait("Cross-window reattachment retained the old scale") { fixture.view.layer?.contentsScale == 1 }
        try check(fixture.session.readViewportText()?.contains("RETAIN_ON_DISPLAY_CHANGE") == true, "Reattachment discarded the terminal state")
        print("PASS display recovery and simulated 1x/2x native backing/screen callbacks: pixel metrics, Metal scale, cross-window reattachment and retained terminal contents")
        try await physicalDisplays()
        try await fullScreen()
    }

    static func physicalDisplays() async throws {
        let screens = NSScreen.screens
        try check(!screens.isEmpty, "No physical display available")
        let fixture = Fixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.feed("\u{1b}[2J\u{1b}[HPHYSICAL_SCREEN_MIGRATION_CONTENT")
        try await wait("Physical display fixture not ready") { fixture.session.readViewportText()?.contains("PHYSICAL_SCREEN_MIGRATION_CONTENT") == true }
        // This loop automatically exercises every real display when run on a dual-screen Mac.
        for screen in screens + screens.reversed() {
            let bounds = screen.visibleFrame
            let size = CGSize(width: min(940, bounds.width), height: min(600, bounds.height))
            fixture.window.setFrame(CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height), display: true)
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            try await wait("Window did not migrate to the requested physical display") {
                fixture.window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == number
                    && fixture.view.layer?.contentsScale == screen.backingScaleFactor
                    && fixture.metrics.value?.columns ?? 0 > 0
            }
            try check(fixture.session.readScreenText()?.text.contains("PHYSICAL_SCREEN_MIGRATION_CONTENT") == true, "Physical screen migration lost terminal contents")
        }
        print("PASS actual connected-display traversal: \(screens.count) display(s), forward/reverse, screen identity, backing scale and retained content")
        if screens.count < 2 { print("HARDWARE LIMIT: only one physical display; cross-display and hot-plug acceptance remains unverified") }
    }

    static func fullScreen() async throws {
        guard let home = ProcessInfo.processInfo.environment["ONEAGENT_TEST_HOME"] else { throw Failure("Missing test home") }
        let id = UUID(), windowID = UUID()
        TerminalWindowsTests.installTerminal(id, home: home)
        let snapshot = SessionSnapshot(tabs: [.init(id: id, directory: home)], workspaces: [], windows: [
            .init(id: windowID, blocks: [.localGroup, .ungrouped], localGroup: [id], ungrouped: [], selected: id, quickTerminal: true)
        ], keyWindow: windowID)
        UserDefaults.standard.set(try JSONEncoder().encode(snapshot), forKey: SessionSnapshot.storageKey)
        let model = AppModel()
        MainWindowManager.shared.attach(model: model)
        model.restoreLastSession()
        try await wait("Quick terminal test snapshot did not restore") { model.tabs.count == 1 }
        guard let quick = model.window(for: windowID) else { throw Failure("Missing quick terminal state") }
        defer { MainWindowManager.shared.closeImmediately(quick) }
        AppShortcuts.setChords([.quickTerminal: KeyChord(key: "g", modifiers: [.control, .shift, .option])])
        QuickTerminalController.shared.start(model: model)
        try check(QuickTerminalController.shared.registrationError == nil, "Fullscreen test hotkey could not register")
        let full = Fixture()
        defer { full.close() }
        try await full.ready()
        try await full.feed("\u{1b}[2J\u{1b}[H1Agent 全屏验收：原终端内容必须保留")
        try await wait("Fullscreen fixture did not display its initial contents") { full.session.readViewportText()?.contains("原终端内容必须保留") == true }
        var entered = false, exited = false
        let center = NotificationCenter.default
        let enterToken = center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: full.window, queue: .main) { _ in MainActor.assumeIsolated { entered = true } }
        let exitToken = center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: full.window, queue: .main) { _ in MainActor.assumeIsolated { exited = true } }
        defer { center.removeObserver(enterToken); center.removeObserver(exitToken) }
        full.window.toggleFullScreen(nil)
        try await wait("Native window did not complete fullscreen entry", seconds: 15) { entered }
        let imageRow = max(1, Int(full.metrics.value?.rows ?? 50) - 5)
        let rgb = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255]).base64EncodedString()
        try await full.feed("\u{1b}[\(imageRow);5H\u{1b}_Ga=T,f=24,s=2,v=2,i=71,c=12,r=3;\(rgb)\u{1b}\\")
        try await wait("Kitty graphics transmission/display did not acknowledge") { full.outgoing.text.contains("i=71;OK") }
        print("FULLSCREEN_IMAGE_READY: native Kitty RGB image displayed")
        fflush(stdout)
        try await hold(suffix: ".image")
        try TerminalWindowsTests.sendHotKeyEvent()
        guard let native = MainWindowManager.shared.window(for: quick) else { throw Failure("Missing fullscreen auxiliary quick terminal") }
        try await wait("Quick terminal is not visible in the active fullscreen Space") { native.isVisible && native.isOnActiveSpace && native.occlusionState.contains(.visible) }
        let terminal = SSHTerminalRegistry.automationView("\(id.uuidString)#0")!
        terminal.processHost?.session.receive("\r\n1Agent 快速终端：全屏空间显示正常\r\n")
        try check(full.window.styleMask.contains(.fullScreen), "Showing quick terminal exited the original fullscreen window")
        print("FULLSCREEN_READY: native fullscreen and auxiliary quick terminal visible")
        fflush(stdout)
        try await hold(suffix: "")
        try TerminalWindowsTests.sendHotKeyEvent()
        try await wait("Quick terminal did not hide in fullscreen") { !native.isVisible }
        full.window.toggleFullScreen(nil)
        try await wait("Native window did not complete fullscreen exit", seconds: 15) { exited }
        try check(full.session.readScreenText()?.text.contains("原终端内容必须保留") == true, "Fullscreen transition lost terminal contents: viewport=\(String((full.session.readViewportText() ?? "").prefix(400)).debugDescription); screen=\(String((full.session.readScreenText()?.text ?? "").prefix(400)).debugDescription)")
        print("PASS actual single-display fullscreen entry/exit, quick terminal visibility in active fullscreen Space and original terminal preservation")
    }

    static func hold(suffix: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["ONEAGENT_TEST_HOLD_PATH"], path.hasPrefix("/private/tmp/oneagent-") else { return }
        let deadline = Date().addingTimeInterval(45)
        while FileManager.default.fileExists(atPath: path + suffix), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
    }

    static func tool(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try check(process.terminationStatus == 0, "Owned test tool failed: \(executable): \(String(decoding: data, as: UTF8.self))")
        return String(decoding: data, as: UTF8.self)
    }

    static func tui(home: String) async throws {
        let environment = ["HOME=\(home)", "PATH=/opt/homebrew/bin:/usr/bin:/bin", "TERM=xterm-256color", "LANG=en_US.UTF-8", "SHELL=/bin/sh"]
        let socket = home + "/tmux.sock"
        let process = TerminalProcess()
        let terminal = Fixture(process: process)
        defer {
            _ = try? tool("/opt/homebrew/bin/tmux", ["-S", socket, "kill-server"])
            terminal.close()
        }
        try await terminal.ready()
        try check(process.start(executable: "/opt/homebrew/bin/tmux", args: ["-S", socket, "-f", "/dev/null", "new-session", "-s", "check", "/bin/sh"], environment: environment, directory: home), "tmux PTY launch failed")
        try await wait("tmux test server did not start: \(terminal.incoming.text.debugDescription)") { FileManager.default.fileExists(atPath: socket) }
        let marker = UUID().uuidString
        process.write(Data("printf '%s%s\\n' 'TMUX_' '\(marker)'\r".utf8))
        try await wait("tmux output did not render") { terminal.session.readViewportText()?.contains("TMUX_" + marker) == true }
        _ = try tool("/opt/homebrew/bin/tmux", ["-S", socket, "split-window", "-h", "-t", "check", "-c", home, "/bin/sh"])
        let panes = try tool("/opt/homebrew/bin/tmux", ["-S", socket, "list-panes", "-t", "check", "-F", "#{pane_id}"])
        try check(panes.split(separator: "\n").count == 2, "tmux split did not create two panes")
        for index in 0..<20 {
            terminal.window.setContentSize(NSSize(width: 800 + index * 13, height: 500 + index * 7))
            try await Task.sleep(for: .milliseconds(10))
        }
        let secondMarker = UUID().uuidString
        _ = try tool("/opt/homebrew/bin/tmux", ["-S", socket, "send-keys", "-t", "check:0.1", "printf '%s%s\\n' 'PANE_' '\(secondMarker)'", "Enter"])
        try await wait("tmux split redraw after resize lost the second pane") { terminal.session.readViewportText()?.contains("PANE_" + secondMarker) == true }
        _ = try tool("/opt/homebrew/bin/tmux", ["-S", socket, "kill-server"])
        terminal.close()

        let vimProcess = TerminalProcess(), vim = Fixture(process: vimProcess)
        defer { vim.close() }
        let file = home + "/vim-中文.txt"
        let ready = home + "/vim-ready"
        try await vim.ready()
        try check(vimProcess.start(executable: "/usr/bin/vim", args: ["-Nu", "NONE", "-n", "-i", "NONE", "-c", "set showmode", "-c", "call writefile(['ready'], '\(ready)')", file], environment: environment, directory: home), "Vim PTY launch failed")
        try await wait("Vim did not finish opening its new buffer") { FileManager.default.fileExists(atPath: ready) && vim.session.readViewportText()?.contains("~") == true }
        _ = vim.view.sendKey(.i)
        try await wait("Vim did not enter Insert mode; tail=\(String(vim.incoming.text.suffix(1500)).debugDescription)") { vim.session.readViewportText()?.contains("INSERT") == true }
        try check(vim.view.paste(text: "中文🙂 e\u{301}"), "Vim paste failed")
        try await wait("Vim did not display pasted text") { vim.session.readViewportText()?.contains("中文🙂 e\u{301}") == true }
        _ = vim.view.sendKey(.escape)
        try await wait("Physical Escape did not leave Vim Insert mode") { vim.session.readViewportText()?.contains("INSERT") == false }
        for character: Character in [":", "w", "q"] { _ = vim.view.sendKey(TerminalKeyPress(typing: character)!) }
        _ = vim.view.sendKey(.enter)
        try await wait("Vim did not save input through the PTY; file=\((try? String(contentsOfFile: file, encoding: .utf8)).debugDescription); tail=\(String(vim.incoming.text.suffix(1500)).debugDescription)") { (try? String(contentsOfFile: file, encoding: .utf8)) == "中文🙂 e\u{301}\n" }
        print("PASS TUI: tmux real PTY, two panes and 20 resizes; Vim alternate screen, bracketed Unicode paste, physical Escape and UTF-8 file save")
    }

    static func residentBytes() -> UInt64 {
        var info = proc_taskinfo()
        let count = MemoryLayout<proc_taskinfo>.size
        guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, Int32(count)) == count else { return 0 }
        return info.pti_resident_size
    }

    static func sustainedOutput(rounds: Int = 12, interval: Duration = .zero) async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try await fixture.ready()
        let started = Date()
        let line = String(repeating: "0123456789abcdef", count: 16) + "\r\n"
        let payload = String(repeating: line, count: 4096)
        var samples: [UInt64] = []
        for round in 0..<rounds {
            fixture.session.receive(payload + "\r\nOUTPUT_END_\(round)\r\n")
            try await wait("Sustained output lost its tail in round \(round)", seconds: 30) { fixture.session.readViewportText()?.contains("OUTPUT_END_\(round)") == true }
            samples.append(residentBytes())
            if round % 20 == 19 {
                fixture.outgoing.clear()
                fixture.session.receive("\u{1b}[5n")
                try await wait("Terminal query became unresponsive during sustained output") { fixture.outgoing.text.contains("\u{1b}[0n") }
                print("STRESS_PROGRESS: \(round + 1) MiB batches, resident=\(samples.last! / 1048576) MiB")
                fflush(stdout)
            }
            if interval > .zero { try await Task.sleep(for: interval) }
        }
        let tail = fixture.session.readScreenText(maxRows: 300, maxBytes: 128 * 1024)
        try check(tail?.text.contains("OUTPUT_END_\(rounds - 1)") == true && tail!.text.utf8.count <= 128 * 1024, "Bounded scrollback export lost final output or exceeded its limit")
        if rounds >= 40 {
            let steady = samples.dropFirst(20)
            try check(steady.max()! - steady.min()! < 64 * 1048576, "Bounded scrollback resident memory continued growing after warmup")
        }
        print("PASS sustained output: \(payload.utf8.count * rounds) bytes, all \(rounds) tail markers, bounded export; seconds=\(String(format: "%.2f", Date().timeIntervalSince(started))); resident MiB=\(samples.enumerated().filter { $0.offset < 12 || $0.offset % 20 == 19 }.map { $0.element / 1048576 })")
    }
}
