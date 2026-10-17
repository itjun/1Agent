import SwiftUI

/// Passive chrome shared by the window title band and lower split headers.
/// Reserve the same space in every focus state so the host title never jumps.
struct TerminalInputIndicator: View {
    @Environment(\.windowChrome) private var chrome
    var active: Bool
    var paneWidth: CGFloat
    var sessionID: String

    static func reservedWidth(for paneWidth: CGFloat) -> CGFloat {
        if paneWidth >= Theme.PaneStyle.inputLabelMinimumWidth {
            return Theme.PaneStyle.inputLabelWidth + Theme.PaneStyle.inputTrailingInset
        }
        if paneWidth >= Theme.PaneStyle.inputIconMinimumWidth {
            return Theme.PaneStyle.inputIconWidth + Theme.PaneStyle.inputTrailingInset
        }
        return Theme.Space.s
    }

    var body: some View {
        if active && paneWidth >= Theme.PaneStyle.inputIconMinimumWidth {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "keyboard")
                if paneWidth >= Theme.PaneStyle.inputLabelMinimumWidth {
                    Text("Current Input")
                }
            }
            .font(.system(size: Theme.PaneStyle.statusIconSize, weight: .medium))
            .foregroundStyle(chrome.secondary)
            .fixedSize()
            .padding(.trailing, Theme.PaneStyle.inputTrailingInset)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Current Input"))
            .accessibilityIdentifier("terminal.currentInput." + sessionID)
            .transaction { $0.animation = nil }
        }
    }
}
