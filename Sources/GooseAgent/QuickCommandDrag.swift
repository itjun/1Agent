import AppKit
import SwiftUI

/// Like the sidebar's pane drags, commands stay inside native event tracking.
/// 主机指令保持确认执行；公共文本可复制给主机或走终端粘贴保护。
struct QuickCommandDragHandle: NSViewRepresentable {
    let item: QuickCommand
    let chrome: WindowChrome
    let onClick: () -> Void
    let onDoubleClick: () -> Void
    let onDragStart: () -> Void

    func makeNSView(context: Context) -> QuickCommandDragHandleView { QuickCommandDragHandleView() }
    func updateNSView(_ view: QuickCommandDragHandleView, context: Context) {
        view.commandID = item.id
        view.section = item.section
        view.title = item.alias
        view.chrome = chrome
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onDragStart = onDragStart
    }
}

final class QuickCommandDragHandleView: NSView {
    var commandID: UUID?
    var section = 0
    var title = ""
    var chrome = WindowChrome(isDark: false)
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onDragStart: () -> Void = {}
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.intersection(visibleRect).contains(convert(point, from: superview)) ? self : nil
    }
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }

    static func terminal(at point: NSPoint, in window: NSWindow) -> SSHTerminalNSView? {
        guard let content = window.contentView else { return nil }
        let location = content.superview?.convert(point, from: nil) ?? point
        var view = content.hitTest(location)
        while let current = view {
            if let terminal = current as? SSHTerminalNSView { return terminal }
            view = current.superview
        }
        return nil
    }

    static func reorderTarget(at point: NSPoint, in window: NSWindow, sourceID: UUID, section: Int) -> QuickCommandReorderTargetView? {
        func find(in view: NSView) -> QuickCommandReorderTargetView? {
            guard !view.isHiddenOrHasHiddenAncestor else { return nil }
            if let row = view as? QuickCommandReorderTargetView, row.commandID != sourceID, row.section == section,
               row.bounds.intersection(row.visibleRect).contains(row.convert(point, from: nil)) { return row }
            for child in view.subviews {
                if let row = find(in: child) { return row }
            }
            return nil
        }
        return window.contentView.flatMap { find(in: $0) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, let id = commandID else { return }
        let wasMovable = window.isMovable
        window.isMovable = false
        let start = event.locationInWindow
        let clickCount = event.clickCount
        var dragging = false
        var target: SSHTerminalNSView?
        var reorderTarget: QuickCommandReorderTargetView?
        var copyTarget: QuickCommandCopyTargetView?
        var preview: NSPanel?
        defer {
            target?.highlightQuickCommand(nil)
            reorderTarget?.insertionAfter = nil
            copyTarget?.isHighlighted = false
            preview?.close()
            NSCursor.arrow.set()
            window.isMovable = wasMovable
        }
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown], timeout: 3600, mode: .eventTracking) { event, stop in
            guard let event else { stop.pointee = true; return }
            if event.type == .keyDown {
                if event.keyCode == 53 { stop.pointee = true }
                return
            }
            if event.type == .leftMouseUp {
                if dragging {
                    // Re-resolve at release; a pane or its command can change mid-drag.
                    if let destination = QuickCommandCopyTargetView.target(at: event.locationInWindow, in: window, commandID: id) {
                        destination.onCopy(id)
                    } else if let row = Self.reorderTarget(at: event.locationInWindow, in: window, sourceID: id, section: self.section) {
                        row.move(id, after: row.isAfter(event.locationInWindow))
                    } else {
                        Self.terminal(at: event.locationInWindow, in: window)?.dropQuickCommand(id)
                    }
                } else if clickCount == 2 {
                    self.onDoubleClick()
                } else if clickCount == 1 {
                    self.onClick()
                }
                stop.pointee = true
                return
            }
            if !dragging, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 6 {
                dragging = true
                self.onDragStart() // 拖拽只更新选择，不能在拖动途中打开卡片并改变终端位置。
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: min(self.bounds.width, 260), height: 42),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.level = .popUpMenu
                panel.ignoresMouseEvents = true
                panel.contentView = NSHostingView(rootView:
                    HStack { Image(systemName: "terminal"); Text(verbatim: self.title).lineLimit(1); Spacer(minLength: 0) }
                        .font(Theme.Font.row).foregroundStyle(self.chrome.text).padding(10)
                        .background(self.chrome.elevated).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control)))
                preview = panel
            }
            guard dragging else { return }
            let destination = QuickCommandCopyTargetView.target(at: event.locationInWindow, in: window, commandID: id)
            if destination !== copyTarget { copyTarget?.isHighlighted = false; copyTarget = destination }
            copyTarget?.isHighlighted = true
            let row = destination == nil ? Self.reorderTarget(at: event.locationInWindow, in: window, sourceID: id, section: self.section) : nil
            if row !== reorderTarget { reorderTarget?.insertionAfter = nil; reorderTarget = row }
            row?.insertionAfter = row?.isAfter(event.locationInWindow)
            let candidate = row == nil && destination == nil ? Self.terminal(at: event.locationInWindow, in: window) : nil
            if candidate !== target { target?.highlightQuickCommand(nil); target = candidate }
            let accepted = target?.acceptsQuickCommand(id) == true
            target?.highlightQuickCommand(accepted ? id : nil)
            let screen = window.convertPoint(toScreen: event.locationInWindow)
            preview?.setFrameOrigin(NSPoint(x: screen.x + 12, y: screen.y - 36))
            preview?.orderFrontRegardless()
            (row != nil ? NSCursor.closedHand : accepted || destination != nil ? NSCursor.dragCopy : NSCursor.operationNotAllowed).set()
        }
    }
}

/// A transparent native destination covers the whole row, including its padding.
/// It draws feedback without changing SwiftUI row identities during event tracking.
struct QuickCommandReorderTarget: NSViewRepresentable {
    let item: QuickCommand
    let chrome: WindowChrome
    let onMove: (UUID, UUID, Bool) -> Void
    func makeNSView(context: Context) -> QuickCommandReorderTargetView { QuickCommandReorderTargetView() }
    func updateNSView(_ view: QuickCommandReorderTargetView, context: Context) {
        view.commandID = item.id
        view.section = item.section
        view.accent = NSColor(chrome.accent)
        view.onMove = onMove
    }
}

final class QuickCommandReorderTargetView: NSView {
    var commandID: UUID?
    var section = 0
    var accent = NSColor.controlAccentColor
    var onMove: (UUID, UUID, Bool) -> Void = { _, _, _ in }
    var insertionAfter: Bool? { didSet { if insertionAfter != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func isAfter(_ point: NSPoint) -> Bool { convert(point, from: nil).y >= bounds.midY }
    func move(_ sourceID: UUID, after: Bool) {
        guard let commandID, commandID != sourceID else { return }
        onMove(sourceID, commandID, after)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let insertionAfter else { return }
        accent.setFill()
        NSRect(x: bounds.minX, y: insertionAfter ? bounds.maxY - 2 : bounds.minY, width: bounds.width, height: 2).fill()
    }
}

/// 主机行的公共文本接收区只落盘副本，不连接主机或执行命令。
struct QuickCommandCopyTarget: NSViewRepresentable {
    let chrome: WindowChrome
    let onCopy: (UUID) -> Void
    @Environment(\.isEnabled) private var isEnabled
    func makeNSView(context: Context) -> QuickCommandCopyTargetView { QuickCommandCopyTargetView() }
    func updateNSView(_ view: QuickCommandCopyTargetView, context: Context) {
        view.accent = NSColor(chrome.accent)
        view.isEnabled = isEnabled
        view.onCopy = onCopy
    }
}

final class QuickCommandCopyTargetView: NSView {
    var onCopy: (UUID) -> Void = { _ in }
    var isEnabled = true
    var accent = NSColor.controlAccentColor
    var isHighlighted = false { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    static func target(at point: NSPoint, in window: NSWindow, commandID: UUID) -> QuickCommandCopyTargetView? {
        guard let command = QuickCommandStore.shared.commands.first(where: { $0.id == commandID }),
              command.scope == .all, !command.needsRepair else { return nil }
        func find(in view: NSView) -> QuickCommandCopyTargetView? {
            guard !view.isHiddenOrHasHiddenAncestor else { return nil }
            if let target = view as? QuickCommandCopyTargetView, target.isEnabled,
               target.bounds.intersection(target.visibleRect).contains(target.convert(point, from: nil)) { return target }
            for child in view.subviews { if let target = find(in: child) { return target } }
            return nil
        }
        return window.contentView.flatMap { find(in: $0) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        accent.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.Radius.control, yRadius: Theme.Radius.control).fill()
    }
}
