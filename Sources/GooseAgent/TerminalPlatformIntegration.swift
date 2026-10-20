import AppKit
import Carbon
import Combine

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
