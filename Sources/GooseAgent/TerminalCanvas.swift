import AppKit
import QuartzCore
import SwiftUI

struct TerminalCanvas: View {
    @Environment(\.windowChrome) private var chrome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @ObservedObject private var find = TerminalFind.shared
    @ObservedObject private var inputFocus = FocusedTerminal.shared
    @AppStorage(TerminalSettings.paddingXKey) private var terminalPaddingX = TerminalSettings.defaults.paddingX
    var dropRelay: CanvasDropRelay
    var dark: Bool
    /// `id` is the dragged divider, `split` the split it resizes (a detached segment gets its own split).
    @State private var ratioDrag: (id: UUID, split: UUID, start: CGFloat)?
    /// Divider under the pointer. Its line turns accent while set.
    @State private var hoveredDividerID: UUID?
    /// Last on-screen content rect per tab. Hidden tabs keep this size/position so Ghostty
    /// does not resize the PTY to 1×1 (which reflows scrollback and jumps the cursor).
    @State private var lastContentFrame: [UUID: CGRect] = [:]

    /// The first row's titles live in the stable window band. Lower split rows own a header.
    static func headerHeight(for frame: CGRect) -> CGFloat {
        frame.minY < 1 ? 0 : Theme.PaneStyle.headerHeight
    }

    var body: some View {
        GeometryReader { geo in
            let root = model.displayRoot(in: window)
            let bounds = CGRect(origin: .zero, size: geo.size)
            let layout = bounds
            let zoomed = model.zoomedPane(in: window)
            let frames = Self.paneFrames(root, zoomed: zoomed, in: layout)
            let dividers = Self.paneDividers(root, zoomed: zoomed, in: layout)
            let isSplit = frames.count > 1
            let fallbackContent = Self.contentFrame(layout, headerHeight: 0)
            // Only this window's terminals get a view here. A terminal shown in another window
            // keeps its process; the registry hands the same view over when it moves.
            let shown = Set(model.sidebarOrder(in: window))
            let ownTabs = model.tabs.filter { $0.hasTerminal && shown.contains($0.id) }
            let liveIDs = Set(ownTabs.map(\.id))
            let _ = dropRelay.sync(frames: frames, model: model, window: window)
            ZStack(alignment: .topLeading) {
                chrome.background
                ForEach(ownTabs) { tab in
                    let content = frames[tab.id].map { Self.contentFrame($0, headerHeight: Self.headerHeight(for: $0) + findBarInset(tab)) }
                    let drawn = content ?? lastContentFrame[tab.id] ?? fallbackContent
                    let visible = content != nil
                    SSHTerminalView(
                        sessionID: tab.sessionID,
                        alias: tab.alias ?? "",
                        directory: tab.isLocal ? tab.directory : nil,
                        remoteDirectory: tab.remoteDirectory,
                        environment: ShellIntegrationEnvironment.merged(model.launchEnvironment, overrides: tab.creationEnvironment),
                        dark: dark,
                        initialFontSize: tab.creationFontSize,
                        restoration: tab.restoration,
                        isPresented: visible && !window.presentation.fullFilesWorkspace,
                        isSelected: window.selectedTabID == tab.id && window.section == .terminals,
                        focusRailColor: isSplit && visible && window.selectedTabID == tab.id
                            && !window.presentation.fullFilesWorkspace
                            && CGFloat(terminalPaddingX) >= Theme.PaneStyle.focusRailInset + Theme.PaneStyle.focusRailWidth
                            ? NSColor(inputFocus.receivesInput(tab, in: window) ? chrome.accent : chrome.secondary.opacity(0.5)) : nil,
                        canFocus: {
                            window.selectedTabID == tab.id && window.section == .terminals &&
                                !window.presentation.fullFilesWorkspace
                        },
                        takeInitialInput: { model.takeInitialInput(for: tab.id) },
                        takeRemoteStartupCommand: { model.takeRemoteStartupCommand(for: tab.id) },
                        takeLocalStartupCommand: { model.takeLocalStartupCommand(for: tab.id) },
                        onExit: { code, lived in
                            model.terminalDidExit(tab.id, code: code, lived: lived)
                        },
                        onClose: { model.closeTab(tab.id) },
                        onFocus: { model.notePaneFocused(tab.id, in: window) },
                        onSplit: { edge in model.duplicate(tab.id, edge: edge) },
                        onRevealFiles: { model.showFiles(for: tab.id, in: window) },
                        paneMenuItems: { TerminalPaneActions.items(tab: tab, model: model, window: window, includingFind: false) },
                        onFileDrop: { urls, zone in model.openDropped(urls, zone: zone, on: tab.id, in: window) },
                        canDropQuickCommand: { model.commandForDrop($0, on: tab.id, in: window) != nil },
                        onQuickCommandDrop: { model.confirmDroppedQuickCommand($0, on: tab.id, in: window) }
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
                ForEach(model.tabs.filter { !$0.content.isTerminal && frames[$0.id] != nil }) { tab in
                    if let frame = frames[tab.id] {
                        let content = Self.contentFrame(frame, headerHeight: Self.headerHeight(for: frame))
                        PaneContentView(model: model, window: window, tab: tab)
                            .frame(width: content.width, height: content.height)
                            .position(x: content.midX, y: content.midY)
                            .zIndex(1)
                    }
                }
                ForEach(dividers) { divider in
                    dividerControl(divider, in: layout)
                }
                ForEach(model.tabs.filter { frames[$0.id] != nil }) { tab in
                    if let frame = frames[tab.id] {
                        paneChrome(tab, frame: frame, headerHeight: Self.headerHeight(for: frame), isSplit: isSplit, isZoomed: zoomed == tab.id)
                    }
                }
                if isSplit, let selected = window.selectedTabID, let frame = frames[selected],
                   model.tabs.first(where: { $0.id == selected })?.hasTerminal != true {
                    Rectangle()
                        .strokeBorder(chrome.accent.opacity(window.section == .terminals ? 0.75 : 0.3), lineWidth: 1)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .zIndex(5)
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

    private func dividerControl(_ divider: PaneDivider, in layout: CGRect) -> some View {
        let vertical = divider.axis == .vertical
        let active = hoveredDividerID == divider.id || ratioDrag?.id == divider.id
        var lineWidth = Theme.PaneStyle.dividerLineWidth
        if active {
            lineWidth = Theme.PaneStyle.dividerActiveLineWidth
        }
        return Color.clear
            .frame(width: divider.frame.width, height: divider.frame.height)
            .overlay {
                Rectangle()
                    .fill(active ? chrome.accent : chrome.hairline)
                    .frame(
                        width: vertical ? lineWidth : divider.frame.width,
                        height: vertical ? divider.frame.height : lineWidth
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                // AppKit owns the cursor here: the terminal views underneath set their own cursor
                // on every move, which a SwiftUI hover push cannot win against.
                PaneDividerHandle(
                    vertical: vertical,
                    onHover: { inside in
                        if inside {
                            hoveredDividerID = divider.id
                        } else if hoveredDividerID == divider.id {
                            hoveredDividerID = nil
                        }
                    },
                    onDragChanged: { delta in
                        if ratioDrag?.id != divider.id {
                            let start = currentRatio(divider.splitID)
                            var split = divider.splitID
                            if let segment = divider.segment,
                               let detached = model.detachDividerSegment(segment, of: divider.splitID, in: layout) {
                                split = detached
                            }
                            ratioDrag = (divider.id, split, start)
                        }
                        guard let drag = ratioDrag else { return }
                        guard divider.span > 1 else { return }
                        model.setSplitRatio(drag.split, to: drag.start + delta / divider.span)
                    },
                    onDragEnded: { ratioDrag = nil },
                    onDoubleClick: {
                        var split = divider.splitID
                        if let segment = divider.segment,
                           let detached = model.detachDividerSegment(segment, of: divider.splitID, in: layout) {
                            split = detached
                        }
                        model.evenOutSplit(split)
                    }
                )
            }
            .offset(x: divider.frame.minX, y: divider.frame.minY)
            .onDisappear {
                if hoveredDividerID == divider.id {
                    hoveredDividerID = nil
                }
            }
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
        for panel in model.workspaces.flatMap(\.panels) {
            if let ratio = find(panel.layout) {
                return ratio
            }
        }
        return 0.5
    }

    /// The focused pane's title takes the accent; other panes in a split fall back to secondary.
    /// Connection state is shown by the icon next to the title, not by recoloring the text.
    private func hostTitleColor(focused: Bool) -> Color {
        if focused {
            return chrome.accent
        }
        return chrome.secondary
    }

    @ViewBuilder
    private func paneChrome(_ tab: TerminalTab, frame: CGRect, headerHeight: CGFloat, isSplit: Bool, isZoomed: Bool) -> some View {
        let selected = window.selectedTabID == tab.id
        let focused = tab.hasTerminal ? inputFocus.receivesInput(tab, in: window) : selected
        if isSplit && headerHeight > 0 {
            ZStack {
                chrome.panelHeader
                    .allowsHitTesting(false)
                WindowDragArea(onClick: { model.selectOnly(tab.id, in: window) })
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    PaneProgressBar(sessionID: tab.sessionID)
                }
                .allowsHitTesting(false)
                // Only the title merges panes; the blank rest of the bar moves the window.
                HStack(spacing: 6) {
                    DuplicateHostDot(mark: model.duplicateHostMark(for: tab.id))
                    Text(paneTitle(tab))
                        .font(Theme.Font.paneTitle)
                        .fontWeight(selected ? .semibold : .medium)
                        .foregroundStyle(hostTitleColor(focused: focused))
                        .lineLimit(1)
                        .layoutPriority(1)
                    RemoteTitleStatus(tab: tab)
                        .font(Theme.Font.paneTitle)
                    if tab.reconnecting {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: Theme.PaneStyle.statusIconSize, weight: .medium))
                            .foregroundStyle(chrome.warning)
                            .accessibilityLabel(Text("Reconnecting…"))
                    } else if tab.showsDisconnected {
                        Image(systemName: "link.slash")
                            .font(.system(size: Theme.PaneStyle.statusIconSize, weight: .medium))
                            .foregroundStyle(chrome.danger)
                            .accessibilityLabel(Text(tab.isLocal ? String(localized: "Terminal Exited") : String(localized: "Connection closed")))
                    }
                }
                .allowsHitTesting(false)
                .padding(.horizontal, Theme.Space.s)
                .frame(maxHeight: .infinity)
                .overlay {
                    TabDragHandle(
                        onClick: { _, _ in },
                        onActivate: { TerminalPaneActions.showTitleContext(model: model, window: window, tabID: tab.id, anchor: $0) },
                        onBegan: { dropRelay.dragBegan(tab.id, fromPane: true) },
                        onMoved: { dropRelay.dragMoved(windowPoint: $0) },
                        onEnded: { dropRelay.dragEnded(windowPoint: $0) },
                        prepareContextMenu: nil,
                        freezesWindow: true
                    )
                    .help(String(localized: "Click the title for session details. Drag it to move the pane."))
                }
                .padding(.horizontal, Theme.Space.s)
            }
            .frame(width: frame.width, height: headerHeight)
            .position(x: frame.midX, y: frame.minY + headerHeight / 2)
            .zIndex(4)
        } else if headerHeight > 0 {
            // A lone pane has no title bar: a strip in the terminal's own color, where the
            // system title bar would be, shows the title centered and moves the window.
            ZStack(alignment: .trailing) {
                chrome.panelHeader
                    .allowsHitTesting(false)
                WindowDragArea()
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    PaneProgressBar(sessionID: tab.sessionID)
                }
                .allowsHitTesting(false)
                HStack(spacing: 6) {
                    DuplicateHostDot(mark: model.duplicateHostMark(for: tab.id))
                    Text(paneTitle(tab))
                        .font(Theme.Font.paneTitle)
                        .foregroundStyle(chrome.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    RemoteTitleStatus(tab: tab)
                        .font(Theme.Font.paneTitle)
                    if tab.reconnecting {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: Theme.PaneStyle.statusIconSize, weight: .medium))
                            .foregroundStyle(chrome.warning)
                            .accessibilityLabel(Text("Reconnecting…"))
                    } else if tab.showsDisconnected {
                        Image(systemName: "link.slash")
                            .font(.system(size: Theme.PaneStyle.statusIconSize, weight: .medium))
                            .foregroundStyle(chrome.danger)
                            .accessibilityLabel(Text(tab.isLocal ? String(localized: "Terminal Exited") : String(localized: "Connection closed")))
                    }
                }
                .allowsHitTesting(false)
                // The title moves the window like the rest of the strip; right-click copies host info.
                .background(WindowDragArea(onSecondaryClick: { copySessionInfo(tab, model: model) }))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.PaneStyle.stripTitleInset)
                .offset(y: Theme.PaneStyle.trafficLightCenterY - headerHeight / 2)
                HStack(spacing: 0) {

                    if isZoomed {
                        zoomMark
                    }
                }
                .padding(.horizontal, Theme.Space.s)
                .offset(y: Theme.PaneStyle.trafficLightCenterY - headerHeight / 2)
            }
            .frame(width: frame.width, height: headerHeight)
            .position(x: frame.midX, y: frame.minY + headerHeight / 2)
            .zIndex(4)
        }
        let showsBanner = showsConnectionBanner(tab)
        if showsBanner {
            connectionBanner(tab)
                .frame(width: frame.width, height: Theme.PaneStyle.bannerHeight)
                .position(x: frame.midX, y: frame.minY + headerHeight + Theme.PaneStyle.bannerHeight / 2)
                .zIndex(4)
        }
        if let findState = find.states[tab.sessionID] {
            let bannerOffset = showsBanner ? Theme.PaneStyle.bannerHeight : 0
            let findTop = frame.minY + headerHeight + bannerOffset
            TerminalFindBar(state: findState, onFocus: { model.notePaneFocused(tab.id, in: window) })
                .frame(width: frame.width, height: Theme.PaneStyle.findBarHeight)
                .position(x: frame.midX, y: findTop + Theme.PaneStyle.findBarHeight / 2)
                .zIndex(4)
        }
    }

    /// Shown at the right end of the zoomed pane's strip. A click shows every pane again.
    private var zoomMark: some View {
        let help = String(
            format: String(localized: "Zoomed. Click to show all panes (%@)"),
            AppShortcuts.display(for: .toggleSplitZoom)
        )
        return Button {
            model.toggleSplitZoom(in: window)
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: Theme.PaneStyle.statusIconSize, weight: .semibold))
                .foregroundStyle(chrome.accent)
                .frame(width: Theme.PaneStyle.headerButtonSize, height: Theme.PaneStyle.headerButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    private func showsConnectionBanner(_ tab: TerminalTab) -> Bool {
        tab.reconnecting || tab.showsDisconnected
    }

    /// The terminal starts below an open find bar, and below the banner above that bar, so neither
    /// hides the row Ghostty scrolls the current match to.
    private func findBarInset(_ tab: TerminalTab) -> CGFloat {
        let banner = showsConnectionBanner(tab) ? Theme.PaneStyle.bannerHeight : 0
        let find = find.openSessionIDs.contains(tab.sessionID) ? Theme.PaneStyle.findBarHeight : 0
        return banner + find
    }

    /// Strip under the title bar for an exited terminal. Only its recovery button takes clicks;
    /// the rest lets the terminal keep its text selection.
    private func connectionBanner(_ tab: TerminalTab) -> some View {
        let tint: Color
        let message: String
        if tab.reconnecting {
            tint = chrome.warning
            if tab.reconnectAttempts > 0 {
                message = String(
                    format: String(localized: "Connection lost, reconnecting (%lld/%lld)"),
                    tab.reconnectAttempts,
                    AppModel.maxAutoReconnectAttempts
                )
            } else {
                message = String(localized: "Reconnecting…")
            }
        } else {
            tint = chrome.danger
            message = tab.isLocal ? String(localized: "Terminal Exited") : String(localized: "Connection closed")
        }
        return HStack(spacing: Theme.Space.s) {
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(chrome.text)
                .lineLimit(1)
                .allowsHitTesting(false)
            Spacer(minLength: 0)
            if tab.showsDisconnected {
                Button {
                    if tab.isLocal { model.reopenLocalTerminal(tab.id) }
                    else { model.reconnect(tab.id) }
                } label: {
                    Text(tab.isLocal ? String(localized: "Reopen Terminal") : String(localized: "Reconnect"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(chrome.background)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, Theme.Space.xs)
                        .background(Capsule().fill(chrome.accent))
                }
                .buttonStyle(.plain)
                .help(AppShortcuts.display(for: .reconnect))
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                chrome.background
                tint.opacity(Theme.PaneStyle.bannerTintOpacity)
            }
            .allowsHitTesting(false)
        }
    }

    private func paneTitle(_ tab: TerminalTab) -> String {
        if let title = tab.contentTitle {
            return title
        }
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
    if case .preview(let path) = tab.content {
        text = path
    } else if tab.isLocal {
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
    /// A zoomed pane takes the whole area. The other panes get no frame, so their terminals stay
    /// alive, hidden at their last size, like any tab that is not shown.
    static func paneFrames(_ root: PaneNode?, zoomed: UUID?, in layout: CGRect) -> [UUID: CGRect] {
        if let zoomed {
            return [zoomed: layout]
        }
        guard let root else { return [:] }
        return PaneLayout.frames(of: root, in: layout)
    }

    static func paneDividers(_ root: PaneNode?, zoomed: UUID?, in layout: CGRect) -> [PaneDivider] {
        if zoomed != nil {
            return []
        }
        guard let root else { return [] }
        return PaneLayout.dividers(of: root, in: layout)
    }

    static func contentFrame(_ frame: CGRect, headerHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: frame.minY + headerHeight,
            width: frame.width,
            height: max(frame.height - headerHeight, 1)
        )
    }
}

/// Grab area of a divider between panes. Reports hover and the drag distance in points
/// (rightward / downward positive), and keeps the resize cursor while over it or dragging.
struct PaneDividerHandle: NSViewRepresentable {
    var vertical: Bool
    var onHover: (Bool) -> Void
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: () -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> PaneDividerView {
        PaneDividerView()
    }

    func updateNSView(_ view: PaneDividerView, context: Context) {
        view.vertical = vertical
        view.onHover = onHover
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        view.onDoubleClick = onDoubleClick
        view.window?.invalidateCursorRects(for: view)
    }
}

final class PaneDividerView: NSView {
    var vertical = true
    var onHover: (Bool) -> Void = { _ in }
    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    var onDoubleClick: () -> Void = {}

    private var cursor: NSCursor {
        if vertical {
            return NSCursor.resizeLeftRight
        }
        return NSCursor.resizeUpDown
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        claimCursor()
        onHover(true)
    }

    /// The terminal under the grab area gets the same moves and resets its own cursor,
    /// so set ours again after it has run.
    override func mouseMoved(with event: NSEvent) {
        claimCursor()
    }

    private func claimCursor() {
        cursor.set()
        DispatchQueue.main.async {
            self.cursor.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        onHover(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            onDoubleClick()
            return
        }
        let start = event.locationInWindow
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: 3600,
            mode: .eventTracking
        ) { event, stop in
            guard let event else {
                stop.pointee = true
                return
            }
            self.cursor.set()
            if event.type == .leftMouseUp {
                self.onDragEnded()
                stop.pointee = true
                return
            }
            let point = event.locationInWindow
            if self.vertical {
                self.onDragChanged(point.x - start.x)
            } else {
                // Window coordinates grow upward; the layout grows downward.
                self.onDragChanged(start.y - point.y)
            }
        }
    }
}
