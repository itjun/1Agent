import AppKit
import QuartzCore
import SwiftUI

/// Right-click on a workspace title. Scroll events pass through to the sidebar.
struct WorkspaceHeaderMenu: NSViewRepresentable {
    var layouts: [WorkspaceLayout]
    var titles: [String]
    var canReconnect: Bool
    var canSeparate: Bool
    var onLayout: (WorkspaceLayout) -> Void
    var onReconnect: () -> Void
    var onSeparate: () -> Void
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
        view.canSeparate = canSeparate
        view.onLayout = onLayout
        view.onReconnect = onReconnect
        view.onSeparate = onSeparate
        view.onRename = onRename
        view.onDissolve = onDissolve
        view.onDragBegan = onDragBegan
        view.onDragMoved = onDragMoved
        view.onDragEnded = onDragEnded
        view.toolTip = String(localized: "Drag to reorder. Right-click to manage the workspace or combine and separate its panels.")
    }
}

final class WorkspaceHeaderMenuView: NSView {
    var layouts: [WorkspaceLayout] = []
    var titles: [String] = []
    var canReconnect = false
    var canSeparate = false
    var onLayout: (WorkspaceLayout) -> Void = { _ in }
    var onReconnect: () -> Void = {}
    var onSeparate: () -> Void = {}
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
        menu.addItem(.separator())
        if !layouts.isEmpty {
            let merge = NSMenuItem(title: String(localized: "Merge All and Arrange"), action: nil, keyEquivalent: "")
            let choices = NSMenu()
            for index in layouts.indices {
                let title = titles.indices.contains(index) ? titles[index] : ""
                let item = NSMenuItem(title: title, action: #selector(chooseLayout(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                choices.addItem(item)
            }
            merge.submenu = choices
            menu.addItem(merge)
        }
        let separate = NSMenuItem(title: String(localized: "Separate All Panels"), action: #selector(separateFromMenu(_:)), keyEquivalent: "")
        separate.target = self
        menu.addItem(separate)
        menu.addItem(.separator())
        let rename = NSMenuItem(
            title: String(localized: "Rename"),
            action: #selector(renameFromMenu(_:)),
            keyEquivalent: ""
        )
        rename.target = self
        menu.addItem(rename)
        menu.addItem(.separator())
        menu.addItem(TerminalCloseMenu.item(
            title: String(localized: "Dissolve Workspace"),
            action: #selector(dissolveFromMenu(_:)),
            target: self
        ))
        return menu
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(separateFromMenu(_:)) { return canSeparate }
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

    @objc private func separateFromMenu(_: Any?) { onSeparate() }

    @objc private func renameFromMenu(_: Any?) {
        onRename()
    }

    @objc private func dissolveFromMenu(_: Any?) {
        onDissolve()
    }
}

func workspaceTitle(_ workspace: Workspace) -> String {
    if let name = workspace.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
        return name
    }
    return String(format: String(localized: "Workspace %lld"), workspace.number)
}

func workspaceLayoutTitle(_ layout: WorkspaceLayout) -> String {
    switch layout {
    case .columns:
        return String(localized: "Equal Columns")
    case .rows:
        return String(localized: "Equal Rows")
    case .grid:
        return String(localized: "Grid")
    case .leadingSide:
        return String(localized: "Leading Pane on the Left")
    case .leadingTop:
        return String(localized: "Leading Pane on the Top")
    }
}

/// Both sidebar rows and pane titles expose the same membership and display operations.
@MainActor
func terminalContextMenu(for tab: TerminalTab, model: AppModel, window: WindowState,
                         forPane: Bool = false, onRename: (() -> Void)? = nil) -> TabContextMenu {
    let targets = forPane ? [tab.id] : model.sidebarTargets(clicking: tab.id, in: window)
    return TabContextMenu(
        showsDuplicate: targets.count == 1,
        canDetach: model.sidebarSplits(targets),
        canRemove: targets.contains { id in model.workspaces.contains { $0.isGrouped && $0.members.contains(id) } },
        canCreateArea: model.sidebarCanCreateArea(targets),
        layouts: WorkspaceBoard.availableLayouts(paneCount: targets.count).map { ($0, workspaceLayoutTitle($0)) },
        workspaces: model.workspacesByNumber.filter { workspace in
            !targets.allSatisfy { workspace.members.contains($0) }
        }.map { ($0.id, workspaceTitle($0)) },
        duplicateRight: { model.duplicate(targets[0], edge: .right) },
        duplicateDown: { model.duplicate(targets[0], edge: .bottom) },
        merge: { model.mergeSidebar(targets, onto: tab.id, as: $0, in: window) },
        detach: { model.splitSidebar(targets, in: window) },
        move: { model.joinWorkspace(targets, $0, beside: nil, after: true) },
        remove: {
            if forPane { model.removePaneFromWorkspace(tab.id, in: window) }
            else { model.removeSidebarFromWorkspace(targets, in: window) }
        },
        createArea: { model.createAreaFromSidebar(targets, in: window) },
        close: { model.closeTabs(targets) },
        copyInfo: { copySessionInfo(tab, model: model) },
        rename: forPane ? nil : onRename
    )
}
