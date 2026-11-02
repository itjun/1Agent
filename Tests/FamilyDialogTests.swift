import AppKit
import SwiftUI

@main struct FamilyDialogTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in await run(); exit(0) }
        NSApp.run()
    }
    @MainActor static func run() async {
        let owner = NSWindow(contentRect: NSRect(x: 180, y: 160, width: 880, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        owner.contentView?.addSubview(field)
        owner.makeKeyAndOrderFront(nil)
        owner.makeFirstResponder(field)
        let modal = FamilyModalPresentation(content: NSHostingView(rootView: Text("表单")), size: NSSize(width: 420, height: 200), owner: owner) {}
        modal.show()
        await settle()
        require(owner.attachedSheet === modal.window, "Forms use native sheets")
        require(modal.window.hasShadow, "System owns sheet shadow")
        modal.close()
        await settle()
        require(owner.attachedSheet == nil, "Closing detaches the native sheet")

        var responses: [NSApplication.ModalResponse] = []
        let first = FamilyAlert()
        first.messageText = "Delete?"
        first.addButton(withTitle: "Delete").hasDestructiveAction = true
        first.addButton(withTitle: "Cancel")
        let pending = FamilyAlert()
        pending.messageText = "Queued"
        pending.addButton(withTitle: "OK")
        first.beginSheetModal(for: owner) { responses.append($0) }
        pending.beginSheetModal(for: owner) { responses.append($0) }
        await settle()
        require(owner.attachedSheet === first.native.window, "Confirmation uses NSAlert sheet")
        require(!pending.native.window.isVisible, "Concurrent requests remain queued")
        pending.cancel()
        require(responses == [.abort], "Cancelling queued request resumes caller")
        first.buttons[0].performClick(nil)
        await settle()
        require(responses == [.abort, .alertFirstButtonReturn], "Native response preserves original codes")
        first.cancel()
        require(responses.count == 2, "Completion fires exactly once")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = "中文名称"
        let edit = FamilyAlert()
        edit.messageText = "Rename"
        edit.accessoryView = input
        edit.initialFirstResponder = input
        edit.addButton(withTitle: "OK")
        edit.addButton(withTitle: "Cancel")
        edit.beginSheetModal(for: owner) { responses.append($0) }
        await settle()
        require(input.currentEditor() != nil, "Accessory text field receives native editing focus")
        input.stringValue = "保留名称"
        edit.buttons[1].performClick(nil)
        await settle()
        require(responses.last == .alertSecondButtonReturn, "Cancel button preserves response code")
        require(input.stringValue == "保留名称", "Accessory content is preserved")
        let checkbox = FamilyNativeButton(title: "Convert", target: nil, action: nil)
        checkbox.kind = .checkbox
        checkbox.performClick(nil)
        require(checkbox.state == .on, "Native checkbox activation")
        owner.close()
        print("FamilyDialogTests passed: native sheets, alert queue, cancellation, response mapping, input and checkbox")
    }
    @MainActor static func settle() async { try? await Task.sleep(for: .milliseconds(400)) }
    static func require(_ condition: Bool, _ message: String) { precondition(condition, message) }
}
