import SwiftUI

/// The Files area: panes in a grid like the terminal canvas, each with its own tabs on this Mac or
/// on hosts. Dividers resize panes; dragging a tab onto a pane joins it or splits it.
struct FilesWorkspaceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    var relay: CanvasDropRelay

    var body: some View {
        FilesGrid(workspace: model.fileWorkspace(for: window), model: model, window: window, relay: relay)
    }
}

private struct FilesGrid: View {
    @ObservedObject private var material = WindowMaterial.shared
    @ObservedObject var workspace: FileWorkspace
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    var relay: CanvasDropRelay
    @Environment(\.windowChrome) private var chrome
    @StateObject private var tabDrag = FileTabDragTracker()
    @State private var hoveredDividerID: UUID?
    @State private var ratioDrag: (id: UUID, start: CGFloat)?

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(origin: .zero, size: geometry.size)
            let frames = PaneLayout.frames(of: workspace.layout, in: rect)
            ZStack(alignment: .topLeading) {
                ForEach(workspace.groupIDs, id: \.self) { id in
                    if let frame = frames[id] {
                        FileGroupView(workspace: workspace, groupID: id, model: model, window: window,
                                      relay: relay, tabDrag: tabDrag)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                ForEach(PaneLayout.dividers(of: workspace.layout, in: rect)) { divider in
                    dividerControl(divider)
                }
                if let zone = tabDrag.zone, let frame = frames[zone.group] {
                    let area = PaneLayout.reminder(for: zone.edge, in: frame)
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .fill(chrome.accentFill.opacity(0.75))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(chrome.accent, lineWidth: 2))
                        .frame(width: area.width, height: area.height)
                        .offset(x: area.minX, y: area.minY)
                        .allowsHitTesting(false)
                        .animation(.easeOut(duration: 0.12), value: zone)
                        .zIndex(5)
                }
            }
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        }
        .background(chrome.background.opacity(material.opacity))
        .onChange(of: tabDrag.draggingID) { _, _ in hoveredDividerID = nil }
        .onChange(of: window.filesDropTarget) { _, _ in hoveredDividerID = nil }
    }

    private func dividerControl(_ divider: PaneDivider) -> some View {
        let vertical = divider.axis == .vertical
        let active = hoveredDividerID == divider.id || ratioDrag?.id == divider.id
        let lineWidth = active ? Theme.PaneStyle.dividerActiveLineWidth : Theme.PaneStyle.dividerLineWidth
        return Color.clear
            .frame(width: divider.frame.width, height: divider.frame.height)
            .overlay {
                Rectangle()
                    .fill(active ? chrome.accent : chrome.hairline)
                    .frame(width: vertical ? lineWidth : divider.frame.width,
                           height: vertical ? divider.frame.height : lineWidth)
                    .allowsHitTesting(false)
            }
            .overlay {
                PaneDividerHandle(
                    vertical: vertical,
                    onHover: { inside in
                        if inside {
                            hoveredDividerID = divider.id
                        } else if hoveredDividerID == divider.id {
                            hoveredDividerID = nil
                        }
                    },
                    onDragChanged: { delta in
                        if ratioDrag?.id != divider.id {
                            ratioDrag = (divider.id, workspace.ratio(of: divider.splitID))
                        }
                        guard let drag = ratioDrag, divider.span > 1 else { return }
                        workspace.setSplitRatio(divider.splitID, to: drag.start + delta / divider.span)
                    },
                    onDragEnded: { ratioDrag = nil },
                    onDoubleClick: { workspace.evenOutSplit(divider.splitID) }
                )
            }
            .offset(x: divider.frame.minX, y: divider.frame.minY)
            .zIndex(4)
    }
}

/// One pane: its tab strip and its current tab.
private struct FileGroupView: View {
    @ObservedObject var workspace: FileWorkspace
    var groupID: UUID
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    var relay: CanvasDropRelay
    @ObservedObject var tabDrag: FileTabDragTracker
    @Environment(\.windowChrome) private var chrome

    private var group: FileWorkspace.Group? { workspace.groups[groupID] }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Rectangle().fill(chrome.hairline).frame(height: 1)
            if let column = group?.active {
                FileColumnView(workspace: workspace, column: column)
                    .id(column.id)
            } else {
                emptyPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BoundsAnchor { view in
            relay.filesSideAnchors[.group(groupID)] = AnchorBox(view)
            tabDrag.panes[groupID] = AnchorBox(view)
        })
        .overlay { dropHighlight }
    }

    /// Not a ScrollView: inside one, SwiftUI's container takes the tabs' clicks and the title bar
    /// moves the window. Many tabs shrink instead.
    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(group?.tabs ?? []) { column in
                FileTabButton(workspace: workspace, column: column, groupID: groupID, tabDrag: tabDrag)
            }
            Menu {
                Button(String(localized: "This Mac"), action: addLocalTab)
                Button(String(localized: "Connect Host…"), action: connectHost)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: FileBrowserLayout.toolbarButtonSize, height: FileBrowserLayout.toolbarButtonSize)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(chrome.secondary)
            .help(String(localized: "New Tab"))
        }
        .padding(.horizontal, Theme.Space.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .frame(height: FileBrowserLayout.tabStripHeight)
        .background(WindowDragArea())
        .background(BoundsAnchor { tabDrag.strips[groupID] = AnchorBox($0) })
        .background(chrome.sidebarBackground)
    }

    private var emptyPane: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "rectangle.on.rectangle")
                .font(Theme.Font.emptySymbol)
                .foregroundStyle(chrome.tertiary)
            Text("No open tabs")
                .font(Theme.Font.emptyTitle)
                .foregroundStyle(chrome.text)
            Text("Drag a host from the sidebar or a tab here, or open one.")
                .font(Theme.Font.body)
                .foregroundStyle(chrome.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: Theme.Space.s) {
                Button(String(localized: "This Mac"), action: addLocalTab)
                Button("Connect Host…", action: connectHost)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if window.filesDropTarget == .group(groupID) {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(chrome.accent, lineWidth: 2)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(chrome.accentFill.opacity(0.6)))
                .overlay {
                    Text("Release to open files")
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(chrome.text)
                }
                .padding(6)
                .allowsHitTesting(false)
        }
    }

    private func addLocalTab() {
        workspace.addLocalTab(at: nil, in: groupID)
    }

    private func connectHost() {
        workspace.pickerGroupID = groupID
        model.openHostPicker(in: window, purpose: .files)
    }
}

/// Tab drags. The strips sit in the title bar band, where SwiftUI drags would move the window, so
/// each tab tracks the mouse in its own view and reports here. Over its own strip a tab reorders
/// live; over another pane it shows where it would land (the whole pane to join it, half of it to
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

    func dragEnded(_ column: FileColumn, in workspace: FileWorkspace) {
        if let zone {
            let before = zone.before.flatMap { id in workspace.allTabs.first { $0.id == id } }
            withAnimation(.easeOut(duration: 0.15)) {
                workspace.drop(column, on: zone.group, edge: zone.edge, before: before)
            }
        }
        draggingID = nil
        zone = nil
    }

    private func target(for column: FileColumn, at windowPoint: NSPoint, in workspace: FileWorkspace) -> Zone? {
        guard let source = workspace.groupID(of: column) else { return nil }
        for id in workspace.groupIDs {
            if let strip = strips[id]?.view, Self.contains(strip, windowPoint) {
                let hovered = workspace.groups[id]?.tabs.first { tab in
                    tabs[tab.id]?.view.map { Self.contains($0, windowPoint) } ?? false
                }
                if id == source {
                    if let hovered {
                        withAnimation(.easeOut(duration: 0.15)) { workspace.reorder(column, toward: hovered) }
                    }
                    return nil
                }
                return Zone(group: id, edge: .center, before: hovered?.id)
            }
            if let pane = panes[id]?.view, Self.contains(pane, windowPoint) {
                let local = pane.convert(windowPoint, from: nil)
                let point = CGPoint(x: local.x, y: pane.isFlipped ? local.y : pane.bounds.height - local.y)
                let edge = Self.edge(at: point, in: pane.bounds.size)
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
        return view.bounds.contains(view.convert(windowPoint, from: nil))
    }
}

/// Over a tab, taking all of its mouse input: a click selects it (or closes it on the close mark),
/// a drag moves it, and neither moves the window. Hover, menu and tooltip live here too: any SwiftUI
/// gesture on the tab would claim the click and let the title bar move the window.
private struct FileTabHandle: NSViewRepresentable {
    var toolTip: String
    /// From the trailing edge: clicks there close the tab.
    var closeWidth: CGFloat
    var menu: [(title: String, action: () -> Void)]
    var onClick: () -> Void
    var onClose: () -> Void
    var onHover: (Bool) -> Void
    var onDragMoved: (NSPoint) -> Void
    var onDragEnded: () -> Void
    var onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> FileTabHandleView { FileTabHandleView() }

    func updateNSView(_ view: FileTabHandleView, context: Context) {
        view.toolTip = toolTip
        view.closeWidth = closeWidth
        view.menuItems = menu
        view.onClick = onClick
        view.onClose = onClose
        view.onHover = onHover
        view.onDragMoved = onDragMoved
        view.onDragEnded = onDragEnded
        onResolve(view)
    }
}

final class FileTabHandleView: NSView {
    var closeWidth: CGFloat = 0
    var menuItems: [(title: String, action: () -> Void)] = []
    var onClick: () -> Void = {}
    var onClose: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var onDragMoved: (NSPoint) -> Void = { _ in }
    var onDragEnded: () -> Void = {}

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
        for (index, entry) in menuItems.enumerated() {
            let item = NSMenuItem(title: entry.title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        return menu
    }

    @objc private func runMenuItem(_ item: NSMenuItem) {
        guard menuItems.indices.contains(item.tag) else { return }
        menuItems[item.tag].action()
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
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else {
                if dragging { self.onDragEnded() }
                stop.pointee = true
                return
            }
            if event.type == .leftMouseUp {
                if dragging {
                    self.onDragEnded()
                } else {
                    let x = self.convert(start, from: nil).x
                    if x >= self.bounds.maxX - self.closeWidth { self.onClose() } else { self.onClick() }
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

/// One tab: the host alias, or the folder name on this Mac. The current tab is filled: solid in the
/// focused pane, tinted in the others. The close mark shows on hover.
private struct FileTabButton: View {
    @ObservedObject var workspace: FileWorkspace
    @ObservedObject var column: FileColumn
    var groupID: UUID
    @ObservedObject var tabDrag: FileTabDragTracker
    @Environment(\.windowChrome) private var chrome
    @State private var hovering = false
    private static let closeSize: CGFloat = 14

    private var dragging: Bool { tabDrag.draggingID == column.id }
    private var active: Bool { workspace.groups[groupID]?.activeID == column.id }
    private var solid: Bool { active && workspace.focusedGroupID == groupID }

    private var title: String {
        if let host = column.fileSystem.host { return host }
        if column.directory.isEmpty { return column.title }
        return column.directory == "/" ? "/" : (column.directory as NSString).lastPathComponent
    }

    private var fill: Color {
        if solid { return chrome.accent }
        if active || dragging { return chrome.accentFill }
        return hovering ? chrome.elevated : Color.clear
    }

    private var foreground: Color {
        if solid { return .white }
        return active ? chrome.accent : chrome.secondary
    }

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: column.isRemote ? "cloud" : "folder")
                .font(.system(size: 11))
            Text(verbatim: title)
                .font(Theme.Font.rowMeta.weight(active ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: Self.closeSize, height: Self.closeSize)
                .opacity(hovering || active ? 1 : 0)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, Theme.Space.s)
        .frame(minWidth: FileBrowserLayout.tabMinWidth, idealWidth: FileBrowserLayout.tabMaxWidth, maxWidth: FileBrowserLayout.tabMaxWidth)
        .frame(height: FileBrowserLayout.tabStripHeight - 6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(fill))
        .shadow(color: .black.opacity(dragging ? 0.2 : 0), radius: 6, y: 2)
        .scaleEffect(dragging ? 1.04 : 1)
        .zIndex(dragging ? 1 : 0)
        .overlay(FileTabHandle(
            toolTip: column.directory,
            closeWidth: Self.closeSize + Theme.Space.s + Theme.Space.xs,
            menu: menu,
            onClick: { workspace.activate(column) },
            onClose: { workspace.close(column) },
            onHover: { hovering = $0 },
            onDragMoved: { tabDrag.dragMoved(column, to: $0, in: workspace) },
            onDragEnded: { tabDrag.dragEnded(column, in: workspace) },
            onResolve: { tabDrag.tabs[column.id] = FileTabDragTracker.Entry(view: $0, column: column) }
        ))
    }

    private var menu: [(title: String, action: () -> Void)] {
        var items: [(title: String, action: () -> Void)] = []
        if (workspace.groups[groupID]?.tabs.count ?? 0) > 1 {
            items.append((String(localized: "Split Right"), { workspace.drop(column, on: groupID, edge: .right) }))
            items.append((String(localized: "Split Down"), { workspace.drop(column, on: groupID, edge: .bottom) }))
        }
        items.append((String(localized: "Close Tab"), { workspace.close(column) }))
        return items
    }
}
