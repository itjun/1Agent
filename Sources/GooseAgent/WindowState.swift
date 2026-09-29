import AppKit
import SwiftUI

/// Everything that belongs to one main window: which sidebar blocks it shows, what is selected,
/// and the drag in progress. Terminals and workspaces themselves live in `AppModel` and can move
/// between windows.
@MainActor
final class WindowState: ObservableObject, Identifiable {
    let id: UUID
    /// User-given title. Nil shows "Window N".
    @Published var name: String?
    /// Sidebar block order for this window. Local Group and Ungrouped are always present.
    @Published var blocks: [SidebarBlock] = [.localGroup, .ungrouped]
    /// Standalone terminals of this window's two loose groups, in sidebar order.
    @Published var looseMembers: [SidebarBlock: [UUID]] = [.localGroup: [], .ungrouped: []]
    @Published var selectedTabID: UUID?
    /// Sidebar multi-select. Not written into the session snapshot.
    @Published var sidebarSelection: Set<UUID> = []
    var sidebarAnchor: UUID?
    @Published var draggingTabID: UUID?
    /// Every terminal in the current drag. The first one is `draggingTabID`.
    @Published var draggingTabIDs: [UUID] = []
    @Published var draggingBlock: SidebarBlock?
    @Published var dropHighlight: TabDropHighlight?
    @Published var hostPickerPresented = false
    /// True while this is the key window. Drives the accent on selection and pane headers.
    @Published var isKey = false
    /// Last known frame on screen, restored at launch.
    var frame: CGRect?
    /// The drop relay of this window's view, for cross-window drags.
    weak var relay: CanvasDropRelay?
    var dropEpoch = 0

    init(id: UUID = UUID(), name: String? = nil, frame: CGRect? = nil) {
        self.id = id
        self.name = name
        self.frame = frame
    }
}

/// Creates and tracks the AppKit windows behind each `WindowState`.
@MainActor
final class MainWindowManager: NSObject, NSWindowDelegate {
    static let shared = MainWindowManager()
    static let windowID = NSUserInterfaceItemIdentifier("main")

    private var windows: [UUID: NSWindow] = [:]
    private weak var model: AppModel?

    func attach(model: AppModel) {
        self.model = model
    }

    func window(for state: WindowState) -> NSWindow? {
        windows[state.id]
    }

    func state(for window: NSWindow) -> WindowState? {
        guard let entry = windows.first(where: { $0.value === window }) else { return nil }
        return model?.window(for: entry.key)
    }

    /// Shows the window for `state`, creating it on first use.
    func show(_ state: WindowState, model: AppModel) {
        self.model = model
        if let window = windows[state.id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: RootView(model: model, window: state))
        let window = NSWindow(contentViewController: controller)
        window.identifier = Self.windowID
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = TerminalAppearance.appKitAppearance(isDark: TerminalAppearance.stored().resolvesDark())
        window.minSize = NSSize(width: 880, height: 520)
        if let frame = state.frame, frame.width >= 880, frame.height >= 520 {
            window.setFrame(frame, display: false)
        } else {
            window.setContentSize(NSSize(width: 1100, height: 720))
            if let previous = windows.values.max(by: { $0.orderedIndex > $1.orderedIndex }) {
                let origin = previous.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY))
                window.cascadeTopLeft(from: origin)
            } else {
                window.center()
            }
        }
        windows[state.id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close(_ state: WindowState) {
        windows[state.id]?.close()
    }

    /// Screen point → the 1Agent window under it, front-most first. `except` skips the drag's own window.
    func windowState(atScreenPoint point: NSPoint, except: UUID?) -> (WindowState, NSWindow)? {
        for window in NSApp.orderedWindows where window.identifier == Self.windowID && window.isVisible {
            guard window.frame.contains(point) else { continue }
            guard let state = state(for: window), state.id != except else { continue }
            return (state, window)
        }
        return nil
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let state = state(for: window) else { return }
        model?.noteKeyWindow(state)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let state = state(for: window) else { return }
        if state.isKey {
            state.isKey = false
        }
    }

    func windowDidMove(_ notification: Notification) {
        rememberFrame(notification)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        rememberFrame(notification)
    }

    private func rememberFrame(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let state = state(for: window) else { return }
        state.frame = window.frame
        model?.persistSessionIfReady()
    }

    /// Closing one of several windows ends its terminals. Ask first when there is something to lose.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model, let state = state(for: sender) else { return true }
        guard model.windows.count > 1, !model.isQuitting else { return true }
        let count = model.sidebarOrder(in: state).count
        guard count > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "Close this window and its %lld terminals?"), count)
        alert.informativeText = String(localized: "Drag terminals to another window first if you want to keep them.")
        alert.addButton(withTitle: String(localized: "Close Window"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard let entry = windows.first(where: { $0.value === window }) else { return }
        windows[entry.key] = nil
        guard let model, let state = model.window(for: entry.key) else { return }
        state.frame = window.frame
        model.windowClosed(state, remaining: windows.count)
    }
}
