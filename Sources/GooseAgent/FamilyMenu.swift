import AppKit
import SwiftUI

/// Commands are independent of presentation. Existing AppKit menus remain command models,
/// so their targets, validation, shortcuts and submenus keep working with native menus.
@MainActor
struct FamilyMenuItem {
    var title: String
    var enabled = true
    var checked = false
    var destructive = false
    var key = ""
    var modifiers: NSEvent.ModifierFlags = []
    var children: [FamilyMenuItem] = []
    var action: () -> Void = {}
    var isSeparator = false

    static var separator: Self { Self(title: "", enabled: false, isSeparator: true) }

    var shortcut: String {
        guard !key.isEmpty else { return "" }
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let special = ["\r": "↩", "\u{1b}": "⎋", "\t": "⇥", "\u{7f}": "⌫", " ": "␣",
                       "\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←", "\u{f703}": "→",
                       "\u{f728}": "⌦", "\u{f729}": "↖", "\u{f72b}": "↘", "\u{f72c}": "⇞", "\u{f72d}": "⇟"]
        let scalar = key.unicodeScalars.first?.value ?? 0
        let function = key.unicodeScalars.count == 1 && (0xf704...0xf726).contains(scalar) ? "F\(scalar - 0xf704 + 1)" : nil
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + (special[key] ?? function ?? key.uppercased())
    }

    static func commands(from menu: NSMenu) -> [Self] {
        menu.delegate?.menuWillOpen?(menu)
        menu.update()
        return menu.items.filter { !$0.isHidden }.map { item in
            if item.isSeparatorItem { return .separator }
            return Self(
                title: item.title, enabled: item.isEnabled, checked: item.state != .off,
                destructive: item.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil,
                key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask,
                children: item.submenu.map { commands(from: $0) } ?? [],
                action: {
                    if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
                }
            )
        }
    }
}

/// 菜单模型保留原有动作，显示及键盘导航交给 NSMenu。
@MainActor
final class FamilyMenuPresenter {
    static let shared = FamilyMenuPresenter()
    private(set) var activeMenu: NSMenu?
    var isPresented: Bool { activeMenu != nil }

    static func menu(_ items: [FamilyMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.isSeparator { menu.addItem(.separator()); continue }
            let native = NativeActionMenuItem(item)
            if !item.children.isEmpty { native.submenu = Self.menu(item.children) }
            menu.addItem(native)
        }
        return menu
    }

    func show(_ menu: NSMenu, with event: NSEvent, for view: NSView) {
        dismiss()
        activeMenu = menu
        defer { activeMenu = nil }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    func show(_ items: [FamilyMenuItem], with event: NSEvent, for view: NSView) {
        show(Self.menu(items), with: event, for: view)
    }

    func show(_ items: [FamilyMenuItem], below view: NSView, selection: Bool = false, onDismiss: @escaping () -> Void = {}) {
        dismiss()
        let menu = Self.menu(items)
        activeMenu = menu
        defer { activeMenu = nil; onDismiss() }
        let point = NSPoint(x: view.bounds.minX, y: view.isFlipped ? view.bounds.maxY : view.bounds.minY)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    func show(_ items: [FamilyMenuItem], centeredBelow view: NSView) { show(items, below: view) }

    func show(_ items: [FamilyMenuItem], at point: NSPoint, owner: NSWindow,
              minWidth: CGFloat = 180, maxHeight: CGFloat = 640, above: CGFloat? = nil, centered: Bool = false) {
        dismiss()
        let menu = Self.menu(items)
        activeMenu = menu
        defer { activeMenu = nil }
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    func dismiss() { activeMenu?.cancelTracking() }
}

private final class NativeActionMenuItem: NSMenuItem {
    private let perform: () -> Void
    @MainActor init(_ item: FamilyMenuItem) {
        perform = item.action
        super.init(title: item.title, action: #selector(invoke), keyEquivalent: item.key)
        target = self
        keyEquivalentModifierMask = item.modifiers
        isEnabled = item.enabled
        state = item.checked ? .on : .off
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { perform() }
}
