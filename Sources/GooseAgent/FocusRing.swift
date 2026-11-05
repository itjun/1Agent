import SwiftUI

/// Compact family button treatments; native keyboard activation remains unchanged.
struct FamilyButtonStyle: PrimitiveButtonStyle {
    enum Kind { case plain, secondary, primary }
    var kind: Kind = .plain
    var showsFocusRing = true
    @Environment(\.windowChrome) private var chrome

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if chrome.isSystem {
            switch kind {
            case .plain:
                Button(configuration).buttonStyle(.plain)
            case .secondary:
                Button(configuration).buttonStyle(.bordered).controlSize(.large)
            case .primary:
                Button(configuration).buttonStyle(.borderedProminent).controlSize(.large)
            }
        } else {
            Button(configuration)
                .buttonStyle(FamilyThemedButtonStyle(kind: kind, showsFocusRing: showsFocusRing))
        }
    }
}

private struct FamilyThemedButtonStyle: ButtonStyle {
    var kind: FamilyButtonStyle.Kind
    var showsFocusRing: Bool
    @Environment(\.windowChrome) private var chrome
    @Environment(\.isShellTransparent) private var isShellTransparent
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        label(configuration)
            .padding(.horizontal, kind == .plain ? 0 : 12)
            .frame(minHeight: kind == .plain ? nil : Theme.Control.height)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(fill(configuration.isPressed)))
            .contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .stroke(showsFocusRing && focused ? chrome.focus : kind == .secondary ? chrome.lineStrong : Color.clear,
                            lineWidth: showsFocusRing && focused ? 2 : 1)
                    .padding(showsFocusRing && focused ? -2 : 0).allowsHitTesting(false)
            }
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovered = $0 }
    }

    @ViewBuilder private func label(_ configuration: Configuration) -> some View {
        if kind == .plain {
            configuration.label
        } else {
            configuration.label.foregroundStyle(kind == .primary ? chrome.filledForeground(on: fill(configuration.isPressed)) : chrome.text)
        }
    }

    private func fill(_ pressed: Bool) -> Color {
        if kind == .primary {
            return enabled && (pressed || hovered) ? chrome.secondary : chrome.text
        }
        if enabled && pressed { return chrome.hairline }
        if enabled && hovered { return chrome.hairline }
        return kind == .secondary ? chrome.background.opacity(isShellTransparent ? ShellLayout.controlOpacity : 1) : .clear
    }
}

private struct FamilyFocusRing: ViewModifier {
    @Environment(\.windowChrome) private var chrome
    var focused: Bool
    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control + 2)
                .stroke(focused ? chrome.focus : .clear, lineWidth: 2)
                .padding(-2).allowsHitTesting(false)
        }
    }
}

extension View {
    func familyFocusRing(_ focused: Bool) -> some View { modifier(FamilyFocusRing(focused: focused)) }
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
        // isFocused 会从可聚焦的整个列表继承；未选中的行不能据此绘制焦点框。
        let showsFocus = selected && isKeyboardTarget && focused && activeState != .inactive
        content
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(chrome.isSystem
                          ? (selected ? chrome.rowSelection(active: activeState != .inactive) : hovered ? chrome.hoverFill : .clear)
                          : legacyFill)
            }
            .overlay {
                if chrome.isSystem {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(showsFocus ? chrome.focus :
                            selected && contrast == .increased ? chrome.secondary : .clear,
                            lineWidth: showsFocus ? 2 : 1)
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovered = $0 }
    }
}

extension View {
    func defaultRowSurface(selected: Bool, legacyFill: Color, radius: CGFloat = Theme.Radius.control, isKeyboardTarget: Bool = true) -> some View {
        modifier(DefaultRowSurface(selected: selected, legacyFill: legacyFill, isKeyboardTarget: isKeyboardTarget, radius: radius))
    }
}
