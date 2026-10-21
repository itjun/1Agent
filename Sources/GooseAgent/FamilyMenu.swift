import AppKit
import SwiftUI

/// Commands are independent of presentation. Existing AppKit menus remain command models,
/// so their targets, validation, shortcuts and submenus keep working without system chrome.
@MainActor
struct FamilyMenuItem {
    var title: String
    var enabled = true
    var checked = false
    var destructive = false
    var key = ""
    var modifiers: NSEvent.ModifierFlags = []
    var children: [FamilyMenuItem] = []
    var action: () -> Void = {}
    var isSeparator = false

    static var separator: Self { Self(title: "", enabled: false, isSeparator: true) }

    var shortcut: String {
        guard !key.isEmpty else { return "" }
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let special = ["\r": "↩", "\u{1b}": "⎋", "\t": "⇥", "\u{7f}": "⌫", " ": "␣",
                       "\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←", "\u{f703}": "→",
                       "\u{f728}": "⌦", "\u{f729}": "↖", "\u{f72b}": "↘", "\u{f72c}": "⇞", "\u{f72d}": "⇟"]
        let scalar = key.unicodeScalars.first?.value ?? 0
        let function = key.unicodeScalars.count == 1 && (0xf704...0xf726).contains(scalar) ? "F\(scalar - 0xf704 + 1)" : nil
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + (special[key] ?? function ?? key.uppercased())
    }

    static func commands(from menu: NSMenu) -> [Self] {
        menu.delegate?.menuWillOpen?(menu)
        menu.update()
        return menu.items.filter { !$0.isHidden }.map { item in
            if item.isSeparatorItem { return .separator }
            return Self(
                title: item.title, enabled: item.isEnabled, checked: item.state != .off,
                destructive: item.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil,
                key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask,
                children: item.submenu.map { commands(from: $0) } ?? [],
                action: {
                    if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
                }
            )
        }
    }
}

/// A native, non-key popup: terminal/editor focus never moves into a transient window.
/// All menu drawing uses WindowChrome, not the terminal theme or an NSVisualEffectView.
@MainActor
final class FamilyMenuPresenter {
    static let shared = FamilyMenuPresenter()
    private(set) var panels: [NSPanel] = []
    private var contents: [FamilyMenuContent] = []
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private weak var owner: NSWindow?
    private weak var trigger: NSView?
    private var onDismiss: (() -> Void)?
    private var activeDepth = 0
    private var typePrefix = ""
    private var lastTypeTime: TimeInterval = 0

    func show(_ menu: NSMenu, with event: NSEvent, for view: NSView) {
        show(FamilyMenuItem.commands(from: menu), with: event, for: view)
    }

    func show(_ items: [FamilyMenuItem], with event: NSEvent, for view: NSView) {
        guard let window = view.window else { return }
        show(items, at: window.convertPoint(toScreen: event.locationInWindow), owner: window)
    }

    func show(_ items: [FamilyMenuItem], below view: NSView, selection: Bool = false, onDismiss: @escaping () -> Void = {}) {
        guard let window = view.window else { return }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        show(items, at: NSPoint(x: rect.minX, y: rect.minY - 4), owner: window,
             minWidth: selection ? rect.width : 180, maxHeight: selection ? 280 : 640, above: rect.maxY + 4)
        trigger = view
        self.onDismiss = onDismiss
    }

    /// `point.x` is the horizontal center of the view; the card's top sits just under it.
    func show(_ items: [FamilyMenuItem], centeredBelow view: NSView) {
        guard let window = view.window else { return }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        show(items, at: NSPoint(x: rect.midX, y: rect.minY - 4), owner: window, centered: true)
        trigger = view
    }

    func show(_ items: [FamilyMenuItem], at point: NSPoint, owner: NSWindow,
              minWidth: CGFloat = 180, maxHeight: CGFloat = 640, above: CGFloat? = nil, centered: Bool = false) {
        dismiss()
        guard items.contains(where: { !$0.isSeparator }) else { return }
        self.owner = owner
        append(items, at: point, minWidth: minWidth, maxHeight: maxHeight, above: above, centered: centered)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard let self, !self.panels.isEmpty else { return event }
            if event.type == .keyDown { return self.handleKey(event) ? nil : event }
            return self.handlePointer(event) ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }

    func dismiss() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        close(after: -1)
        owner = nil
        trigger = nil
        typePrefix = ""
        let completion = onDismiss
        onDismiss = nil
        completion?()
    }

    /// Clicking the open trigger closes it; other outside clicks keep their normal action.
    @discardableResult
    func handlePointer(_ event: NSEvent) -> Bool {
        guard !panels.isEmpty, !panels.contains(where: { $0 === event.window }) else { return false }
        let clickedTrigger = event.type == .leftMouseDown && trigger.map {
            $0.window === event.window && $0.visibleRect.intersection($0.bounds).contains($0.convert(event.locationInWindow, from: nil))
        } == true
        dismiss()
        return clickedTrigger
    }

    private func close(after depth: Int) {
        while panels.count > depth + 1 {
            let panel = panels.removeLast()
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            contents.removeLast()
        }
        activeDepth = max(0, min(activeDepth, depth))
    }

    private func append(_ items: [FamilyMenuItem], at point: NSPoint, minWidth: CGFloat = 180,
                        maxHeight: CGFloat = 640, above: CGFloat? = nil, parentRect: NSRect? = nil, centered: Bool = false) {
        guard let owner else { return }
        let depth = panels.count
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? owner.screen ?? NSScreen.main
        let safe = (screen?.visibleFrame ?? owner.frame).insetBy(dx: 4, dy: 4)
        let chrome = WindowChrome.resolve(isDark: owner.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let content = FamilyMenuContent(items: items, chrome: chrome, minWidth: min(minWidth, safe.width), maxWidth: safe.width, maxHeight: min(maxHeight, safe.height))
        content.onHover = { [weak self] index in
            guard let self else { return }
            self.activeDepth = depth
            self.highlight(index, depth: depth, expand: true)
        }
        content.onPress = { [weak self] index in self?.activate(index, depth: depth) }
        let originX = centered ? point.x - content.frame.width / 2 : point.x
        var origin = NSPoint(x: originX, y: point.y - content.frame.height)
        if let parentRect, origin.x + content.frame.width > safe.maxX {
            origin.x = parentRect.minX - content.frame.width - 4
        }
        if origin.y < safe.minY, let above, above + content.frame.height <= safe.maxY { origin.y = above }
        origin.x = max(safe.minX, min(origin.x, safe.maxX - content.frame.width))
        origin.y = max(safe.minY, min(origin.y, safe.maxY - content.frame.height))
        let panel = FamilyPopupPanel(contentRect: NSRect(origin: origin, size: content.frame.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.appearance = owner.effectiveAppearance
        panel.contentView = content
        panel.setAccessibilityRole(.menu)
        panel.setAccessibilityLabel(String(localized: "Actions"))
        panels.append(panel)
        contents.append(content)
        owner.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        if let checked = items.firstIndex(where: { $0.checked && $0.enabled }) { content.select(checked) }
        NSAccessibility.post(element: content, notification: .created)
    }

    private func highlight(_ index: Int?, depth: Int, expand: Bool) {
        guard contents.indices.contains(depth) else { return }
        let content = contents[depth]
        if content.selected != index { close(after: depth) }
        content.select(index)
        guard expand, let index, content.items[index].enabled, !content.items[index].children.isEmpty,
              panels.count == depth + 1 else { return }
        let row = content.rows[index]
        let rect = panels[depth].convertToScreen(row.convert(row.bounds, to: nil))
        append(content.items[index].children, at: NSPoint(x: panels[depth].frame.maxX + 4, y: rect.maxY + 4), parentRect: panels[depth].frame)
    }

    private func activate(_ index: Int, depth: Int) {
        guard contents.indices.contains(depth), contents[depth].items.indices.contains(index) else { return }
        let item = contents[depth].items[index]
        guard item.enabled, !item.isSeparator else { return }
        if !item.children.isEmpty {
            highlight(index, depth: depth, expand: true)
            activeDepth = min(depth + 1, contents.count - 1)
            contents[activeDepth].select(contents[activeDepth].enabledIndices.first)
        } else {
            dismiss()
            item.action()
        }
    }

    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        guard contents.indices.contains(activeDepth) else { return false }
        let content = contents[activeDepth]
        let enabled = content.enabledIndices
        let current = content.selected.flatMap { enabled.firstIndex(of: $0) }
        switch event.keyCode {
        case 53, 48: dismiss() // Escape / Tab retain the owner's first responder.
        case 125, 126:
            guard !enabled.isEmpty else { return true }
            let next = event.keyCode == 125 ? ((current ?? -1) + 1) % enabled.count : ((current ?? 0) + enabled.count - 1) % enabled.count
            highlight(enabled[next], depth: activeDepth, expand: false)
        case 115: highlight(enabled.first, depth: activeDepth, expand: false)
        case 119: highlight(enabled.last, depth: activeDepth, expand: false)
        case 124:
            if let selected = content.selected, !content.items[selected].children.isEmpty { activate(selected, depth: activeDepth) }
        case 123:
            if activeDepth > 0 { close(after: activeDepth - 1) }
        case 36, 76, 49:
            if let selected = content.selected { activate(selected, depth: activeDepth) }
        default:
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if !modifiers.intersection([.command, .control, .option]).isEmpty {
                if let match = content.items.firstIndex(where: { $0.enabled && !$0.key.isEmpty && $0.key.lowercased() == characters && $0.modifiers.intersection([.command, .option, .control, .shift]) == modifiers }) {
                    activate(match, depth: activeDepth)
                } else { dismiss(); return false }
            } else if !characters.isEmpty {
                if event.timestamp - lastTypeTime > 0.7 { typePrefix = "" }
                typePrefix += characters
                lastTypeTime = event.timestamp
                if let match = enabled.first(where: { content.items[$0].title.localizedLowercase.hasPrefix(typePrefix) }) {
                    highlight(match, depth: activeDepth, expand: false)
                }
            }
        }
        return true
    }
}

private final class FamilyPopupPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class FamilyMenuContent: NSView {
    let items: [FamilyMenuItem]
    private var chrome: WindowChrome
    var rows: [FamilyMenuRow] = []
    var selected: Int?
    var onHover: (Int?) -> Void = { _ in }
    var onPress: (Int) -> Void = { _ in }
    var enabledIndices: [Int] { items.indices.filter { items[$0].enabled && !items[$0].isSeparator } }

    init(items: [FamilyMenuItem], chrome: WindowChrome, minWidth: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat) {
        self.items = items
        self.chrome = chrome
        let width = min(maxWidth, max(minWidth, min(420, items.map { item in
            (item.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width +
            (item.shortcut as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width + 68
        }.max() ?? minWidth)))
        let height = items.reduce(CGFloat(8)) { $0 + ($1.isSeparator ? 9 : 32) }
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(width), height: min(height, maxHeight)))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(chrome.background).cgColor
        layer?.borderColor = NSColor(chrome.hairline).cgColor
        layer?.borderWidth = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
        let scroll = NSScrollView(frame: bounds.insetBy(dx: 4, dy: 4))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = height > maxHeight
        scroll.autohidesScrollers = true
        let document = FamilyMenuDocument(frame: NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: height - 8))
        var y: CGFloat = 0
        for (index, item) in items.enumerated() {
            let row = FamilyMenuRow(item: item, chrome: chrome)
            row.frame = NSRect(x: 0, y: y, width: document.frame.width, height: item.isSeparator ? 9 : 32)
            row.onHover = { [weak self] in self?.onHover(index) }
            row.onPress = { [weak self] in self?.onPress(index) }
            document.addSubview(row)
            rows.append(row)
            y += row.frame.height
        }
        scroll.documentView = document
        addSubview(scroll)
        setAccessibilityChildren(rows.filter { !$0.item.isSeparator })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard window != nil else { return }
        chrome = WindowChrome.resolve(isDark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        layer?.backgroundColor = NSColor(chrome.background).cgColor
        layer?.borderColor = NSColor(chrome.hairline).cgColor
        for row in rows { row.chrome = chrome }
        needsDisplay = true
    }

    func select(_ index: Int?) {
        selected = index
        for (position, row) in rows.enumerated() { row.menuHighlighted = position == index }
        setAccessibilitySelectedChildren(index.map { [rows[$0]] } ?? [])
        if let index {
            rows[index].scrollToVisible(rows[index].bounds)
            NSAccessibility.post(element: rows[index], notification: .focusedUIElementChanged)
        }
    }
}

private final class FamilyMenuDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class FamilyMenuRow: NSButton {
    let item: FamilyMenuItem
    var chrome: WindowChrome { didSet { needsDisplay = true } }
    var menuHighlighted = false { didSet { needsDisplay = true } }
    var onHover: () -> Void = {}
    var onPress: () -> Void = {}

    init(item: FamilyMenuItem, chrome: WindowChrome) {
        self.item = item
        self.chrome = chrome
        super.init(frame: .zero)
        title = item.title
        isBordered = false
        isEnabled = item.enabled
        target = self
        action = #selector(pressed)
        setAccessibilityElement(!item.isSeparator)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
        if item.checked { setAccessibilityValue(1) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func pressed() { onPress() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        if !item.isSeparator { addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)) }
    }
    override func mouseEntered(with event: NSEvent) { onHover() }

    override func draw(_ dirtyRect: NSRect) {
        if item.isSeparator {
            NSColor(chrome.hairline).setFill()
            NSRect(x: 4, y: 4, width: bounds.width - 8, height: 1).fill()
            return
        }
        if item.checked || (menuHighlighted && item.enabled) {
            NSColor(item.checked ? chrome.accentFill : chrome.elevated).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        let color = NSColor(item.destructive ? chrome.danger : item.checked ? chrome.accent : chrome.text).withAlphaComponent(item.enabled ? 1 : 0.4)
        let secondary = NSColor(chrome.secondary).withAlphaComponent(item.enabled ? 1 : 0.4)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let rightWidth: CGFloat = !item.children.isEmpty || item.checked ? 20 : (item.shortcut as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        (item.title as NSString).draw(in: NSRect(x: 8, y: 7, width: bounds.width - 24 - rightWidth, height: 19), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: color, .paragraphStyle: paragraph])
        if !item.children.isEmpty || item.checked {
            let symbol = !item.children.isEmpty ? "chevron.right" : "checkmark"
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                .applying(.init(paletteColors: [color]))
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            image?.draw(in: NSRect(x: bounds.width - 24, y: 8, width: 16, height: 16))
        } else if !item.shortcut.isEmpty {
            (item.shortcut as NSString).draw(in: NSRect(x: bounds.width - 8 - rightWidth, y: 8, width: rightWidth, height: 17), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: secondary])
        }
    }
}
