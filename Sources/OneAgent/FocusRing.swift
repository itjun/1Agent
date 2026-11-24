import AppKit
import SwiftUI

/// 预览和表单按钮使用系统控件尺寸与外观。
struct PreviewCardButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(.borderless).controlSize(.small).clickableCursor()
    }
}

struct FamilyButtonStyle: PrimitiveButtonStyle {
    enum Kind { case plain, primary, secondary }
    var kind: Kind = .plain
    var showsFocusRing = true

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        switch kind {
        case .plain: Button(configuration).buttonStyle(.borderless).clickableCursor()
        case .primary: Button(configuration).buttonStyle(.borderedProminent).clickableCursor()
        case .secondary: Button(configuration).buttonStyle(.bordered).clickableCursor()
        }
    }
}

struct FamilyPlainButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(.plain).clickableCursor()
    }
}

private struct ClickableCursor: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(isEnabled ? .link : nil)
        } else {
            content.background(ClickableCursorRegion(isEnabled: isEnabled))
        }
    }
}

/// 仅标记可点击区域；不接管事件，也不覆盖输入框、终端和拖动区域的光标。
extension View {
    func clickableCursor() -> some View { modifier(ClickableCursor()) }
}

private struct ClickableCursorRegion: NSViewRepresentable {
    var isEnabled: Bool
    func makeNSView(context: Context) -> ClickableCursorView { ClickableCursorView() }
    func updateNSView(_ view: ClickableCursorView, context: Context) { view.isEnabled = isEnabled }
}

/// macOS 14 和 AppKit 控件共用；由系统维护光标区域，避免 push/pop 泄漏。
final class ClickableCursorView: NSView {
    var isEnabled = true {
        didSet { if oldValue != isEnabled { window?.invalidateCursorRects(for: self) } }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard isEnabled, (superview as? NSControl)?.isEnabled != false else { return }
        addVisibleCursorRect(.pointingHand)
    }

    static func attach(to control: NSControl) {
        let view = ClickableCursorView(frame: control.bounds)
        view.autoresizingMask = [.width, .height]
        control.addSubview(view)
    }
}

extension NSView {
    /// 滚动到可视区域之外时交集可能是 null，AppKit 不接受这种光标矩形。
    func addVisibleCursorRect(_ cursor: NSCursor) {
        let rect = bounds.intersection(visibleRect)
        guard !rect.isEmpty else { return }
        addCursorRect(rect, cursor: cursor)
    }
}

extension View {
    // 原生输入框和按钮各自显示键盘焦点，避免外面再套一层描边。
    func familyFocusRing(_ focused: Bool) -> some View { self }
}

/// 系统主题行状态统一处理，非默认预设完全使用调用处的原有样式。
private struct DefaultRowSurface: ViewModifier {
    @Environment(\.windowChrome) private var chrome
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isFocused) private var focused
    @State private var hovered = false
    var selected: Bool
    var legacyFill: Color
    var isKeyboardTarget: Bool
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(chrome.isSystem
                          ? (selected ? chrome.rowSelection(active: activeState != .inactive) : hovered ? chrome.hoverFill : .clear)
                          : legacyFill)
            }
            .onHover { hovered = $0 }
    }
}

extension View {
    func defaultRowSurface(selected: Bool, legacyFill: Color, radius: CGFloat = Theme.Radius.control, isKeyboardTarget: Bool = true) -> some View {
        modifier(DefaultRowSurface(selected: selected, legacyFill: legacyFill, isKeyboardTarget: isKeyboardTarget, radius: radius))
    }
}
