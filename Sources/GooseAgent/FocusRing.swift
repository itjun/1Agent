import SwiftUI

/// Compact family button treatments; native keyboard activation remains unchanged.
struct FamilyButtonStyle: ButtonStyle {
    enum Kind { case plain, secondary, primary }
    var kind: Kind = .plain
    @Environment(\.windowChrome) private var chrome
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        label(configuration)
            .padding(.horizontal, kind == .plain ? 0 : 12)
            .frame(minHeight: kind == .plain ? nil : Theme.Control.height)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(fill(configuration.isPressed)))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .stroke(focused ? chrome.focus : Color.clear, lineWidth: 2)
                    .padding(-2).allowsHitTesting(false)
            }
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovered = $0 }
    }

    @ViewBuilder private func label(_ configuration: Configuration) -> some View {
        if kind == .plain {
            configuration.label
        } else {
            configuration.label.foregroundStyle(kind == .primary ? Color.white : chrome.text)
        }
    }

    private func fill(_ pressed: Bool) -> Color {
        if kind == .primary {
            return enabled && pressed ? chrome.accentActive : enabled && hovered ? chrome.accentHover : chrome.accent
        }
        if enabled && pressed { return chrome.accentFill }
        if enabled && hovered { return chrome.hairline }
        return kind == .secondary ? chrome.elevated : .clear
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
