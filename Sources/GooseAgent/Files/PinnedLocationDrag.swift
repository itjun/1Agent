import AppKit
import SwiftUI

/// Native pointer tracking makes an explicit mouse-up distinct from Escape or an interrupted drag.
@MainActor
final class PinnedLocationDragArea: NSObject, ObservableObject {
    private static let areas = NSHashTable<PinnedLocationDragArea>.weakObjects()
    let locations: PinnedLocations
    weak var sidebar: NSView?
    weak var list: NSView?
    var rows: [UUID: NSView] = [:]
    @Published private(set) var insertionBefore: UUID?
    @Published private(set) var targeted = false

    enum Landing {
        case keep
        case reorder(PinnedLocationDragArea, UUID?)
        case unpin
    }

    init(locations: PinnedLocations = .shared) {
        self.locations = locations
        super.init()
        Self.areas.add(self)
    }

    private static func frame(_ view: NSView?) -> CGRect? {
        guard let view, let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor else { return nil }
        let visible = view.bounds.intersection(view.visibleRect)
        guard !visible.isEmpty else { return nil }
        return window.convertToScreen(view.convert(visible, to: nil))
    }

    func landing(at point: NSPoint) -> Landing {
        // A disappearing/collapsed source must never turn an unknown drop into removal.
        guard Self.frame(sidebar) != nil else { return .keep }
        for window in NSApp.orderedWindows {
            for area in Self.areas.allObjects where area.sidebar?.window === window {
                guard Self.frame(area.sidebar)?.contains(point) == true else { continue }
                guard Self.frame(area.list)?.contains(point) == true else { return .keep }
                for item in area.locations.items {
                    if let row = Self.frame(area.rows[item.id]), point.y >= row.midY {
                        return .reorder(area, item.id)
                    }
                }
                return .reorder(area, nil)
            }
        }
        return .unpin
    }

    @discardableResult
    func moved(to point: NSPoint) -> Bool {
        cancel()
        switch landing(at: point) {
        case .reorder(let area, let before):
            area.insertionBefore = before
            area.targeted = true
            return false
        case .unpin: return true
        case .keep: return false
        }
    }

    func finish(_ id: UUID, at point: NSPoint) {
        let destination = landing(at: point)
        cancel()
        switch destination {
        case .unpin: locations.remove(id)
        case .reorder(let area, let before):
            // All production windows share the same pins; do not remove on a cross-window drop.
            if area.locations === locations { locations.move(id, before: before) }
        case .keep: break
        }
    }

    func cancel() {
        for area in Self.areas.allObjects {
            if area.insertionBefore != nil { area.insertionBefore = nil }
            if area.targeted { area.targeted = false }
        }
    }
}

struct PinnedLocationDragHandle: NSViewRepresentable {
    let item: PinnedLocation
    let title: String
    let path: String
    let area: PinnedLocationDragArea
    let chrome: WindowChrome
    let open: () -> Void

    func makeNSView(context: Context) -> PinnedLocationDragHandleView { PinnedLocationDragHandleView() }

    func updateNSView(_ view: PinnedLocationDragHandleView, context: Context) {
        view.itemID = item.id
        view.title = title
        view.path = path
        view.area = area
        view.chrome = chrome
        view.open = open
        area.rows[item.id] = view
    }

    static func dismantleNSView(_ view: PinnedLocationDragHandleView, coordinator: ()) {
        if let id = view.itemID, view.area?.rows[id] === view { view.area?.rows.removeValue(forKey: id) }
    }
}

final class PinnedLocationDragHandleView: NSView {
    var itemID: UUID?
    var title = ""
    var path = ""
    weak var area: PinnedLocationDragArea?
    var chrome = WindowChrome(isDark: false)
    var open: () -> Void = {}

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.intersection(visibleRect).contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, let area, let id = itemID else { return }
        let wasMovable = window.isMovable
        window.isMovable = false
        let start = event.locationInWindow
        var dragging = false
        var preview: NSPanel?
        var previewView: PinnedLocationDragPreview?
        defer {
            preview?.close()
            area.cancel()
            NSCursor.arrow.set()
            window.isMovable = wasMovable
        }
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown], timeout: 3600, mode: .eventTracking) { event, stop in
            guard let event else { stop.pointee = true; return }
            if event.type == .keyDown {
                if event.keyCode == 53 { stop.pointee = true }
                return
            }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            if event.type == .leftMouseUp {
                if dragging { area.finish(id, at: point) }
                else { self.open() }
                stop.pointee = true
                return
            }
            if !dragging, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 6 {
                dragging = true
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: self.bounds.width, height: 48),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.level = .popUpMenu
                panel.ignoresMouseEvents = true
                let content = PinnedLocationDragPreview(frame: NSRect(origin: .zero, size: panel.frame.size))
                content.title = self.title
                content.path = self.path
                content.chrome = self.chrome
                panel.contentView = content
                preview = panel
                previewView = content
            }
            guard dragging else { return }
            let removing = area.moved(to: point)
            previewView?.removing = removing
            preview?.setFrameOrigin(NSPoint(x: point.x + 12, y: point.y - 36))
            preview?.orderFrontRegardless()
            previewView?.displayIfNeeded()
            (removing ? NSCursor.disappearingItem : NSCursor.closedHand).set()
        }
    }
}

private final class PinnedLocationDragPreview: NSView {
    var title = ""
    var path = ""
    var chrome = WindowChrome(isDark: false)
    var removing = false { didSet { if oldValue != removing { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let foreground = NSColor(removing ? chrome.accent : chrome.text)
        let secondary = NSColor(removing ? chrome.accent : chrome.secondary)
        NSColor(removing ? chrome.accentFill : chrome.background).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        if removing {
            foreground.withAlphaComponent(0.45).setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            outline.lineWidth = 1
            outline.stroke()
        }
        let symbol = NSImage(systemSymbolName: removing ? "folder.badge.minus" : "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [foreground]))
        symbol?.draw(in: NSRect(x: 10, y: 16, width: 18, height: 18))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        (title as NSString).draw(in: NSRect(x: 38, y: 26, width: bounds.width - 48, height: 18),
            withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: foreground, .paragraphStyle: paragraph])
        let subtitle = removing ? String(localized: "Release to Unpin") : path
        (subtitle as NSString).draw(in: NSRect(x: 38, y: 8, width: bounds.width - 48, height: 16),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: removing ? .medium : .regular), .foregroundColor: secondary, .paragraphStyle: paragraph])
    }
}
