import AppKit
import QuartzCore
import SwiftUI

final class AnchorBox {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}

/// What is being dragged and from which window. Passed to whichever window's relay is under the pointer.
enum DragPayload {
    case tabs([UUID], source: WindowState)
    case block(SidebarBlock, source: WindowState)

    var source: WindowState {
        switch self {
        case .tabs(_, let source), .block(_, let source):
            return source
        }
    }
}

/// Where a sidebar drag is about to land. Computed on every mouse move and reused on mouse-up,
/// so the preview line and the final action can never disagree.
enum SidebarDropTarget: Equatable {
    /// Between two rows of a workspace, or at its end when `beside` is nil.
    case workspace(UUID, beside: UUID?, after: Bool)
    /// Between two rows of Local Group / Ungrouped, or at its end when `beside` is nil.
    case loose(SidebarBlock, beside: UUID?, after: Bool)
    /// The gap between two blocks. `index` is where a new block would be inserted.
    case gap(index: Int)
    /// A whole block, for merging everything into it.
    case block(SidebarBlock)
}

/// Tracks the drag that started in the main window and draws its landing preview.
final class CanvasDropRelay: ObservableObject {
    var frames: [UUID: CGRect] = [:]
    weak var modelBox: AppModel?
    weak var windowBox: WindowState?
    weak var catcher: PaneDropCatcherView?
    weak var sidebarAnchor: NSView?
    var rowAnchors: [UUID: AnchorBox] = [:]
    var blockAnchors: [SidebarBlock: AnchorBox] = [:]
    /// The two sides of the Files area, and the Files button in the sidebar header. A sidebar row
    /// dropped on any of them opens that host's files instead of moving the row.
    var filesSideAnchors: [FilesDropTarget: AnchorBox] = [:]
    weak var filesButtonAnchor: NSView?
    var dragTitle = ""
    private var draggingFromPane = false
    private var autoscrollTimer: Timer?
    private var autoscrollStep: CGFloat = 0

    /// How close to a block's top or bottom edge counts as "between blocks" for a block drag.
    private static let blockEdgeBand: CGFloat = 10
    /// Pointer this close to the sidebar's top or bottom edge scrolls the list.
    private static let autoscrollBand: CGFloat = 28

    private var nsWindow: NSWindow? {
        catcher?.window ?? sidebarAnchor?.window
    }

    /// The drag this window started, if any.
    private var ownPayload: DragPayload? {
        MainActor.assumeIsolated {
            guard let window = windowBox else { return nil }
            if let block = window.draggingBlock {
                return .block(block, source: window)
            }
            if window.draggingTabID != nil {
                return .tabs(window.draggingTabIDs, source: window)
            }
            return nil
        }
    }

    // MARK: Drag lifecycle (called by the handles of this window)

    func dragBegan(_ id: UUID, fromPane: Bool = false) {
        draggingFromPane = fromPane
        MainActor.assumeIsolated {
            guard let model = modelBox, let window = windowBox else { return }
            model.beginDrag(id, in: window)
            if fromPane {
                window.draggingTabIDs = [id]
            }
            let count = window.draggingTabIDs.count
            if count >= 2 {
                dragTitle = String(format: String(localized: "%lld terminals"), count)
            } else if let title = model.tabs.first(where: { $0.id == id })?.contentTitle {
                dragTitle = title
            } else if let tab = model.tabs.first(where: { $0.id == id }), tab.isLocal, let directory = tab.directory {
                dragTitle = LocalTerminal.displayPath(directory)
            } else {
                let alias = model.tabs.first { $0.id == id }?.alias ?? ""
                dragTitle = model.host(alias)?.sessionBadge ?? alias
            }
        }
    }

    func blockDragBegan(_ block: SidebarBlock) {
        draggingFromPane = false
        MainActor.assumeIsolated {
            guard let model = modelBox, let window = windowBox else { return }
            switch block {
            case .workspace(let id):
                dragTitle = model.workspace(for: id).map { workspace in
                    if let name = workspace.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                        return name
                    }
                    return String(format: String(localized: "Workspace %lld"), workspace.number)
                } ?? String(localized: "Workspace")
            case .localGroup:
                dragTitle = String(localized: "Local Group")
            case .ungrouped:
                dragTitle = String(localized: "Ungrouped")
            }
            model.beginBlockDrag(block, in: window)
        }
    }

    func blockDragMoved(windowPoint: NSPoint) {
        dragMoved(windowPoint: windowPoint)
    }

    func blockDragEnded(windowPoint: NSPoint) {
        dragEnded(windowPoint: windowPoint)
    }

    /// Shows the landing preview while the pointer is inside this window; outside there is nothing to land on.
    func dragMoved(windowPoint: NSPoint) {
        guard let payload = ownPayload, let source = nsWindow else { return }
        let screenPoint = source.convertPoint(toScreen: windowPoint)
        let inside = MainActor.assumeIsolated {
            MainWindowManager.shared.windowState(atScreenPoint: screenPoint, except: nil) != nil
        }
        guard inside else {
            hidePreview()
            return
        }
        showPreview(for: payload, windowPoint: windowPoint)
    }

    func dragEnded(windowPoint: NSPoint) {
        stopAutoscroll()
        catcher?.hide()
        guard let payload = ownPayload, let source = nsWindow else { return }
        let screenPoint = source.convertPoint(toScreen: windowPoint)
        MainActor.assumeIsolated {
            guard let model = modelBox, let window = windowBox else { return }
            defer {
                window.filesDropTarget = nil
                model.endDrag(in: window)
            }
            // Dropped on the desktop or another app: nothing happens.
            guard MainWindowManager.shared.windowState(atScreenPoint: screenPoint, except: nil) != nil else { return }
            performDrop(of: payload, windowPoint: windowPoint, model: model)
        }
    }

    // MARK: Preview and drop in this window

    func hidePreview() {
        stopAutoscroll()
        catcher?.hide()
        MainActor.assumeIsolated {
            if let window = windowBox, window.dropHighlight != nil {
                window.dropHighlight = nil
            }
            if let window = windowBox, window.filesDropTarget != nil {
                window.filesDropTarget = nil
            }
        }
    }

    func showPreview(for payload: DragPayload, windowPoint: NSPoint) {
        guard let catcher else { return }
        catcher.layoutSubtreeIfNeeded()
        updateAutoscroll(windowPoint: windowPoint)
        let overFiles = MainActor.assumeIsolated { () -> Bool in
            guard let window = windowBox else { return false }
            let target = filesTarget(at: windowPoint, window: window)
            if window.filesDropTarget != target { window.filesDropTarget = target }
            if target != nil, window.dropHighlight != nil { window.dropHighlight = nil }
            return target != nil
        }
        if overFiles {
            catcher.present(over: catcher, zone: nil, title: dragTitle)
            return
        }
        if overCanvas(windowPoint) {
            let zone = canvasZone(for: payload, windowPoint: windowPoint)
            catcher.present(over: catcher, zone: zone, title: dragTitle)
            return
        }
        let preview = MainActor.assumeIsolated { () -> (NSView, CGRect)? in
            guard let model = modelBox, let window = windowBox else { return nil }
            let target: SidebarDropTarget?
            switch payload {
            case .tabs:
                target = sidebarTarget(for: payload, windowPoint: windowPoint, model: model, window: window)
            case .block:
                target = blockTarget(for: payload, windowPoint: windowPoint, model: model, window: window)
            }
            guard let target else {
                window.dropHighlight = nil
                return nil
            }
            return self.preview(for: target, model: model, window: window)
        }
        if let preview {
            catcher.present(over: preview.0, zone: preview.1, title: dragTitle, insertionLine: true)
        } else {
            catcher.present(over: catcher, zone: nil, title: dragTitle)
        }
    }

    @MainActor
    func performDrop(of payload: DragPayload, windowPoint: NSPoint, model: AppModel) {
        stopAutoscroll()
        catcher?.hide()
        guard let window = windowBox else { return }
        window.dropHighlight = nil
        let filesTarget = filesTarget(at: windowPoint, window: window)
        window.filesDropTarget = nil
        if let filesTarget {
            let group: UUID? = switch filesTarget {
            case .group(let id): id
            case .button: nil
            }
            model.openFiles(forTabs: draggedIDs(of: payload, model: model), in: group, window: window)
            return
        }
        let excluded = Set(draggedIDs(of: payload, model: model))
        if overCanvas(windowPoint) {
            let swiftPoint = catcher?.swiftPoint(windowPoint) ?? .zero
            guard let hit = PaneLayout.dropTarget(at: swiftPoint, frames: frames, excluding: excluded) else { return }
            switch payload {
            case .tabs(let ids, _):
                model.dropTabs(ids, onto: hit.0, edge: hit.1, in: window)
            case .block(let block, let source):
                model.dropBlock(block, from: source, onto: hit.0, edge: hit.1, in: window)
            }
            return
        }
        switch payload {
        case .tabs(let ids, _):
            guard let target = sidebarTarget(for: payload, windowPoint: windowPoint, model: model, window: window) else { return }
            switch target {
            case .workspace(let workspaceID, let beside, let after):
                model.joinWorkspace(ids, workspaceID, beside: beside, after: after, detach: draggingFromPane)
            case .loose(let block, let beside, let after):
                model.moveToLooseGroup(ids, block, in: window, beside: beside, after: after)
            case .gap(let index):
                if ids.count >= 2 {
                    model.createWorkspace(from: ids, atBlockIndex: index, in: window)
                } else if let only = ids.first {
                    let tab = model.tabs.first { $0.id == only }
                    let block: SidebarBlock = tab?.isLocal == true ? .localGroup : .ungrouped
                    model.moveToLooseGroup(ids, block, in: window, beside: nil, after: true)
                }
            case .block(let block):
                switch block {
                case .workspace(let workspaceID):
                    model.joinWorkspace(ids, workspaceID, beside: nil, after: true, detach: draggingFromPane)
                case .localGroup, .ungrouped:
                    model.moveToLooseGroup(ids, block, in: window, beside: nil, after: true)
                }
            }
        case .block(let dragged, let source):
            guard let target = blockTarget(for: payload, windowPoint: windowPoint, model: model, window: window) else { return }
            switch target {
            case .gap(let index):
                model.dropBlock(dragged, from: source, intoGap: index, of: window)
            case .block(let block):
                model.mergeBlock(dragged, from: source, into: block, in: window)
            case .workspace, .loose:
                break
            }
        }
    }

    @MainActor
    private func draggedIDs(of payload: DragPayload, model: AppModel) -> [UUID] {
        switch payload {
        case .tabs(let ids, _):
            return ids
        case .block(let block, let source):
            return model.members(of: block, in: source)
        }
    }

    /// The pane and edge under the pointer, published as the drop highlight. Nil when over no pane.
    private func canvasZone(for payload: DragPayload, windowPoint: NSPoint) -> CGRect? {
        guard let catcher else { return nil }
        let frames = frames
        let swiftPoint = catcher.swiftPoint(windowPoint)
        return MainActor.assumeIsolated { () -> CGRect? in
            guard let model = modelBox, let window = windowBox else { return nil }
            let excluded = Set(draggedIDs(of: payload, model: model))
            guard let hit = PaneLayout.dropTarget(at: swiftPoint, frames: frames, excluding: excluded) else {
                window.dropHighlight = nil
                return nil
            }
            let next = TabDropHighlight.edge(hit.0, hit.1)
            if window.dropHighlight != next { window.dropHighlight = next }
            guard let frame = frames[hit.0] else { return nil }
            return Self.previewZone(for: hit.1, in: frame)
        }
    }

    /// Resolves the sidebar landing spot for a terminal drag. Rows win over gaps; the nearest
    /// row edge inside the block under the pointer decides the insertion slot.
    @MainActor
    private func sidebarTarget(for payload: DragPayload, windowPoint: NSPoint, model: AppModel, window: WindowState) -> SidebarDropTarget? {
        guard sidebarContains(windowPoint) else { return nil }
        let dragged = Set(draggedIDs(of: payload, model: model))
        let target: SidebarDropTarget
        if let block = blockUnderPointer(windowPoint) {
            let slot = nearestRowEdge(windowPoint: windowPoint, ids: model.members(of: block, in: window), skipping: dragged)
            switch block {
            case .workspace(let id):
                target = .workspace(id, beside: slot?.id, after: slot?.after ?? true)
            case .localGroup, .ungrouped:
                target = .loose(block, beside: slot?.id, after: slot?.after ?? true)
            }
        } else {
            target = .gap(index: gapIndex(windowPoint: windowPoint, window: window))
        }
        window.dropHighlight = nil
        return target
    }

    /// Near a block's top or bottom edge the drag reorders; over its body it merges into that block.
    @MainActor
    private func blockTarget(for payload: DragPayload, windowPoint: NSPoint, model: AppModel, window: WindowState) -> SidebarDropTarget? {
        guard sidebarContains(windowPoint), let sidebar = sidebarAnchor else { return nil }
        guard case .block(let dragged, let source) = payload else { return nil }
        let local = sidebar.convert(windowPoint, from: nil)
        if let block = blockUnderPointer(windowPoint),
           !(block == dragged && source.id == window.id),
           let view = blockAnchors[block]?.view {
            let frame = sidebar.convert(view.bounds, from: view)
            let nearTop = local.y - frame.minY < Self.blockEdgeBand
            let nearBottom = frame.maxY - local.y < Self.blockEdgeBand
            if !nearTop, !nearBottom {
                return .block(block)
            }
        }
        return .gap(index: gapIndex(windowPoint: windowPoint, window: window))
    }

    /// The insertion line (or block outline) for a resolved target.
    @MainActor
    private func preview(for target: SidebarDropTarget, model: AppModel, window: WindowState) -> (NSView, CGRect)? {
        guard let sidebar = sidebarAnchor, sidebar.window != nil else { return nil }
        switch target {
        case .workspace(let id, let beside, let after):
            if let beside, let row = rowAnchors[beside]?.view {
                return Self.sidebarLine(sidebar: sidebar, over: row, after: after)
            }
            guard let view = blockAnchors[.workspace(id)]?.view else { return nil }
            return Self.sidebarLine(sidebar: sidebar, over: view, after: true)
        case .loose(let block, let beside, let after):
            if let beside, let row = rowAnchors[beside]?.view {
                return Self.sidebarLine(sidebar: sidebar, over: row, after: after)
            }
            guard let view = blockAnchors[block]?.view else { return nil }
            return Self.sidebarLine(sidebar: sidebar, over: view, after: true)
        case .gap(let index):
            let blocks = window.blocks
            if index < blocks.count, let view = blockAnchors[blocks[index]]?.view {
                return Self.sidebarLine(sidebar: sidebar, over: view, after: false)
            }
            if let last = blocks.last, let view = blockAnchors[last]?.view {
                return Self.sidebarLine(sidebar: sidebar, over: view, after: true)
            }
            return nil
        case .block(let block):
            window.dropHighlight = .block(block)
            return nil
        }
    }

    // MARK: Geometry helpers

    private func overCanvas(_ windowPoint: NSPoint) -> Bool {
        guard let catcher else { return false }
        let showingTerminals = MainActor.assumeIsolated { windowBox?.section != .files }
        return showingTerminals && catcher.contains(windowPoint) && catcher.bounds.width > 2
    }

    /// The Files button anywhere; a side of the Files area while it is shown.
    @MainActor
    private func filesTarget(at windowPoint: NSPoint, window: WindowState) -> FilesDropTarget? {
        if let button = filesButtonAnchor, Self.view(button, contains: windowPoint) {
            return .button
        }
        guard window.section == .files else { return nil }
        for (target, box) in filesSideAnchors {
            if let view = box.view, Self.view(view, contains: windowPoint) {
                return target
            }
        }
        return nil
    }

    private static func view(_ view: NSView, contains windowPoint: NSPoint) -> Bool {
        guard view.window != nil else { return false }
        return view.bounds.contains(view.convert(windowPoint, from: nil))
    }

    private func sidebarContains(_ windowPoint: NSPoint) -> Bool {
        guard let sidebarAnchor, sidebarAnchor.window != nil else { return false }
        let local = sidebarAnchor.convert(windowPoint, from: nil)
        return sidebarAnchor.bounds.contains(local)
    }

    private func blockUnderPointer(_ windowPoint: NSPoint) -> SidebarBlock? {
        for (block, box) in blockAnchors {
            guard let view = box.view, view.window != nil else { continue }
            let local = view.convert(windowPoint, from: nil)
            if view.bounds.contains(local) { return block }
        }
        return nil
    }

    /// Visible blocks sorted top to bottom, with their frames in sidebar coordinates.
    private func blockFrames() -> [(block: SidebarBlock, frame: CGRect)] {
        guard let sidebar = sidebarAnchor, sidebar.window != nil else { return [] }
        var rows: [(block: SidebarBlock, frame: CGRect)] = []
        for (block, box) in blockAnchors {
            guard let view = box.view, view.window != nil else { continue }
            rows.append((block, sidebar.convert(view.bounds, from: view)))
        }
        rows.sort { $0.frame.minY < $1.frame.minY }
        return rows
    }

    /// Index in the window's block order of the gap nearest to the pointer.
    @MainActor
    private func gapIndex(windowPoint: NSPoint, window: WindowState) -> Int {
        guard let sidebar = sidebarAnchor else { return window.blocks.count }
        let local = sidebar.convert(windowPoint, from: nil)
        let rows = blockFrames()
        guard !rows.isEmpty else { return window.blocks.count }
        var bestBlock = rows[0].block
        var bestAfter = false
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for row in rows {
            let top = abs(local.y - row.frame.minY)
            if top < bestDistance {
                bestDistance = top
                bestBlock = row.block
                bestAfter = false
            }
            let bottom = abs(local.y - row.frame.maxY)
            if bottom < bestDistance {
                bestDistance = bottom
                bestBlock = row.block
                bestAfter = true
            }
        }
        guard let index = window.blocks.firstIndex(of: bestBlock) else { return window.blocks.count }
        return bestAfter ? index + 1 : index
    }

    /// The row edge nearest to the pointer among `ids`, skipping the rows being dragged so the
    /// line never glues itself to the moving terminal. Nil when the block has no other rows.
    private func nearestRowEdge(windowPoint: NSPoint, ids: [UUID], skipping: Set<UUID>) -> (id: UUID, after: Bool)? {
        guard let sidebar = sidebarAnchor, sidebar.window != nil else { return nil }
        let local = sidebar.convert(windowPoint, from: nil)
        var best: (id: UUID, after: Bool)?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for id in ids where !skipping.contains(id) {
            guard let view = rowAnchors[id]?.view, view.window != nil else { continue }
            let frame = sidebar.convert(view.bounds, from: view)
            let top = abs(local.y - frame.minY)
            if top < bestDistance {
                bestDistance = top
                best = (id, false)
            }
            let bottom = abs(local.y - frame.maxY)
            if bottom < bestDistance {
                bestDistance = bottom
                best = (id, true)
            }
        }
        return best
    }

    /// A 3pt bar across the whole sidebar column, on the top or bottom edge of `view`.
    /// Coordinates grow downward.
    private static func sidebarLine(sidebar: NSView?, over view: NSView, after: Bool) -> (NSView, CGRect)? {
        guard let sidebar, sidebar.window != nil, view.window != nil else { return nil }
        let frame = sidebar.convert(view.bounds, from: view)
        let edge = after ? frame.maxY : frame.minY
        let y = min(max(edge - 1.5, 0), max(sidebar.bounds.height - 3, 0))
        let line = CGRect(x: 0, y: y, width: sidebar.bounds.width, height: 3)
        return (sidebar, line)
    }

    /// The landing half, slightly inset. Kept in the canvas's own coordinates.
    private static func previewZone(for edge: SplitEdge, in frame: CGRect) -> CGRect {
        let raw = PaneLayout.highlight(for: edge, in: frame)
        let inset = min(8, min(raw.width, raw.height) / 4)
        let padded = raw.insetBy(dx: inset, dy: inset)
        if padded.width >= 32, padded.height >= 32 {
            return padded
        }
        return raw
    }

    // MARK: Autoscroll

    /// The sidebar list is a plain scroll view and this is not a system drag session, so nudge
    /// it ourselves while the pointer sits near the top or bottom edge.
    private func updateAutoscroll(windowPoint: NSPoint) {
        guard let sidebar = sidebarAnchor, sidebar.window != nil, sidebarContains(windowPoint) else {
            stopAutoscroll()
            return
        }
        let local = sidebar.convert(windowPoint, from: nil)
        if local.y < Self.autoscrollBand {
            autoscrollStep = -6
        } else if sidebar.bounds.height - local.y < Self.autoscrollBand {
            autoscrollStep = 6
        } else {
            stopAutoscroll()
            return
        }
        guard autoscrollTimer == nil else { return }
        autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.autoscrollTick()
        }
    }

    private func autoscrollTick() {
        guard let scrollView = rowAnchors.values.compactMap({ $0.view?.enclosingScrollView }).first else { return }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        let maxY = max(0, (scrollView.documentView?.bounds.height ?? 0) - clip.bounds.height)
        origin.y = min(max(origin.y + autoscrollStep, 0), maxY)
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }
}

/// Drawn above the terminal while a tab is dragged. It does not take clicks.
/// AppKit y grows upward. `preview` is already in that space.
final class DropSessionOverlay: NSView {
    let chip = DragChipView()
    var preview: CGRect?
    var drawsInsertionLine = false
    var accent: NSColor = .controlAccentColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.zPosition = 20_000
        addSubview(chip)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let preview else { return }
        if drawsInsertionLine {
            let path = NSBezierPath(roundedRect: preview, xRadius: 1.5, yRadius: 1.5)
            accent.setFill()
            path.fill()
            return
        }
        let rect = preview.insetBy(dx: 1, dy: 1)
        guard rect.width > 2, rect.height > 2 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.28).setFill()
        path.fill()
        accent.withAlphaComponent(0.62).setFill()
        path.fill()
        accent.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    /// `zone` uses the canvas layout: origin at the top, y downward.
    func show(zone: CGRect?, canvasHeight: CGFloat, title: String, insertionLine: Bool = false) {
        drawsInsertionLine = insertionLine
        guard let zone else {
            preview = nil
            chip.isHidden = true
            needsDisplay = true
            return
        }
        let preview = CGRect(
            x: zone.minX,
            y: canvasHeight - zone.maxY,
            width: zone.width,
            height: zone.height
        )
        showDirect(preview: preview, title: title, insertionLine: insertionLine)
    }

    /// `preview` is already in this view's AppKit coordinates (origin at the bottom).
    func showDirect(preview: CGRect?, title: String, insertionLine: Bool) {
        drawsInsertionLine = insertionLine
        guard let preview else {
            self.preview = nil
            chip.isHidden = true
            needsDisplay = true
            return
        }
        self.preview = preview
        needsDisplay = true
        if insertionLine {
            chip.isHidden = true
            return
        }
        let size = DragChipView.size(for: title)
        let width = min(size.width, max(preview.width - 16, 44))
        let height = min(size.height, max(preview.height - 16, 22))
        chip.isHidden = false
        chip.title = title
        chip.frame = CGRect(
            x: preview.midX - width / 2,
            y: preview.midY - height / 2,
            width: width,
            height: height
        )
        chip.needsDisplay = true
    }
}

/// Anchor for the terminal area. Stays unflipped so SwiftUI places it on the canvas.
final class PaneDropCatcherView: NSView {
    weak var relay: CanvasDropRelay?
    let overlay = DropSessionOverlay()

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit {
        overlay.removeFromSuperview()
    }

    func contains(_ windowPoint: NSPoint) -> Bool {
        guard window != nil else { return false }
        return bounds.contains(convert(windowPoint, from: nil))
    }

    /// Canvas layout point: origin at the top, y downward.
    func swiftPoint(_ windowPoint: NSPoint) -> CGPoint {
        let local = convert(windowPoint, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    /// `zone` is inside `anchor`. Insertion lines come from the flipped sidebar and must
    /// be converted through AppKit; canvas previews stay in top-down layout space.
    func present(over anchor: NSView, zone: CGRect?, title: String, insertionLine: Bool = false) {
        guard anchor.bounds.width > 2, let window else { return }
        let host = window.contentView?.superview ?? window.contentView
        guard let host else { return }
        let frameInHost = anchor.convert(anchor.bounds, to: host)
        overlay.frame = frameInHost
        let aboveContent = host === window.contentView ? nil : window.contentView
        host.addSubview(overlay, positioned: .above, relativeTo: aboveContent)
        overlay.layer?.zPosition = 20_000
        if insertionLine {
            let preview: CGRect?
            if let zone {
                let inHost = anchor.convert(zone, to: host)
                preview = CGRect(
                    x: inHost.origin.x - frameInHost.origin.x,
                    y: inHost.origin.y - frameInHost.origin.y,
                    width: inHost.width,
                    height: inHost.height
                )
            } else {
                preview = nil
            }
            overlay.showDirect(preview: preview, title: title, insertionLine: true)
        } else {
            overlay.show(zone: zone, canvasHeight: anchor.bounds.height, title: title, insertionLine: false)
        }
        // Mouse tracking does not refresh the screen by itself, and the terminal
        // metal layer covers a preview left inside the SwiftUI view.
        overlay.display()
        CATransaction.flush()
    }

    func hide() {
        overlay.show(zone: nil, canvasHeight: bounds.height, title: "")
        overlay.removeFromSuperview()
        CATransaction.flush()
    }
}

struct PaneDropCatcher: NSViewRepresentable {
    var relay: CanvasDropRelay
    var chrome: WindowChrome

    func makeNSView(context: Context) -> PaneDropCatcherView {
        let view = PaneDropCatcherView()
        view.relay = relay
        applyColors(view)
        relay.catcher = view
        return view
    }

    func updateNSView(_ view: PaneDropCatcherView, context: Context) {
        view.relay = relay
        applyColors(view)
        relay.catcher = view
    }

    private func applyColors(_ view: PaneDropCatcherView) {
        view.overlay.accent = NSColor(chrome.accent)
        view.overlay.chip.surface = NSColor(chrome.elevated)
        view.overlay.chip.ink = NSColor(chrome.text)
    }
}

/// The floating name of the terminal being dragged. Painted in the window's own colors.
final class DragChipView: NSView {
    var title = ""
    var surface: NSColor = .windowBackgroundColor
    var ink: NSColor = .labelColor

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        surface.setFill()
        path.fill()
        ink.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: ink,
            .paragraphStyle: paragraph,
        ]
        let textRect = CGRect(x: 10, y: (bounds.height - 16) / 2, width: max(bounds.width - 32, 8), height: 16)
        (title as NSString).draw(in: textRect, withAttributes: attributes)

        let markRect = CGRect(x: bounds.width - 18, y: (bounds.height - 10) / 2, width: 10, height: 10)
        if let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil) {
            let mark = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)) ?? image
            mark.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 0.55)
        }
    }

    static func size(for title: String) -> CGSize {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        return CGSize(width: max(size.width + 42, 72), height: max(size.height + 12, 26))
    }
}

/// Right-click on a workspace title. Scroll events pass through to the sidebar.

/// Follows the pointer until mouse-up. A system drag session does not report the landing point reliably.
struct TabContextMenu {
    var showsDuplicate: Bool
    var canDetach: Bool
    var canRemove: Bool
    var canCreateArea: Bool
    var layouts: [(WorkspaceLayout, String)]
    var workspaces: [(UUID, String)]
    var duplicateRight: () -> Void
    var duplicateDown: () -> Void
    var merge: (WorkspaceLayout) -> Void
    var detach: () -> Void
    var move: (UUID) -> Void
    var remove: () -> Void
    var createArea: () -> Void
    var close: () -> Void
    var copyInfo: () -> Void
}

final class TabDragHandleView: NSView {
    var onClick: (Bool, Bool) -> Void = { _, _ in }
    var onHover: (Bool) -> Void = { _ in }
    var onBegan: () -> Void = {}
    var onMoved: (NSPoint) -> Void = { _ in }
    var onEnded: (NSPoint) -> Void = { _ in }
    var onClose: (() -> Void)?
    var onSecondaryClick: (() -> Void)?
    var prepareContextMenu: (() -> TabContextMenu)?
    private var contextMenuActions: TabContextMenu?
    /// The pane title sits in the transparent titlebar. Freeze window movement
    /// while the pointer is already over the title, or the window moves with the pane drag.
    var freezesWindow = false {
        didSet {
            guard oldValue != freezesWindow else { return }
            window?.invalidateCursorRects(for: self)
            installTrackingIfNeeded(force: true)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard freezesWindow, bounds.width > 1, bounds.height > 1 else { return }
        addCursorRect(bounds, cursor: .openHand)
    }

    private var trackedBounds: NSRect = .zero

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        installTrackingIfNeeded(force: false)
    }

    override func layout() {
        super.layout()
        installTrackingIfNeeded(force: false)
    }

    private func installTrackingIfNeeded(force: Bool) {
        if !force, bounds == trackedBounds {
            return
        }
        trackedBounds = bounds
        installTrackingAreas()
    }

    /// Rebuilding tracking areas on every SwiftUI update sends a false mouse-exit.
    private func installTrackingAreas() {
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        if freezesWindow {
            options.formUnion([.mouseMoved, .cursorUpdate])
        }
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        if freezesWindow {
            NSCursor.openHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    /// Titlebar dragging is decided when the button goes down. The header has to
    /// freeze the window while the pointer is already over it, not after mouseDown.
    private var pressLocksWindow = false

    private func freezeWindowMovement() {
        window?.isMovable = false
    }

    private func restoreWindowMovementIfPointerLeft() {
        guard !pressLocksWindow, let window else { return }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !bounds.contains(local) {
            window.isMovable = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard freezesWindow, !pressLocksWindow else { return }
        freezeWindowMovement()
    }

    override func mouseEntered(with event: NSEvent) {
        if freezesWindow {
            if !pressLocksWindow {
                freezeWindowMovement()
            }
            NSCursor.openHand.set()
            return
        }
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        if !freezesWindow {
            onHover(false)
            restoreWindowMovementIfPointerLeft()
            return
        }
        NSCursor.arrow.set()
        restoreWindowMovementIfPointerLeft()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let local = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if self.bounds.contains(local) {
                if !self.pressLocksWindow {
                    self.freezeWindowMovement()
                }
                NSCursor.openHand.set()
            } else {
                self.restoreWindowMovementIfPointerLeft()
            }
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// A drag may start in a window that is not key yet, such as pulling a terminal from a
    /// background window into the front one.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // The pane title sits in the transparent titlebar. Keep the window still
        // for the whole press so this drag merges panes instead of moving the window.
        pressLocksWindow = true
        window.isMovable = false
        defer {
            pressLocksWindow = false
            let local = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            window.isMovable = !self.bounds.contains(local)
        }
        let start = event.locationInWindow
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        var dragging = false
        var pushedHand = false
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: 3600,
            mode: .eventTracking
        ) { event, stop in
            guard let event else {
                if pushedHand {
                    NSCursor.pop()
                }
                stop.pointee = true
                return
            }
            window.isMovable = false
            let point = event.locationInWindow
            if event.type == .leftMouseUp {
                if dragging {
                    self.onEnded(point)
                } else {
                    self.onClick(command, shift)
                }
                if pushedHand {
                    NSCursor.pop()
                }
                stop.pointee = true
                return
            }
            if !dragging, hypot(point.x - start.x, point.y - start.y) >= 6 {
                dragging = true
                if self.freezesWindow {
                    NSCursor.closedHand.push()
                    pushedHand = true
                }
                self.onBegan()
            }
            if dragging {
                self.onMoved(point)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if freezesWindow {
            window?.isMovable = false
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if let onSecondaryClick {
            onSecondaryClick()
            restoreWindowMovementIfPointerLeft()
            return
        }
        if let prepareContextMenu {
            let actions = prepareContextMenu()
            contextMenuActions = actions
            NSMenu.popUpContextMenu(sidebarMenu(for: actions), with: event, for: self)
            restoreWindowMovementIfPointerLeft()
            return
        }
        guard onClose != nil else {
            super.rightMouseUp(with: event)
            return
        }
        let menu = NSMenu()
        menu.addItem(TerminalCloseMenu.item(action: #selector(closeFromMenu(_:)), target: self))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func sidebarMenu(for actions: TabContextMenu) -> NSMenu {
        let menu = NSMenu()
        let copyInfo = NSMenuItem(
            title: String(localized: "Copy Info"),
            action: #selector(copyInfoFromMenu(_:)),
            keyEquivalent: ""
        )
        copyInfo.target = self
        menu.addItem(copyInfo)
        menu.addItem(.separator())
        if actions.showsDuplicate {
            menu.addItem(shortcutItem(
                title: String(localized: "Duplicate Right"),
                chord: AppShortcuts.chord(for: .duplicateRight),
                action: #selector(duplicateRightFromMenu(_:))
            ))
            menu.addItem(shortcutItem(
                title: String(localized: "Duplicate Down"),
                chord: AppShortcuts.chord(for: .duplicateDown),
                action: #selector(duplicateDownFromMenu(_:))
            ))
            menu.addItem(.separator())
        }
        if actions.canCreateArea {
            let createArea = NSMenuItem(
                title: String(localized: "New Workspace"),
                action: #selector(createAreaFromMenu(_:)),
                keyEquivalent: ""
            )
            createArea.target = self
            menu.addItem(createArea)
        }
        if !actions.workspaces.isEmpty {
            let move = NSMenuItem(title: String(localized: "Move to Workspace"), action: nil, keyEquivalent: "")
            let choices = NSMenu()
            for (index, entry) in actions.workspaces.enumerated() {
                let item = NSMenuItem(title: entry.1, action: #selector(moveWorkspaceFromMenu(_:)), keyEquivalent: "")
                item.tag = index
                item.target = self
                choices.addItem(item)
            }
            move.submenu = choices
            menu.addItem(move)
        }
        let remove = NSMenuItem(title: String(localized: "Remove from Workspace"), action: #selector(removeWorkspaceFromMenu(_:)), keyEquivalent: "")
        remove.target = self
        remove.isEnabled = actions.canRemove
        menu.addItem(remove)
        menu.addItem(.separator())
        let merge = NSMenuItem(title: String(localized: "Merge Panels"), action: nil, keyEquivalent: "")
        let layouts = NSMenu()
        for (index, entry) in actions.layouts.enumerated() {
            let item = NSMenuItem(title: entry.1, action: #selector(mergeFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            layouts.addItem(item)
        }
        merge.submenu = layouts
        merge.isEnabled = !actions.layouts.isEmpty
        menu.addItem(merge)
        let detach = NSMenuItem(title: String(localized: "Separate into Independent Panels"), action: #selector(detachFromMenu(_:)), keyEquivalent: "")
        detach.target = self
        detach.isEnabled = actions.canDetach
        menu.addItem(detach)
        menu.addItem(.separator())
        menu.addItem(TerminalCloseMenu.item(action: #selector(closeFromMenu(_:)), target: self))
        return menu
    }

    private func shortcutItem(title: String, chord: KeyChord, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: chord.key)
        item.keyEquivalentModifierMask = chord.menuModifierMask
        item.target = self
        return item
    }

    @objc private func copyInfoFromMenu(_: Any?) {
        contextMenuActions?.copyInfo()
    }

    @objc private func duplicateRightFromMenu(_: Any?) {
        contextMenuActions?.duplicateRight()
    }

    @objc private func duplicateDownFromMenu(_: Any?) {
        contextMenuActions?.duplicateDown()
    }

    @objc private func mergeFromMenu(_ sender: NSMenuItem) {
        guard let actions = contextMenuActions, actions.layouts.indices.contains(sender.tag) else { return }
        actions.merge(actions.layouts[sender.tag].0)
    }

    @objc private func detachFromMenu(_: Any?) { contextMenuActions?.detach() }

    @objc private func removeWorkspaceFromMenu(_: Any?) { contextMenuActions?.remove() }

    @objc private func moveWorkspaceFromMenu(_ sender: NSMenuItem) {
        guard let actions = contextMenuActions, actions.workspaces.indices.contains(sender.tag) else { return }
        actions.move(actions.workspaces[sender.tag].0)
    }

    @objc private func createAreaFromMenu(_: Any?) {
        contextMenuActions?.createArea()
    }

    @objc private func closeFromMenu(_: Any?) {
        if let contextMenuActions {
            contextMenuActions.close()
            return
        }
        onClose?()
    }
}

struct TabDragHandle: NSViewRepresentable {
    var onClick: (Bool, Bool) -> Void
    var onHover: (Bool) -> Void = { _ in }
    var onBegan: () -> Void
    var onMoved: (NSPoint) -> Void
    var onEnded: (NSPoint) -> Void
    var onClose: (() -> Void)? = nil
    var onSecondaryClick: (() -> Void)? = nil
    var prepareContextMenu: (() -> TabContextMenu)? = nil
    var freezesWindow = false

    func makeNSView(context: Context) -> TabDragHandleView { TabDragHandleView() }

    func updateNSView(_ view: TabDragHandleView, context: Context) {
        view.onClick = onClick
        view.onHover = onHover
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
        view.onClose = onClose
        view.onSecondaryClick = onSecondaryClick
        view.prepareContextMenu = prepareContextMenu
        view.freezesWindow = freezesWindow
        view.window?.invalidateCursorRects(for: view)
    }
}

final class BoundsAnchorView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct BoundsAnchor: NSViewRepresentable {
    var onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> BoundsAnchorView { BoundsAnchorView() }

    func updateNSView(_ view: BoundsAnchorView, context: Context) {
        onResolve(view)
    }
}

struct SidebarBlockAnchor: NSViewRepresentable {
    var block: SidebarBlock
    var relay: CanvasDropRelay

    func makeNSView(context: Context) -> BoundsAnchorView { BoundsAnchorView() }

    func updateNSView(_ view: BoundsAnchorView, context: Context) {
        relay.blockAnchors[block] = AnchorBox(view)
    }
}

struct BlockDragHandle: NSViewRepresentable {
    var onBegan: () -> Void
    var onMoved: (NSPoint) -> Void
    var onEnded: (NSPoint) -> Void

    func makeNSView(context: Context) -> BlockDragHandleView {
        BlockDragHandleView()
    }

    func updateNSView(_ view: BlockDragHandleView, context: Context) {
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
    }
}

final class BlockDragHandleView: NSView {
    var onBegan: () -> Void = {}
    var onMoved: (NSPoint) -> Void = { _ in }
    var onEnded: (NSPoint) -> Void = { _ in }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
                    self.onEnded(event.locationInWindow)
                }
                stop.pointee = true
                return
            }
            let delta = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
            if !dragging, delta >= 4 {
                dragging = true
                self.onBegan()
            }
            if dragging {
                self.onMoved(event.locationInWindow)
            }
        }
    }
}

struct RowAnchor: NSViewRepresentable {
    var id: UUID
    var relay: CanvasDropRelay

    func makeNSView(context: Context) -> BoundsAnchorView { BoundsAnchorView() }

    func updateNSView(_ view: BoundsAnchorView, context: Context) {
        relay.rowAnchors[id] = AnchorBox(view)
    }
}


extension CanvasDropRelay {
    func sync(frames: [UUID: CGRect], model: AppModel, window: WindowState) {
        self.frames = frames
        self.modelBox = model
        self.windowBox = window
    }
}
