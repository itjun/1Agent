import SwiftUI

/// Compact family button treatments; native keyboard activation remains unchanged.
struct FamilyButtonStyle: ButtonStyle {
    enum Kind { case plain, secondary, primary }
    var kind: Kind = .plain
    var showsFocusRing = true
    @Environment(\.windowChrome) private var chrome
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
        return kind == .secondary ? chrome.background : .clear
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
