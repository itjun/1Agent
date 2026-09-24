import AppKit
import SwiftUI

enum SidebarContextMenuItem {
    case item(title: String, action: () -> Void, isEnabled: Bool = true)
    case destructive(title: String, action: () -> Void)
    case separator
}

/// AppKit drag/drop host. SwiftUI `.onDrag` on macOS does not start when a
/// `Button` (or even `onTapGesture`) owns mouseDown; a few points of movement
/// here begin an `NSDraggingSession` instead.
struct SidebarRowDragHost: NSViewRepresentable {
    let entryID: String
    let pasteboardType: NSPasteboard.PasteboardType
    let menuItems: [SidebarContextMenuItem]
    let onClick: () -> Void
    var onDoubleClick: (() -> Void)?
    var allowsDrag = true
    var onDragStart: ((String) -> Void)?
    var onDragEnd: (() -> Void)?
    var onDropHover: ((Bool) -> Void)?
    var onHoverExit: (() -> Void)?
    var onDrop: ((String, Bool) -> Void)?
    var onFolderDrop: (([String]) -> Void)?

    func makeNSView(context: Context) -> SidebarRowDragNSView {
        // Non-zero seed frame: a SwiftUI overlay NSView that starts at .zero
        // can stay 0-size, so clicks and drags never arrive (#42).
        let view = SidebarRowDragNSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.pasteboardType = pasteboardType
        view.allowsDrag = allowsDrag
        view.onFolderDrop = onFolderDrop
        view.registerForDraggedTypes(Self.draggedTypes(pasteboardType, folders: onFolderDrop != nil, allowsDrag: allowsDrag))
        return view
    }

    func updateNSView(_ view: SidebarRowDragNSView, context: Context) {
        let folders = onFolderDrop != nil
        if view.pasteboardType != pasteboardType || view.allowsDrag != allowsDrag || (view.onFolderDrop != nil) != folders {
            view.unregisterDraggedTypes()
            view.pasteboardType = pasteboardType
            view.registerForDraggedTypes(Self.draggedTypes(pasteboardType, folders: folders, allowsDrag: allowsDrag))
        }
        view.entryID = entryID
        view.menuItems = menuItems
        view.allowsDrag = allowsDrag
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
        view.onDropHover = onDropHover
        view.onHoverExit = onHoverExit
        view.onDrop = onDrop
        view.onFolderDrop = onFolderDrop
    }

    private static func draggedTypes(
        _ pasteboardType: NSPasteboard.PasteboardType,
        folders: Bool,
        allowsDrag: Bool
    ) -> [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = []
        if allowsDrag { types.append(pasteboardType) }
        if folders { types.append(.fileURL) }
        return types
    }
}

struct SpaceRowDragHost: View {
    let entryID: String
    let label: String
    let onClick: () -> Void
    let onRename: () -> Void
    let onCopyPath: (() -> Void)?
    let onCopyGooseAgentLocation: () -> Void
    let onClose: () -> Void
    let onDragStart: (String) -> Void
    let onDragEnd: () -> Void
    let onDropHover: (Bool) -> Void
    let onHoverExit: () -> Void
    let onDrop: (String, Bool) -> Void
    var onFolderDrop: (([String]) -> Void)?

    var body: some View {
        SidebarRowDragHost(
            entryID: entryID,
            pasteboardType: SidebarRowDragNSView.spacePasteboardType,
            menuItems: [
                .item(title: String(localized: "Rename Space…"), action: onRename),
                .item(
                    title: String(localized: "Copy Space Path"),
                    action: { onCopyPath?() },
                    isEnabled: onCopyPath != nil
                ),
                .item(
                    title: String(localized: "Copy Goose Agent Space Location"),
                    action: onCopyGooseAgentLocation
                ),
                .separator,
                .destructive(title: String(localized: "Close Space \"\(label)\"…"), action: onClose),
            ],
            onClick: onClick,
            onDoubleClick: onRename,
            onDragStart: onDragStart,
            onDragEnd: onDragEnd,
            onDropHover: onDropHover,
            onHoverExit: onHoverExit,
            onDrop: onDrop,
            onFolderDrop: onFolderDrop
        )
    }
}

struct AgentRowDragHost: View {
    var allowsDrag = true
    let entryID: String
    let onClick: () -> Void
    let onRename: () -> Void
    let onClose: () -> Void
    let onDragStart: (String) -> Void
    let onDragEnd: () -> Void
    let onDropHover: (Bool) -> Void
    let onHoverExit: () -> Void
    let onDrop: (String, Bool) -> Void

    var body: some View {
        SidebarRowDragHost(
            entryID: entryID,
            pasteboardType: SidebarRowDragNSView.sessionPasteboardType,
            menuItems: [
                .item(title: String(localized: "Rename Agent…"), action: onRename),
                .separator,
                .destructive(title: String(localized: "Close Agent…"), action: onClose),
            ],
            onClick: onClick,
            onDoubleClick: onRename,
            allowsDrag: allowsDrag,
            onDragStart: onDragStart,
            onDragEnd: onDragEnd,
            onDropHover: onDropHover,
            onHoverExit: onHoverExit,
            onDrop: onDrop
        )
    }
}

struct TerminalRowDragHost: View {
    var allowsDrag = true
    let entryID: String
    let onClick: () -> Void
    let onRename: () -> Void
    let onClose: () -> Void
    let onDragStart: (String) -> Void
    let onDragEnd: () -> Void
    let onDropHover: (Bool) -> Void
    let onHoverExit: () -> Void
    let onDrop: (String, Bool) -> Void

    var body: some View {
        SidebarRowDragHost(
            entryID: entryID,
            pasteboardType: SidebarRowDragNSView.sessionPasteboardType,
            menuItems: [
                .item(title: String(localized: "Rename Terminal…"), action: onRename),
                .separator,
                .destructive(title: String(localized: "Close Terminal…"), action: onClose),
            ],
            onClick: onClick,
            onDoubleClick: onRename,
            allowsDrag: allowsDrag,
            onDragStart: onDragStart,
            onDragEnd: onDragEnd,
            onDropHover: onDropHover,
            onHoverExit: onHoverExit,
            onDrop: onDrop
        )
    }
}

final class SidebarRowDragNSView: NSView, NSDraggingSource {
    static let spacePasteboardType = NSPasteboard.PasteboardType("dev.eachann.gooseagent.space-id")
    static let sessionPasteboardType = NSPasteboard.PasteboardType("dev.eachann.gooseagent.session-id")

    var pasteboardType = SidebarRowDragNSView.spacePasteboardType
    var entryID = ""
    var menuItems: [SidebarContextMenuItem] = []
    var allowsDrag = true
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragStart: ((String) -> Void)?
    var onDragEnd: (() -> Void)?
    var onDropHover: ((Bool) -> Void)?
    var onHoverExit: (() -> Void)?
    var onDrop: ((String, Bool) -> Void)?
    var onFolderDrop: (([String]) -> Void)?

    private var downEvent: NSEvent?
    private var didDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Explicit hit-test so a 0-size overlay cannot silently drop clicks.
        // AppKit passes the point in the superview's coordinate space.
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard allowsDrag, let down = downEvent, !didDrag else { return }
        let start = convert(down.locationInWindow, from: nil)
        let now = convert(event.locationInWindow, from: nil)
        guard hypot(now.x - start.x, now.y - start.y) >= 4 else { return }
        didDrag = true
        let preview = dragPreviewImage()
        onDragStart?(entryID)
        let pbItem = NSPasteboardItem()
        pbItem.setString(entryID, forType: pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pbItem)
        item.setDraggingFrame(bounds, contents: preview)
        beginDraggingSession(with: [item], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag {
            // Native clickCount on mouse-up (Apple NSEvent.clickCount), not a
            // home-grown streak. First up is 1 (select); second is 2 (rename).
            if event.clickCount >= 2, let onDoubleClick {
                onDoubleClick()
            } else {
                onClick?()
            }
        }
        downEvent = nil
        didDrag = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for item in menuItems {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case .item(let title, let action, let isEnabled):
                let menuItem = menu.addItem(withTitle: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.isEnabled = isEnabled
                menuItem.representedObject = MenuAction(action)
            case .destructive(let title, let action):
                let menuItem = menu.addItem(withTitle: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = MenuAction(action)
            }
        }
        return menu
    }

    @objc private func runMenuItem(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onDragEnd?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if draggedID(from: sender) != nil {
            onDropHover?(placeAfter(sender))
            return .move
        }
        return folderPaths(from: sender) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if draggedID(from: sender) != nil {
            onDropHover?(placeAfter(sender))
            return .move
        }
        return folderPaths(from: sender) == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHoverExit?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        draggedID(from: sender) != nil || folderPaths(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let sourceID = draggedID(from: sender) {
            onDrop?(sourceID, placeAfter(sender))
            return true
        }
        guard let paths = folderPaths(from: sender) else { return false }
        onFolderDrop?(paths)
        return true
    }

    /// Snapshot the SwiftUI row under this transparent overlay. Taken before
    /// `onDragStart` dims the source so the drag image stays opaque.
    private func dragPreviewImage() -> NSImage? {
        guard let content = window?.contentView else { return nil }
        let rect = convert(bounds, to: content)
        guard !rect.isEmpty, let rep = content.bitmapImageRepForCachingDisplay(in: rect) else {
            return nil
        }
        content.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    private func placeAfter(_ sender: NSDraggingInfo) -> Bool {
        convert(sender.draggingLocation, from: nil).y > bounds.midY
    }

    private func draggedID(from sender: NSDraggingInfo) -> String? {
        guard allowsDrag else { return nil }
        return sender.draggingPasteboard.string(forType: pasteboardType)
    }

    private func folderPaths(from sender: NSDraggingInfo) -> [String]? {
        guard onFolderDrop != nil else { return nil }
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        let dirs = SidebarFolderDrop.directoryPaths(from: urls)
        return dirs.isEmpty ? nil : dirs
    }
}

enum SidebarFolderDrop {
    static func directoryPaths(from urls: [URL]) -> [String] {
        urls.compactMap { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? url.path : nil
        }
    }
}

/// NSMenu `representedObject` must be an object; a closure is not.
private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}
