import AppKit
import QuartzCore
import SwiftUI

struct TerminalCanvas: View {
    /// One title line. Dragging this line merges panes.
    static let sidebarHeaderHeight: CGFloat = 18

    @Environment(\.windowChrome) private var chrome
    @Environment(\.isKeyWindow) private var isKeyWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    var dropRelay: CanvasDropRelay
    var dark: Bool
    @State private var ratioDrag: (id: UUID, start: CGFloat)?
    /// Last on-screen content rect per tab. Hidden tabs keep this size/position so Ghostty
    /// does not resize the PTY to 1×1 (which reflows scrollback and jumps the cursor).
    @State private var lastContentFrame: [UUID: CGRect] = [:]

    private var headerHeight: CGFloat { Self.sidebarHeaderHeight }

    var body: some View {
        GeometryReader { geo in
            let root = model.displayRoot(in: window)
            let bounds = CGRect(origin: .zero, size: geo.size)
            let layout = bounds
            let frames = root.map { PaneLayout.frames(of: $0, in: layout) } ?? [:]
            let dividers = root.map { PaneLayout.dividers(of: $0, in: layout) } ?? []
            let headerH = headerHeight
            let fallbackContent = Self.contentFrame(layout, headerHeight: headerH)
            // Only this window's terminals get a view here. A terminal shown in another window
            // keeps its process; the registry hands the same view over when it moves.
            let shown = Set(model.sidebarOrder(in: window))
            let ownTabs = model.tabs.filter { $0.isSession && shown.contains($0.id) }
            let liveIDs = Set(ownTabs.map(\.id))
            let _ = dropRelay.sync(frames: frames, model: model, window: window)
            ZStack(alignment: .topLeading) {
                chrome.background
                ForEach(ownTabs) { tab in
                    let content = frames[tab.id].map { Self.contentFrame($0, headerHeight: headerH) }
                    let drawn = content ?? lastContentFrame[tab.id] ?? fallbackContent
                    let visible = content != nil
                    SSHTerminalView(
                        sessionID: tab.sessionID,
                        alias: tab.alias ?? "",
                        directory: tab.isLocal ? tab.directory : nil,
                        environment: model.launchEnvironment,
                        dark: dark,
                        focusesOnCreate: window.selectedTabID == tab.id,
                        onExit: { code, lived in
                            // A local shell exit closes the tab. ssh uses 255 when the connection itself fails.
                            if tab.isLocal {
                                model.closeTab(tab.id)
                            } else if let code, code != 255 {
                                model.closeTab(tab.id)
                            } else {
                                model.markClosed(tab.id, lived: lived)
                            }
                        },
                        onClose: { model.closeTab(tab.id) },
                        onFocus: { model.notePaneFocused(tab.id, in: window) }
                    )
                    .id(tab.sessionID)
                    .frame(
                        width: max(drawn.width, 1),
                        height: max(drawn.height, 1)
                    )
                    .position(
                        x: drawn.midX,
                        y: drawn.midY
                    )
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(visible)
                    .accessibilityHidden(!visible)
                    .zIndex(visible ? 1 : 0)
                    .onChange(of: content) { _, newContent in
                        guard let newContent else { return }
                        lastContentFrame[tab.id] = newContent
                    }
                    .onAppear {
                        if let content {
                            lastContentFrame[tab.id] = content
                        }
                    }
                }
                ForEach(dividers) { divider in
                    dividerControl(divider)
                }
                ForEach(model.tabs.filter { frames[$0.id] != nil }) { tab in
                    if let frame = frames[tab.id] {
                        paneChrome(tab, frame: frame, headerHeight: headerH, isSplit: frames.count > 1)
                    }
                }
            }
            .overlay {
                PaneDropCatcher(relay: dropRelay, chrome: chrome)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
            }
            .onChange(of: liveIDs) { _, ids in
                lastContentFrame = lastContentFrame.filter { ids.contains($0.key) }
            }
        }
    }

    private func dividerControl(_ divider: PaneDivider) -> some View {
        let vertical = divider.axis == .vertical
        return Color.clear
            .frame(width: divider.frame.width, height: divider.frame.height)
            .overlay {
                Rectangle()
                    .fill(chrome.hairline)
                    .frame(
                        width: vertical ? 1 : divider.frame.width,
                        height: vertical ? divider.frame.height : 1
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .offset(x: divider.frame.minX, y: divider.frame.minY)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = ratioDrag?.id == divider.id ? ratioDrag!.start : currentRatio(divider.id)
                        if ratioDrag?.id != divider.id {
                            ratioDrag = (divider.id, start)
                        }
                        let delta = divider.axis == .vertical ? value.translation.width : value.translation.height
                        guard divider.span > 1 else { return }
                        model.setSplitRatio(divider.id, to: start + delta / divider.span)
                    }
                    .onEnded { _ in ratioDrag = nil }
            )
            .zIndex(4)
    }

    private func currentRatio(_ id: UUID) -> CGFloat {
        func find(_ node: PaneNode) -> CGFloat? {
            guard case .split(let split) = node else { return nil }
            if split.id == id { return split.ratio }
            if let leading = find(split.leading) {
                return leading
            }
            return find(split.trailing)
        }
        for workspace in model.workspaces {
            if let ratio = find(workspace.layout) {
                return ratio
            }
        }
        return 0.5
    }

    /// The focused pane's title takes the accent; other panes in a split fall back to secondary. Danger always wins.
    private func hostTitleColor(_ tab: TerminalTab, focused: Bool, dimmed: Bool) -> Color {
        if tab.showsDisconnected || tab.reconnecting {
            return chrome.danger
        }
        if focused {
            return chrome.accent
        }
        if dimmed {
            return chrome.secondary
        }
        return chrome.text
    }

    @ViewBuilder
    private func paneChrome(_ tab: TerminalTab, frame: CGRect, headerHeight: CGFloat, isSplit: Bool) -> some View {
        let focused = window.selectedTabID == tab.id
        let highlighted = focused && isSplit
        let focusColor = isKeyWindow ? chrome.accent : chrome.secondary
        let dimmed = !focused && isSplit
        if headerHeight > 0 {
            ZStack {
                chrome.background
                    .allowsHitTesting(false)
                focusColor
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                        $0.opacity(highlighted ? 0.12 : 0)
                    }
                    .allowsHitTesting(false)
                // A 2pt accent bar along the top makes the focused pane readable at a glance in a grid.
                VStack(spacing: 0) {
                    focusColor
                        .frame(height: 2)
                        .opacity(highlighted ? 1 : 0)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)
                HStack(spacing: 6) {
                    DuplicateHostDot(mark: model.duplicateHostMark(for: tab.id))
                    Text(paneTitle(tab))
                        .font(.system(size: 12, weight: highlighted ? .semibold : .medium, design: .monospaced))
                        .foregroundStyle(hostTitleColor(tab, focused: highlighted && isKeyWindow, dimmed: dimmed))
                        .lineLimit(1)
                    if tab.reconnecting {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(chrome.danger)
                            .accessibilityLabel(Text("Reconnecting…"))
                    } else if tab.showsDisconnected {
                        Image(systemName: "link.slash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(chrome.danger)
                            .accessibilityLabel(Text("Connection closed"))
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                TabDragHandle(
                    onClick: { _, _ in model.selectOnly(tab.id, in: window) },
                    onBegan: { dropRelay.dragBegan(tab.id) },
                    onMoved: { dropRelay.dragMoved(windowPoint: $0) },
                    onEnded: { dropRelay.dragEnded(windowPoint: $0) },
                    onSecondaryClick: { copySessionInfo(tab, model: model) },
                    freezesWindow: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .help(String(localized: "Drag the title onto the top, bottom, left, or right of a pane to merge. Drag it back to the sidebar to separate it. Right-click the title to copy host info."))
            }
            .frame(width: frame.width, height: headerHeight)
            .position(x: frame.midX, y: frame.minY + headerHeight / 2)
            .zIndex(4)
        }
        if focused, tab.reconnecting {
            Text("Reconnecting…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(chrome.secondary)
                .position(x: frame.midX, y: frame.maxY - 28)
                .zIndex(4)
        } else if focused, tab.showsDisconnected {
            Button {
                model.reconnect(tab.id)
            } label: {
                Text("Reconnect")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(chrome.background)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(chrome.accent))
            }
            .buttonStyle(.plain)
            .position(x: frame.midX, y: frame.maxY - 28)
            .zIndex(4)
        }
    }

    private func paneTitle(_ tab: TerminalTab) -> String {
        if tab.isLocal, let directory = tab.directory {
            return LocalTerminal.displayPath(directory)
        }
        let alias = tab.alias ?? ""
        return model.host(alias)?.sessionBadge ?? alias
    }

}

/// Alias, address, and user for a remote host. The directory path for a local terminal.
@MainActor
func copySessionInfo(_ tab: TerminalTab, model: AppModel) {
    let text: String
    if tab.isLocal {
        text = tab.directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    } else if let alias = tab.alias {
        let copied = model.host(alias)?.connectionCopyText ?? ""
        if copied.isEmpty {
            text = alias
        } else {
            text = copied
        }
    } else {
        text = ""
    }
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

extension TerminalCanvas {
    static func contentFrame(_ frame: CGRect, headerHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: frame.minY + headerHeight,
            width: frame.width,
            height: max(frame.height - headerHeight, 1)
        )
    }
}
