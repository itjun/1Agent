import AppKit
import SwiftUI

/// Command text must reach argv byte-for-byte. The controls below own their editors;
/// disabling macOS prose substitutions never changes the user's shared field editor.
final class CommandLiteralTextView: NSTextView {
    private var ownedStorage: NSTextStorage?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer? = nil) {
        let resolvedContainer: NSTextContainer
        if let container {
            resolvedContainer = container
        } else {
            let storage = NSTextStorage()
            let manager = NSLayoutManager()
            resolvedContainer = NSTextContainer(size: NSSize(width: max(frameRect.width, 1), height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(manager)
            manager.addTextContainer(resolvedContainer)
            ownedStorage = storage
        }
        super.init(frame: frameRect, textContainer: resolvedContainer)
        configureLiteralInput()
        allowsUndo = true
        font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configureLiteralInput() {
        isRichText = false
        importsGraphics = false
        smartInsertDeleteEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        enabledTextCheckingTypes = 0
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        configureLiteralInput()
        return accepted
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        configureLiteralInput()
        let plain = (insertString as? NSAttributedString)?.string ?? insertString
        super.insertText(plain, replacementRange: replacementRange)
    }

    func updateFromModel(_ text: String) {
        guard string != text, !hasMarkedText() else { return }
        let ranges = selectedRanges
        string = text
        restoreSelection(ranges)
    }

    func restoreSelection(_ ranges: [NSValue]) {
        let count = (string as NSString).length
        selectedRanges = ranges.map {
            let range = $0.rangeValue
            let location = min(range.location, count)
            return NSValue(range: NSRange(location: location, length: min(range.length, count - location)))
        }
    }
}

struct CommandLiteralEditor: NSViewRepresentable {
    @Binding var text: String
    var textColor: NSColor
    var backgroundColor: NSColor
    var identifier: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = CommandLiteralTextView(frame: .zero)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.delegate = context.coordinator
        editor.string = text
        editor.setAccessibilityIdentifier(identifier)
        scroll.documentView = editor
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let editor = scroll.documentView as? CommandLiteralTextView else { return }
        editor.updateFromModel(text)
        editor.textColor = textColor
        editor.insertionPointColor = textColor
        editor.backgroundColor = backgroundColor
        scroll.backgroundColor = backgroundColor
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            text.wrappedValue = editor.string
        }
    }
}

final class CommandLiteralTextField: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        cell = CommandLiteralFieldCell(textCell: "")
        isBezeled = false
        isEditable = true
        isSelectable = true
        drawsBackground = true
        focusRingType = .none
        font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        usesSingleLineMode = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateFromModel(_ text: String) {
        guard stringValue != text else { return }
        let editor = currentEditor() as? CommandLiteralTextView
        guard editor?.hasMarkedText() != true else { return }
        let ranges = editor?.selectedRanges
        stringValue = text
        if let editor {
            editor.string = text
            if let ranges { editor.restoreSelection(ranges) }
        }
    }
}

private final class CommandLiteralFieldCell: NSTextFieldCell {
    private let literalEditor = CommandLiteralTextView(frame: .zero)

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        literalEditor.isFieldEditor = true
        literalEditor.configureLiteralInput()
        return literalEditor
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let height = min(rect.height, ceil(font.map { $0.ascender - $0.descender + $0.leading } ?? 20))
        return NSRect(x: rect.minX + 8, y: rect.midY - height / 2, width: max(0, rect.width - 16), height: height)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        // NSTextField's editor otherwise fills the entire 32pt control and starts
        // its first line at the top, ignoring the cell's drawing inset.
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj,
                     delegate: delegate, start: selStart, length: selLength)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj,
                   delegate: delegate, event: event)
    }
}

struct CommandLiteralField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var textColor: NSColor
    var backgroundColor: NSColor
    var identifier: String
    var font: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    var fillsProposedHeight = false

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> CommandLiteralTextField {
        let field = CommandLiteralTextField(frame: .zero)
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier(identifier)
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: CommandLiteralTextField, context: Context) {
        context.coordinator.text = $text
        field.updateFromModel(text)
        field.placeholderString = placeholder
        field.textColor = textColor
        field.backgroundColor = backgroundColor
        field.font = font
        if let editor = field.currentEditor() as? NSTextView {
            editor.textColor = textColor
            editor.insertionPointColor = textColor
            editor.backgroundColor = backgroundColor
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CommandLiteralTextField, context: Context) -> CGSize? {
        guard fillsProposedHeight, let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
