import AppKit
import SwiftUI

@MainActor
private final class MenuTarget: NSObject, NSMenuItemValidation {
    var invoked = 0
    @objc func run(_ sender: NSMenuItem) { invoked = sender.tag }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { menuItem.tag != 2 }
}

@main
struct FamilyMenuTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let owner = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        owner.contentView = field
        owner.makeFirstResponder(field)
        let presenter = FamilyMenuPresenter()
        let target = MenuTarget()
        let menu = NSMenu()
        for tag in [1, 2, 3] {
            let item = NSMenuItem(title: "Action \(tag)", action: #selector(MenuTarget.run(_:)), keyEquivalent: tag == 3 ? "r" : "")
            item.target = target
            item.tag = tag
            if tag == 3 { item.keyEquivalentModifierMask = [.command, .shift] }
            menu.addItem(item)
        }
        let commands = FamilyMenuItem.commands(from: menu)
        expect(commands.map(\.enabled) == [true, false, true], "AppKit validation must survive conversion")
        expect(commands[2].shortcut == "⇧⌘R", "Shortcut modifiers and key must survive conversion")
        commands[0].action()
        expect(target.invoked == 1, "Original target and sender tag must survive conversion")

        var fired: [String] = []
        let items: [FamilyMenuItem] = [
            .init(title: "Disabled", enabled: false, action: { fired.append("disabled") }),
            .separator,
            .init(title: "First", action: { fired.append("first") }),
            .init(title: "Submenu", children: [.init(title: "Child", action: { fired.append("child") })]),
            .init(title: "Last", action: { fired.append("last") }),
        ]
        func show(_ list: [FamilyMenuItem] = items) { presenter.show(list, at: NSPoint(x: 400, y: 500), owner: owner) }
        func key(_ code: UInt16, _ chars: String = "", _ modifiers: NSEvent.ModifierFlags = []) {
            presenter.handleKey(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: owner.windowNumber, context: nil,
                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
        }
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            owner.appearance = NSAppearance(named: appearance)
            show()
            let panel = presenter.panels[0]
            expect(!panel.hasShadow && !panel.canBecomeKey, "Popup must have no shadow and must not take keyboard focus")
            expect(panel.contentView?.layer?.cornerRadius == 6 && panel.contentView?.layer?.borderWidth == 1, "Panel must use 6px radius and 1px border")
            let chrome = WindowChrome.resolve(isDark: appearance == .darkAqua)
            expect(panel.contentView?.layer?.backgroundColor == NSColor(chrome.background).cgColor, "Menu must use the fixed family light/dark surface")
            let rows = buttons(panel.contentView!)
            expect(rows.filter { $0.frame.height == 32 }.count == 4, "Action rows must be 32px high")
            expect(rows.first?.isEnabled == false, "Disabled commands must remain non-interactive")
            key(125); key(36)
            expect(fired.last == "first" && presenter.panels.isEmpty, "Down skips disabled rows/separators; Enter invokes and dismisses")
            expect(owner.firstResponder === field, "Menu dismissal must retain editor/terminal focus")
        }
        show()
        let liveMenu = presenter.panels[0]
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            liveMenu.appearance = NSAppearance(named: appearance)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let chrome = WindowChrome(isDark: appearance == .darkAqua)
            expect(liveMenu.contentView?.layer?.backgroundColor == NSColor(chrome.background).cgColor,
                   "An already-open menu follows light/dark changes")
            expect(liveMenu.contentView?.layer?.borderColor == NSColor(chrome.hairline).cgColor,
                   "An already-open menu refreshes its border")
        }
        presenter.dismiss()
        show(); key(119); key(36)
        expect(fired.last == "last", "End selects the final enabled action")
        show(); key(115); key(125); key(124)
        expect(presenter.panels.count == 2, "Right arrow opens a submenu")
        key(123)
        expect(presenter.panels.count == 1, "Left arrow closes only the submenu")
        key(124); key(36)
        expect(fired.last == "child" && presenter.panels.isEmpty, "Submenu commands invoke and close the whole menu")
        show(); key(53)
        expect(presenter.panels.isEmpty && !fired.contains("disabled"), "Escape cancels without invoking a disabled action")
        show(commands); key(15, "r", [.command, .shift])
        expect(target.invoked == 3 && presenter.panels.isEmpty, "Configured shortcuts work while the menu is open")

        show([.init(title: "One"), .init(title: "Selected", checked: true), .init(title: "Next", action: { fired.append("next") })])
        key(125); key(36)
        expect(fired.last == "next", "Picker navigation starts at the selected option")
        let edge = NSScreen.main!.visibleFrame
        let longTitle = "Export configuration, saved commands, shortcuts, themes and other preferences"
        show([.init(title: longTitle)])
        let longRow = buttons(presenter.panels[0].contentView!).first!
        let titleWidth = (longTitle as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width
        expect(longRow.bounds.width - 24 >= titleWidth, "A menu action that fits on screen must not be truncated")
        presenter.dismiss()
        presenter.show(items, at: NSPoint(x: edge.maxX - 1, y: edge.minY + 1), owner: owner)
        expect(edge.contains(presenter.panels[0].frame), "Menus at screen edges must remain fully visible")
        presenter.dismiss()
        func click(_ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: owner.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        presenter.show(items, below: field)
        expect(presenter.handlePointer(click(NSPoint(x: 30, y: 30))) && presenter.panels.isEmpty,
               "Clicking the trigger again must close the menu without reopening it")
        show()
        expect(!presenter.handlePointer(click(NSPoint(x: 500, y: 300))) && presenter.panels.isEmpty,
               "Outside clicks dismiss the menu and continue to the intended control")
        owner.orderOut(nil)
        print("PASS: family menus — palette, geometry, command validation, shortcuts, disabled items, keyboard navigation, submenus, selection, screen bounds and focus")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
