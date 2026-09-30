import AppKit
import QuartzCore
import SwiftUI

/// Right-click on a workspace title. Scroll events pass through to the sidebar.
struct WorkspaceHeaderMenu: NSViewRepresentable {
    var layouts: [WorkspaceLayout]
    var titles: [String]
    var canReconnect: Bool
    var onLayout: (WorkspaceLayout) -> Void
    var onReconnect: () -> Void
    var onRename: () -> Void
    var onDissolve: () -> Void
    var onDragBegan: () -> Void
    var onDragMoved: (NSPoint) -> Void
    var onDragEnded: (NSPoint) -> Void

    func makeNSView(context: Context) -> WorkspaceHeaderMenuView {
        WorkspaceHeaderMenuView()
    }

    func updateNSView(_ view: WorkspaceHeaderMenuView, context: Context) {
        view.layouts = layouts
        view.titles = titles
        view.canReconnect = canReconnect
        view.onLayout = onLayout
        view.onReconnect = onReconnect
        view.onRename = onRename
        view.onDissolve = onDissolve
        view.onDragBegan = onDragBegan
        view.onDragMoved = onDragMoved
        view.onDragEnded = onDragEnded
        view.toolTip = String(localized: "Drag to reorder. Right-click to reconnect closed terminals, rename the workspace, or arrange its panes.")
    }
}

final class WorkspaceHeaderMenuView: NSView {
    var layouts: [WorkspaceLayout] = []
    var titles: [String] = []
    var canReconnect = false
    var onLayout: (WorkspaceLayout) -> Void = { _ in }
    var onReconnect: () -> Void = {}
    var onRename: () -> Void = {}
    var onDissolve: () -> Void = {}
    var onDragBegan: () -> Void = {}
    var onDragMoved: (NSPoint) -> Void = { _ in }
    var onDragEnded: (NSPoint) -> Void = { _ in }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow
        var dragging = false
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: 3600,
            mode: .eventTracking
        ) { event, stop in
            guard let event else {
                stop.pointee = true
                return
            }
            if event.type == .leftMouseUp {
                if dragging {
                    self.onDragEnded(event.locationInWindow)
                }
                stop.pointee = true
                return
            }
            let delta = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
            if !dragging, delta >= 4 {
                dragging = true
                self.onDragBegan()
            }
            if dragging {
                self.onDragMoved(event.locationInWindow)
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let reconnect = NSMenuItem(
            title: String(localized: "Reconnect"),
            action: #selector(reconnectFromMenu(_:)),
            keyEquivalent: ""
        )
        reconnect.target = self
        menu.addItem(reconnect)
        if !layouts.isEmpty {
            menu.addItem(.separator())
        }
        for index in layouts.indices {
            let title = titles.indices.contains(index) ? titles[index] : ""
            let item = NSMenuItem(title: title, action: #selector(chooseLayout(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let rename = NSMenuItem(
            title: String(localized: "Rename"),
            action: #selector(renameFromMenu(_:)),
            keyEquivalent: ""
        )
        rename.target = self
        menu.addItem(rename)
        menu.addItem(TerminalCloseMenu.item(
            title: String(localized: "Dissolve Workspace"),
            action: #selector(dissolveFromMenu(_:)),
            target: self
        ))
        return menu
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(reconnectFromMenu(_:)) {
            return canReconnect
        }
        return true
    }

    @objc private func chooseLayout(_ sender: NSMenuItem) {
        guard layouts.indices.contains(sender.tag) else { return }
        onLayout(layouts[sender.tag])
    }

    @objc private func reconnectFromMenu(_: Any?) {
        onReconnect()
    }

    @objc private func renameFromMenu(_: Any?) {
        onRename()
    }

    @objc private func dissolveFromMenu(_: Any?) {
        onDissolve()
    }
}

/// Follows the pointer until mouse-up. A system drag session does not report the landing point reliably.
