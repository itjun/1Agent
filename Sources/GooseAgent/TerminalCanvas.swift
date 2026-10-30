import AppKit
import QuartzCore
import SwiftUI

struct TerminalCanvas: View {
    @Environment(\.windowChrome) private var chrome
    @Environment(\.isShellTransparent) private var isShellTransparent
    @Environment(\.workspaceTitlebarLeadingInset) private var titlebarLeadingInset
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @ObservedObject private var find = TerminalFind.shared
    @ObservedObject private var themePreview = ThemePreview.shared
    @AppStorage(LocalPalette.storageKey) private var localPaletteRaw = LocalPalette.defaultPalette.rawValue
    @AppStorage(RemotePalette.storageKey) private var remotePaletteRaw = RemotePalette.defaultPalette.rawValue
    var dropRelay: CanvasDropRelay
    var dark: Bool
    /// `id` is the dragged divider, `split` the split it resizes (a detached segment gets its own split).
    @State private var ratioDrag: (id: UUID, split: UUID, start: CGFloat)?
    /// Divider under the pointer. Its line turns accent while set.
    @State private var hoveredDividerID: UUID?
    /// Last on-screen content rect per tab. Hidden tabs keep this size/position so Ghostty
    /// does not resize the PTY to 1×1 (which reflows scrollback and jumps the cursor).
    @State private var lastContentFrame: [UUID: CGRect] = [:]

    /// 透明模式每张卡片都包含标题；经典模式首排标题仍放在窗口顶栏。
    static func headerHeight(for frame: CGRect, isFloating: Bool = false) -> CGFloat {
        if isFloating { return ShellLayout.compactHeaderHeight }
        return frame.minY < 1 ? 0 : Theme.PaneStyle.headerHeight
    }

    var body: some View {
        GeometryReader { geo in
            let root = model.displayRoot(in: window)
            let bounds = CGRect(origin: .zero, size: geo.size)
            let layout = bounds
            let zoomed = model.zoomedPane(in: window)
            let frames = Self.paneFrames(root, zoomed: zoomed, in: layout, isFloating: isShellTransparent)
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
                (isShellTransparent ? Color.clear : chrome.background)
                ForEach(ownTabs) { tab in
                    let content = frames[tab.id].map { Self.terminalContentFrame($0, isFloating: isShellTransparent, accessoryHeight: findBarInset(tab)) }
                    let drawn = content ?? lastContentFrame[tab.id] ?? fallbackContent
                    let visible = content != nil
                    let cardHeader = isShellTransparent ? ShellLayout.compactHeaderHeight + findBarInset(tab) : 0
                    SSHTerminalView(
                        sessionID: tab.sessionID,
                        alias: tab.alias ?? "",
                        directory: tab.isLocal ? tab.directory : nil,
                        remoteDirectory: tab.remoteDirectory,
                        environment: ShellIntegrationEnvironment.merged(model.launchEnvironment, overrides: tab.creationEnvironment),
                        dark: terminalIsDark,
                        initialFontSize: tab.creationFontSize,
                        restoration: tab.restoration,
                        isPresented: visible && !window.presentation.fullFilesWorkspace && !model.showingSettings,
                        isSelected: window.selectedTabID == tab.id && window.section == .terminals,
                        contentCornerRadius: isShellTransparent ? ShellLayout.contentRadius : 0,
                        isHeaderIntegrated: isShellTransparent,
                        canFocus: {
                            !model.showingSettings && window.selectedTabID == tab.id && window.section == .terminals &&
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
                    .padding(.top, cardHeader)
                    .background(alignment: .top) {
                        if isShellTransparent {
                            floatingTerminalBackground.opacity(ShellLayout.terminalOpacity)
                                .frame(height: cardHeader).allowsHitTesting(false)
                        }
                    }
                    .modifier(FloatingContentSurface(isSelected: window.selectedTabID == tab.id && window.section == .terminals
                        && !window.presentation.fullFilesWorkspace && !model.showingSettings))
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
                        let cardHeader = isShellTransparent ? ShellLayout.compactHeaderHeight : 0
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
                                   headerHeight: Self.headerHeight(for: frame, isFloating: isShellTransparent),
                                   isSplit: isSplit, isZoomed: zoomed == tab.id)
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

    private var terminalIsDark: Bool {
        themePreview.previewingDark ?? TerminalAppearance.stored().resolvesDark()
    }

    private var floatingTerminalBackground: Color {
        let theme = terminalIsDark ? themePreview.effectiveDark() : themePreview.effectiveLight()
        return RGBColor(ghosttyHex: theme.definition.background)?.color ?? chrome.background
    }

    private var floatingTerminalForeground: Color {
        let theme = terminalIsDark ? themePreview.effectiveDark() : themePreview.effectiveLight()
        return RGBColor(ghosttyHex: theme.definition.foreground)?.color ?? chrome.text
    }

    private func terminalChrome(_ tab: TerminalTab) -> WindowChrome {
        WindowChrome.resolve(isDark: terminalIsDark,
            icon: tab.isLocal ? LocalPalette.palette(raw: localPaletteRaw) : RemotePalette.palette(raw: remotePaletteRaw))
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
                    .fill(active ? chrome.accent : (isShellTransparent ? Color.clear : chrome.hairline))
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
        let chrome = tab.hasTerminal ? terminalChrome(tab) : self.chrome
        let isSelected = tab.hasTerminal && window.selectedTabID == tab.id && window.section == .terminals
            && !window.presentation.fullFilesWorkspace && !model.showingSettings
        if (isSplit || isShellTransparent) && headerHeight > 0 {
            ZStack {
                chrome.panelHeader.opacity(isShellTransparent ? 0 : 1)
                    .allowsHitTesting(false)
                WindowDragArea(onClick: { model.selectOnly(tab.id, in: window) })
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    PaneProgressBar(sessionID: tab.sessionID)
                }
                .allowsHitTesting(false)
                // Only the title merges panes; the blank rest of the bar moves the window.
                HStack(spacing: 6) {
                    Text(verbatim: numberedPaneTitle(tab))
                        .font(isShellTransparent ? Theme.Font.floatingPaneTitle : Theme.Font.paneTitle.weight(.regular))
                        .foregroundStyle(isShellTransparent && tab.hasTerminal ? floatingTerminalForeground : chrome.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    DuplicateHostDot(mark: model.duplicateHostMark(for: tab.id))
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
                .frame(maxHeight: .infinity)
                .overlay {
                    TabDragHandle(
                        onClick: { _, _ in model.selectOnly(tab.id, in: window) },
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
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityAction { TerminalPaneActions.showTitleContext(model: model, window: window, tabID: tab.id) }
                .accessibilityLabel(Text(verbatim: numberedPaneTitle(tab)))
                .accessibilityIdentifier("workspace.titleMenu." + tab.id.uuidString)
                .padding(.leading, isShellTransparent && frame.minY < 1 && frame.minX < 1 ? titlebarLeadingInset : 0)
                .padding(.horizontal, isShellTransparent && frame.minY < 1 ? ShellLayout.titlebarActionWidth : 0)
            }
            .overlay(alignment: .trailing) {
                if isShellTransparent && isZoomed { zoomMark.padding(.trailing, Theme.Space.s) }
            }
            .frame(width: frame.width, height: headerHeight)
            .position(x: frame.midX, y: frame.minY + headerHeight / 2)
            .zIndex(4)
        } else if headerHeight > 0 {
            // A lone pane has no title bar: a strip in the terminal's own color, where the
            // system title bar would be, shows the title centered and moves the window.
            ZStack(alignment: .trailing) {
                chrome.panelHeader.opacity(isShellTransparent ? 0 : 1)
                    .allowsHitTesting(false)
                WindowDragArea()
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    PaneProgressBar(sessionID: tab.sessionID)
                }
                .allowsHitTesting(false)
                HStack(spacing: 6) {
                    Text(verbatim: numberedPaneTitle(tab))
                        .font(Theme.Font.paneTitle.weight(.regular))
                        .foregroundStyle(chrome.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    DuplicateHostDot(mark: model.duplicateHostMark(for: tab.id))
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
        .environment(\.windowChrome, terminalChrome(tab))
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
