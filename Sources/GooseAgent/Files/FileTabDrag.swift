import AppKit
import SwiftUI

struct FileTabMenuItem {
    var title: String
    var enabled = true
    var action: () -> Void = {}
    var isSeparator = false

    static var separator: Self { Self(title: "", isSeparator: true) }
}

/// Tab drags. The strips sit in the title bar band, where SwiftUI drags would move the window, so
/// each tab tracks the mouse in its own view and reports here. Over its own strip a tab reorders
/// with an insertion marker; over another pane it shows where it would land (the whole pane to join it, half of it to
/// split it) and moves there on release.
@MainActor
final class FileTabDragTracker: ObservableObject {
    final class Entry {
        weak var view: NSView?
        weak var column: FileColumn?
        init(view: NSView, column: FileColumn) {
            self.view = view
            self.column = column
        }
    }

    struct Zone: Equatable {
        var group: UUID
        var edge: SplitEdge
        /// Joining over another pane's strip: the tab under the pointer, which it goes before.
        var before: UUID?
        var reordering = false
    }

    var tabs: [UUID: Entry] = [:]
    var strips: [UUID: AnchorBox] = [:]
    var panes: [UUID: AnchorBox] = [:]
    /// The tab being dragged, drawn lifted.
    @Published private(set) var draggingID: UUID?
    /// Where the dragged tab would land, highlighted over the grid.
    @Published private(set) var zone: Zone?

    func dragMoved(_ column: FileColumn, to windowPoint: NSPoint, in workspace: FileWorkspace) {
        if draggingID != column.id { draggingID = column.id }
        let next = target(for: column, at: windowPoint, in: workspace)
        if zone != next { zone = next }
    }

    func dragEnded(_ column: FileColumn, at windowPoint: NSPoint, in workspace: FileWorkspace) {
        zone = target(for: column, at: windowPoint, in: workspace)
        if let zone {
            let before = zone.before.flatMap { id in workspace.allTabs.first { $0.id == id } }
            withAnimation(.easeOut(duration: 0.15)) {
                if zone.reordering, let before {
                    workspace.reorder(column, toward: before)
                } else {
                    workspace.drop(column, on: zone.group, edge: zone.edge, before: before)
                }
            }
        }
        draggingID = nil
        zone = nil
    }

    func cancel() {
        draggingID = nil
        zone = nil
    }

    private func target(for column: FileColumn, at windowPoint: NSPoint, in workspace: FileWorkspace) -> Zone? {
        guard let source = workspace.groupID(of: column) else { return nil }
        for id in workspace.groupIDs {
            if let strip = strips[id]?.view, Self.contains(strip, windowPoint) {
                if let scroll = tabs[column.id]?.view?.enclosingScrollView, source == id {
                    let point = scroll.convert(windowPoint, from: nil)
                    let delta: CGFloat = point.x < 24 ? -14 : point.x > scroll.bounds.width - 24 ? 14 : 0
                    if delta != 0, let document = scroll.documentView {
                        var origin = scroll.contentView.bounds.origin
                        origin.x = min(max(0, origin.x + delta), max(0, document.bounds.width - scroll.contentView.bounds.width))
                        scroll.contentView.scroll(to: origin)
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                }
                let hovered = workspace.groups[id]?.tabs.first { tab in
                    tabs[tab.id]?.view.map { Self.contains($0, windowPoint) } ?? false
                }
                if id == source {
                    guard let hovered, hovered !== column else { return nil }
                    // Keep geometry stable while AppKit is tracking the mouse. Commit once on release.
                    return Zone(group: id, edge: .center, before: hovered.id, reordering: true)
                }
                return workspace.canDrop(column, on: id, edge: .center) ? Zone(group: id, edge: .center, before: hovered?.id) : nil
            }
            if let pane = panes[id]?.view, Self.contains(pane, windowPoint) {
                let local = pane.convert(windowPoint, from: nil)
                let point = CGPoint(x: local.x, y: pane.isFlipped ? local.y : pane.bounds.height - local.y)
                let edge = workspace.groups[id]?.tabs.isEmpty == true ? .center : Self.edge(at: point, in: pane.bounds.size)
                return workspace.canDrop(column, on: id, edge: edge) ? Zone(group: id, edge: edge) : nil
            }
        }
        return nil
    }

    /// The middle of a pane joins it; nearer an edge splits toward that edge.
    static func edge(at point: CGPoint, in size: CGSize) -> SplitEdge {
        let middle = CGRect(origin: .zero, size: size)
            .insetBy(dx: size.width * FileBrowserLayout.joinZoneInset, dy: size.height * FileBrowserLayout.joinZoneInset)
        if middle.contains(point) { return .center }
        return SplitEdge.at(point, in: size) ?? .center
    }

    private static func contains(_ view: NSView, _ windowPoint: NSPoint) -> Bool {
        guard view.window != nil else { return false }
        // AppKit may report a visibleRect larger than bounds for an unclipped SwiftUI
        // background. Intersect both so a header cannot claim the entire pane.
        return view.bounds.intersection(view.visibleRect).contains(view.convert(windowPoint, from: nil))
    }
}

/// Over a tab, taking all of its mouse input: a click selects it (or closes it on the close mark),
/// a drag moves it, and neither moves the window. Hover, menu and tooltip live here too: any SwiftUI
/// gesture on the tab would claim the click and let the title bar move the window.
private struct FileTabHandle: NSViewRepresentable {
    var title: String
    var identifier: String
    var toolTip: String
    /// From the trailing edge: clicks there close the tab.
    var closeWidth: CGFloat
    var menu: [FileTabMenuItem]
    var onClick: () -> Void
    var onClose: () -> Void
    var onHover: (Bool) -> Void
    var onDragMoved: (NSPoint) -> Void
    var onDragEnded: (NSPoint) -> Void
    var onCancel: () -> Void
    var onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> FileTabHandleView { FileTabHandleView() }

    func updateNSView(_ view: FileTabHandleView, context: Context) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(title)
        view.setAccessibilityIdentifier(identifier)
        view.toolTip = toolTip
        view.closeWidth = closeWidth
        view.menuItems = menu
        view.onClick = onClick
        view.onClose = onClose
        view.onHover = onHover
        view.onDragMoved = onDragMoved
        view.onDragEnded = onDragEnded
        view.onCancel = onCancel
        onResolve(view)
    }
}

final class FileTabHandleView: NSView {
    var closeWidth: CGFloat = 0
    var menuItems: [FileTabMenuItem] = []
    var onClick: () -> Void = {}
    var onClose: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var onDragMoved: (NSPoint) -> Void = { _ in }
    var onDragEnded: (NSPoint) -> Void = { _ in }
    var onCancel: () -> Void = {}

    /// The window server decides on a title bar drag when the button goes down, so the window is
    /// frozen while the pointer is over the tab, as the pane titles do.
    private var pressed = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        window?.isMovable = false
        onHover(true)
    }

    override func mouseMoved(with event: NSEvent) {
        window?.isMovable = false
    }

    override func mouseExited(with event: NSEvent) {
        onHover(false)
        restoreWindowMovementIfPointerLeft()
    }

    private func restoreWindowMovementIfPointerLeft() {
        guard !pressed, let window else { return }
        if !bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            window.isMovable = true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, entry) in menuItems.enumerated() {
            if entry.isSeparator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: entry.title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = entry.enabled
            menu.addItem(item)
        }
        FamilyMenuPresenter.shared.show(menu, with: event, for: self)
        return nil
    }

    @objc private func runMenuItem(_ item: NSMenuItem) {
        guard menuItems.indices.contains(item.tag), menuItems[item.tag].enabled else { return }
        menuItems[item.tag].action()
    }

    func requestClose() {
        guard let window, window.attachedSheet == nil && !(NSApp.keyWindow is FamilyModalWindow) else { return }
        let alert = FamilyAlert()
        alert.messageText = String(localized: "Close")
        alert.addButton(withTitle: String(localized: "Close"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let close = onClose
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { close() }
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        pressed = true
        window.isMovable = false
        defer {
            pressed = false
            restoreWindowMovementIfPointerLeft()
        }
        let start = event.locationInWindow
        var dragging = false
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown], timeout: 3600, mode: .eventTracking) { event, stop in
            guard let event else {
                if dragging { self.onCancel() }
                stop.pointee = true
                return
            }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.onCancel()
                    stop.pointee = true
                }
                return
            }
            if event.type == .leftMouseUp {
                if dragging {
                    self.onDragEnded(event.locationInWindow)
                } else {
                    let x = self.convert(start, from: nil).x
                    if x >= self.bounds.maxX - self.closeWidth { self.requestClose() } else { self.onClick() }
                }
                stop.pointee = true
                return
            }
            let point = event.locationInWindow
            if !dragging, hypot(point.x - start.x, point.y - start.y) >= 4 {
                dragging = true
                self.onClick()
            }
            if dragging { self.onDragMoved(point) }
        }
    }
}

/// A remote file tab with the same native mouse tracking as terminal pane titles.
struct FileTabButton: View {
    @ObservedObject var workspace: FileWorkspace
    @ObservedObject var column: FileColumn
    var groupID: UUID
    @ObservedObject var tabDrag: FileTabDragTracker
    @Environment(\.windowChrome) private var chrome
    @State private var hovering = false
    private static let closeSize: CGFloat = 14

    private var dragging: Bool { tabDrag.draggingID == column.id }
    private var active: Bool { workspace.groups[groupID]?.activeID == column.id }
    private var multipleTabs: Bool { (workspace.groups[groupID]?.tabs.count ?? 0) > 1 }

    private var title: String {
        if let host = column.fileSystem.host { return host }
        if column.directory.isEmpty { return column.title }
        return column.directory == "/" ? "/" : (column.directory as NSString).lastPathComponent
    }

    private var fill: Color {
        if dragging || (active && multipleTabs) { return chrome.accentFill }
        return hovering ? chrome.elevated : Color.clear
    }

    private var foreground: Color { active ? (multipleTabs ? chrome.accent : chrome.text) : chrome.secondary }

    private var insertionAtTrailingEdge: Bool? {
        guard let zone = tabDrag.zone, zone.reordering, zone.before == column.id,
              let tabs = workspace.groups[groupID]?.tabs,
              let source = tabs.firstIndex(where: { $0.id == tabDrag.draggingID }),
              let target = tabs.firstIndex(where: { $0.id == column.id }) else { return nil }
        return source < target
    }

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Text(verbatim: title)
                .font(Theme.Font.body.weight(active ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)

            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: Self.closeSize, height: Self.closeSize)
                .opacity(hovering || active ? 1 : 0)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, Theme.Space.s)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 27)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(fill))
        .accessibilityHidden(true)
        .zIndex(dragging ? 1 : 0)
        .overlay(FileTabHandle(
            title: title,
            identifier: "files.tab." + column.id.uuidString,
            toolTip: title + ": " + column.directory,
            closeWidth: Self.closeSize + Theme.Space.s + Theme.Space.xs,
            menu: menu,
            onClick: { workspace.activate(column) },
            onClose: { workspace.close(column) },
            onHover: { hovering = $0 },
            onDragMoved: { tabDrag.dragMoved(column, to: $0, in: workspace) },
            onDragEnded: { tabDrag.dragEnded(column, at: $0, in: workspace) },
            onCancel: { tabDrag.cancel() },
            onResolve: { tabDrag.tabs[column.id] = FileTabDragTracker.Entry(view: $0, column: column) }
        ))
        .overlay(alignment: insertionAtTrailingEdge == true ? .trailing : .leading) {
            if insertionAtTrailingEdge != nil {
                Rectangle().fill(chrome.accent).frame(width: 2, height: 27).allowsHitTesting(false)
            }
        }
    }

    private var menu: [FileTabMenuItem] {
        var items: [FileTabMenuItem] = [
            FileTabMenuItem(title: String(localized: "Open in Terminal"), enabled: !column.directory.isEmpty,
                            action: { workspace.openTerminal([], in: column) })
        ]
        if workspace.canDrop(column, on: groupID, edge: .right) {
            items.append(.separator)
            items.append(FileTabMenuItem(title: String(localized: "Split Right"), action: { workspace.drop(column, on: groupID, edge: .right) }))
            items.append(FileTabMenuItem(title: String(localized: "Split Down"), action: { workspace.drop(column, on: groupID, edge: .bottom) }))
        }
        return items
    }
}
