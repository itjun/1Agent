import AppKit
import SwiftUI

/// Empty top-of-window surface (sidebar header, single-pane strip, blank part of a pane title).
/// Press and drag moves the window; a double-click does what System Settings → Desktop & Dock
/// says for a title bar double-click.
struct WindowDragArea: NSViewRepresentable {
    /// A press that did not move the window.
    var onClick: (() -> Void)? = nil
    var onSecondaryClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> WindowDragAreaView { WindowDragAreaView() }

    func updateNSView(_ view: WindowDragAreaView, context: Context) {
        view.onClick = onClick
        view.onSecondaryClick = onSecondaryClick
    }
}

final class WindowDragAreaView: NSView {
    var onClick: (() -> Void)?
    var onSecondaryClick: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            WindowDragAreaView.performTitlebarDoubleClick(window)
            return
        }
        let origin = window.frame.origin
        window.performDrag(with: event)
        let moved = window.frame.origin
        if hypot(moved.x - origin.x, moved.y - origin.y) < 1 {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let onSecondaryClick {
            onSecondaryClick()
        } else {
            super.rightMouseDown(with: event)
        }
    }

    /// `AppleActionOnDoubleClick` is "Maximize", "Minimize", or "None"; unset means Maximize.
    static func performTitlebarDoubleClick(_ window: NSWindow) {
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        if action == "Minimize" {
            window.miniaturize(nil)
        } else if action == "None" {
            return
        } else {
            window.zoom(nil)
        }
    }
}
