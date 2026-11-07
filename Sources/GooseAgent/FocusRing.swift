import AppKit
import SwiftUI

/// 预览和表单按钮使用系统控件尺寸与外观。
struct PreviewCardButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(.borderless).controlSize(.small)
    }
}

struct FamilyButtonStyle: PrimitiveButtonStyle {
    enum Kind { case plain, primary, secondary }
    var kind: Kind = .plain
    var showsFocusRing = true

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        switch kind {
        case .plain: Button(configuration).buttonStyle(.borderless)
        case .primary: Button(configuration).buttonStyle(.borderedProminent)
        case .secondary: Button(configuration).buttonStyle(.bordered)
        }
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
