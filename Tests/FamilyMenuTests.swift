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
        let target = MenuTarget()
        let source = NSMenu()
        let applicationIcon = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        for tag in [1, 2, 3] {
            let item = NSMenuItem(title: "Action \(tag)", action: #selector(MenuTarget.run(_:)), keyEquivalent: tag == 3 ? "r" : "")
            item.target = target
            item.tag = tag
            if tag == 1 { item.image = applicationIcon }
            if tag == 3 { item.keyEquivalentModifierMask = [.command, .shift] }
            source.addItem(item)
        }
        let commands = FamilyMenuItem.commands(from: source)
        expect(commands.map(\.enabled) == [true, false, true], "AppKit validation survives conversion")
        let menu = FamilyMenuPresenter.menu(commands)
        expect(menu.items[0].image === applicationIcon, "Application icons survive native menu conversion")
        if #available(macOS 27.0, *) {
            expect(menu.items[0].preferredImageVisibility == .visible, "Application icons remain visible on macOS 27")
        }
        expect(menu.items.map(\.isEnabled) == [true, false, true], "Native menu preserves disabled actions")
        expect(menu.items[2].keyEquivalent == "r" && menu.items[2].keyEquivalentModifierMask == [.command, .shift], "Native shortcuts survive conversion")
        menu.performActionForItem(at: 0)
        expect(target.invoked == 1, "Original action target and sender tag survive native action dispatch")
        var fired = false
        let nested = FamilyMenuPresenter.menu([
            .init(title: "Checked", checked: true), .separator,
            .init(title: "Parent", children: [.init(title: "Child", action: { fired = true })])
        ])
        expect(nested.items[0].state == .on && nested.items[1].isSeparatorItem, "Selection and separators remain native")
        nested.items[2].submenu!.performActionForItem(at: 0)
        expect(fired, "Submenu closures remain alive and callable")
        print("PASS: native menu validation, disabled actions, shortcuts, selection, separators, targets and submenus")
    }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
