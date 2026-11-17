import AppKit
import SwiftUI

/// 文件预览和改动对比共用排版与当前窗口主题。
enum PreviewCodeStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    static let lineHeight: CGFloat = 21.7
}

struct PreviewThemeStyle {
    let chrome: WindowChrome
    let syntaxColors: [NSColor]
    var background: NSColor { NSColor(chrome.background) }
    var foreground: NSColor { NSColor(chrome.text) }
    var bright: NSColor { foreground }
    var selection: NSColor { NSColor(chrome.selection) }
    var accent: NSColor { NSColor(chrome.accent) }
    var gutter: NSColor { NSColor(chrome.secondary) }
    var activeGutter: NSColor { accent.withAlphaComponent(0.10) }
    var activeLine: NSColor { accent.withAlphaComponent(0.06) }
    var hoverLine: NSColor { accent.withAlphaComponent(0.04) }
    var occurrence: NSColor { accent.withAlphaComponent(0.18) }
    var bracket: NSColor { accent.withAlphaComponent(0.25) }

    init(chrome: WindowChrome) {
        self.chrome = chrome
        let base = NSColor(chrome.background).usingColorSpace(.sRGB)!
        let background = RGBColor(red: base.redComponent, green: base.greenComponent, blue: base.blueComponent)
        let ink = NSColor(chrome.text).usingColorSpace(.sRGB)!
        let target = RGBColor(red: ink.redComponent, green: ink.greenComponent, blue: ink.blueComponent)
        syntaxColors = (chrome.syntaxPalette ?? AppTheme.colors(isDark: chrome.isDark).ansi).map {
            NSColor(RGBColor.ensureContrast(RGBColor(ghosttyHex: $0)!, against: background,
                                           toward: target, minimum: 4.5).color)
        }
    }

    func attributes(for scope: String) -> [NSAttributedString.Key: Any] {
        let root = scope.split(separator: ".").first.map(String.init) ?? scope
        let color: NSColor
        switch root {
        case "comment", "quote":
            return [.foregroundColor: gutter,
                    .font: NSFontManager.shared.convert(PreviewCodeStyle.font, toHaveTrait: .italicFontMask)]
        case "keyword", "selector-tag", "literal", "deletion": color = syntaxColors[1]
        case "section", "attribute", "attr", "built_in", "type": color = syntaxColors[4]
        case "string", "title", "name": color = syntaxColors[3]
        case "number", "meta": color = syntaxColors[5]
        case "addition": color = syntaxColors[2]
        default: color = foreground
        }
        return [.foregroundColor: color]
    }
}

struct NativeTextPreview: NSViewRepresentable {
    @Environment(\.windowChrome) private var chrome
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
        container.applyTheme(chrome)
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
        appearance = SystemTheme.appearance(isDark: code.style.chrome.isDark)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.findBarPosition = .aboveContent
        scroll.drawsBackground = true
        scroll.backgroundColor = code.style.background
        scroll.clipsToBounds = true
        scroll.documentView = code
        code.lineGutter = gutter
        addSubview(gutter)
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme(_ chrome: WindowChrome) {
        guard code.style.chrome != chrome else { return }
        appearance = SystemTheme.appearance(isDark: chrome.isDark)
        code.applyTheme(chrome)
        scroll.backgroundColor = code.style.background
        needsDisplay = true
        gutter.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        code.style.background.setFill()
        dirtyRect.fill()
    }

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
final class PreviewTextView: NSTextView, NSTextViewDelegate, NSLayoutManagerDelegate {
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
    private var syntaxTokens: [PreviewSyntaxToken] = []
    private(set) var style = PreviewThemeStyle(chrome: WindowChrome(isDark: true))

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        layout.delegate = self
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
        appearance = SystemTheme.appearance(isDark: style.chrome.isDark)
        drawsBackground = true
        backgroundColor = style.background
        textColor = style.foreground
        font = PreviewCodeStyle.font
        insertionPointColor = style.bright
        selectedTextAttributes = [.backgroundColor: style.selection, .foregroundColor: style.bright]
        setAccessibilityIdentifier("files.preview.code")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        FocusedTerminal.shared.refreshSoon()
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        FocusedTerminal.shared.refreshSoon()
        return result
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        // 固定行高多出的留白上下均分；直接调整 TextKit 基线，让选区与光标一同对齐。
        let font = PreviewCodeStyle.font
        baselineOffset.pointee = (lineFragmentRect.pointee.height + font.ascender + font.descender) / 2
        return true
    }

    func applyTheme(_ chrome: WindowChrome) {
        style = PreviewThemeStyle(chrome: chrome)
        appearance = SystemTheme.appearance(isDark: chrome.isDark)
        backgroundColor = style.background
        textColor = style.foreground
        insertionPointColor = style.bright
        selectedTextAttributes = [.backgroundColor: style.selection, .foregroundColor: style.bright]
        apply(tokens: syntaxTokens)
    }

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
        syntaxTokens = tokens
        guard let storage = textStorage else { return }
        let selection = selectedRanges
        let scrollOrigin = enclosingScrollView?.contentView.bounds.origin
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = PreviewCodeStyle.lineHeight
        paragraph.maximumLineHeight = PreviewCodeStyle.lineHeight
        paragraph.tabStops = []
        paragraph.defaultTabInterval = ("  " as NSString).size(withAttributes: [.font: PreviewCodeStyle.font]).width
        storage.beginEditing()
        storage.setAttributes([.foregroundColor: style.foreground, .font: PreviewCodeStyle.font,
                               .paragraphStyle: paragraph], range: NSRange(location: 0, length: storage.length))
        for token in tokens { storage.addAttributes(style.attributes(for: token.scope), range: token.range) }
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
        for range in occurrenceRanges { layoutManager.addTemporaryAttribute(.backgroundColor, value: style.occurrence, forCharacterRange: range) }
        for range in matchedBrackets { layoutManager.addTemporaryAttribute(.backgroundColor, value: style.bracket, forCharacterRange: range) }
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
            style.hoverLine.setFill(); line.fill()
        }
        if let line = lineRect(activeLine), line.intersects(rect) {
            style.activeLine.setFill(); line.fill()
        }
    }

    override var shouldDrawInsertionPoint: Bool { window?.firstResponder === self && window?.isKeyWindow == true }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height),
                                 color: style.bright, turnedOn: flag)
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
        guard let view = textView else { return }
        let first = view.index.line(at: view.characterIndexForInsertion(at: view.visibleRect.origin))
        for line in first..<view.index.lineStarts.count {
            guard let source = view.lineRect(line) else { continue }
            let row = convert(source, from: view)
            if row.minY > bounds.maxY { break }
            if row.maxY < bounds.minY { continue }
            let active = line == view.activeLine
            if active {
                view.style.activeGutter.setFill()
                NSRect(x: 0, y: row.minY, width: bounds.width, height: row.height).fill()
            }
            let label = String(line + 1) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: PreviewCodeStyle.font,
                                                             .foregroundColor: active ? view.style.bright : view.style.gutter]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: bounds.width - size.width - 10, y: row.minY + (row.height - size.height) / 2), withAttributes: attributes)
        }
    }
}
