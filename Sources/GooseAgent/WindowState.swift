import AppKit
import SwiftUI

/// Everything that belongs to the main window: which sidebar blocks it shows, what is selected,
/// and the drag in progress. Terminals and workspaces themselves live in `AppModel`.
@MainActor
final class WindowState: ObservableObject, Identifiable {
    let id: UUID
    /// Sidebar block order for this window. Local Group and Ungrouped are always present.
    @Published var blocks: [SidebarBlock] = [.localGroup, .ungrouped]
    /// Standalone terminals of this window's two loose groups, in sidebar order.
    @Published var looseMembers: [SidebarBlock: [UUID]] = [.localGroup: [], .ungrouped: []]
    @Published var selectedTabID: UUID?
    /// What fills the area right of the sidebar.
    @Published var section: AppSection = .terminals
    /// Sidebar multi-select. Not written into the session snapshot.
    @Published var sidebarSelection: Set<UUID> = []
    var sidebarAnchor: UUID?
    @Published var draggingTabID: UUID?
    /// Every terminal in the current drag. The first one is `draggingTabID`.
    @Published var draggingTabIDs: [UUID] = []
    @Published var draggingBlock: SidebarBlock?
    @Published var dropHighlight: TabDropHighlight?
    @Published var hostPickerPresented = false
    /// What a host chosen in the picker opens. Back to `.terminal` whenever the picker closes.
    @Published var hostPickerPurpose: HostPickerPurpose = .terminal
    /// Where a sidebar row dragged over the Files area or the Files button would land.
    @Published var filesDropTarget: FilesDropTarget?
    /// Workspace ID → the pane drawn alone (⇧⌘↩). Memory only; not in the session snapshot.
    @Published var zoomedPanes: [UUID: UUID] = [:]
    /// Last known frame on screen, restored at launch.
    var frame: CGRect?
    /// The drop relay of this window's view.
    weak var relay: CanvasDropRelay?
    var dropEpoch = 0

    init(id: UUID = UUID(), frame: CGRect? = nil) {
        self.id = id
        self.frame = frame
    }
}

enum HostPickerPurpose {
    /// New terminals.
    case terminal
    /// New remote tabs in the Files area.
    case files
}

enum FilesDropTarget: Hashable {
    /// A pane of the Files area.
    case group(UUID)
    case button
}

/// Terminals, or the file manager, right of the sidebar.
enum AppSection: String, Codable {
    case terminals
    case files

    /// A saved session may name an area that no longer exists; it opens on Terminals.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AppSection(rawValue: raw) ?? .terminals
    }
}

/// Creates and tracks the AppKit window behind the main `WindowState`.
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
            window.center()
        }
        windows[state.id] = window
        applyBackgroundOpacity(TerminalSettings.load().backgroundOpacity, to: state)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// A translucent terminal needs a non-opaque window. At 100% the window goes back to exactly
    /// what AppKit creates, so the default look and compositing cost stay unchanged.
    func applyBackgroundOpacity(_ opacity: Double, to state: WindowState) {
        guard let window = windows[state.id] else { return }
        if opacity < 1 {
            window.isOpaque = false
            window.backgroundColor = .clear
        } else {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
        }
    }

    /// Hides the window. The app and its terminals keep running; the Dock icon or the next open shows it again.
    func close(_ state: WindowState) {
        guard let window = windows[state.id] else { return }
        hide(window)
    }

    private func hide(_ window: NSWindow) {
        if let state = state(for: window) {
            state.frame = window.frame
        }
        window.orderOut(nil)
        model?.persistSessionIfReady()
    }

    /// Screen point → the Ghostty window under it. `except` skips that window. Nil when the pointer is outside.
    func windowState(atScreenPoint point: NSPoint, except: UUID?) -> (WindowState, NSWindow)? {
        for window in NSApp.orderedWindows where window.identifier == Self.windowID && window.isVisible {
            guard window.frame.contains(point) else { continue }
            guard let state = state(for: window), state.id != except else { continue }
            return (state, window)
        }
        return nil
    }

    // MARK: NSWindowDelegate

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

    /// The close button and File → Close only hide the single main window, so sessions survive it.
    /// Quitting closes windows without asking here.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model?.isQuitting == true {
            return true
        }
        hide(sender)
        return false
    }

    /// Only reached while quitting; the frame and snapshot saved here come back at next launch.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard let entry = windows.first(where: { $0.value === window }) else { return }
        windows[entry.key] = nil
        guard let model, let state = model.window(for: entry.key) else { return }
        state.frame = window.frame
        model.windowClosed(state)
    }
}
