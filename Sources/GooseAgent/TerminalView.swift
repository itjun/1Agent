import AppKit
import CoreText
import GhosttyTerminal
import GhosttyTheme
import SwiftUI

enum TerminalDefaults {
    static let defaultFontSize: Double = 14
    static let defaultFontFamily = "SF Mono"
    static let defaultFontWeight: Double = 0
    static let defaultLineSpacing: Double = 1
    static let minFontSize: Double = 10
    static let maxFontSize: Double = 28
    static let symbolFallbackFamily = "Symbols Nerd Font Mono"

    static func registerBundledFonts() {
        guard let url = Bundle.main.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

/// Persisted terminal typeface / size. Ghostty reads these on every surface refresh.
enum TerminalFontSettings {
    static let familyKey = "appearance.terminalFontFamily"
    static let sizeKey = "appearance.terminalFontSize"

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
        let raw = UserDefaults.standard.string(forKey: familyKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? TerminalDefaults.defaultFontFamily : raw
    }

    static var size: Double {
        let stored = UserDefaults.standard.object(forKey: sizeKey) as? Double
        let value = stored ?? TerminalDefaults.defaultFontSize
        return min(max(value, TerminalDefaults.minFontSize), TerminalDefaults.maxFontSize)
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

    /// Called once at launch and again whenever the font settings change. Not per view update.
    static func applyFontSettings() {
        controller.setTerminalConfiguration(fontConfiguration())
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

    private static func fontConfiguration() -> TerminalConfiguration {
        let family = TerminalFontSettings.family
        let size = TerminalFontSettings.size
        return TerminalConfiguration { builder in
            builder.withFontSize(Float(size))
            builder.withWindowPaddingX(0)
            builder.withWindowPaddingY(0)
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(true)
            builder.withFontThicken(false)
            builder.withFontFamily(family)
            builder.withCustom("macos-option-as-alt", "true")
            builder.withCustom("keybind", "super+c=unbind")
            builder.withCustom("clipboard-write", "allow")
            builder.withCustom("mouse-shift-capture", "never")
            builder.withCustom("font-codepoint-map", "U+E000-U+F8FF=\(TerminalDefaults.symbolFallbackFamily)")
            builder.withCustom("font-codepoint-map", "U+F0000-U+FFFFD=\(TerminalDefaults.symbolFallbackFamily)")
            builder.withCustom("font-codepoint-map", "U+100000-U+10FFFD=\(TerminalDefaults.symbolFallbackFamily)")
        }
    }

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
}

/// Owns one Ghostty session and the child process behind it. The process can be replaced
/// (reconnect) while the session, and with it the scrollback on screen, stays the same.
final class TerminalProcessHost {
    /// Holds the current process so the session's `@Sendable` closures can follow a replacement.
    private final class ProcessBox: @unchecked Sendable {
        var process = TerminalProcess()
    }

    let session: InMemoryTerminalSession
    private let box = ProcessBox()
    private var launch: TerminalLaunch?
    private var startedAt: TimeInterval = 0

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

    func start(_ launch: TerminalLaunch) {
        self.launch = launch
        startProcess(launch)
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

    func terminate() {
        process.terminate()
    }

    private func startProcess(_ launch: TerminalLaunch) {
        let process = TerminalProcess()
        // PTY bytes go straight to Ghostty. No rewriting in between.
        process.onOutput = { [session] data in session.receive(data) }
        process.onExit = { [weak self, weak process] code in
            guard let self, let process, process === self.box.process else { return }
            let lived = ProcessInfo.processInfo.systemUptime - self.startedAt
            self.onExit?(code, lived)
        }
        box.process = process
        startedAt = ProcessInfo.processInfo.systemUptime
        process.start(
            executable: launch.executable,
            args: launch.args,
            environment: sshChildEnvironment(launch.environment),
            directory: launch.directory
        )
    }
}

/// Owns every live terminal view. A view is created the first time a window shows its session and
/// stays alive until the tab closes, so it can move between panes and windows without the ssh
/// process dying with a SwiftUI teardown.
@MainActor
enum SSHTerminalRegistry {
    private static var views: [String: SSHTerminalNSView] = [:]

    /// The terminal for this session, made on first use.
    static func view(for id: String, make: () -> SSHTerminalNSView) -> SSHTerminalNSView {
        if let existing = views[id] {
            return existing
        }
        let created = make()
        views[id] = created
        return created
    }

    /// The tab closed. Ends the process and drops the view.
    static func destroy(_ id: String) {
        guard let view = views.removeValue(forKey: id) else { return }
        view.processHost?.terminate()
        view.removeFromSuperview()
    }

    static func focus(_ id: String) {
        DispatchQueue.main.async {
            guard let view = views[id], let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }

    /// The shell's own cwd. Nil until the process is running, or after it exits.
    static func currentWorkingDirectory(for id: String) -> String? {
        views[id]?.processHost?.process.currentWorkingDirectory
    }

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
    var appliedDarkAppearance: Int?
    weak var attachedSurface: TerminalSurface?
    /// Strong: the view is the only owner. The session keeps the process alive on its own, so a weak
    /// reference here drops the host silently and exits, restarts, and cwd lookups stop working.
    var processHost: TerminalProcessHost?
    private var gestureIsLocal = false
    private var locallyConsumedKeyCode: UInt16?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        locallyConsumedKeyCode = nil
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

    /// First line under the pane title. A shell drag here moves the window; a captured mouse still reaches the remote app.
    private static let windowDragBand: CGFloat = 32

    override func mouseDown(with event: NSEvent) {
        if dragWindow(fromTopOf: event) {
            return
        }
        gestureIsLocal = isSelectionGesture(event) || !isMouseCaptured
        super.mouseDown(with: routedMouseEvent(event))
    }

    private func dragWindow(fromTopOf event: NSEvent) -> Bool {
        guard !isMouseCaptured, let window else { return false }
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return false }
        let fromTop = isFlipped ? local.y : bounds.height - local.y
        guard fromTop >= 0, fromTop <= Self.windowDragBand else { return false }
        let origin = window.frame.origin
        window.performDrag(with: event)
        let moved = window.frame.origin
        if hypot(moved.x - origin.x, moved.y - origin.y) < 1 {
            window.makeFirstResponder(self)
        }
        return true
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: routedMouseEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        defer { gestureIsLocal = false }
        super.mouseUp(with: routedMouseEvent(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func rightMouseUp(with event: NSEvent) {
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }

    override func menu(for _: NSEvent) -> NSMenu? {
        contextMenu()
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        if attachedSurface?.hasSelection() == true,
           let selection = attachedSurface?.readSelection(),
           !selection.isEmpty {
            menu.addItem(makeItem(String(localized: "Copy"), #selector(copySelectionFromMenu(_:))))
            if let url = Self.firstURL(in: selection) {
                menu.addItem(.separator())
                let open = makeItem(String(localized: "Open Link"), #selector(openLinkFromMenu(_:)))
                open.representedObject = url
                menu.addItem(open)
                let copyLink = makeItem(String(localized: "Copy Link Address"), #selector(copyLinkFromMenu(_:)))
                copyLink.representedObject = url
                menu.addItem(copyLink)
            }
            menu.addItem(.separator())
        }
        menu.addItem(makeItem(String(localized: "Paste"), #selector(performPaste(_:))))
        menu.addItem(makeItem(String(localized: "Select All"), #selector(selectAll(_:))))
        menu.addItem(.separator())
        menu.addItem(TerminalCloseMenu.item(action: #selector(closeTerminalFromMenu(_:)), target: self))
        return menu
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
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

    private func pastePlainText() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        paste(text: text)
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

/// Plain container that hosts the registry's terminal view for one session. SwiftUI may create and
/// destroy containers freely; the terminal inside is only detached, never terminated here.
final class TerminalHostView: NSView {
    var sessionID: String?

    func attach(_ terminal: SSHTerminalNSView) {
        if terminal.superview === self { return }
        terminal.removeFromSuperview()
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
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
    var environment: [String]
    var dark: Bool
    /// Only the window's selected pane grabs the keyboard when its view is first made. Restoring
    /// several terminals at once must not hand focus to whichever finished last.
    var focusesOnCreate: Bool = true
    /// Exit code and seconds the process lived. Fires again after every in-place reconnect.
    var onExit: (Int32?, TimeInterval) -> Void
    var onClose: () -> Void = {}
    var onFocus: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The ssh command for a host, or the login shell for a local directory.
    static func launch(alias: String, directory: String?, environment: [String]) -> TerminalLaunch {
        if alias.isEmpty, let directory, !directory.isEmpty {
            return TerminalLaunch(
                executable: LocalTerminal.shellExecutable,
                args: ["-l"],
                environment: environment,
                directory: LocalTerminal.launchDirectory(directory)
            )
        }
        return TerminalLaunch(
            executable: "/usr/bin/ssh",
            args: SSHCommand.arguments(alias: alias),
            environment: environment,
            directory: nil
        )
    }

    func makeNSView(context: Context) -> TerminalHostView {
        let container = TerminalHostView(frame: .zero)
        container.sessionID = sessionID
        let terminal = SSHTerminalRegistry.view(for: sessionID) { makeTerminal() }
        context.coordinator.terminal = terminal
        wire(terminal, coordinator: context.coordinator)
        container.attach(terminal)
        applyAppearance(terminal, dark: dark)
        if focusesOnCreate {
            DispatchQueue.main.async { [weak terminal] in
                guard let terminal, let window = terminal.window else { return }
                window.makeFirstResponder(terminal)
            }
        }
        return container
    }

    func updateNSView(_ container: TerminalHostView, context: Context) {
        let terminal = SSHTerminalRegistry.view(for: sessionID) { makeTerminal() }
        context.coordinator.terminal = terminal
        wire(terminal, coordinator: context.coordinator)
        container.attach(terminal)
        applyAppearance(terminal, dark: dark)
    }

    static func dismantleNSView(_ container: TerminalHostView, coordinator: Coordinator) {
        guard let terminal = coordinator.terminal else { return }
        container.detach(terminal)
    }

    /// A brand-new terminal with its own process. Only called once per session.
    private func makeTerminal() -> SSHTerminalNSView {
        let host = TerminalProcessHost()
        let view = SSHTerminalNSView(frame: .zero)
        view.processHost = host
        view.controller = GhosttyRuntime.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(host.session))
        host.start(Self.launch(alias: alias, directory: directory, environment: environment))
        return view
    }

    /// Callbacks point at the coordinator of whichever container currently shows the terminal.
    /// Exit is the exception: it must reach the model even when no window shows the terminal,
    /// or a dropped connection in a hidden tab would never reconnect.
    private func wire(_ terminal: SSHTerminalNSView, coordinator: Coordinator) {
        coordinator.onClose = onClose
        coordinator.onFocus = onFocus
        terminal.delegate = coordinator
        terminal.onFocus = { [weak coordinator] in coordinator?.onFocus?() }
        terminal.onClose = { [weak coordinator] in coordinator?.onClose?() }
        let onExit = self.onExit
        terminal.processHost?.onExit = { code, lived in
            onExit(code, lived)
        }
    }

    /// Only touches Ghostty when this view's appearance actually flips. SwiftUI calls
    /// `updateNSView` for every model change, and the controller's config is global.
    private func applyAppearance(_ view: SSHTerminalNSView, dark: Bool) {
        let signature = dark ? 1 : 0
        guard view.appliedDarkAppearance != signature else { return }
        view.appliedDarkAppearance = signature
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        GhosttyRuntime.controller.setColorScheme(dark ? .dark : .light)
    }

    final class Coordinator: NSObject, TerminalSurfaceLifecycleDelegate {
        var onClose: (() -> Void)?
        var onFocus: (() -> Void)?
        weak var terminal: SSHTerminalNSView?

        func terminalDidAttachSurface(_ surface: TerminalSurface) {
            terminal?.attachedSurface = surface
        }

        func terminalDidDetachSurface() {
            terminal?.attachedSurface = nil
        }
    }
}
