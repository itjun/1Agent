import AppKit
import SwiftUI

/// Commands are independent of presentation. Existing AppKit menus remain command models,
/// so their targets, validation, shortcuts and submenus survive native presentation.
@MainActor
struct FamilyMenuItem {
    var title: String
    var image: NSImage? = nil
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
                title: item.title, image: item.image, enabled: item.isEnabled, checked: item.state != .off,
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

/// 系统菜单负责绘制、键盘导航、子菜单和关闭行为。
@MainActor
final class FamilyMenuPresenter {
    static let shared = FamilyMenuPresenter()
    private(set) var activeMenu: NSMenu?

    func show(_ menu: NSMenu, with event: NSEvent, for view: NSView) {
        activeMenu = menu
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        activeMenu = nil
    }

    func show(_ items: [FamilyMenuItem], with event: NSEvent, for view: NSView) {
        show(Self.menu(items), with: event, for: view)
    }

    func show(_ items: [FamilyMenuItem], below view: NSView, selection: Bool = false,
              onDismiss: @escaping () -> Void = {}) {
        let menu = Self.menu(items)
        activeMenu = menu
        let point = NSPoint(x: view.bounds.minX, y: view.isFlipped ? view.bounds.maxY : view.bounds.minY)
        menu.popUp(positioning: selection ? menu.items.first { $0.state == .on } : nil, at: point, in: view)
        activeMenu = nil
        onDismiss()
    }

    func show(_ items: [FamilyMenuItem], centeredBelow view: NSView) {
        show(items, below: view)
    }

    func show(_ items: [FamilyMenuItem], at point: NSPoint, owner: NSWindow,
              minWidth: CGFloat = 180, maxHeight: CGFloat = 640, above: CGFloat? = nil, centered: Bool = false) {
        let menu = Self.menu(items)
        activeMenu = menu
        menu.popUp(positioning: nil, at: point, in: nil)
        activeMenu = nil
    }

    /// macOS 27 起 AppKit 会隐藏菜单图标；preferredImageVisibility 声明只在最新 SDK 里。
    /// 运行时探测 setter，编译期不引用符号，旧 Xcode 也能编译。
    private static func forceMenuImageVisible(_ item: NSMenuItem) {
        let selector = NSSelectorFromString("setPreferredImageVisibility:")
        guard item.responds(to: selector) else { return }
        let setter = unsafeBitCast(item.method(for: selector),
                                   to: (@convention(c) (NSObject, Selector, Int) -> Void).self)
        setter(item, selector, 1) // NSMenuItemImageVisibilityVisible
    }

    func dismiss() {
        activeMenu?.cancelTracking()
        activeMenu = nil
    }

    static func menu(_ commands: [FamilyMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for command in commands {
            if command.isSeparator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: command.title, action: nil, keyEquivalent: command.key)
            item.image = command.image
            if command.image != nil { Self.forceMenuImageVisible(item) }
            item.keyEquivalentModifierMask = command.modifiers
            item.isEnabled = command.enabled
            item.state = command.checked ? .on : .off
            if command.children.isEmpty {
                let target = NativeMenuAction(command.action)
                item.target = target
                item.action = #selector(NativeMenuAction.invokeMenuCommand(_:))
                item.representedObject = target
            } else {
                item.submenu = Self.menu(command.children)
            }
            menu.addItem(item)
        }
        return menu
    }
}

@MainActor
private final class NativeMenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invokeMenuCommand(_ sender: NSMenuItem) { action() }
}
