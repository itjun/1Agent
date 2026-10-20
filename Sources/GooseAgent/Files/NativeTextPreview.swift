import AppKit
import SwiftUI

/// Code colors intentionally follow 1Panel's independent Monokai surface.
enum PreviewCodeStyle {
    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static let background = color(0x191C21), foreground = color(0xE5E7EB), bright = color(0xF8F8F2)
    static let selection = color(0x365D91), occurrence = color(0x2B4567), bracket = color(0x48637C)
    static let accent = color(0x66D9EF), gutter = color(0x8B98A8), activeGutter = color(0x29384B)
    static let activeLine = color(0x6699DC).withAlphaComponent(0.14)
    static let hoverLine = accent.withAlphaComponent(0.08)
    static let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    static let lineHeight: CGFloat = 21.7

    static func attributes(for scope: String) -> [NSAttributedString.Key: Any] {
        let root = scope.split(separator: ".").first.map(String.init) ?? scope
        switch root {
        case "comment", "quote":
            return [.foregroundColor: color(0x75715E), .font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)]
        case "keyword", "selector-tag", "literal": return [.foregroundColor: color(0xF92672)]
        case "section", "attribute", "attr", "built_in", "type": return [.foregroundColor: accent]
        case "string", "title", "name": return [.foregroundColor: color(0xE6DB74)]
        case "number", "meta": return [.foregroundColor: color(0xAE81FF)]
        case "punctuation", "bullet", "operator": return [.foregroundColor: bright]
        case "addition": return [.foregroundColor: color(0xA6E22E)]
        case "deletion": return [.foregroundColor: color(0xF92672)]
        default: return [:]
        }
    }
}

struct NativeTextPreview: NSViewRepresentable {
    let text: String
    let path: String
    let findRequest: Int
    var onClose: () -> Void

    final class Coordinator {
        var text: String?, path: String?, findRequest = 0
        var highlighting: Task<Void, Never>?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PreviewCodeContainer {
        let container = PreviewCodeContainer()
        container.code.onClose = onClose
        return container
    }

    func updateNSView(_ container: PreviewCodeContainer, context: Context) {
        let view = container.code
        view.onClose = onClose
        if context.coordinator.text != text || context.coordinator.path != path {
            context.coordinator.text = text
            context.coordinator.path = path
            context.coordinator.highlighting?.cancel()
            view.load(text)
            context.coordinator.highlighting = Task { @MainActor [weak view] in
                let tokens = await PreviewSyntax.shared.tokens(in: text, path: path)
                guard !Task.isCancelled, let view, view.string == text else { return }
                view.apply(tokens: tokens)
            }
        }
        if context.coordinator.findRequest != findRequest {
            context.coordinator.findRequest = findRequest
            let item = NSMenuItem()
            item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            view.performFindPanelAction(item)
        }
    }

    static func dismantleNSView(_ view: PreviewCodeContainer, coordinator: Coordinator) { coordinator.highlighting?.cancel() }
}

/// Keep the gutter outside the scroll view. NSRulerView can float over text in a
/// full-size-content native window; explicit sibling frames prevent any overlap.
final class PreviewCodeContainer: NSView {
    let scroll = NSScrollView()
    let code = PreviewTextView()
    private let gutter: PreviewLineGutter
    override var isFlipped: Bool { true }

    init() {
        gutter = PreviewLineGutter(textView: code, scrollView: scroll)
        super.init(frame: .zero)
        clipsToBounds = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.findBarPosition = .aboveContent
        scroll.drawsBackground = true
        scroll.backgroundColor = PreviewCodeStyle.background
        scroll.appearance = NSAppearance(named: .darkAqua)
        scroll.clipsToBounds = true
        scroll.documentView = code
        code.lineGutter = gutter
        addSubview(gutter)
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = max(42, CGFloat(String(code.index.lineStarts.count).count) * 8.5 + 20)
        let origin = scroll.contentView.bounds.origin
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scroll.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        scroll.tile()
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        gutter.needsDisplay = true
    }
}

/// TextKit keeps native copy, find, Unicode selection and keyboard navigation.
final class PreviewTextView: NSTextView, NSTextViewDelegate {
    override func menu(for event: NSEvent) -> NSMenu? {
        if let menu = super.menu(for: event) {
            FamilyMenuPresenter.shared.show(menu, with: event, for: self)
        }
        return nil
    }

    var onClose: (() -> Void)?
    weak var lineGutter: PreviewLineGutter?
    private(set) var index = PreviewTextIndex("")
    private(set) var occurrenceRanges: [NSRange] = []
    private(set) var matchedBrackets: [NSRange] = []
    private(set) var activeLine = 0
    private var hoveredLine: Int?
    private var hoverTracking: NSTrackingArea?
    private var replacingText = false

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        delegate = self
        isEditable = false
        isSelectable = true
        isRichText = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isVerticallyResizable = true
        isHorizontallyResizable = true
        autoresizingMask = [.width]
        container.widthTracksTextView = false
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(width: 10, height: 10)
        backgroundColor = PreviewCodeStyle.background
        textColor = PreviewCodeStyle.foreground
        font = PreviewCodeStyle.font
        insertionPointColor = PreviewCodeStyle.bright
        selectedTextAttributes = [.backgroundColor: PreviewCodeStyle.selection, .foregroundColor: PreviewCodeStyle.bright]
        setAccessibilityIdentifier("files.preview.code")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(_ text: String) {
        occurrenceRanges = []; matchedBrackets = []; hoveredLine = nil
        replacingText = true
        string = text
        replacingText = false
        apply(tokens: [])
        sizeToFit()
        enclosingScrollView?.contentView.scroll(to: .zero)
        if let scroll = enclosingScrollView { scroll.reflectScrolledClipView(scroll.contentView) }
    }

    func apply(tokens: [PreviewSyntaxToken]) {
        guard let storage = textStorage else { return }
        let selection = selectedRanges
        let scrollOrigin = enclosingScrollView?.contentView.bounds.origin
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = PreviewCodeStyle.lineHeight
        paragraph.maximumLineHeight = PreviewCodeStyle.lineHeight
        paragraph.tabStops = []
        paragraph.defaultTabInterval = ("  " as NSString).size(withAttributes: [.font: PreviewCodeStyle.font]).width
        storage.beginEditing()
        storage.setAttributes([.foregroundColor: PreviewCodeStyle.foreground, .font: PreviewCodeStyle.font,
                               .paragraphStyle: paragraph], range: NSRange(location: 0, length: storage.length))
        for token in tokens { storage.addAttributes(PreviewCodeStyle.attributes(for: token.scope), range: token.range) }
        storage.endEditing()
        index = PreviewTextIndex(string, tokens: tokens)
        if selectedRanges != selection { selectedRanges = selection }
        refreshHighlights()
        lineGutter?.superview?.needsLayout = true
        lineGutter?.superview?.layoutSubtreeIfNeeded()
        if let scroll = enclosingScrollView, let scrollOrigin {
            scroll.tile()
            scroll.contentView.scroll(to: scrollOrigin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) { refreshHighlights() }

    private func refreshHighlights() {
        guard !replacingText, let layoutManager else { return }
        for range in occurrenceRanges + matchedBrackets where NSMaxRange(range) <= (string as NSString).length {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        let selection = selectedRange()
        activeLine = index.line(at: selection.location)
        occurrenceRanges = index.occurrences(for: selection)
        matchedBrackets = selection.length == 0 ? index.matchingBrackets(at: selection.location) : []
        for range in occurrenceRanges { layoutManager.addTemporaryAttribute(.backgroundColor, value: PreviewCodeStyle.occurrence, forCharacterRange: range) }
        for range in matchedBrackets { layoutManager.addTemporaryAttribute(.backgroundColor, value: PreviewCodeStyle.bracket, forCharacterRange: range) }
        needsDisplay = true
        lineGutter?.needsDisplay = true
    }

    func lineRect(_ line: Int) -> NSRect? {
        guard index.lineStarts.indices.contains(line), let layoutManager, let textContainer else { return nil }
        let position = index.lineStarts[line]
        layoutManager.ensureLayout(for: textContainer)
        let rect: NSRect
        if position == (string as NSString).length {
            rect = layoutManager.extraLineFragmentRect
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: position)
            rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        return NSRect(x: visibleRect.minX, y: rect.minY + textContainerOrigin.y,
                      width: visibleRect.width, height: max(rect.height, PreviewCodeStyle.lineHeight))
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let hoveredLine, hoveredLine != activeLine, let line = lineRect(hoveredLine), line.intersects(rect) {
            PreviewCodeStyle.hoverLine.setFill(); line.fill()
        }
        if let line = lineRect(activeLine), line.intersects(rect) {
            PreviewCodeStyle.activeLine.setFill(); line.fill()
            PreviewCodeStyle.accent.setFill()
            NSRect(x: line.minX, y: line.minY, width: 2, height: line.height).fill()
        }
    }

    override var shouldDrawInsertionPoint: Bool { window?.firstResponder === self && window?.isKeyWindow == true }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height),
                                 color: PreviewCodeStyle.bright, turnedOn: flag)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredLine = index.line(at: characterIndexForInsertion(at: point))
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) { hoveredLine = nil; needsDisplay = true }

    override func cancelOperation(_ sender: Any?) {
        if enclosingScrollView?.isFindBarVisible == true { enclosingScrollView?.isFindBarVisible = false }
        else { onClose?() }
    }
}

final class PreviewLineGutter: NSView {
    private weak var textView: PreviewTextView?
    override var isFlipped: Bool { true }
    init(textView: PreviewTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(frame: .zero)
        setAccessibilityElement(false)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func scrolled() { needsDisplay = true }

    override func draw(_ rect: NSRect) {
        PreviewCodeStyle.background.setFill(); bounds.fill()
        guard let view = textView else { return }
        let first = view.index.line(at: view.characterIndexForInsertion(at: view.visibleRect.origin))
        for line in first..<view.index.lineStarts.count {
            guard let source = view.lineRect(line) else { continue }
            let row = convert(source, from: view)
            if row.minY > bounds.maxY { break }
            if row.maxY < bounds.minY { continue }
            let active = line == view.activeLine
            if active {
                PreviewCodeStyle.activeGutter.setFill()
                NSRect(x: 0, y: row.minY, width: bounds.width, height: row.height).fill()
            }
            let label = String(line + 1) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: PreviewCodeStyle.font,
                                                             .foregroundColor: active ? PreviewCodeStyle.bright : PreviewCodeStyle.gutter]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: bounds.width - size.width - 10, y: row.minY + (row.height - size.height) / 2), withAttributes: attributes)
        }
    }
}
