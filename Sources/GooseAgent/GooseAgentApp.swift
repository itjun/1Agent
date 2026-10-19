import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel

    private var shortcutMonitor: Any?
    private var shortcutsObserver: NSObjectProtocol?
    private var appliedShortcutsRevision = 0
    /// Existing paths after `-e`. AppKit also reports them as files to open; each is skipped once.
    private var commandArgumentPaths: Set<String> = []

    /// `AppModel` reads saved settings, so old defaults must be copied over first.
    override init() {
        CommandLineLaunch.handOffIfAnotherInstanceRuns()
        LegacyDefaultsMigration.runIfNeeded()
        model = AppModel()
        commandArgumentPaths = CommandLineLaunch.existingCommandPaths()
        super.init()
    }

    /// `oneagent://` links, plus folders and scripts from `open`, Finder, or the Dock.
    func application(_ application: NSApplication, open urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            if !url.isFileURL {
                model.openExternalURL(url)
                continue
            }
            if commandArgumentPaths.remove(url.standardizedFileURL.path) != nil {
                continue
            }
            files.append(url)
        }
        if !files.isEmpty {
            model.openFiles(files)
        }
    }

    @objc private func receiveHandedOffRunRequest(_ notification: Notification) {
        guard let id = notification.userInfo?[CommandLineLaunch.ticketKey] as? String,
              let ticket = CommandLineLaunch.takeTicket(id: id),
              let url = URL(string: ticket.url),
              let request = ExternalOpen.runRequest(from: url) else { return }
        model.openRunRequest(request)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ApplicationIconManager.shared.applyStoredIcon()
        AppearanceDriver.shared.reapply()
        TerminalDefaults.registerBundledFonts()
        GhosttyRuntime.removeLeftoverConfigFiles()
        GhosttyRuntime.applyTerminalSettings()
        MainWindowManager.shared.attach(model: model)
        TerminalAutomation.model = model
        TerminalActivity.shared.model = model
        TerminalNotifications.shared.install()
        // Reading PATH from a login shell takes a moment; do it now so the first ⌘T does not wait.
        Task.detached(priority: .utility) { _ = await SSHLaunchEnvironment.shared.get() }
        model.watchSSHConfig()
        model.restoreLastSession()
        QuickTerminalController.shared.start(model: model)
        NSApp.servicesProvider = ServiceProvider(model: model)
        NSUpdateDynamicServices()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(receiveHandedOffRunRequest(_:)),
            name: CommandLineLaunch.handOffNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        if let request = CommandLineLaunch.request {
            model.openRunRequest(request)
        }
        FocusedTerminal.shared.refresh()
        // SwiftUI fills in the Edit menu after launch returns.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                TerminalCommands.applySelectAllShortcut()
            }
        }
        appliedShortcutsRevision = UserDefaults.standard.integer(forKey: AppShortcuts.revisionKey)
        shortcutsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shortcutsDidChangeIfNeeded()
            }
        }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                self.handleShortcut(event)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + GhosttyConfigImport.promptDelay) { [model] in
            MainActor.assumeIsolated {
                GhosttyConfigImport.promptIfNeeded(model: model)
            }
        }
    }

    /// Clicking the Dock icon (or `open` without arguments) with the main window hidden brings it back.
    /// `flag` is also true when only Settings is on screen, so the main window is checked itself.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let hasTerminalWindow = model.windows.contains { MainWindowManager.shared.window(for: $0)?.isVisible == true }
        if !flag || !hasTerminalWindow {
            MainWindowManager.shared.show(model.keyWindow ?? model.mainWindow, model: model)
        }
        return true
    }

    /// SwiftUI menus follow the revision themselves; Edit → Select All is an AppKit item and is re-bound
    /// after SwiftUI has rebuilt the menus, so the rebuild cannot put ⌘A back.
    private func shortcutsDidChangeIfNeeded() {
        let revision = UserDefaults.standard.integer(forKey: AppShortcuts.revisionKey)
        if revision == appliedShortcutsRevision {
            return
        }
        appliedShortcutsRevision = revision
        QuickTerminalController.shared.refreshRegistration()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                TerminalCommands.applySelectAllShortcut()
            }
        }
    }

    /// Duplicate right/down and Close Terminal follow their `AppShortcuts` bindings (⌘D, ⇧⌘D, ⌘W by default).
    /// Close Terminal closes the selected terminal so the window stays open. Ctrl+D is left for the shell.
    /// Everything acts on the key window.
    private func handleShortcut(_ event: NSEvent) -> NSEvent? {
        // A transient menu owns navigation and its commands before app-wide shortcuts.
        if !FamilyMenuPresenter.shared.panels.isEmpty, FamilyMenuPresenter.shared.handleKey(event) { return nil }
        if let modal = NSApp.keyWindow as? FamilyModalWindow {
            if let chord = KeyChord.from(event: event) {
                if chord == AppShortcuts.chord(for: .closeTab) { modal.cancelOperation(nil); return nil }
                if AppShortcutID.allCases.contains(where: { $0.group != .terminal && AppShortcuts.chord(for: $0) == chord }) { return nil }
            }
            return event
        }
        // The Settings recorder swallows the key in its own monitor, which may run after this one.
        if ShortcutRecorder.isRecording {
            return event
        }
        if TerminalSwitcher.shared.isOpen {
            return TerminalSwitcher.shared.handle(event) ? nil : event
        }
        let window = model.keyWindow
        if event.keyCode == 53, let window, window.draggingTabID != nil || window.draggingBlock != nil {
            model.endDrag(in: window)
            return nil
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53, modifiers.isEmpty, TerminalFind.shared.closeForFocusedTerminal() {
            return nil
        }
        guard let chord = KeyChord.from(event: event) else { return event }
        if let window, !window.hostPickerPresented,
           NSApp.keyWindow?.identifier == MainWindowManager.windowID {
            if chord == AppShortcuts.chord(for: .toggleSidebar) {
                model.toggleSidebar(in: window)
                return nil
            }
            if chord == AppShortcuts.chord(for: .toggleToolSidebar) {
                model.toggleToolSidebar(in: window)
                return nil
            }
            if chord == AppShortcuts.chord(for: .commandPalette) {
                model.openCommandPalette(in: window)
                return nil
            }
        }
        if increasesFontSizeByPlusAlias(chord) {
            return nil
        }
        if jumpsToPromptByShiftAlias(chord) {
            return nil
        }
        if chord == AppShortcuts.chord(for: .openFileBrowser) {
            guard let window, !window.hostPickerPresented,
                  NSApp.keyWindow?.identifier == MainWindowManager.windowID else { return event }
            model.toggleSection(in: window)
            return nil
        }
        if let window, window.section == .files, !window.hostPickerPresented,
           chord == AppShortcuts.chord(for: .closeTab),
           NSApp.keyWindow?.identifier == MainWindowManager.windowID {
            _ = model.fileWorkspace(for: window).closeFocusedTab()
            return nil
        }
        if let window, window.section != .terminals, NSApp.keyWindow?.identifier == MainWindowManager.windowID {
            let terminalChord = AppShortcutID.allCases.contains { id in
                (id.group == .pane || id.group == .terminal) && AppShortcuts.chord(for: id) == chord
            }
            if terminalChord {
                return event
            }
        }
        if let handled = switchPane(chord, in: window) {
            return handled ? nil : event
        }
        if let handled = switchTerminal(chord, in: window) {
            return handled ? nil : event
        }
        if togglesFullScreen(chord) {
            return nil
        }
        let duplicatesRight = chord == AppShortcuts.chord(for: .duplicateRight)
        let duplicatesDown = chord == AppShortcuts.chord(for: .duplicateDown)
        let closesTerminal = chord == AppShortcuts.chord(for: .closeTab)
        guard duplicatesRight || duplicatesDown || closesTerminal else { return event }
        if NSApp.keyWindow?.identifier == SettingsWindowController.windowID {
            if closesTerminal {
                NSApp.keyWindow?.close()
            }
            return nil
        }
        guard let window else { return event }
        if window.hostPickerPresented {
            if closesTerminal {
                window.hostPickerPresented = false
            }
            return nil
        }
        if duplicatesRight || duplicatesDown {
            guard window.selectedTabID != nil else { return event }
            model.duplicateFocused(downward: duplicatesDown, in: window)
            return nil
        }
        // Nothing selected: hide the window like any other Mac app's close. The app keeps running.
        guard window.selectedTabID != nil else {
            MainWindowManager.shared.close(window)
            return nil
        }
        model.closeSelectedTab(in: window)
        return nil
    }

    /// ⌘+ (keypad plus, or ⇧⌘= on a US layout) also enlarges the text, like Ghostty's `super+plus`.
    /// A shortcut can hold only one chord, so these two stay fixed unless a shortcut claims them.
    /// `KeyChord.pressed(by:)` reports ⇧⌘= as `=` plus Shift.
    private func increasesFontSizeByPlusAlias(_ chord: KeyChord) -> Bool {
        let plus = KeyChord(key: "+", modifiers: .command)
        let shiftPlus = KeyChord(key: "=", modifiers: [.command, .shift])
        guard chord == plus || chord == shiftPlus else { return false }
        if AppShortcutID.allCases.contains(where: { AppShortcuts.chord(for: $0) == chord }) {
            return false
        }
        return FocusedTerminal.perform("increase_font_size:1")
    }

    /// ⇧⌘↑ / ⇧⌘↓ also jump between prompts, like Ghostty's defaults, unless a shortcut claims them.
    private func jumpsToPromptByShiftAlias(_ chord: KeyChord) -> Bool {
        let up = KeyChord(key: KeyChord.upArrow, modifiers: [.command, .shift])
        let down = KeyChord(key: KeyChord.downArrow, modifiers: [.command, .shift])
        guard chord == up || chord == down else { return false }
        if AppShortcutID.allCases.contains(where: { AppShortcuts.chord(for: $0) == chord }) {
            return false
        }
        if chord == up {
            return FocusedTerminal.perform("jump_to_prompt:-1")
        }
        return FocusedTerminal.perform("jump_to_prompt:1")
    }

    /// Nil when the chord is not a sidebar-switching shortcut. False lets the key through.
    private func switchTerminal(_ chord: KeyChord, in window: WindowState?) -> Bool? {
        let terminalShortcuts = AppShortcutID.allCases.filter { $0.group == .sidebar }
        let switcherChord = AppShortcuts.chord(for: .terminalSwitcher)
        var reverseSwitcherChord = switcherChord
        reverseSwitcherChord.modifierRaw = KeyChord.pack(switcherChord.modifiers.union(.shift))
        let matched = terminalShortcuts.first(where: { AppShortcuts.chord(for: $0) == chord })
            ?? (chord == reverseSwitcherChord ? .terminalSwitcher : nil)
        guard let id = matched else { return nil }
        guard let window else { return false }
        if NSApp.keyWindow?.identifier == SettingsWindowController.windowID || window.hostPickerPresented {
            return false
        }
        if id == .terminalSwitcher {
            return TerminalSwitcher.shared.open(model: model, window: window, chord: chord)
        }
        if id == .previousTerminal {
            return model.selectAdjacentTerminal(forward: false, in: window)
        }
        if id == .nextTerminal {
            return model.selectAdjacentTerminal(forward: true, in: window)
        }
        if id == .selectLastTerminal {
            return model.selectTerminal(number: nil, in: window)
        }
        guard let number = id.terminalNumber else { return false }
        return model.selectTerminal(number: number, in: window)
    }

    /// ⌃⌘F by default. ⌘↩ does the same, like Ghostty, unless a shortcut claims it.
    private func togglesFullScreen(_ chord: KeyChord) -> Bool {
        let returnAlias = KeyChord(key: "\r", modifiers: .command)
        var matches = chord == AppShortcuts.chord(for: .toggleFullScreen)
        if !matches && chord == returnAlias {
            matches = !AppShortcutID.allCases.contains(where: { AppShortcuts.chord(for: $0) == returnAlias })
        }
        if !matches {
            return false
        }
        return AppDelegate.toggleFullScreenOfKeyWindow()
    }

    /// View → Toggle Full Screen and its shortcut. Settings and sheets stay as they are.
    @discardableResult
    static func toggleFullScreenOfKeyWindow() -> Bool {
        guard let window = NSApp.keyWindow,
              window.identifier != SettingsWindowController.windowID,
              window.sheetParent == nil else { return false }
        window.toggleFullScreen(nil)
        return true
    }

    /// Nil when the chord is not a pane-switching shortcut. False lets the key through.
    private func switchPane(_ chord: KeyChord, in window: WindowState?) -> Bool? {
        let paneShortcuts: [AppShortcutID] = [
            .nextPane, .previousPane, .paneLeft, .paneRight, .paneUp, .paneDown,
            .movePaneLeft, .movePaneRight, .movePaneUp, .movePaneDown,
        ]
        guard paneShortcuts.contains(where: { AppShortcuts.chord(for: $0) == chord }) else { return nil }
        guard let window else { return false }
        if NSApp.keyWindow?.identifier == SettingsWindowController.windowID || window.hostPickerPresented {
            return false
        }
        // Moving comes first: it shares the arrow keys with focusing and adds Shift.
        if chord == AppShortcuts.chord(for: .movePaneLeft) {
            return model.movePane(toward: .left, in: window)
        }
        if chord == AppShortcuts.chord(for: .movePaneRight) {
            return model.movePane(toward: .right, in: window)
        }
        if chord == AppShortcuts.chord(for: .movePaneUp) {
            return model.movePane(toward: .up, in: window)
        }
        if chord == AppShortcuts.chord(for: .movePaneDown) {
            return model.movePane(toward: .down, in: window)
        }
        if chord == AppShortcuts.chord(for: .nextPane) {
            return model.focusAdjacentPane(forward: true, in: window)
        }
        if chord == AppShortcuts.chord(for: .previousPane) {
            return model.focusAdjacentPane(forward: false, in: window)
        }
        if chord == AppShortcuts.chord(for: .paneLeft) {
            return model.focusPane(toward: .left, in: window)
        }
        if chord == AppShortcuts.chord(for: .paneRight) {
            return model.focusPane(toward: .right, in: window)
        }
        if chord == AppShortcuts.chord(for: .paneUp) {
            return model.focusPane(toward: .up, in: window)
        }
        return model.focusPane(toward: .down, in: window)
    }

    /// The main window is hidden, not closed, so closing Settings last must not quit the terminals.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quitting closes every window; mark it first so those closes keep the terminals in the snapshot.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.isQuitting else { return .terminateLater }
        model.isQuitting = true
        model.persistSessionIfReady()
        FileTransferQueue.shared.interruptForTermination()
        Task { @MainActor in
            await SSHTerminalRegistry.stopAgentsForApplicationExit()
            model.persistSessionIfReady()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.persistSessionIfReady()
        RemoteShell.closeSharedConnections()
    }
}

/// `open -na 1Agent.app --args --working-directory=<dir> -e <cmd> …` (VS Code / Cursor debug
/// "runInTerminal") starts a second copy of the app. That copy hands the request to the copy
/// already running and exits before it reads or writes the session or shows a window.
///
/// Any process can post a distributed notification, so the request itself goes into a `HandOffTicket`
/// file in a folder only this user can open, and the notification carries just its name. The running
/// copy also checks that the ticket's pid runs this same executable.
enum CommandLineLaunch {
    static let handOffNotification = Notification.Name("com.itjun.1agent.handOffRunRequest")
    static let ticketKey = "ticket"
    /// The receiver reads the ticket while the sender is still alive; after this the sender gives up.
    static let handOffTimeout: TimeInterval = 2

    /// This process's own `--working-directory` / `-e` request, if it was started with one.
    static let request = ExternalOpen.runRequest(fromArguments: CommandLine.arguments)

    static var handOffDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.itjun.1agent/handoff", isDirectory: true)
    }

    /// A distributed notification reaches exactly the running copy. LaunchServices might hand a
    /// `oneagent://` URL back to this still-launching copy, and would also let any web page run commands.
    static func handOffIfAnotherInstanceRuns() {
        guard let request = CommandLineLaunch.request else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.itjun.1agent"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            $0.processIdentifier != me && !$0.isTerminated
        }
        guard !others.isEmpty, let url = ExternalOpen.runURL(for: request) else { return }
        let ticket = HandOffTicket(pid: me, url: url.absoluteString)
        guard let file = CommandLineLaunch.writeTicket(ticket) else {
            // Starting a second full copy would fight the running one over the saved session.
            exit(1)
        }
        DistributedNotificationCenter.default().postNotificationName(
            CommandLineLaunch.handOffNotification,
            object: nil,
            userInfo: [CommandLineLaunch.ticketKey: file.lastPathComponent],
            deliverImmediately: true
        )
        let deadline = Date().addingTimeInterval(CommandLineLaunch.handOffTimeout)
        while FileManager.default.fileExists(atPath: file.path) && Date() < deadline {
            usleep(50_000)
        }
        try? FileManager.default.removeItem(at: file)
        exit(0)
    }

    /// The folder is 0700 and the file 0600, named with a fresh UUID.
    private static func writeTicket(_ ticket: HandOffTicket) -> URL? {
        let manager = FileManager.default
        let directory = CommandLineLaunch.handOffDirectory
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            return nil
        }
        guard let data = try? JSONEncoder().encode(ticket) else { return nil }
        let file = directory.appendingPathComponent(UUID().uuidString)
        if !manager.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) {
            return nil
        }
        return file
    }

    /// The ticket named `id`, if it passes every check. It is removed either way, but only after the
    /// sender's pid was checked: the sender stays alive until the file is gone.
    static func takeTicket(id: String) -> HandOffTicket? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let directory = CommandLineLaunch.handOffDirectory.path
        var folder = stat()
        guard lstat(directory, &folder) == 0,
              folder.st_mode & S_IFMT == S_IFDIR,
              folder.st_uid == getuid(),
              folder.st_mode & 0o777 == 0o700 else { return nil }
        let path = (directory as NSString).appendingPathComponent(uuid.uuidString)
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        defer { unlink(path) }
        let birth = info.st_birthtimespec
        let createdAt = Date(timeIntervalSince1970: TimeInterval(birth.tv_sec) + TimeInterval(birth.tv_nsec) / 1_000_000_000)
        let acceptable = ExternalOpen.handOffFileIsAcceptable(
            isRegularFile: info.st_mode & S_IFMT == S_IFREG,
            owner: info.st_uid,
            currentUser: getuid(),
            permissions: Int(info.st_mode & 0o777),
            createdAt: createdAt,
            now: Date()
        )
        guard acceptable,
              let data = FileManager.default.contents(atPath: path),
              let ticket = try? JSONDecoder().decode(HandOffTicket.self, from: data),
              CommandLineLaunch.runsThisExecutable(pid: ticket.pid) else { return nil }
        return ticket
    }

    private static func runsThisExecutable(pid: Int32) -> Bool {
        if pid <= 0 || pid == ProcessInfo.processInfo.processIdentifier {
            return false
        }
        guard let own = Bundle.main.executablePath else { return false }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) <= 0 {
            return false
        }
        let path = String(cString: buffer)
        let theirs = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let ours = URL(fileURLWithPath: own).resolvingSymlinksInPath().path
        return theirs == ours
    }

    /// Absolute paths of the arguments after `-e` that exist right now, plus a bare folder argument
    /// that already became the working directory.
    static func existingCommandPaths() -> Set<String> {
        let arguments = CommandLine.arguments
        var paths: Set<String> = []
        if let folder = ExternalOpen.positionalDirectory(in: arguments) {
            paths.insert(folder)
        }
        guard let index = arguments.firstIndex(of: "-e") else { return paths }
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for argument in arguments[(index + 1)...] {
            let url = URL(fileURLWithPath: argument, relativeTo: base).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) {
                paths.insert(url.path)
            }
        }
        return paths
    }
}

@main
struct GooseAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Menu key equivalents are read while `commands` is built; this rebuilds them when a shortcut changes.
    @AppStorage(AppShortcuts.revisionKey) private var shortcutsRevision = 0

    init() {
        CommandLineLaunch.handOffIfAnotherInstanceRuns()
        LegacyDefaultsMigration.runIfNeeded()
        AppLanguage.synchronize()
        TerminalThemeChoice.migrateIfNeeded()
        // AppKit's own View → Enter Full Screen always shows 🌐F. View → Toggle Full Screen below replaces it,
        // so its key follows `AppShortcuts`. Registered, not written, so the defaults domain is unchanged.
        // A terminal never wants AutoFill guessing at its input; official Ghostty turns it off the same way.
        UserDefaults.standard.register(defaults: [
            "NSFullScreenMenuItemEverywhere": false,
            "NSAutoFillHeuristicControllerEnabled": false,
        ])
    }

    /// The main window is an AppKit window run by `MainWindowManager`.
    /// The Settings scene only exists to give the app a scene; ⌘, is replaced below.
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            let _ = shortcutsRevision
            CommandGroup(replacing: .newItem) {
                Button("New Window") { if !(NSApp.keyWindow is FamilyModalWindow) { appDelegate.model.newWindow() } }
                    .keyboardShortcut(AppShortcuts.chord(for: .newWindow).keyboardShortcut)
                Button("Close Window") {
                    guard !(NSApp.keyWindow is FamilyModalWindow), let state = appDelegate.model.keyWindow else { return }
                    MainWindowManager.shared.close(state)
                }
                    .keyboardShortcut(AppShortcuts.chord(for: .closeWindow).keyboardShortcut)
                Button("New Terminal") { if !(NSApp.keyWindow is FamilyModalWindow) { appDelegate.model.newTab() } }
                    .keyboardShortcut(AppShortcuts.chord(for: .newTab).keyboardShortcut)
                Button("New Local Terminal") { if !(NSApp.keyWindow is FamilyModalWindow) { appDelegate.model.openLocalTerminal() } }
                    .keyboardShortcut(AppShortcuts.chord(for: .newLocalTerminal).keyboardShortcut)
                Button("Open Host…") {
                    guard !(NSApp.keyWindow is FamilyModalWindow) else { return }
                    appDelegate.model.openHostPicker(purpose: appDelegate.model.keyWindow?.presentation.filesVisible == true ? .files : .terminal)
                }
                    .keyboardShortcut(AppShortcuts.chord(for: .openHost).keyboardShortcut)
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Quick Terminal") { QuickTerminalController.shared.toggle() }
                    .keyboardShortcut(AppShortcuts.chord(for: .quickTerminal).keyboardShortcut)
                Button(AppShortcutID.toggleSidebar.title) {
                    guard !(NSApp.keyWindow is FamilyModalWindow) else { return }
                    if let state = appDelegate.model.keyWindow { appDelegate.model.toggleSidebar(in: state) }
                }
                .keyboardShortcut(AppShortcuts.chord(for: .toggleSidebar).keyboardShortcut)
                Button(AppShortcutID.toggleToolSidebar.title) {
                    guard !(NSApp.keyWindow is FamilyModalWindow) else { return }
                    if let state = appDelegate.model.keyWindow { appDelegate.model.toggleToolSidebar(in: state) }
                }
                .keyboardShortcut(AppShortcuts.chord(for: .toggleToolSidebar).keyboardShortcut)
                Button(AppShortcutID.commandPalette.title) {
                    guard !(NSApp.keyWindow is FamilyModalWindow) else { return }
                    if let state = appDelegate.model.keyWindow { appDelegate.model.openCommandPalette(in: state) }
                }
                .keyboardShortcut(AppShortcuts.chord(for: .commandPalette).keyboardShortcut)
                Divider()
                Button("Open Items Overview") {
                    guard !(NSApp.keyWindow is FamilyModalWindow) else { return }
                    guard let window = appDelegate.model.keyWindow else { return }
                    DispatchQueue.main.async {
                        TerminalSwitcher.shared.open(model: appDelegate.model, window: window,
                            chord: AppShortcuts.chord(for: .terminalSwitcher), searching: true)
                    }
                }
                Button("Toggle Full Screen") {
                    guard !(NSApp.keyWindow is FamilyModalWindow) else { return }
                    AppDelegate.toggleFullScreenOfKeyWindow()
                }
                .keyboardShortcut(AppShortcuts.chord(for: .toggleFullScreen).keyboardShortcut)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings") { if !(NSApp.keyWindow is FamilyModalWindow) { appDelegate.model.toggleSettings() } }
                    .keyboardShortcut(AppShortcuts.chord(for: .settings).keyboardShortcut)
            }
            TerminalCommands(focus: FocusedTerminal.shared, model: appDelegate.model) {
                if let state = appDelegate.model.keyWindow { appDelegate.model.toggleSplitZoom(in: state) }
            }
        }
    }
}
