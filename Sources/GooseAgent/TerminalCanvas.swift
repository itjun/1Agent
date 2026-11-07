import AppKit
import QuartzCore
import SwiftUI

struct TerminalLocationBadge: View {
    var tab: TerminalTab
    @Environment(\.windowChrome) private var chrome

    static let titleInset: CGFloat = 80

    var body: some View {
        if tab.hasTerminal {
            Text(tab.isLocal ? "This Mac" : "Remote")
                .font(Theme.Font.rowMeta)
                .foregroundStyle(chrome.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, chrome.isSystem ? 0 : 3)
                .frame(height: chrome.isSystem ? Theme.DefaultLayout.badgeHeight : nil)
                .background(chrome.isSystem ? chrome.hoverFill : chrome.accentFill, in: RoundedRectangle(cornerRadius: 5))
                .fixedSize()
                .allowsHitTesting(false)
                .accessibilityIdentifier("workspace.location." + tab.id.uuidString)
        }
    }
}

struct TerminalCanvas: View {
    @Environment(\.windowChrome) private var chrome
    @Environment(\.isShellTransparent) private var isShellTransparent
    @Environment(\.workspaceTitlebarLeadingInset) private var titlebarLeadingInset
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @ObservedObject private var find = TerminalFind.shared
    var dropRelay: CanvasDropRelay
    var dark: Bool
    /// `id` is the dragged divider, `split` the split it resizes (a detached segment gets its own split).
    @State private var ratioDrag: (id: UUID, split: UUID, start: CGFloat)?
    /// Divider under the pointer. Its line turns accent while set.
    @State private var hoveredDividerID: UUID?
    /// Last on-screen content rect per tab. Hidden tabs keep this size/position so Ghostty
    /// does not resize the PTY to 1×1 (which reflows scrollback and jumps the cursor).
    @State private var lastContentFrame: [UUID: CGRect] = [:]

    /// 终端信息统一放到窗口工具栏，各分屏只预留搜索和连接状态区域。
    static func headerHeight(for frame: CGRect, isFloating: Bool = false) -> CGFloat { 0 }

    var body: some View {
        GeometryReader { geo in
            let root = model.displayRoot(in: window)
            let bounds = CGRect(origin: .zero, size: geo.size)
            let layout = bounds
            let zoomed = model.zoomedPane(in: window)
            let frames = Self.paneFrames(root, zoomed: zoomed, in: layout, isFloating: isShellTransparent)
            let dividers = Self.paneDividers(root, zoomed: zoomed, in: layout)
            let isSplit = frames.count > 1
            let paneHeaderHeight = isSplit ? ShellLayout.compactHeaderHeight : 0
            let fallbackContent = Self.contentFrame(layout, headerHeight: 0)
            // Only this window's terminals get a view here. A terminal shown in another window
            // keeps its process; the registry hands the same view over when it moves.
            let shown = Set(model.sidebarOrder(in: window))
            let ownTabs = model.tabs.filter { $0.hasTerminal && shown.contains($0.id) }
            let liveIDs = Set(ownTabs.map(\.id))
            let _ = dropRelay.sync(frames: frames, model: model, window: window)
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(ownTabs) { tab in
                    let content = frames[tab.id].map { Self.terminalContentFrame($0, isFloating: isShellTransparent, accessoryHeight: paneHeaderHeight + findBarInset(tab)) }
                    let drawn = content ?? lastContentFrame[tab.id] ?? fallbackContent
                    let visible = content != nil
                    let isSelected = window.selectedTabID == tab.id && window.section == .terminals
                    let cardHeader = paneHeaderHeight + findBarInset(tab)
                    SSHTerminalView(
                        sessionID: tab.sessionID,
                        alias: tab.alias ?? "",
                        directory: tab.isLocal ? tab.directory : nil,
                        remoteDirectory: tab.remoteDirectory,
                        environment: ShellIntegrationEnvironment.merged(model.launchEnvironment, overrides: tab.creationEnvironment),
                        dark: terminalIsDark,
                        initialFontSize: tab.creationFontSize,
                        restoration: tab.restoration,
                        isPresented: visible && window.section == .terminals && !window.presentation.fullFilesWorkspace
                            && !window.isToolReadingExpanded,
                        isSelected: isSelected,
                        contentCornerRadius: 0,
                        isHeaderIntegrated: false,
                        canFocus: {
                            window.selectedTabID == tab.id && window.section == .terminals &&
                                !window.presentation.fullFilesWorkspace && !window.isToolReadingExpanded
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
                    .padding(.top, cardHeader)
                    .background {
                        AppTheme.terminalPaneBackground(isDark: terminalIsDark, isFocused: isSelected).color
                    }
                    .modifier(FloatingContentSurface())
                    .environment(\.windowChrome, chrome)
                    .position(
                        x: drawn.midX,
                        y: drawn.midY - cardHeader / 2
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
                        let content = Self.terminalContentFrame(frame, isFloating: isShellTransparent)
                        let cardHeader: CGFloat = 0
                        PaneContentView(model: model, window: window, tab: tab)
                            .frame(width: content.width, height: content.height)
                            .padding(.top, cardHeader)
                            .background(alignment: .top) {
                                if isShellTransparent {
                                    chrome.background.opacity(ShellLayout.fileOpacity)
                                        .frame(height: cardHeader).allowsHitTesting(false)
                                }
                            }
                            .modifier(FloatingContentSurface())
                            .environment(\.windowChrome, chrome)
                            .position(x: content.midX, y: content.midY - cardHeader / 2)
                            .zIndex(1)
                    }
                }
                ForEach(dividers) { divider in
                    dividerControl(divider, in: layout)
                }
                ForEach(model.tabs.filter { frames[$0.id] != nil }) { tab in
                    if let frame = frames[tab.id] {
                        paneChrome(tab, frame: ShellLayout.contentFrame(frame, isFloating: isShellTransparent),
                                   headerHeight: tab.hasTerminal ? paneHeaderHeight : 0,
                                   isSplit: isSplit, isZoomed: zoomed == tab.id)
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

    private var terminalIsDark: Bool {
        dark
    }

    private func dividerControl(_ divider: PaneDivider, in layout: CGRect) -> some View {
        let vertical = divider.axis == .vertical
        let active = hoveredDividerID == divider.id || ratioDrag?.id == divider.id
        let lineWidth = Theme.PaneStyle.dividerLineWidth
        return Color.clear
            .frame(width: divider.frame.width, height: divider.frame.height)
            .overlay {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
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

    @ViewBuilder
    private func paneChrome(_ tab: TerminalTab, frame: CGRect, headerHeight: CGFloat, isSplit: Bool, isZoomed: Bool) -> some View {
        if tab.hasTerminal && headerHeight > 0 {
            terminalHeader(tab)
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

    private func terminalHeader(_ tab: TerminalTab) -> some View {
        let isSelected = window.selectedTabID == tab.id && window.section == .terminals
        return HStack(spacing: Theme.Space.s) {
            Image(systemName: tab.isLocal ? "terminal" : "network")
                .foregroundStyle(isSelected ? chrome.accent : chrome.secondary)
            Text(verbatim: numberedPaneTitle(tab))
                .font(Theme.Font.paneTitle)
                .lineLimit(1).truncationMode(.middle)
            if let path = TerminalPaneActions.workingDirectory(of: tab) {
                Text(verbatim: tab.isLocal ? LocalTerminal.displayPath(path) : path)
                    .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                    .lineLimit(1).truncationMode(.middle).help(path)
            }
            Spacer(minLength: 4)
            Button { model.closeTab(tab.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Close")
                .accessibilityLabel(Text("Close"))
        }
        .foregroundStyle(chrome.text)
        .padding(.horizontal, Theme.Space.m)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.notePaneFocused(tab.id, in: window) }
        .familyContextMenu { TerminalPaneActions.items(tab: tab, model: model, window: window) }
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

    /// Recovery stays inside the reserved strip; it never covers the terminal or takes focus.
    private func connectionBanner(_ tab: TerminalTab) -> some View {
        TerminalConnectionBanner(tab: tab, onRecover: {
            // A queued second click must not restart a terminal that has already recovered.
            guard let current = model.tabs.first(where: { $0.id == tab.id }), current.showsDisconnected else { return }
            if current.isLocal { model.reopenLocalTerminal(current.id) }
            else { model.reconnect(current.id) }
        }, menuItems: {
            TerminalPaneActions.items(tab: tab, model: model, window: window)
        })
        .environment(\.windowChrome, chrome)
    }

    private func numberedPaneTitle(_ tab: TerminalTab) -> String {
        guard let number = model.paneNumber(for: tab.id, in: window) else { return paneTitle(tab) }
        return "\(number)-\(paneTitle(tab))"
    }

    private func paneTitle(_ tab: TerminalTab) -> String {
        if let title = tab.contentTitle {
            return title
        }
        if tab.isLocal, let directory = tab.directory {
            if isShellTransparent {
                let name = (directory as NSString).lastPathComponent
                return directory == FileManager.default.homeDirectoryForCurrentUser.path || name.isEmpty
                    ? String(localized: "This Mac") : name
            }
            return LocalTerminal.displayPath(directory)
        }
        return tab.alias ?? ""
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
    /// 先确定整张浮动卡片，再预留内部标题、搜索及连接状态区域。
    static func terminalContentFrame(_ frame: CGRect, isFloating: Bool, accessoryHeight: CGFloat = 0) -> CGRect {
        Self.contentFrame(ShellLayout.contentFrame(frame, isFloating: isFloating),
                          headerHeight: Self.headerHeight(for: frame, isFloating: isFloating) + accessoryHeight)
    }

    /// A zoomed pane takes the whole area. The other panes get no frame, so their terminals stay
    /// alive, hidden at their last size, like any tab that is not shown.
    static func paneFrames(_ root: PaneNode?, zoomed: UUID?, in layout: CGRect, isFloating: Bool = false) -> [UUID: CGRect] {
        if let zoomed {
            return [zoomed: layout]
        }
        guard let root else { return [:] }
        return ShellLayout.paneFrames(of: root, in: layout, isFloating: isFloating)
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
        var resizingTerminals: [TerminalHostView] = []
        func terminalHosts(in view: NSView) -> [TerminalHostView] {
            guard !view.isHidden else { return [] }
            if let host = view as? TerminalHostView { return [host] }
            return view.subviews.flatMap { terminalHosts(in: $0) }
        }
        defer {
            window.contentView?.layoutSubtreeIfNeeded()
            resizingTerminals.forEach { $0.endDividerResize() }
        }
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
            if resizingTerminals.isEmpty, let content = window.contentView {
                resizingTerminals = terminalHosts(in: content)
                resizingTerminals.forEach { $0.beginDividerResize() }
            }
            if self.vertical {
                self.onDragChanged(point.x - start.x)
            } else {
                // Window coordinates grow upward; the layout grows downward.
                self.onDragChanged(start.y - point.y)
            }
        }
    }
}
