import AppKit

@MainActor private final class MenuTarget: NSObject, NSMenuItemValidation {
    var invoked = 0
    @objc func run(_ sender: NSMenuItem) { invoked = sender.tag }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { item.tag != 2 }
}

@main struct FamilyMenuTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let target = MenuTarget()
        let original = NSMenu()
        for tag in [1, 2, 3] {
            let item = NSMenuItem(title: "Action \(tag)", action: #selector(MenuTarget.run(_:)), keyEquivalent: tag == 3 ? "r" : "")
            item.target = target
            item.tag = tag
            if tag == 3 { item.keyEquivalentModifierMask = [.command, .shift] }
            original.addItem(item)
        }
        let commands = FamilyMenuItem.commands(from: original)
        expect(commands.map(\.enabled) == [true, false, true], "AppKit validation survives conversion")
        let menu = FamilyMenuPresenter.menu(commands)
        menu.performActionForItem(at: 0)
        expect(target.invoked == 1, "Original target and sender tag survive native presentation")
        expect(menu.items[2].keyEquivalent == "r" && menu.items[2].keyEquivalentModifierMask == [.command, .shift], "Native menu preserves configured shortcut")
        expect(!menu.items[1].isEnabled, "Disabled commands remain disabled")
        var invoked = false
        let nested = FamilyMenuPresenter.menu([
            .init(title: "Selected", checked: true), .separator,
            .init(title: "Parent", children: [.init(title: "Child", action: { invoked = true })])
        ])
        expect(nested.items[0].state == .on && nested.items[1].isSeparatorItem, "Checkmarks and separators survive")
        nested.items[2].submenu!.performActionForItem(at: 0)
        expect(invoked, "Submenus retain their action closures")
        expect(nested.items.allSatisfy { $0.view == nil }, "System renders menu items without custom views")
        print("FamilyMenuTests passed: native menu validation, targets, shortcuts, checkmarks, separators and submenu actions")
    }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
}
