import AppKit
import SwiftUI

@main
struct FamilyDialogTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let owner = NSWindow(contentRect: NSRect(x: 180, y: 160, width: 880, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let original = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 32))
        owner.contentView?.addSubview(original)
        owner.makeKeyAndOrderFront(nil)
        owner.makeFirstResponder(original)
        let first = FamilyAlert()
        first.messageText = "Delete?"
        first.alertStyle = .critical
        first.addButton(withTitle: "Delete")
        first.addButton(withTitle: "Cancel")
        let pending = FamilyAlert()
        pending.messageText = "Upload?"
        pending.addButton(withTitle: "Upload")
        var responses: [NSApplication.ModalResponse] = []
        first.beginSheetModal(for: owner) { responses.append($0) }
        settle()
        require(first.window.sheetParent === owner, "confirmation is a real native sheet")
        require(first.buttons.first?.hasDestructiveAction == true, "destructive action retains native semantics")
        pending.beginSheetModal(for: owner) { responses.append($0) }
        require(pending.window.sheetParent == nil, "simultaneous requests are queued")
        pending.cancel()
        require(responses == [.abort], "cancelling queued upload resumes its caller")
        first.buttons[0].performClick(nil)
        settle()
        require(responses == [.abort, .alertFirstButtonReturn], "native confirmation preserves response codes")
        first.cancel()
        require(responses.count == 2, "completion is delivered once")
        let second = FamilyAlert()
        second.messageText = "Rename"
        second.addButton(withTitle: "Rename")
        second.addButton(withTitle: "Cancel")
        let field = FamilyNativeTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = "old.txt"
        second.accessoryView = field
        second.initialFirstResponder = field
        let third = FamilyAlert()
        third.messageText = "Next"
        third.addButton(withTitle: "OK")
        second.beginSheetModal(for: owner) { responses.append($0) }
        third.beginSheetModal(for: owner) { responses.append($0) }
        settle()
        require(field.isEditable && field.currentEditor() != nil, "native accessory input receives focus")
        field.currentEditor()?.insertText("new.txt")
        require(field.stringValue == "new.txt", "selected name can be replaced")
        second.cancel()
        settle()
        require(third.window.sheetParent === owner, "next queued sheet opens after cancellation")
        third.cancel()
        settle()
        require(owner.attachedSheet == nil && responses.count == 4, "all sheets close and all waiters resume")
        let card = NSHostingView(rootView: Text("History"))
        var cancelled = false
        let sheet = FamilyModalPresentation(content: card, size: NSSize(width: 520, height: 440), owner: owner) { cancelled = true }
        sheet.show()
        settle()
        require(sheet.window.sheetParent === owner, "SwiftUI dialogs use a native sheet")
        require(card.bounds.size == NSSize(width: 520, height: 440), "sheet uses shared content dimensions")
        sheet.window.cancelOperation(nil)
        require(cancelled, "Escape routes to the sheet cancellation action")
        sheet.close()
        settle()
        require(owner.attachedSheet == nil, "closing releases the native sheet")
        owner.close()
        print("PASS: native sheets, response mapping, queued cancellation, input editing and dismissal")
    }
    @MainActor static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
    static func require(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
}
