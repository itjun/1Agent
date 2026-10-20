import AppKit
import SwiftUI

/// All app confirmations share the 1Panel dialog surface and preserve their existing response
/// codes. This is an app-owned dialog, not a styled NSAlert or a native sheet.
@MainActor
final class FamilyAlert {
    var messageText = ""
    var informativeText = ""
    var alertStyle: NSAlert.Style = .informational
    var accessoryView: NSView?
    var initialFirstResponder: NSView?
    private(set) var buttons: [FamilyNativeButton] = []
    private(set) var presentation: FamilyModalPresentation?
    private var completion: ((NSApplication.ModalResponse) -> Void)?
    private var response: NSApplication.ModalResponse = .abort
    private var runningModal = false
    private var finished = false
    private static var queue: [(FamilyAlert, NSWindow?, (NSApplication.ModalResponse) -> Void)] = []
    private static var active: FamilyAlert?

    @discardableResult func addButton(withTitle title: String) -> FamilyNativeButton {
        let button = FamilyNativeButton(title: title, target: nil, action: nil)
        button.tag = buttons.count
        buttons.append(button)
        return button
    }

    func beginSheetModal(for window: NSWindow, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        self.completion = completionHandler
        Self.queue.append((self, window, completionHandler))
        Self.presentNext()
    }

    func beginSheetModal(for window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    private static func presentNext() {
        guard active == nil, !queue.isEmpty else { return }
        let (alert, owner, completion) = queue.removeFirst()
        active = alert
        alert.completion = completion
        if let owner, !owner.isVisible { alert.cancel(); return }
        alert.show(owner: owner)
    }

    @discardableResult func runModal() -> NSApplication.ModalResponse {
        runningModal = true
        show(owner: NSApp.keyWindow ?? NSApp.mainWindow)
        if let presentation, !finished { NSApp.runModal(for: presentation.window) }
        // abortModal (e.g. application shutdown) must release the backdrop and focus too.
        if !finished { finish(.abort) }
        return response
    }

    func cancel() { finish(.abort) }

    private func show(owner: NSWindow?) {
        let card = FamilyAlertCard()
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel(messageText)
        let width = max(SheetLayout.confirmation, (accessoryView?.frame.width ?? 0) + SheetLayout.dialogInset * 2)
        let inset = SheetLayout.dialogInset
        let inner = width - inset * 2
        let textWidth = inner - 32
        let title = label(messageText, font: .systemFont(ofSize: 16, weight: .semibold))
        let detail = label(informativeText, font: .systemFont(ofSize: 14))
        card.titleLabel = title
        card.detailLabel = detail
        card.alertStyle = alertStyle
        card.addSubview(title)
        let titleHeight = height(messageText, font: title.font!, width: textWidth)
        title.frame = NSRect(x: inset + 32, y: 24, width: textWidth, height: titleHeight)
        var y = 24 + titleHeight
        if !informativeText.isEmpty {
            y += 8
            let detailHeight = height(informativeText, font: detail.font!, width: textWidth)
            detail.frame = NSRect(x: inset + 32, y: y, width: textWidth, height: detailHeight)
            card.addSubview(detail)
            y += detailHeight
        }
        if let accessoryView {
            y += 16
            if let field = accessoryView as? NSTextField {
                field.isBezeled = false
                field.focusRingType = .none
                field.font = .systemFont(ofSize: 14)
                field.frame.size.height = Theme.Control.height
            }
            accessoryView.frame = NSRect(x: inset, y: y, width: inner, height: accessoryView.frame.height)
            card.addSubview(accessoryView)
            y += accessoryView.frame.height
        }
        y += 24
        var right = width - inset
        for (index, button) in buttons.enumerated() {
            button.kind = button.hasDestructiveAction || (index == 0 && alertStyle == .critical) ? .danger : index == 0 ? .primary : .secondary
            button.target = self
            button.action = #selector(choose(_:))
            button.keyEquivalent = index == 0 ? "\r" : index == buttons.count - 1 ? "\u{1b}" : ""
            let buttonWidth = max(64, button.intrinsicContentSize.width)
            right -= buttonWidth
            button.frame = NSRect(x: right, y: y, width: buttonWidth, height: Theme.Control.height)
            card.addSubview(button)
            right -= 8
        }
        let visualButtons = buttons.reversed()
        func inputControls(_ view: NSView) -> [NSView] {
            if let field = view as? NSTextField { return field.isEditable ? [field] : [] }
            if let control = view as? NSControl, control.isEnabled, control.acceptsFirstResponder { return [control] }
            return view.subviews.flatMap(inputControls)
        }
        let inputs = accessoryView.map(inputControls) ?? []
        var keyViews: [NSView] = inputs
        keyViews.append(contentsOf: visualButtons.map { $0 as NSView })
        for (i, view) in keyViews.enumerated() { view.nextKeyView = keyViews[(i + 1) % keyViews.count] }
        let size = NSSize(width: width, height: y + Theme.Control.height + 24)
        card.frame.size = size
        let presentation = FamilyModalPresentation(content: card, size: size, owner: owner) { [weak self] in self?.cancel() }
        self.presentation = presentation
        presentation.window.title = messageText
        presentation.window.autorecalculatesKeyViewLoop = false
        presentation.window.defaultButtonCell = buttons.first?.cell as? NSButtonCell
        presentation.show(initialFirstResponder: initialFirstResponder ?? inputs.first ?? buttons.first)
        if let field = initialFirstResponder as? NSTextField { field.selectText(nil) }
    }

    private func label(_ text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.isSelectable = true
        label.maximumNumberOfLines = 0
        return label
    }
    private func height(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        max(24, ceil((text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height))
    }
    @objc private func choose(_ sender: NSButton) {
        finish(NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + sender.tag))
    }
    private func finish(_ result: NSApplication.ModalResponse) {
        guard !finished else { return }
        finished = true
        response = result
        Self.queue.removeAll { $0.0 === self }
        if runningModal, NSApp.modalWindow === presentation?.window { NSApp.stopModal(withCode: result) }
        presentation?.close()
        presentation = nil
        let callback = completion
        completion = nil
        if Self.active === self { Self.active = nil }
        callback?(result)
        Self.presentNext()
    }
}

private final class FamilyAlertCard: NSView {
    var titleLabel: NSTextField?
    var detailLabel: NSTextField?
    var alertStyle: NSAlert.Style = .informational
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) {} // Only a click on the scrim cancels.
    override func draw(_ dirtyRect: NSRect) {
        let chrome = WindowChrome(isDark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.Radius.card, yRadius: Theme.Radius.card)
        NSColor(chrome.background).setFill(); path.fill()
        NSColor(chrome.hairline).setStroke(); path.lineWidth = 1; path.stroke()
        titleLabel?.textColor = NSColor(chrome.text)
        detailLabel?.textColor = NSColor(chrome.secondary)
        let symbol = NSImage(systemSymbolName: alertStyle == .informational ? "info.circle" : "exclamationmark.circle", accessibilityDescription: nil)
        let color = alertStyle == .critical ? chrome.danger : alertStyle == .warning ? chrome.warning : chrome.accent
        let image = symbol?.withSymbolConfiguration(.init(pointSize: 20, weight: .regular))?.withSymbolConfiguration(.init(paletteColors: [NSColor(color)]))
        image?.draw(in: NSRect(x: SheetLayout.dialogInset, y: 26, width: 20, height: 20))
    }
}

/// Shared AppKit button for alert actions and upload checkboxes; keeps NSButton's accessibility,
/// key equivalents and tracking, but draws only 1Panel tokens.
final class FamilyNativeButton: NSButton {
    enum Kind { case secondary, primary, danger, checkbox }
    var kind = Kind.secondary { didSet { needsDisplay = true } }
    private var hovered = false
    private var showsKeyboardFocus = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        // This control draws its own focus-visible treatment; AppKit must not add a halo.
        focusRingType = .none
        cell?.focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor && window != nil }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width) + (kind == .checkbox ? 24 : 24), height: 32)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { showsKeyboardFocus = NSApp.currentEvent?.type == .keyDown }
        needsDisplay = true
        return result
    }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
    override func mouseDown(with event: NSEvent) {
        showsKeyboardFocus = false
        needsDisplay = true
        super.mouseDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        let chrome = WindowChrome(isDark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let primary = kind == .primary || kind == .danger
        let fill = kind == .danger ? chrome.danger : kind == .primary ? (isHighlighted ? chrome.accentActive : hovered ? chrome.accentHover : chrome.accent) : hovered ? chrome.hairline : chrome.elevated
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let focused = showsKeyboardFocus && window?.firstResponder === self
        let textColor = NSColor(primary ? .white : chrome.text).withAlphaComponent(isEnabled ? 1 : 0.45)
        var textRect = rect
        if kind == .checkbox {
            let box = NSRect(x: 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
            let selected = state != .off
            let shape = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            NSColor(selected ? chrome.accent : chrome.background).setFill(); shape.fill()
            NSColor(selected || hovered ? chrome.accent : chrome.lineStrong).setStroke(); shape.lineWidth = 1; shape.stroke()
            if selected {
                let symbol = NSImage(systemSymbolName: state == .mixed ? "minus" : "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [.white]))
                symbol?.draw(in: box.insetBy(dx: 2, dy: 2))
            }
            textRect = NSRect(x: 26, y: 0, width: bounds.width - 26, height: bounds.height)
        } else {
            NSColor(fill).withAlphaComponent(isEnabled ? 1 : 0.45).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        if focused {
            NSColor(chrome.focus).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            ring.lineWidth = 2; ring.stroke()
        }
        let style = NSMutableParagraphStyle()
        style.alignment = kind == .checkbox ? .left : .center
        style.lineBreakMode = .byTruncatingMiddle
        textRect.origin.y = (bounds.height - 18) / 2
        textRect.size.height = 20
        (title as NSString).draw(in: textRect, withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: textColor, .paragraphStyle: style])
    }
}

final class FamilyNativeTextField: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        cell = FamilyTextFieldCell(textCell: "")
        isBezeled = false
        isEditable = true
        isSelectable = true
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 14)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let chrome = WindowChrome(isDark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let focused = currentEditor() != nil
        textColor = NSColor(chrome.text)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor(focused ? chrome.background : chrome.elevated).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        if focused {
            NSColor(chrome.focus).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            ring.lineWidth = 2; ring.stroke()
            NSColor(chrome.accent).setStroke()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).stroke()
        }
        super.draw(dirtyRect)
    }
    override func textDidBeginEditing(_ notification: Notification) { super.textDidBeginEditing(notification); needsDisplay = true }
    override func textDidEndEditing(_ notification: Notification) { super.textDidEndEditing(notification); needsDisplay = true }
}
private final class FamilyTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let height = min(20, rect.height)
        return NSRect(x: rect.minX + 10, y: rect.midY - height / 2, width: max(0, rect.width - 20), height: height)
    }
}
