import SwiftUI

/// An inline status strip. Its transparent context anchor preserves ordinary mouse and
/// scroll routing, including right-clicking the recovery button to close the pane.
struct TerminalConnectionBanner: View {
    @Environment(\.windowChrome) private var chrome
    var tab: TerminalTab
    var onRecover: () -> Void
    var menuItems: () -> [FamilyMenuItem]

    private var tint: Color { tab.reconnecting ? chrome.warning : chrome.danger }

    private var message: String {
        if tab.reconnecting {
            if tab.reconnectAttempts > 0 {
                return String(
                    format: String(localized: "Connection lost, reconnecting (%lld/%lld)"),
                    tab.reconnectAttempts,
                    AppModel.maxAutoReconnectAttempts
                )
            }
            return String(localized: "Reconnecting…")
        }
        return tab.isLocal ? String(localized: "Terminal Exited") : String(localized: "Connection closed")
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                if tab.reconnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(verbatim: message)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .allowsHitTesting(false)
            Spacer(minLength: 0)
            if tab.showsDisconnected {
                Button(action: onRecover) {
                    Label(tab.isLocal ? String(localized: "Reopen Terminal") : String(localized: "Reconnect"),
                          systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(chrome.background)
                        .fixedSize()
                        .frame(minHeight: 32)
                }
                .buttonStyle(FamilyButtonStyle(kind: .primary))
                .help(AppShortcuts.display(for: .reconnect))
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack(alignment: .leading) {
                chrome.background
                tint.opacity(Theme.PaneStyle.bannerTintOpacity)
                Rectangle().fill(tint).frame(width: 3)
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(tint.opacity(0.35)).frame(height: 1)
                .allowsHitTesting(false)
        }
        .familyContextMenu(menuItems)
    }
}
