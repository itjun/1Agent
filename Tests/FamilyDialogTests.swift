import AppKit
import SwiftUI

@main
struct FamilyDialogTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let owner = NSWindow(contentRect: NSRect(x: 180, y: 160, width: 880, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let original = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 32))
        owner.contentView?.addSubview(original)
        owner.makeKeyAndOrderFront(nil)
        owner.makeFirstResponder(original)
        let previous = owner.firstResponder

        let rename = FamilyAlert()
        rename.messageText = "Rename"
        let field = FamilyNativeTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 32))
        field.stringValue = "unchanged.txt"
        rename.accessoryView = field
        rename.initialFirstResponder = field
        rename.addButton(withTitle: "Rename")
        rename.addButton(withTitle: "Cancel")
        var cancelled: NSApplication.ModalResponse?
        rename.beginSheetModal(for: owner) { cancelled = $0 }
        require(rename.presentation?.window.isVisible == true, "dialog is presented")
        require(rename.presentation?.window.hasShadow == false, "no native shadow")
        require(rename.presentation?.backdrop.card?.frame.width == SheetLayout.confirmation, "confirmation width matches 1Panel")
        require(field.isEditable && field.currentEditor() != nil, "name input receives focus and remains editable")
        field.currentEditor()?.insertText("new.txt")
        require(field.stringValue == "new.txt", "typing replaces selected filename")
        rename.presentation?.window.cancelOperation(nil)
        require(cancelled == .abort, "Escape is cancellation, never confirmation")
        require(owner.childWindows?.isEmpty != false, "cancel removes the scrim")
        require(owner.firstResponder === previous, "focus returns to previous input")

        // Unhandled SwiftUI clicks (including disabled controls and button padding) can
        // bubble through the card to the backdrop. Only the actual scrim may cancel.
        let card = NSHostingView(rootView: Text("History"))
        var backdropCancellations = 0
        let history = FamilyModalPresentation(content: card, size: NSSize(width: 600, height: 400), owner: owner) {
            backdropCancellations += 1
        }
        history.show()
        let inside = card.convert(NSPoint(x: 30, y: 30), to: nil)
        history.backdrop.mouseDown(with: mouseEvent(at: inside, in: history.window))
        require(backdropCancellations == 0, "clicks inside the history card must not dismiss the dialog")
        let outside = history.backdrop.convert(NSPoint(x: 2, y: 2), to: nil)
        history.backdrop.mouseDown(with: mouseEvent(at: outside, in: history.window))
        require(backdropCancellations == 1, "clicks on the scrim still cancel the dialog")
        history.close()

        let first = FamilyAlert()
        first.messageText = "Delete?"; first.alertStyle = .critical
        first.addButton(withTitle: "Delete"); first.addButton(withTitle: "Cancel")
        let pending = FamilyAlert()
        pending.messageText = "Convert?"; pending.addButton(withTitle: "Upload"); pending.addButton(withTitle: "Cancel")
        var responses: [NSApplication.ModalResponse] = []
        first.beginSheetModal(for: owner) { responses.append($0) }
        first.presentation?.window.selectNextKeyView(nil)
        require(first.presentation?.window.firstResponder === first.buttons.last, "keyboard navigation reaches Cancel without requiring system keyboard navigation settings")
        first.presentation?.window.selectPreviousKeyView(nil)
        require(first.presentation?.window.firstResponder === first.buttons.first, "reverse keyboard navigation returns to the primary action")
        pending.beginSheetModal(for: owner) { responses.append($0) }
        require(pending.presentation == nil, "simultaneous requests are queued")
        pending.cancel()
        require(responses == [.abort], "cancelling a queued upload resumes its waiting caller")
        require(first.buttons[0].kind == .danger, "destructive confirmation uses danger style")
        first.buttons[0].performClick(nil)
        require(responses == [.abort, .alertFirstButtonReturn], "confirm returns the original response code")
        first.cancel()
        require(responses.count == 2, "completion fires only once")

        let second = FamilyAlert(); second.messageText = "Next"; second.addButton(withTitle: "OK")
        let third = FamilyAlert(); third.messageText = "After"; third.addButton(withTitle: "OK")
        second.beginSheetModal(for: owner) { _ in }
        third.beginSheetModal(for: owner) { _ in }
        second.cancel()
        require(third.presentation?.window.isVisible == true, "next queued request opens after dismissal")
        third.cancel()

        let checkbox = FamilyNativeButton(title: "Convert", target: nil, action: nil)
        checkbox.kind = .checkbox; checkbox.setButtonType(.switch)
        checkbox.performClick(nil)
        require(checkbox.state == .on, "custom checkbox retains native activation")

        let upload = FamilyAlert()
        upload.messageText = "Convert files"
        let choices = NSStackView(views: [checkbox])
        choices.frame = NSRect(x: 0, y: 0, width: 320, height: 64)
        upload.accessoryView = choices
        upload.addButton(withTitle: "Upload")
        upload.addButton(withTitle: "Cancel")
        upload.beginSheetModal(for: owner) { _ in }
        require(upload.presentation?.window.firstResponder === checkbox, "upload choices receive keyboard focus")
        require(checkbox.nextKeyView === upload.buttons.last, "Tab reaches the cancel action after upload choices")
        upload.cancel()

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            owner.appearance = NSAppearance(named: appearance)
            let alert = FamilyAlert(); alert.messageText = "Palette"; alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: owner) { _ in }
            let card = alert.presentation!.backdrop.card!
            card.displayIfNeeded()
            let bitmap = card.bitmapImageRepForCachingDisplay(in: card.bounds)!
            card.cacheDisplay(in: card.bounds, to: bitmap)
            // AppKit's backing bitmap is tagged with the display's ICC profile. Compare in
            // that space rather than treating its raw channels as sRGB.
            let pixel = bitmap.colorAt(x: 20, y: 20)!
            let expected = NSColor(WindowChrome(isDark: appearance == .darkAqua).background).usingColorSpace(bitmap.colorSpace)!
            require(abs(pixel.redComponent - expected.redComponent) < 0.02 && abs(pixel.greenComponent - expected.greenComponent) < 0.02 && abs(pixel.blueComponent - expected.blueComponent) < 0.02,
                    "dialog uses fixed light/dark family surface")
            alert.cancel()
        }
        owner.close()
        print("FamilyDialogTests passed: input focus/editing, cancellation, response mapping, queuing, upload abort, focus restoration, danger/checkbox controls, light/dark surfaces")
    }
    static func mouseEvent(at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    static func require(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
}
