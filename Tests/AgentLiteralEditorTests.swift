import AppKit
import SwiftUI

@main
enum AgentLiteralEditorTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = AgentLiteralTextView(frame: NSRect(x: 0, y: 80, width: 500, height: 120))
        window.contentView?.addSubview(editor)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        let literal = "--version 'single' \"double\" --profile work "
        type(literal, into: editor)
        require(editor.string == literal, "argument input preserves ASCII dashes and quotes byte for byte")
        editor.breakUndoCoalescing()
        editor.undoManager?.removeAllActions()
        type("x", into: editor)
        editor.breakUndoCoalescing()
        editor.undoManager?.undo()
        require(editor.string == literal, "plain text editing retains native undo")
        require(!editor.isAutomaticDashSubstitutionEnabled && !editor.isAutomaticQuoteSubstitutionEnabled &&
                !editor.isAutomaticTextReplacementEnabled && !editor.isAutomaticSpellingCorrectionEnabled,
                "argument editor disables all command-altering substitutions")
        editor.setSelectedRange(NSRange(location: 2, length: 7))
        editor.updateFromModel(literal)
        require(editor.selectedRange() == NSRange(location: 2, length: 7), "binding echoes preserve selection")
        editor.updateFromModel(literal + "next")
        require(editor.selectedRange() == NSRange(location: 2, length: 7), "external updates preserve in-range selection")
        editor.updateFromModel("ab")
        require(editor.selectedRange() == NSRange(location: 2, length: 0), "shorter model updates safely clamp selection")
        require(editor.allowsUndo && !editor.isRichText, "argument editor is plain text with undo")

        let field = AgentLiteralTextField(frame: NSRect(x: 0, y: 20, width: 500, height: 32))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        guard let fieldEditor = field.currentEditor() as? AgentLiteralTextView else {
            fatalError("command field must use its own literal field editor")
        }
        type(literal, into: fieldEditor)
        require(fieldEditor.string == literal, "executable and directory fields preserve literal text")
        require(!fieldEditor.isAutomaticDashSubstitutionEnabled && !fieldEditor.isAutomaticQuoteSubstitutionEnabled,
                "field editing cannot reenable prose substitutions")
        fieldEditor.setSelectedRange(NSRange(location: 2, length: 7))
        field.updateFromModel(literal + "more")
        require(fieldEditor.selectedRange() == NSRange(location: 2, length: 7), "field binding updates preserve selection")
        require(window.fieldEditor(false, for: nil) !== fieldEditor, "literal field editor is not the window's shared editor")
        window.makeFirstResponder(nil)
        window.close()
        print("ok")
    }

    @MainActor static func type(_ text: String, into editor: NSTextView) {
        for character in text {
            let value = String(character)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: editor.window?.windowNumber ?? 0, context: nil,
                                        characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: 0)!
            editor.keyDown(with: event)
        }
    }

    static func require(_ value: Bool, _ message: String) {
        guard value else { fputs("FAIL \(message)\n", stderr); exit(1) }
    }
}
