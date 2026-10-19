import AppKit
import CoreText
import GhosttyTerminal
import GhosttyTheme
import Quartz
import SwiftUI

enum TerminalDefaults {
    static let defaultFontSize = TerminalSettings.defaults.fontSize
    static let defaultFontFamily = TerminalSettings.defaults.fontFamily
    static let defaultFontWeight: Double = 0
    static let defaultLineSpacing: Double = 1
    static let minFontSize = TerminalSettings.minFontSize
    static let maxFontSize = TerminalSettings.maxFontSize
    static let symbolFallbackFamily = TerminalSettings.symbolFallbackFamily

    static func registerBundledFonts() {
        guard let url = Bundle.main.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

/// Persisted terminal typeface / size. Ghostty reads these on every surface refresh.
enum TerminalFontSettings {
    static let familyKey = TerminalSettings.fontFamilyKey
    static let sizeKey = TerminalSettings.fontSizeKey

    /// Preferred families shown first when installed (Ghostty resolves SF Mono even if NSFont cannot).
    private static let preferredFamilies = [
        "SF Mono",
        "Menlo",
        "Monaco",
        "Maple Mono NF CN",
        "JetBrains Mono",
        "Fira Code",
        "Hack",
        "Source Code Pro",
        "IBM Plex Mono",
        "Cascadia Code",
        "Cascadia Mono",
        "PT Mono",
        "Andale Mono",
        "Courier New",
    ]

    static var family: String {
        TerminalSettings.load().fontFamily
    }

    /// Monospace-ish families for the settings picker, preferred names first.
    static func availableFamilies() -> [String] {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        var result: [String] = []
        var seen = Set<String>()

        func append(_ name: String) {
            guard !seen.contains(name) else { return }
            // Always keep the current / default choice, even if NSFont cannot resolve SF Mono.
            let keepAlways = name == family
                || name == TerminalDefaults.defaultFontFamily
                || preferredFamilies.contains(name)
            let present = installed.contains(name) || keepAlways
            guard present else { return }
            if name == TerminalDefaults.symbolFallbackFamily { return }
            seen.insert(name)
            result.append(name)
        }

        for name in preferredFamilies {
            append(name)
        }

        for name in installed.sorted() where isLikelyMonospace(name) {
            append(name)
        }

        append(family)
        return result
    }

    private static func isLikelyMonospace(_ family: String) -> Bool {
        if family == TerminalDefaults.symbolFallbackFamily { return false }
        let lower = family.lowercased()
        if lower.contains("mono") || lower.contains("code") || lower.contains("consolas") {
            return true
        }
        if family == "Menlo" || family == "Monaco" || family == "Courier" || family == "Courier New" {
            return true
        }
        if let font = NSFontManager.shared.font(
            withFamily: family,
            traits: .fixedPitchFontMask,
            weight: 5,
            size: 12
        ), font.isFixedPitch {
            return true
        }
        return false
    }
}

@MainActor
enum GhosttyRuntime {
    static let controller = TerminalController(
        configSource: appearanceConfigSource,
        theme: selectedThemes()
    )

    /// The two marker files make Ghostty treat light and dark as distinct themes, so the
    /// appearance switch reloads colors. The colors themselves come from `TerminalTheme`.
    static var appearanceConfigSource: TerminalController.ConfigSource {
        guard let light = Bundle.main.url(forResource: "TerminalLight", withExtension: "ghostty"),
              let dark = Bundle.main.url(forResource: "TerminalDark", withExtension: "ghostty") else {
            preconditionFailure("Missing bundled terminal appearance markers")
        }
        return .generated(TerminalConfiguration.default.rendered
            + "\ntheme = light:\(light.path),dark:\(dark.path)\n")
    }

    /// Called once at launch and again after any `TerminalSettings` value changes. Not per view update.
    /// Ghostty only re-renders when the generated configuration actually differs.
    static func applyTerminalSettings() {
        let settings = TerminalSettings.load()
        let custom = TerminalSettings.parseCustomConfig(settings.customConfig)
        // Ghostty refuses a whole configuration over one bad line, so a broken snippet line
        // would also block every settings change. Lines it refuses are dropped one by one.
        let fit = TerminalSnippetFit.fit(custom.entries) { entries in
            let configuration = terminalConfiguration(settings: settings, snippet: entries)
            controller.setTerminalConfiguration(configuration)
            // The controller only commits a configuration Ghostty accepted, and returns false both for a
            // rejection and for "nothing changed"; `lastConfigurationIssue` is not cleared by the latter.
            if controller.terminalConfiguration == configuration {
                return nil
            }
            return controller.lastConfigurationIssue ?? String(localized: "Ghostty gave no reason")
        }
        let diagnostics = TerminalConfigDiagnostics.shared
        diagnostics.skippedLines = custom.skippedLines
        diagnostics.invalidLines = custom.invalidLines
        diagnostics.rejectedLines = fit.rejected
        diagnostics.engineIssue = fit.baseIssue
    }

    /// The engine package writes `ghostty-config-<UUID>.conf` for every applied configuration and removes
    /// the previous one itself, but the file in use when the app quits stays behind. Files older than
    /// this process are those leftovers; nothing else in the folder is touched.
    static func removeLeftoverConfigFiles() {
        let directory = TerminalController.managedConfigDirectory
        guard let started = GhosttyRuntime.processStartDate(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix("ghostty-config-") && name.hasSuffix(".conf") {
            let url = directory.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate else { continue }
            if modified < started {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        if sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) != 0 {
            return nil
        }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// Light and night slots are chosen independently; Ghostty switches with the appearance.
    static func applySelectedThemes() {
        controller.setTheme(selectedThemes())
    }

    private static func selectedThemes() -> TerminalTheme {
        TerminalThemeChoice.migrateIfNeeded()
        return TerminalTheme(
            light: ThemePreview.shared.effectiveLight().terminalConfiguration(),
            dark: ThemePreview.shared.effectiveDark().terminalConfiguration()
        )
    }

    /// Settings first, then the advanced snippet, so a snippet line wins over the same setting.
    /// The window is always opaque, so an imported `background-opacity` must not clear the panes.
    private static func terminalConfiguration(
        settings: TerminalSettings,
        snippet: [TerminalConfigEntry]
    ) -> TerminalConfiguration {
        let entries = (settings.configEntries() + snippet).filter { $0.key != "background-opacity" }
        return TerminalConfiguration { builder in
            for entry in entries {
                builder.withCustom(entry.key, entry.value)
            }
        }
    }

}

/// What the last `applyTerminalSettings()` left out or Ghostty rejected, for the advanced settings page.
@MainActor
final class TerminalConfigDiagnostics: ObservableObject {
    static let shared = TerminalConfigDiagnostics()

    /// Snippet lines dropped because the app owns their key.
    @Published var skippedLines: [String] = []
    /// Snippet lines without `key = value`.
    @Published var invalidLines: [String] = []
    /// Snippet lines Ghostty refused. The settings and the other snippet lines were applied without them.
    @Published var rejectedLines: [TerminalConfigRejection] = []
    /// Ghostty refused the settings even without the snippet; nil when it accepted them.
    @Published var engineIssue: String?
}

/// `ssh` copies `TERM` from its own environment onto the remote pty.
/// Keep that value at `xterm-256color` even if a caller passed something else.
private func sshChildEnvironment(_ commandEnvironment: [String]) -> [String] {
    var environment = commandEnvironment.filter {
        let key = $0.prefix(while: { $0 != "=" })
        return key != "TERM" && key != "COLORTERM" && key != "COLORFGBG"
            && !key.hasPrefix("TERM_PROGRAM") && key != "GHOSTTY_RESOURCES_DIR"
    }
    environment.append("TERM=xterm-256color")
    return environment
}

/// The command a terminal runs, kept so the same session can start it again after a disconnect.
struct TerminalLaunch: Equatable {
    var executable: String
    var args: [String]
    var environment: [String]
    var directory: String?
    /// Local shells only: `ShellIntegrationEnvironment` variables, applied after `sshChildEnvironment`.
    var shellIntegrationEnvironment: [String] = []
    var integratesRemoteShell = false
    var remoteDirectory: String? = nil
}

/// Owns one Ghostty session and the child process behind it. The process can be replaced
/// (reconnect) while the session, and with it the scrollback on screen, stays the same.
@MainActor
final class TerminalProcessHost {
    /// Holds the current process so the session's `@Sendable` closures can follow a replacement.
    private final class ProcessBox: @unchecked Sendable {
        var process = TerminalProcess()
        private let lock = NSLock()
        private var viewport: InMemoryTerminalViewport?
        func record(_ value: InMemoryTerminalViewport) {
            lock.lock(); viewport = value; lock.unlock()
        }
        func size() -> (columns: UInt16, rows: UInt16) {
            lock.lock(); defer { lock.unlock() }
            return (viewport?.columns ?? 80, viewport?.rows ?? 24)
        }
    }

    let session: InMemoryTerminalSession
    private let box = ProcessBox()
    private var launch: TerminalLaunch?
    private var initialLaunch: TerminalLaunch?
    private var startedAt: TimeInterval = 0
    private var hasStarted = false
    private var pendingInitialInput: Data?
    private var pendingRestoration: TerminalRestoration?
    private var terminated = false
    private(set) var commandBridge: LocalCommandBridge?
    private(set) var remoteWorkingDirectory: String?
    private(set) var isRemote = false
    private(set) var agentContext: AgentSessionContext?
    private(set) var remoteAgentContext: RemoteAgentSessionContext?
    private var remoteAgentSeed: AgentConversation?
    var savedAgentConversation: AgentConversation? {
        if isRemote { return remoteAgentContext == nil ? remoteAgentSeed : remoteAgentContext?.conversation }
        return agentContext?.conversation
    }
    var onRemoteDirectory: ((String) -> Void)?
    private var remotePreparation: Task<Void, Never>?
    private var cancelForwarding: (() -> Void)?

    var process: TerminalProcess { box.process }

    /// Exit code and how long the process lived, in seconds.
    var onExit: ((Int32?, TimeInterval) -> Void)?

    init() {
        let box = self.box
        session = InMemoryTerminalSession(
            write: { data in box.process.write(data) },
            resize: { viewport in
                // Ignore park/collapse sizes so a hidden tab never reflows the PTY to 1×1.
                guard viewport.columns >= 2, viewport.rows >= 2 else { return }
                box.record(viewport)
                box.process.resize(
                    columns: viewport.columns,
                    rows: viewport.rows,
                    widthPixels: viewport.widthPixels,
                    heightPixels: viewport.heightPixels
                )
            },
            suppressesPixelOnlyResizes: true
        )
    }

    func start(_ launch: TerminalLaunch, initialLaunch: TerminalLaunch? = nil, restoration: TerminalRestoration? = nil,
               agentConversation: AgentConversation? = nil) {
        self.launch = launch
        self.initialLaunch = initialLaunch
        isRemote = launch.integratesRemoteShell
        remoteAgentSeed = agentConversation
        if !launch.integratesRemoteShell, !launch.shellIntegrationEnvironment.isEmpty {
            agentContext = AgentSessionContext(conversation: agentConversation)
            if initialLaunch == nil, let command = agentContext?.resumeCommand {
                var first = launch
                // Login/interactive rc files load normally before the CLI. Its command is an
                // explicit exec argument, so no password prompt or Agent input can consume it.
                first.args = ["-l", "-i", "-c", command + "; exec " + AgentLaunchPolicy.quote(launch.executable) + " -l"]
                self.initialLaunch = first
            }
        }
        pendingRestoration = restoration
        startWhenReady()
    }

    func startWhenReady() {
        guard !terminated, session.hasAttachedSurface, !hasStarted, let launch else { return }
        hasStarted = true
        if let restoration = pendingRestoration {
            pendingRestoration = nil
            session.receive(restoration.notice())
        }
        startProcess(initialLaunch ?? launch)
        initialLaunch = nil
    }

    func sendInitialInput(_ text: String) {
        let data = Data(text.utf8)
        if process.shellPid > 0 { process.write(data) } else { pendingInitialInput = data }
    }

    /// Prints a dim divider into the same terminal and starts the command again.
    /// Nothing on screen is lost; the new connection continues below the old output.
    func restart(notice: String) {
        guard let launch else { return }
        process.terminate()
        session.receive("\r\n\u{1b}[2m— \(notice) —\u{1b}[0m\r\n")
        startProcess(launch)
    }

    var lastLaunch: TerminalLaunch? { launch }

    /// The shell reports its current remote directory through the model. Remember the
    /// next authenticated SSH launch without sending anything to the current process.
    func updateLaunch(_ next: TerminalLaunch) { launch = next }

    func terminate() {
        terminated = true
        remoteAgentContext?.cancel()
        remotePreparation?.cancel()
        process.terminate()
        cancelForwarding?(); cancelForwarding = nil
        commandBridge = nil
    }

    private func startProcess(_ launch: TerminalLaunch) {
        remotePreparation?.cancel()
        if let remoteAgentContext {
            remoteAgentSeed = remoteAgentContext.conversation
            remoteAgentContext.cancel()
            self.remoteAgentContext = nil
        }
        cancelForwarding?(); cancelForwarding = nil
        commandBridge = nil
        remoteWorkingDirectory = nil
        isRemote = launch.integratesRemoteShell
        let process = TerminalProcess()
        var tracker = RemoteDirectoryTracker()
        process.onOutput = { [weak self, weak process, session] data in
            session.receive(data)
            guard launch.integratesRemoteShell else { return }
            for path in tracker.receive(data) {
                Task { @MainActor [weak self, weak process] in
                    guard let self, let process, self.process === process else { return }
                    self.remoteWorkingDirectory = path
                    self.onRemoteDirectory?(path)
                }
            }
        }
        process.onExit = { [weak self, weak process] code in
            guard let self, let process, process === self.box.process else { return }
            let lived = ProcessInfo.processInfo.systemUptime - self.startedAt
            self.onExit?(code, lived)
        }
        box.process = process
        startedAt = ProcessInfo.processInfo.systemUptime
        var environment = sshChildEnvironment(launch.environment)
        if !launch.shellIntegrationEnvironment.isEmpty {
            environment = ShellIntegrationEnvironment.merged(environment, overrides: launch.shellIntegrationEnvironment)
            if let agentContext { environment = ShellIntegrationEnvironment.merged(environment, overrides: agentContext.environment) }
            commandBridge = LocalCommandBridge()
            if let commandBridge {
                environment = environment.filter { !$0.hasPrefix("ONEAGENT_QC_") } + commandBridge.environment
            }
        }
        if launch.integratesRemoteShell, let resources = Bundle.main.resourcePath, let bridge = LocalCommandBridge(remote: true) {
            let childEnvironment = environment
            let agentSeed = remoteAgentSeed
            let seedData = agentSeed.flatMap { try? JSONEncoder().encode($0) }
            let agentSocket = bridge.folder + "/a"
            let unavailable = String(localized: "Agent conversation recovery needs Python 3.9 or later and Bash or Zsh on this host.")
            let restoreError = String(localized: "Cannot restore the Agent conversation. Check the tool, session file and directory.")
            remotePreparation = Task { [weak self, weak process] in
                let prepared = await Task.detached {
                    RemoteShellIntegration.prepare(arguments: launch.args, environment: childEnvironment,
                                                   resources: resources, socket: bridge.socketPath, token: bridge.token,
                                                   agentSocket: agentSocket, agentConversation: seedData,
                                                   remoteDirectory: launch.remoteDirectory,
                                                   directoryCommand: launch.remoteDirectory.map { SSHCommand.remoteStartupCommand(directory: $0) },
                                                   agentUnavailableMessage: unavailable, agentRestoreError: restoreError)
                }.value
                guard !Task.isCancelled, let self, let process, self.process === process, !self.terminated else { return }
                if let prepared {
                    self.commandBridge = bridge
                    let context = RemoteAgentSessionContext(socketPath: agentSocket, token: bridge.token, conversation: agentSeed)
                    self.remoteAgentContext = context
                    context.start()
                    self.cancelForwarding = {
                        DispatchQueue.global().async {
                            let cancel = Process()
                            cancel.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                            cancel.arguments = prepared.cancelArguments
                            cancel.standardInput = FileHandle.nullDevice
                            cancel.standardOutput = FileHandle.nullDevice; cancel.standardError = FileHandle.nullDevice
                            try? cancel.run()
                        }
                    }
                }
                self.spawn(process, launch: launch, arguments: prepared?.arguments ?? launch.args, environment: childEnvironment)
            }
        } else { spawn(process, launch: launch, arguments: launch.args, environment: environment) }
    }

    private func spawn(_ process: TerminalProcess, launch: TerminalLaunch, arguments: [String], environment: [String]) {
        let size = box.size()
        process.start(executable: launch.executable, args: arguments, environment: environment, directory: launch.directory,
                      columns: size.columns, rows: size.rows)
        if let pendingInitialInput {
            process.write(pendingInitialInput)
            self.pendingInitialInput = nil
        }
    }
}

/// Owns every live terminal view. A view is created the first time a window shows its session and
/// stays alive until the tab closes, so it can move between panes and windows without the ssh
/// process dying with a SwiftUI teardown.
@MainActor
enum SSHTerminalRegistry {
    private static var views: [String: SSHTerminalNSView] = [:]
    private static var directoryTimer: Timer?
    /// Session IDs are never reused, so a closed one must never get a terminal again.
    private static var closedIDs: Set<String> = []

    /// The terminal for this session, made on first use. Nil once the session was destroyed:
    /// SwiftUI still updates a view that is on its way out, and that must not start a new process.
    static func view(for id: String, make: () -> SSHTerminalNSView) -> SSHTerminalNSView? {
        if let existing = views[id] {
            return existing
        }
        if closedIDs.contains(id) {
            return nil
        }
        let created = make()
        views[id] = created
        if directoryTimer == nil {
            directoryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    TerminalActivity.shared.model?.refreshLocalWorkingDirectories()
                }
            }
            directoryTimer?.tolerance = 0.2
        }
        return created
    }

    /// The tab closed. Ends the process and drops the view.
    static func destroy(_ id: String) {
        closedIDs.insert(id)
        TerminalSecureInput.shared.forget(id)
        guard let view = views.removeValue(forKey: id) else { return }
        if views.isEmpty {
            directoryTimer?.invalidate()
            directoryTimer = nil
        }
        view.processHost?.terminate()
        view.removeFromSuperview()
    }

    static func focus(_ id: String) {
        DispatchQueue.main.async {
            guard let view = views[id], let window = view.window else { return }
            if let state = MainWindowManager.shared.state(for: window),
               state.presentation.filesVisible && state.presentation.filesWorkspace { return }
            if let host = view.superview as? TerminalHostView {
                host.requestFocus()
                return
            }
            window.makeFirstResponder(view)
        }
    }

    /// The shell's own cwd. Nil until the process is running, or after it exits.
    static func currentWorkingDirectory(for id: String) -> String? {
        views[id]?.processHost?.process.currentWorkingDirectory
    }

    static func processIdentity(for id: String) -> UUID? {
        views[id]?.processHost?.process.identity
    }

    static func agentConversation(for id: String, fallback: AgentConversation?) -> AgentConversation? {
        guard let host = views[id]?.processHost else { return fallback }
        return host.savedAgentConversation
    }

    /// Called while PTYs and output readers are still alive, allowing transcript flushes.
    static func stopAgentsForApplicationExit() async {
        let pids = views.values.compactMap { view -> pid_t? in
            guard let host = view.processHost else { return nil }
            return host.agentContext?.stop(ownedBy: host.process.shellPid)
        }
        let deadline = Date().addingTimeInterval(3.5)
        await withTaskGroup(of: Void.self) { group in
            for view in views.values {
                if let context = view.processHost?.remoteAgentContext {
                    group.addTask { await context.stop() }
                }
            }
        }
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    static func quickCommandReady(_ id: String) async -> Bool {
        guard let view = views[id], !view.hasMarkedText(), let host = view.processHost,
              host.process.shellIsForeground, let bridge = host.commandBridge else { return false }
        let process = host.process, revision = host.process.commandInputRevision
        guard await bridge.query() else { return false }
        return views[id] === view && host.process === process && !view.hasMarkedText() && host.process.shellIsForeground
            && host.process.commandInputRevision == revision
    }

    static func runQuickCommand(_ request: QuickCommandRunRequest, contextIsCurrent: () -> Bool) async throws {
        guard let id = request.context.sessionID, let view = views[id], !view.hasMarkedText(),
              let host = view.processHost, host.process.shellIsForeground, let bridge = host.commandBridge,
              let directory = request.context.directory,
              (host.isRemote ? host.remoteWorkingDirectory : host.process.currentWorkingDirectory) == directory else { throw QuickCommandError.unavailable }
        let process = host.process, revision = host.process.commandInputRevision
        guard process.identity == request.context.processID else { throw QuickCommandError.changedTarget }
        guard await bridge.query(), views[id] === view, host.process === process, !view.hasMarkedText(),
              host.process.commandInputRevision == revision, host.process.shellIsForeground else { throw QuickCommandError.unavailable }
        guard contextIsCurrent() else { throw QuickCommandError.changedTarget }
        try await bridge.run(id: request.id, script: request.currentShellCommand, expectedDirectory: directory)
    }

    /// Text typed at the prompt as a paste. False when the view is gone.
    @discardableResult
    static func paste(_ text: String, into id: String) -> Bool {
        guard let view = views[id] else { return false }
        view.window?.makeFirstResponder(view)
        return view.paste(text: text)
    }

    /// The terminal's window, for sheets and progress shown over it.
    static func window(for id: String) -> NSWindow? {
        views[id]?.window
    }

    /// The rows on screen as plain text. Nil before the terminal was made or once it closed.
    static func viewportText(for id: String) -> String? {
        views[id]?.processHost?.session.readViewportText()
    }

    static func hasRunningCommand(_ id: String) -> Bool {
        guard let host = views[id]?.processHost else { return false }
        return host.isRemote || !host.process.shellIsForeground
    }

    static func automationView(_ id: String) -> SSHTerminalNSView? { views[id] }

    /// Starts the same command again inside the same terminal. False when the view is gone.
    @discardableResult
    static func restart(_ id: String, notice: String) -> Bool {
        guard let host = views[id]?.processHost else { return false }
        host.restart(notice: notice)
        return true
    }
}

enum TerminalCloseMenu {
    static func item(action: Selector, target: AnyObject) -> NSMenuItem {
        TerminalCloseMenu.item(
            title: String(localized: "Close Terminal"),
            action: action,
            target: target
        )
    }

    /// Red menu title, same treatment as Close Terminal.
    static func item(title: String, action: Selector, target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.menuFont(ofSize: 0),
            ]
        )
        return item
    }
}

final class SSHTerminalNSView: AppTerminalView {
    var onFocus: (() -> Void)?
    var onClose: (() -> Void)?
    var onRevealFiles: (() -> Void)?
    var paneMenuItems: () -> [FamilyMenuItem] = { [] }
    /// Split Right / Split Down from the context menu: another session like this one beside it.
    var onSplit: ((SplitEdge) -> Void)?
    /// Finder files dropped on a split, New Tab, or transfer circle.
    var onFileDrop: (([URL], DropZone) -> Void)?
    var canDropQuickCommand: (UUID) -> Bool = { _ in false }
    var onQuickCommandDrop: (UUID) -> Bool = { _ in false }
    /// The session runs over ssh: the transfer circle uploads instead of copying.
    var dropIsRemote = false
    var appliedDarkAppearance: Int?
    weak var attachedSurface: TerminalSurface? {
        didSet { if attachedSurface != nil { processHost?.startWhenReady() } }
    }
    /// `TerminalTab.sessionID` this terminal was made for. The find bar is keyed by it.
    var sessionID: String?
    /// Strong: the view is the only owner. The session keeps the process alive on its own, so a weak
    /// reference here drops the host silently and exits, restarts, and cwd lookups stop working.
    var processHost: TerminalProcessHost?
    /// Set as `delegate` once, when the terminal is made. `delegate` is weak, so the view keeps it alive.
    let eventRelay = TerminalEventRelay()
    /// Subview rather than SwiftUI: the metal layer covers any SwiftUI view placed over the terminal.
    private let bellBorder = TerminalOverlayView()
    private let linkBanner = TerminalLinkBanner()
    private let dropHighlight = TerminalOverlayView()
    private let focusRail = TerminalOverlayView()
    private let dropOverlay = DropZoneOverlay()
    private var quickLookURLs: [URL] = []
    /// The engine asked for a pointing hand over a link. Other shapes keep the arrow this view always had.
    private var showsLinkCursor = false
    private var gestureIsLocal = false
    /// The right button went down to a program that reads the mouse, so the release goes there too.
    private var rightClickToProgram = false
    private var locallyConsumedKeyCode: UInt16?

    /// Keep the native terminal's explicit appearance in sync without rebuilding its surface.
    /// The surrounding SwiftUI pane continues to inherit the application's appearance.
    func applyTerminalAppearance(dark: Bool) {
        let signature = dark ? 1 : 0
        guard appliedDarkAppearance != signature else { return }
        appliedDarkAppearance = signature
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        GhosttyRuntime.controller.setColorScheme(dark ? .dark : .light)
    }


    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        FocusedTerminal.shared.refreshSoon()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        FocusedTerminal.shared.refreshSoon()
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        FocusedTerminal.shared.refreshSoon()
    }

    /// Draw above the Metal surface without adding a hit target or resizing the PTY.
    func setFocusRail(color: NSColor?) {
        if color != nil && focusRail.superview !== self {
            focusRail.setAccessibilityElement(false)
            addSubview(focusRail)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusRail.layer?.backgroundColor = color?.cgColor
        focusRail.layer?.cornerRadius = Theme.PaneStyle.focusRailWidth / 2
        focusRail.isHidden = color == nil
        layoutFocusRail()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        layoutFocusRail()
    }

    private func layoutFocusRail() {
        guard focusRail.superview === self else { return }
        let height = min(Theme.PaneStyle.focusRailHeight, max(0, bounds.height - 2 * Theme.PaneStyle.focusRailTopInset))
        let y = isFlipped ? Theme.PaneStyle.focusRailTopInset : bounds.height - Theme.PaneStyle.focusRailTopInset - height
        focusRail.frame = NSRect(x: Theme.PaneStyle.focusRailInset, y: y,
                                 width: Theme.PaneStyle.focusRailWidth, height: height)
    }

    override func keyDown(with event: NSEvent) {
        locallyConsumedKeyCode = nil
        hidePointerWhileTyping(event)
        if hasMarkedText() {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.command) || modifiers.contains(.control) { return }
            super.keyDown(with: event)
            return
        }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option, .shift])
        if !modifiers.isEmpty,
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            locallyConsumedKeyCode = event.keyCode
            return
        }
        if let payload = Self.ptyBytes(forMacEditingKey: event) {
            processHost?.session.sendInput(Data(payload.utf8))
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if locallyConsumedKeyCode == event.keyCode {
            locallyConsumedKeyCode = nil
            return
        }
        super.keyUp(with: event)
    }

    func flashBellBorder(color: NSColor) {
        if bellBorder.superview !== self {
            bellBorder.frame = bounds
            bellBorder.autoresizingMask = [.width, .height]
            addSubview(bellBorder)
        }
        guard let layer = bellBorder.layer else { return }
        layer.borderColor = color.cgColor
        layer.borderWidth = Theme.PaneStyle.bellBorderWidth
        layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Theme.PaneStyle.bellFlashDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "bellFlash")
    }

    /// Nil when the pointer left the link.
    func showHoverLink(_ url: String?) {
        guard let url, !url.isEmpty else {
            linkBanner.removeFromSuperview()
            return
        }
        if linkBanner.superview !== self {
            addSubview(linkBanner)
        }
        let chrome = WindowChrome.resolve(isDark: AppearanceDriver.shared.isDark)
        linkBanner.show(
            url,
            background: NSColor(chrome.elevated),
            text: NSColor(chrome.secondary),
            border: NSColor(chrome.hairline),
            in: bounds
        )
    }

    /// Internal command drags never enter the terminal's text/file paste path.
    func acceptsQuickCommand(_ id: UUID) -> Bool {
        guard let sessionID, TerminalActivity.shared.isOnScreen(sessionID: sessionID) else { return false }
        return canDropQuickCommand(id)
    }

    func highlightQuickCommand(_ id: UUID?) {
        showDropHighlight(id.map { acceptsQuickCommand($0) } ?? false)
    }

    @discardableResult
    func dropQuickCommand(_ id: UUID) -> Bool {
        highlightQuickCommand(nil)
        guard acceptsQuickCommand(id) else { return false }
        return onQuickCommandDrop(id)
    }

    // MARK: Dropping files

    /// Finder files, or plain text. Tab drags between panes track the mouse themselves and put
    /// nothing on a pasteboard, so they never reach these methods.
    static let dropTypes: [NSPasteboard.PasteboardType] = [.fileURL, .string]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop(sender) else { return [] }
        trackDrop(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop(sender) else { return [] }
        trackDrop(sender)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        endDropFeedback()
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        endDropFeedback()
    }

    /// Finder files go to the circle under the mouse. Plain text, and Insert Path, become escaped
    /// paths typed at the prompt like any text, so the same works in an ssh session. The paste path
    /// skips paste protection, as Ghostty's drop does.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let zone = dropOverlay.superview === self ? dropOverlay.zone(at: sender.draggingLocation) : nil
        endDropFeedback()
        guard acceptsDrop(sender) else { return false }
        let pasteboard = sender.draggingPasteboard
        if let urls = droppedFiles(pasteboard) {
            return drop(urls, on: zone ?? .insertPath)
        }
        guard let string = pasteboard.string(forType: .string), !string.isEmpty else { return false }
        window?.makeFirstResponder(self)
        return paste(text: string)
    }

    private func droppedFiles(_ pasteboard: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else { return nil }
        return urls
    }

    private func drop(_ urls: [URL], on zone: DropZone) -> Bool {
        switch zone {
        case .insertPath:
            window?.makeFirstResponder(self)
            return paste(text: ShellEscape.dropText(paths: urls.map(\.path)))
        case .openInPlace:
            window?.makeFirstResponder(self)
            var isDirectory: ObjCBool = false
            if urls.count == 1, FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                guard let process = processHost?.process else { return false }
                process.write(Data("cd \(ShellEscape.escape(urls[0].path))\r".utf8))
                return true
            }
            showQuickLook(urls)
            return true
        case .splitLeft, .splitRight, .newTab, .transfer:
            guard let onFileDrop else { return false }
            onFileDrop(urls, zone)
            return true
        }
    }

    private func trackDrop(_ sender: any NSDraggingInfo) {
        guard droppedFiles(sender.draggingPasteboard) != nil else {
            showDropHighlight(true)
            return
        }
        if dropOverlay.superview !== self {
            dropOverlay.frame = bounds
            dropOverlay.autoresizingMask = [.width, .height]
            dropOverlay.configure(transfer: onFileDrop != nil, remote: dropIsRemote)
            addSubview(dropOverlay)
        }
        dropOverlay.highlight(dropOverlay.zone(at: sender.draggingLocation))
    }

    private func endDropFeedback() {
        showDropHighlight(false)
        dropOverlay.highlight(nil)
        dropOverlay.removeFromSuperview()
    }

    /// The panel asks the responder chain for its data source; this view is first responder here.
    private func showQuickLook(_ urls: [URL]) {
        quickLookURLs = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, (panel.currentController as AnyObject?) === self {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        !quickLookURLs.isEmpty
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        quickLookURLs = []
    }

    /// A tab that is not shown keeps its view, invisible, under the visible panes.
    private func acceptsDrop(_ sender: any NSDraggingInfo) -> Bool {
        guard let types = sender.draggingPasteboard.types,
              !Set(types).isDisjoint(with: SSHTerminalNSView.dropTypes) else { return false }
        guard let sessionID else { return false }
        return TerminalActivity.shared.isOnScreen(sessionID: sessionID)
    }

    private func showDropHighlight(_ visible: Bool) {
        guard visible else {
            dropHighlight.removeFromSuperview()
            return
        }
        if dropHighlight.superview !== self {
            dropHighlight.frame = bounds
            dropHighlight.autoresizingMask = [.width, .height]
            addSubview(dropHighlight)
        }
        let accent = NSColor(WindowChrome.resolve(isDark: AppearanceDriver.shared.isDark).accent)
        dropHighlight.layer?.borderColor = accent.cgColor
        dropHighlight.layer?.borderWidth = Theme.PaneStyle.dropHighlightWidth
        dropHighlight.layer?.backgroundColor = accent.withAlphaComponent(Theme.PaneStyle.dropHighlightFillOpacity).cgColor
    }

    func applyMouseShape(_ shape: TerminalMouseShape) {
        if shape == .pointer {
            NSCursor.pointingHand.set()
            showsLinkCursor = true
        } else if showsLinkCursor {
            NSCursor.arrow.set()
            showsLinkCursor = false
        }
    }

    /// `mouse-hide-while-typing` is not handled by the engine in this host. ⌘ and ⌃ combinations are
    /// shortcuts, not typing, and keep the pointer.
    private func hidePointerWhileTyping(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !modifiers.isDisjoint(with: [.command, .control]) {
            return
        }
        if UserDefaults.standard.bool(forKey: TerminalSettings.mouseHideWhileTypingKey) {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private static func ptyBytes(forMacEditingKey event: NSEvent) -> String? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let commandOnly = modifiers.contains(.command)
            && modifiers.isDisjoint(with: [.option, .control])
        let optionOnly = modifiers.contains(.option)
            && modifiers.isDisjoint(with: [.command, .control])
        if commandOnly {
            switch event.keyCode {
            case 51: return "\u{15}"
            case 123: return "\u{01}"
            case 124: return "\u{05}"
            case 117: return "\u{0b}"
            default: break
            }
        }
        if optionOnly {
            switch event.keyCode {
            case 51: return "\u{1b}\u{7f}"
            case 123: return "\u{1b}b"
            case 124: return "\u{1b}f"
            case 117: return "\u{1b}d"
            default: break
            }
        }
        return nil
    }

    private func isSelectionGesture(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
    }

    private func routedMouseEvent(_ event: NSEvent) -> NSEvent {
        guard isMouseCaptured else { return event }
        return gestureIsLocal ? event.addingShiftModifier() : event.removingShiftModifier()
    }

    override func mouseDown(with event: NSEvent) {
        gestureIsLocal = isSelectionGesture(event) || !isMouseCaptured
        super.mouseDown(with: routedMouseEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: routedMouseEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        defer { gestureIsLocal = false }
        super.mouseUp(with: routedMouseEvent(event))
    }

    /// A program that reads the mouse (vim, tmux, htop) gets the right button, as in Ghostty.
    override func rightMouseDown(with event: NSEvent) {
        if isMouseCaptured {
            rightClickToProgram = true
            super.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
    }

    override func rightMouseUp(with event: NSEvent) {
        if rightClickToProgram {
            rightClickToProgram = false
            super.rightMouseUp(with: event)
            return
        }
        FamilyMenuPresenter.shared.show(contextMenu(), with: event, for: self)
    }

    /// ⌃-click asks here before any mouse event; a program that reads the mouse keeps that click.
    override func menu(for event: NSEvent) -> NSMenu? {
        if isMouseCaptured { return nil }
        FamilyMenuPresenter.shared.show(contextMenu(), with: event, for: self)
        return nil
    }

    override func showSelectionContextMenu(with event: NSEvent) {
        FamilyMenuPresenter.shared.show(contextMenu(), with: event, for: self)
    }

    /// The engine shows this for a right-click over a selection while a program reads the mouse.
    override func selectionContextMenu() -> NSMenu {
        contextMenu()
    }

    /// Each item shows its current shortcut from `AppShortcuts`; ⌘C / ⌘V are fixed in this view.
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        menu.delegate = self
        var selection: String?
        if attachedSurface?.hasSelection() == true,
           let text = attachedSurface?.readSelection(),
           !text.isEmpty {
            selection = text
        }
        let copy = makeItem(String(localized: "Copy"), #selector(copySelectionFromMenu(_:)))
        SSHTerminalNSView.showChord(KeyChord(key: "c", modifiers: .command), on: copy)
        copy.isEnabled = selection != nil
        menu.addItem(copy)
        if let selection, let url = Self.firstURL(in: selection) {
            let open = makeItem(String(localized: "Open Link"), #selector(openLinkFromMenu(_:)))
            open.representedObject = url
            menu.addItem(open)
            let copyLink = makeItem(String(localized: "Copy Link Address"), #selector(copyLinkFromMenu(_:)))
            copyLink.representedObject = url
            menu.addItem(copyLink)
        }
        let paste = makeItem(String(localized: "Paste"), #selector(performPaste(_:)))
        SSHTerminalNSView.showChord(KeyChord(key: "v", modifiers: .command), on: paste)
        menu.addItem(paste)
        menu.addItem(makeItem(.selectAll, #selector(selectAll(_:))))
        menu.addItem(.separator())
        menu.addItem(makeItem(.find, #selector(findFromMenu(_:))))
        menu.addItem(makeItem(.clearScreen, #selector(clearScreenFromMenu(_:))))
        menu.addItem(.separator())
        let paneItems = paneMenuItems()
        if paneItems.isEmpty {
            let files = makeItem(String(localized: "Open Files"), #selector(revealFilesFromMenu(_:)))
            files.isEnabled = onRevealFiles != nil
            menu.addItem(files)
        } else {
            for command in paneItems { menu.addItem(makePaneItem(command)) }
        }
        return menu
    }

    /// Keep native menu items targeted at this terminal so AppKit's plugin filter
    /// and the selection-context-menu path retain the same command model.
    private func makePaneItem(_ command: FamilyMenuItem) -> NSMenuItem {
        if command.isSeparator { return .separator() }
        let item = makeItem(command.title, #selector(performPaneAction(_:)))
        item.isEnabled = command.enabled
        item.state = command.checked ? .on : .off
        item.keyEquivalent = command.key
        item.keyEquivalentModifierMask = command.modifiers
        item.representedObject = command
        if !command.children.isEmpty {
            let submenu = NSMenu(title: command.title)
            submenu.autoenablesItems = false
            submenu.allowsContextMenuPlugIns = false
            submenu.delegate = self
            for child in command.children { submenu.addItem(makePaneItem(child)) }
            item.submenu = submenu
        }
        return item
    }

    @objc private func performPaneAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? FamilyMenuItem, command.enabled else { return }
        command.action()
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func makeItem(_ shortcut: AppShortcutID, _ action: Selector) -> NSMenuItem {
        let item = makeItem(shortcut.title, action)
        SSHTerminalNSView.showChord(AppShortcuts.chord(for: shortcut), on: item)
        return item
    }

    private static func showChord(_ chord: KeyChord, on item: NSMenuItem) {
        if chord.isUnbound {
            return
        }
        item.keyEquivalent = chord.key
        item.keyEquivalentModifierMask = chord.menuModifierMask
    }

    @objc private func findFromMenu(_: Any?) {
        window?.makeFirstResponder(self)
        TerminalFind.shared.showFindBar()
    }

    @objc private func clearScreenFromMenu(_: Any?) {
        performBindingAction("clear_screen")
    }

    @objc private func revealFilesFromMenu(_: Any?) { onRevealFiles?() }

    @objc private func splitRightFromMenu(_: Any?) {
        onSplit?(.right)
    }

    @objc private func splitDownFromMenu(_: Any?) {
        onSplit?(.bottom)
    }

    @objc private func openLinkFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyLinkFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func copySelectionFromMenu(_: Any?) {
        copyLocalSelection()
    }

    @discardableResult
    private func copyLocalSelection() -> Bool {
        guard let selection = attachedSurface?.readSelection(), !selection.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(selection, forType: .string)
    }

    static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector?.firstMatch(in: text, range: range),
              let url = match.url,
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            if attachedSurface?.hasSelection() == true {
                locallyConsumedKeyCode = event.keyCode
                copyLocalSelection()
            } else {
                keyDown(with: event)
            }
            return true
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
            pastePlainText()
            return true
        }
        if !modifiers.isDisjoint(with: [.command, .control, .option, .shift]),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            locallyConsumedKeyCode = event.keyCode
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc private func performPaste(_: Any?) {
        pastePlainText()
    }

    @objc private func closeTerminalFromMenu(_: Any?) {
        onClose?()
    }

    /// Goes through Ghostty's paste binding so `clipboard-paste-protection` applies: an unsafe paste
    /// comes back as a confirmation request (`Coordinator.terminalDidRequestClipboardConfirmation`).
    private func pastePlainText() {
        performBindingAction("paste_from_clipboard")
    }

    /// Asks before an unsafe paste. The contents only reach the shell after the user allows it.
    func confirmPaste(_ request: TerminalClipboardConfirmationRequest) {
        guard let window else {
            request.respond(allow: false)
            return
        }
        let alert = FamilyAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Paste text that may run commands?")
        alert.informativeText = String(
            format: String(localized: "The text contains line breaks, so pasting it can run commands right away:\n\n%@"),
            SSHTerminalNSView.pastePreview(request.contents)
        )
        alert.addButton(withTitle: String(localized: "Paste"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            request.respond(allow: response == .alertFirstButtonReturn)
        }
    }

    /// The first few lines, each cut short, so a long paste still fits in the alert.
    static func pastePreview(_ text: String) -> String {
        let maxLines = 6
        let maxLineLength = 80
        let lines = text.components(separatedBy: .newlines)
        var preview: [String] = []
        for line in lines.prefix(maxLines) {
            if line.count > maxLineLength {
                preview.append(String(line.prefix(maxLineLength)) + "…")
            } else {
                preview.append(line)
            }
        }
        if lines.count > maxLines {
            preview.append(String(format: String(localized: "…and %lld more lines"), lines.count - maxLines))
        }
        return preview.joined(separator: "\n")
    }
}

extension SSHTerminalNSView: FamilyModalFocusRestoring {
    var canRestoreModalFocus: Bool {
        !isHiddenOrHasHiddenAncestor && (superview as? TerminalHostView)?.canFocus() != false
    }
}

private extension NSEvent {
    func addingShiftModifier() -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: locationInWindow,
            modifierFlags: modifierFlags.union(.shift),
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: pressure
        ) ?? self
    }

    func removingShiftModifier() -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: locationInWindow,
            modifierFlags: modifierFlags.subtracting(.shift),
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: pressure
        ) ?? self
    }
}

/// Decoration drawn inside a terminal view. Clicks and hovers go through to the terminal.
final class TerminalOverlayView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The URL under the pointer, bottom left of the terminal, cut in the middle when long.
final class TerminalLinkBanner: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.row
        layer?.borderWidth = 1
        label.font = .systemFont(ofSize: Theme.PaneStyle.linkBannerFontSize)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        autoresizingMask = [.maxXMargin, .maxYMargin]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ url: String, background: NSColor, text: NSColor, border: NSColor, in container: NSRect) {
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = border.cgColor
        label.textColor = text
        label.stringValue = url
        let paddingX = Theme.Space.s
        let paddingY = Theme.Space.xs / 2
        let margin = Theme.Space.xs
        let natural = label.intrinsicContentSize
        let maxWidth = max(container.width * Theme.PaneStyle.linkBannerMaxWidthRatio, paddingX * 2)
        let width = min(natural.width + paddingX * 2, maxWidth)
        let height = natural.height + paddingY * 2
        frame = NSRect(x: margin, y: margin, width: width, height: height)
        label.frame = NSRect(x: paddingX, y: paddingY, width: width - paddingX * 2, height: natural.height)
    }
}

/// Plain container that hosts the registry's terminal view for one session. SwiftUI may create and
/// destroy containers freely; the terminal inside is only detached, never terminated here.
final class TerminalHostView: NSView {
    var sessionID: String?
    /// Read the live selection when the deferred request runs, before SwiftUI has
    /// necessarily updated every other pane's representable.
    var canFocus: () -> Bool = { true }
    private var isFocusTarget = false
    private var focusPending = false
    private var focusScheduled = false

    func setFocusTarget(_ selected: Bool) {
        if selected && !isFocusTarget { focusPending = true }
        isFocusTarget = selected
        if !selected { focusPending = false }
        scheduleFocus()
    }

    func requestFocus() {
        guard isFocusTarget else { return }
        focusPending = true
        // Registry calls this outside SwiftUI updates. Preserve its queue ordering
        // for commands such as Find that act on the newly focused terminal next.
        fulfillFocus()
        scheduleFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self)
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification,
                         FamilyModalPresentation.didCloseNotification] {
                center.addObserver(self, selector: #selector(focusOpportunity), name: name, object: window)
            }
            if isFocusTarget { focusPending = true }
        }
        scheduleFocus()
    }

    override func layout() {
        super.layout()
        scheduleFocus()
    }

    @objc private func focusOpportunity(_ notification: Notification) { scheduleFocus() }

    private func scheduleFocus() {
        guard focusPending, !focusScheduled else { return }
        focusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusScheduled = false
            self.fulfillFocus()
        }
    }

    private func fulfillFocus() {
        guard focusPending, isFocusTarget else { return }
        guard canFocus() else { focusPending = false; return }
        guard !isHiddenOrHasHiddenAncestor, bounds.width > 0, bounds.height > 0,
              let window, window.isKeyWindow, window.attachedSheet == nil,
              window.childWindows?.contains(where: { $0 is FamilyModalWindow && $0.isVisible }) != true,
              let terminal = subviews.first(where: { $0 is SSHTerminalNSView }) as? SSHTerminalNSView else { return }
        // Consume before onFocus publishes model changes. Later layout/theme/output
        // updates must leave deliberate focus in Find, Rename, or a file input alone.
        focusPending = false
        if window.firstResponder !== terminal, !window.makeFirstResponder(terminal) {
            focusPending = true
        }
    }

    /// SwiftUI opacity/accessibility modifiers do not consistently hide an embedded
    /// AppKit terminal view. Hide the native subtree without detaching it or
    /// changing its last layout size, so the same terminal and process stay alive.
    func setPresented(_ presented: Bool) {
        isHidden = !presented
        setAccessibilityHidden(!presented)
        if !presented { focusPending = false }
        scheduleFocus()
    }

    func attach(_ terminal: SSHTerminalNSView) {
        if terminal.superview === self { return }
        terminal.removeFromSuperview()
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        scheduleFocus()
    }

    func detach(_ terminal: SSHTerminalNSView) {
        if terminal.superview === self {
            terminal.removeFromSuperview()
        }
    }
}

struct SSHTerminalView: NSViewRepresentable {
    var sessionID: String
    var alias: String
    /// Set for a local shell. Empty alias plus this path starts the login shell here.
    var directory: String? = nil
    /// Passed as SSH's authenticated remote command, never as password-prompt stdin.
    var remoteDirectory: String? = nil
    var environment: [String]
    var dark: Bool
    var initialFontSize: Float? = nil
    var restoration: TerminalRestoration? = nil
    var agentConversation: AgentConversation? = nil
    var isPresented: Bool = true
    /// Selection is an ongoing focus intent, including views mounted after the open action.
    var isSelected: Bool = true
    var focusRailColor: NSColor? = nil
    var canFocus: () -> Bool = { true }
    /// Asked once when the process first starts. Its text goes to the pty, where it waits
    /// until the shell reads it, as if typed ahead.
    var takeInitialInput: () -> String? = { nil }
    /// Consumed only for a new SSH terminal. Never enters its stdin or its reconnect launch.
    var takeRemoteStartupCommand: () -> String? = { nil }
    var takeLocalStartupCommand: () -> String? = { nil }
    /// Exit code and seconds the process lived. Fires again after every in-place reconnect.
    var onExit: (Int32?, TimeInterval) -> Void
    var onClose: () -> Void = {}
    var onFocus: () -> Void = {}
    var onSplit: (SplitEdge) -> Void = { _ in }
    var onRevealFiles: () -> Void = {}
    var paneMenuItems: () -> [FamilyMenuItem] = { [] }
    var onFileDrop: (([URL], DropZone) -> Void)? = nil
    var canDropQuickCommand: (UUID) -> Bool = { _ in false }
    var onQuickCommandDrop: (UUID) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The ssh command for a host, or the login shell for a local directory.
    static func launch(alias: String, directory: String?, environment: [String], remoteDirectory: String? = nil) -> TerminalLaunch {
        if alias.isEmpty, let directory, !directory.isEmpty {
            let shell = LocalTerminal.shellExecutable
            let settings = TerminalSettings.load()
            let integration = ShellIntegrationEnvironment.variables(settings: settings, shellPath: shell,
                                                                      resourcesPath: Bundle.main.resourcePath, environment: environment)
            return TerminalLaunch(
                executable: shell,
                args: ShellIntegrationEnvironment.launchArguments(settings: settings, shellPath: shell, variables: integration),
                environment: environment,
                directory: LocalTerminal.launchDirectory(directory),
                shellIntegrationEnvironment: integration
            )
        }
        return TerminalLaunch(
            executable: "/usr/bin/ssh",
            args: SSHCommand.arguments(alias: alias, remoteDirectory: remoteDirectory),
            environment: environment,
            directory: nil,
            integratesRemoteShell: true,
            remoteDirectory: remoteDirectory
        )
    }

    func makeNSView(context: Context) -> TerminalHostView {
        let container = TerminalHostView(frame: .zero)
        container.sessionID = sessionID
        container.canFocus = canFocus
        container.setPresented(isPresented)
        container.setFocusTarget(isSelected && isPresented)
        guard let terminal = SSHTerminalRegistry.view(for: sessionID, make: { makeTerminal() }) else {
            return container
        }
        context.coordinator.terminal = terminal
        wire(terminal, coordinator: context.coordinator)
        container.attach(terminal)
        applyAppearance(terminal, dark: dark)
        terminal.setFocusRail(color: focusRailColor)
        return container
    }

    func updateNSView(_ container: TerminalHostView, context: Context) {
        container.canFocus = canFocus
        container.setPresented(isPresented)
        container.setFocusTarget(isSelected && isPresented)
        guard let terminal = SSHTerminalRegistry.view(for: sessionID, make: { makeTerminal() }) else {
            return
        }
        context.coordinator.terminal = terminal
        if !alias.isEmpty {
            terminal.processHost?.updateLaunch(Self.launch(
                alias: alias, directory: directory, environment: environment, remoteDirectory: remoteDirectory
            ))
        }
        wire(terminal, coordinator: context.coordinator)
        container.attach(terminal)
        applyAppearance(terminal, dark: dark)
        terminal.setFocusRail(color: focusRailColor)
    }

    static func dismantleNSView(_ container: TerminalHostView, coordinator: Coordinator) {
        guard let terminal = coordinator.terminal else { return }
        container.detach(terminal)
    }

    /// A brand-new terminal with its own process. Only called once per session.
    private func makeTerminal() -> SSHTerminalNSView {
        let host = TerminalProcessHost()
        let view = SSHTerminalNSView(frame: .zero)
        view.sessionID = sessionID
        view.processHost = host
        view.eventRelay.terminal = view
        host.onRemoteDirectory = { [weak view] path in view?.eventRelay.terminalDidChangeWorkingDirectory(path) }
        view.delegate = view.eventRelay
        view.registerForDraggedTypes(SSHTerminalNSView.dropTypes)
        view.controller = GhosttyRuntime.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(host.session), fontSize: initialFontSize)
        let launch = Self.launch(alias: alias, directory: directory, environment: environment, remoteDirectory: remoteDirectory)
        var initialLaunch: TerminalLaunch?
        if !alias.isEmpty, let command = takeRemoteStartupCommand() {
            var first = launch
            first.args = SSHCommand.arguments(alias: alias, remoteDirectory: remoteDirectory, startupCommand: command)
            initialLaunch = first
        }
        if alias.isEmpty, let command = takeLocalStartupCommand() {
            var first = launch
            first.executable = "/bin/sh"
            first.args = ["-c", command]
            initialLaunch = first
        }
        host.start(launch, initialLaunch: initialLaunch, restoration: restoration, agentConversation: agentConversation)
        if let input = takeInitialInput() {
            host.sendInitialInput(input)
        }
        return view
    }

    /// Callbacks point at the coordinator of whichever container currently shows the terminal.
    /// Exit is the exception: it must reach the model even when no window shows the terminal,
    /// or a dropped connection in a hidden tab would never reconnect.
    private func wire(_ terminal: SSHTerminalNSView, coordinator: Coordinator) {
        coordinator.onClose = onClose
        coordinator.onFocus = onFocus
        coordinator.onSplit = onSplit
        coordinator.onRevealFiles = onRevealFiles
        coordinator.paneMenuItems = paneMenuItems
        terminal.onFocus = { [weak coordinator] in coordinator?.onFocus?() }
        terminal.onClose = { [weak coordinator] in coordinator?.onClose?() }
        terminal.onSplit = { [weak coordinator] edge in coordinator?.onSplit?(edge) }
        terminal.onRevealFiles = { [weak coordinator] in coordinator?.onRevealFiles?() }
        terminal.paneMenuItems = { [weak coordinator] in coordinator?.paneMenuItems?() ?? [] }
        coordinator.onFileDrop = onFileDrop
        terminal.onFileDrop = { [weak coordinator] urls, zone in coordinator?.onFileDrop?(urls, zone) }
        coordinator.canDropQuickCommand = canDropQuickCommand
        coordinator.onQuickCommandDrop = onQuickCommandDrop
        terminal.canDropQuickCommand = { [weak coordinator] in coordinator?.canDropQuickCommand?($0) ?? false }
        terminal.onQuickCommandDrop = { [weak coordinator] in coordinator?.onQuickCommandDrop?($0) ?? false }
        terminal.dropIsRemote = !alias.isEmpty
        let onExit = self.onExit
        terminal.processHost?.onExit = { code, lived in
            onExit(code, lived)
        }
    }

    private func applyAppearance(_ view: SSHTerminalNSView, dark: Bool) {
        view.applyTerminalAppearance(dark: dark)
    }

    final class Coordinator: NSObject {
        var onClose: (() -> Void)?
        var onFocus: (() -> Void)?
        var onSplit: ((SplitEdge) -> Void)?
        var onRevealFiles: (() -> Void)?
        var paneMenuItems: (() -> [FamilyMenuItem])?
        var onFileDrop: (([URL], DropZone) -> Void)?
        var canDropQuickCommand: ((UUID) -> Bool)?
        var onQuickCommandDrop: ((UUID) -> Bool)?
        weak var terminal: SSHTerminalNSView?
    }
}

extension SSHTerminalNSView: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        quickLookURLs[index] as NSURL
    }
}

/// AppKit appends AutoFill to any text-input view's context menu; a terminal has no use for it.
extension SSHTerminalNSView: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem && item.target !== self {
            menu.removeItem(item)
        }
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
    }
}
