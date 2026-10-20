import AppKit
import Carbon
import Combine

@MainActor
final class QuickTerminalController: ObservableObject {
    static let shared = QuickTerminalController()
    private weak var model: AppModel?
    private var previousApplication: NSRunningApplication?

    func start(model: AppModel) {
        self.model = model
        for state in model.windows where state.isQuickTerminal {
            configure(state)
            MainWindowManager.shared.window(for: state)?.orderOut(nil)
        }
    }

    func toggle() {
        guard let model, !model.isQuitting, !(NSApp.keyWindow is FamilyModalWindow) else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let existingState = model.windows.first(where: \.isQuickTerminal)
        let state: WindowState
        if let existing = existingState {
            state = existing
            if model.sidebarOrder(in: state).isEmpty {
                model.openLocalTerminal(at: LocalTerminal.homeDirectory, in: state)
            }
        } else {
            state = model.createWindow()
            state.isQuickTerminal = true
            model.openLocalTerminal(at: LocalTerminal.homeDirectory, in: state)
        }
        if existingState != nil, let native = MainWindowManager.shared.window(for: state), native.isVisible, native.isKeyWindow {
            native.orderOut(nil)
            model.persistSessionIfReady()
            previousApplication?.activate()
            return
        }
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = frontmost
        }
        configure(state)
        MainWindowManager.shared.show(state, model: model)
        if let tab = model.selectedTab(in: state) { SSHTerminalRegistry.focus(tab.sessionID) }
    }

    /// A floating quick terminal must not cover the settings window it opens.
    func hideForSettings() {
        guard let model, let state = model.windows.first(where: \.isQuickTerminal) else { return }
        MainWindowManager.shared.window(for: state)?.orderOut(nil)
        model.persistSessionIfReady()
    }

    private func configure(_ state: WindowState) {
        guard let native = MainWindowManager.shared.window(for: state) else { return }
        native.tabbingMode = .disallowed
        native.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        native.level = .floating
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let screen {
            let frame = screen.visibleFrame
            let width = max(min(frame.width, 1100), min(880, frame.width))
            let height = max(min(frame.height * 0.6, 720), min(520, frame.height))
            native.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height), display: true)
        }
    }
}

/// Owns only this app's Secure Event Input reference; focus loss always releases it.
@MainActor
final class TerminalSecureInput: ObservableObject {
    static let shared = TerminalSecureInput()
    @Published private(set) var isEnabled = false
    @Published var manual = false { didSet { refresh() } }
    private var requested: Set<String> = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var shuttingDown = false

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { TerminalSecureInput.shared.refresh() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { TerminalSecureInput.shared.release() }
            })
        }
    }

    func request(_ enabled: Bool?, for session: String) {
        let enable = enabled ?? !requested.contains(session)
        if enable { requested.insert(session) } else { requested.remove(session) }
        refresh()
    }

    func forget(_ session: String) { requested.remove(session); refresh() }

    func refresh() {
        let terminal = FocusedTerminal.current
        let focused = !shuttingDown && NSApp.isActive && terminal?.window?.isKeyWindow == true
            && terminal?.isHiddenOrHasHiddenAncestor == false && terminal?.window?.attachedSheet == nil
        let needed = focused && (manual || terminal?.sessionID.map { requested.contains($0) } == true
                                || terminal?.processHost?.process.isPasswordInput == true)
        if needed && !isEnabled { if EnableSecureEventInput() == noErr { isEnabled = true } }
        else if !needed { release() }
    }

    func release() { if isEnabled { DisableSecureEventInput(); isEnabled = false } }
    func stop() { shuttingDown = true; timer?.invalidate(); timer = nil; release() }
}
