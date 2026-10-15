import AppKit
import SwiftUI

/// Historical text never enters Ghostty, so OSC clipboard requests, notifications,
/// old mouse modes and TUI queries cannot affect the newly started shell.
@MainActor
final class TerminalHistoryView: NSView {
    private let snapshot: TerminalHistorySnapshot
    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let picker = NSSegmentedControl()
    private let compactPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let controls = NSStackView()
    var onContinue: (() -> Void)?
    var onClose: (() -> Void)?

    init(snapshot: TerminalHistorySnapshot, settings: TerminalSettings = .load(), showsContinue: Bool = true) {
        self.snapshot = snapshot
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        let title = NSTextField(labelWithString: String(localized: "Previous session · read-only text"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.toolTip = String(localized: "A new session is running. Previous programs and terminal modes are not restored.")
        picker.segmentCount = 2
        picker.setLabel(String(localized: "Last Screen"), forSegment: 0)
        picker.setLabel(String(localized: "Text History"), forSegment: 1)
        // Always reopen the exact saved viewport. Text History reveals its location in
        // the larger archive, while a former TUI remains explicitly read-only.
        picker.selectedSegment = 0
        picker.target = self; picker.action = #selector(changeSection)
        picker.controlSize = .small
        compactPicker.addItems(withTitles: [String(localized: "Last Screen"), String(localized: "Text History")])
        compactPicker.target = self; compactPicker.action = #selector(changeCompactSection)
        compactPicker.controlSize = .small
        compactPicker.isHidden = true
        let button = NSButton(title: String(localized: "Enter New Session"), target: self, action: #selector(continueSession))
        button.bezelStyle = .rounded
        button.controlSize = .small
        controls.setViews([title, picker, compactPicker] + (showsContinue ? [button] : []), in: .leading)
        if !showsContinue {
            let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close History"))!,
                                 target: self, action: #selector(closeHistory))
            close.isBordered = false
            close.toolTip = String(localized: "Close History")
            close.setAccessibilityIdentifier("terminal.history.close")
            controls.setViews([close], in: .trailing)
        }
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isAutomaticLinkDetectionEnabled = false
        // Use the same persisted face and size as the terminal, including its Nerd Font
        // fallback. The archive is plain text, but must not silently substitute a UI font.
        let base = NSFont(name: settings.fontFamily, size: settings.fontSize)
            ?? NSFontManager.shared.font(withFamily: settings.fontFamily, traits: [], weight: 5, size: settings.fontSize)
            ?? .monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
        let descriptor = base.fontDescriptor.addingAttributes([
            .cascadeList: [NSFontDescriptor(fontAttributes: [.family: TerminalSettings.symbolFallbackFamily])]
        ])
        textView.font = NSFont(descriptor: descriptor, size: settings.fontSize) ?? base
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: 1_000_000, height: 1_000_000_000)
        textView.minSize = .zero
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 1_000_000, height: 1_000_000_000)
        scroll.documentView = textView
        let stack = NSStackView(views: [controls, scroll])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        changeSection()
        applyFamilyAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFamilyAppearance()
    }

    func applyFamilyAppearance() {
        let appearance = window?.appearance ?? NSApp.appearance ?? NSApp.effectiveAppearance
        let chrome = WindowChrome.resolve(isDark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        layer?.backgroundColor = NSColor(chrome.background).cgColor
        controls.appearance = appearance
        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor(chrome.sidebarBackground).cgColor
        for label in controls.arrangedSubviews.compactMap({ $0 as? NSTextField }) {
            label.textColor = NSColor(chrome.text)
        }
        scroll.backgroundColor = NSColor(chrome.background)
        textView.backgroundColor = NSColor(chrome.background)
        textView.textColor = NSColor(chrome.text)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(chrome.selection)]
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFamilyAppearance()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.restoreScroll() } }
    }

    func focusText() { window?.makeFirstResponder(textView) }

    override func layout() {
        super.layout()
        let compact = bounds.width < 620
        picker.isHidden = compact
        compactPicker.isHidden = !compact
        let narrow = bounds.width < 400
        controls.orientation = narrow ? .vertical : .horizontal
        controls.alignment = narrow ? .leading : .centerY
    }

    @objc private func changeCompactSection() {
        picker.selectedSegment = compactPicker.indexOfSelectedItem
        changeSection()
    }

    @objc private func changeSection() {
        compactPicker.selectItem(at: picker.selectedSegment)
        textView.string = picker.selectedSegment == 0 ? snapshot.lastScreenText : snapshot.mainText
        textView.sizeToFit()
        DispatchQueue.main.async { [weak self] in self?.restoreScroll() }
    }

    private func restoreScroll() {
        guard picker.selectedSegment == 1 else { scroll.contentView.scroll(to: .zero); return }
        let text = textView.string as NSString
        var position = 0
        for _ in 0..<snapshot.mainViewportTop {
            guard position < text.length else { break }
            position = NSMaxRange(text.lineRange(for: NSRange(location: position, length: 0)))
        }
        guard position < text.length, let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: position)
        let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func continueSession() { onContinue?() }
    @objc private func closeHistory() { onClose?() }
}

/// Explicit history drawer below the live canvas; never a restoration overlay.
struct HistoryDrawer: NSViewRepresentable {
    let snapshot: TerminalHistorySnapshot
    var onClose: () -> Void = {}
    func makeNSView(context: Context) -> TerminalHistoryView {
        let view = TerminalHistoryView(snapshot: snapshot, showsContinue: false)
        view.onClose = onClose
        return view
    }
    func updateNSView(_ view: TerminalHistoryView, context: Context) { view.onClose = onClose }
}
