import AppKit
import GooseKit
import SwiftUI

private enum SidebarLayout {
    static let defaultWidth: CGFloat = 260
    static let minimumWidth: CGFloat = 200
    static let maximumWidth: CGFloat = 480
    static let minimumDetailWidth: CGFloat = 460

    static func width(_ requested: CGFloat, available: CGFloat) -> CGFloat {
        min(max(requested, minimumWidth), min(maximumWidth, available - minimumDetailWidth - 1))
    }
}

struct RootView: View {
    // Owned by AppDelegate so it outlives the window — see AppDelegate in GooseAgentApp.swift.
    @ObservedObject var model: AppModel
    // Deliberately not persisted: the app always launches with the sidebar visible.
    @State private var sidebarCollapsed = false
    @AppStorage(SidebarSectionID.spacesHiddenKey) private var spacesHidden = false
    @AppStorage(AppShortcuts.revisionKey) private var shortcutsRevision = 0

    var body: some View {
        let _ = shortcutsRevision  // the hidden ⌘B / ⌘K buttons must follow a remap
        return ZStack(alignment: .bottomLeading) {
            SidebarWorkspace(model: model, collapsed: $sidebarCollapsed)

            // In-window device panel; NSPopover throws in ViewBridge on macOS 26+ betas.
            if model.showDevicePanel {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { model.showDevicePanel = false }
                DevicePopover(model: model, isPresented: $model.showDevicePanel)
                    .padding(.leading, 10)
                    .padding(.bottom, 46)
                    .transition(.scale(scale: 0.96, anchor: .bottomLeading).combined(with: .opacity))
                    .background(
                        Button("") { model.showDevicePanel = false }
                            .keyboardShortcut(.cancelAction)
                            .focusEffectDisabled()
                            .hidden()
                    )
            }
        }
        .overlayPreferenceValue(TooltipRequestKey.self) { request in
            if let request {
                TooltipLayer(request: request)
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: model.showDevicePanel)
        .background(
            Button("") { sidebarCollapsed.toggle() }
                .keyboardShortcut(AppShortcuts.chord(for: .toggleSidebar).keyEquivalent,
                                  modifiers: AppShortcuts.chord(for: .toggleSidebar).modifiers)
                .hidden()
        )
        .background(
            Button("") { model.showSearch = true }
                .keyboardShortcut(AppShortcuts.chord(for: .search).keyEquivalent,
                                  modifiers: AppShortcuts.chord(for: .search).modifiers)
                .hidden()
        )
        .focusedSceneValue(\.appModel, model)
        .focusedSceneValue(\.terminalSplitTree, model.currentSplitTree)
        .sheet(isPresented: $model.showSearch) { SearchSheet(model: model) }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 720, minHeight: 440)
        .gooseagentHideFocusRing()
        .onAppear {
            TooltipDismissal.install()
            model.start()
        }
        .onChange(of: spacesHidden, initial: true) { _, _ in
            model.synchronizeSpaceVisibility()
        }
        .sheet(isPresented: $model.showAddDevice) { AddDeviceSheet(model: model) }
        .sheet(isPresented: $model.showNewSpace) {
            NewSpaceSheet(model: model)
        }
        .sheet(item: $model.spaceToRename) { entry in RenameSpaceSheet(model: model, entry: entry) }
        .sheet(isPresented: $model.showNewItem, onDismiss: { model.showNewItem = false }) {
            NewItemSheet(model: model)
        }
        .sheet(item: $model.newSession) { request in NewSessionSheet(model: model, request: request) }
        .sheet(item: $model.agentToRename) { entry in RenameAgentSheet(model: model, entry: entry) }
        .sheet(item: $model.terminalToRename) { entry in RenameTerminalSheet(model: model, entry: entry) }
        .sheet(item: $model.deviceToEdit) { device in EditDeviceSheet(model: model, device: device) }
        .sheet(item: $model.sshAuthenticationRequest) { request in
            SSHAuthenticationSheet(model: model, request: request)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
        .alert(
            model.closeRequest?.title ?? "",
            isPresented: Binding(
                get: { model.closeRequest != nil },
                set: { if !$0 { model.closeRequest = nil } }
            )
        ) {
            Button("Close", role: .destructive) {
                model.closeRequest?.perform()
                model.closeRequest = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.closeRequest?.message ?? "")
        }
    }

}

/// Dragging the divider must not invalidate RootView's sheets and overlays.
private struct SidebarWorkspace: View {
    @ObservedObject var model: AppModel
    @Binding var collapsed: Bool
    @AppStorage("sidebar.width") private var sidebarWidth = Double(SidebarLayout.defaultWidth)
    @State private var widthAtDragStart: CGFloat?
    @State private var dragWidth: CGFloat?

    private var requestedWidth: CGFloat { dragWidth ?? CGFloat(sidebarWidth) }

    var body: some View {
        GeometryReader { geometry in
            let width = collapsed ? 0 : SidebarLayout.width(requestedWidth, available: geometry.size.width)
            HStack(spacing: 0) {
                StableSidebarPane(model: model, collapsed: $collapsed)
                    .equatable()
                    .frame(width: width, alignment: .trailing)
                    .clipped()
                if !collapsed {
                    Rectangle()
                        .fill(Theme.sidebarBorder)
                        .frame(width: 1)
                        .overlay {
                            Rectangle()
                                .fill(.clear)
                                .frame(width: 11)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                    .onChanged { value in
                                        let start = widthAtDragStart ?? width
                                        widthAtDragStart = start
                                        dragWidth = SidebarLayout.width(
                                            start + value.translation.width, available: geometry.size.width
                                        )
                                    }
                                    .onEnded { value in
                                        let start = widthAtDragStart ?? width
                                        sidebarWidth = Double(SidebarLayout.width(
                                            start + value.translation.width, available: geometry.size.width
                                        ))
                                        dragWidth = nil
                                        widthAtDragStart = nil
                                    })
                                .onHover { hovering in
                                    (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                                }
                                .accessibilityLabel(Text("Resize Sidebar"))
                                .accessibilityAdjustableAction { direction in
                                    let delta: CGFloat = direction == .increment ? 20 : -20
                                    sidebarWidth = Double(SidebarLayout.width(width + delta, available: geometry.size.width))
                                }
                        }
                        .ignoresSafeArea()
                }
                StableDetailPane(model: model, collapsed: $collapsed, isCollapsed: collapsed)
                    .equatable()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: collapsed)
        .onChange(of: collapsed) { _, isCollapsed in
            if isCollapsed {
                dragWidth = nil
                widthAtDragStart = nil
            }
        }
        .overlayPreferenceValue(PiLaunchOriginKey.self) { anchor in
            if let launch = model.piLaunch, model.showsPiLaunch {
                GeometryReader { geometry in
                    let leading: CGFloat = collapsed ? 0 : SidebarLayout.width(requestedWidth, available: geometry.size.width) + 1
                    let top = TitlebarMetrics.height + 1
                    PiLaunchInkView(
                        model: model,
                        launchID: launch.id,
                        origin: CGPoint(
                            x: 0,
                            y: anchor.map { min(max(geometry[$0].minY + 16 - top, 0), geometry.size.height - top) }
                                ?? (geometry.size.height - top) / 2
                        )
                    )
                    .frame(width: max(0, geometry.size.width - leading), height: max(0, geometry.size.height - top))
                    .offset(x: leading, y: top)
                    .id(launch.id)
                }
            }
        }
    }
}

// Divider movement changes only size proposals. Pane-local state and model
// notifications still update their own views without rebuilding them per pixel.
private struct StableSidebarPane: View, Equatable {
    let model: AppModel
    @Binding var collapsed: Bool

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model }

    var body: some View {
        SidebarView(model: model, collapsed: $collapsed)
    }
}

private struct StableDetailPane: View, Equatable {
    let model: AppModel
    @Binding var collapsed: Bool
    let isCollapsed: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.isCollapsed == rhs.isCollapsed
    }

    var body: some View {
        DetailView(model: model, sidebarCollapsed: $collapsed)
    }
}

/// The custom title strip is the source of truth for window-button alignment.
enum TitlebarMetrics {
    static let height: CGFloat = 28
    static let trafficLightClearance: CGFloat = 78
}

private struct WindowTitlebarInteraction: NSViewRepresentable {
    var alignsWindowButtons = false

    func makeNSView(context _: Context) -> NSView {
        let view = WindowTitlebarInteractionView()
        view.alignsWindowButtons = alignsWindowButtons
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

private final class WindowTitlebarInteractionView: NSView {
    var alignsWindowButtons = false

    override func layout() {
        super.layout()
        alignWindowButtons()
    }

    private func alignWindowButtons() {
        guard alignsWindowButtons, bounds.height > 0, let window,
              !window.styleMask.contains(.fullScreen) else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
            let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: parent)
            button.setFrameOrigin(NSPoint(x: button.frame.minX, y: center.y - button.frame.height / 2))
        }
    }
    private static let fillRestoreFrames =
        NSMapTable<NSWindow, NSValue>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var rememberFrameWorkItem: DispatchWorkItem?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rememberFrameWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in self?.alignWindowButtons() }
        Self.rememberNonFilledFrame(of: window)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFrameDidChange(_:)),
            name: NSWindow.didMoveNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFrameDidChange(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
    }

    deinit {
        rememberFrameWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowFrameDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.alignWindowButtons() }
        guard let window = notification.object as? NSWindow else { return }
        rememberFrameWorkItem?.cancel()
        let item = DispatchWorkItem { [weak window] in
            guard let window else { return }
            Self.rememberNonFilledFrame(of: window)
        }
        rememberFrameWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        guard event.clickCount == 2 else {
            window.performDrag(with: event)
            return
        }
        guard !window.styleMask.contains(.fullScreen) else { return }

        let action = UserDefaults.standard
            .string(forKey: "AppleActionOnDoubleClick")?
            .lowercased()
        switch action {
        case "fill":
            Self.toggleFill(window)
        case nil:
            if #available(macOS 15.0, *) {
                Self.toggleFill(window)
            } else {
                Self.fillRestoreFrames.removeObject(forKey: window)
                window.performZoom(nil)
            }
        case "minimize":
            Self.fillRestoreFrames.removeObject(forKey: window)
            window.performMiniaturize(nil)
        case "none":
            break
        default:
            Self.fillRestoreFrames.removeObject(forKey: window)
            window.performZoom(nil)
        }
    }

    private static func toggleFill(_ window: NSWindow) {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return
        }
        if framesApproximatelyEqual(window.frame, visibleFrame) {
            let previous = fillRestoreFrames.object(forKey: window)?.rectValue
                ?? fallbackRestoreFrame(in: visibleFrame)
            fillRestoreFrames.removeObject(forKey: window)
            let restored = constrainedRestoreFrame(previous, for: window)
            window.setFrame(restored, display: true, animate: true)
        } else {
            fillRestoreFrames.setObject(NSValue(rect: window.frame), forKey: window)
            window.setFrame(visibleFrame, display: true, animate: true)
        }
    }

    private static func rememberNonFilledFrame(of window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame,
              !framesApproximatelyEqual(window.frame, visibleFrame)
        else { return }
        fillRestoreFrames.setObject(NSValue(rect: window.frame), forKey: window)
    }

    private static func fallbackRestoreFrame(in visibleFrame: NSRect) -> NSRect {
        visibleFrame.insetBy(
            dx: visibleFrame.width * 0.1,
            dy: visibleFrame.height * 0.1
        )
    }

    private static func framesApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 1
            && abs(lhs.minY - rhs.minY) < 1
            && abs(lhs.width - rhs.width) < 1
            && abs(lhs.height - rhs.height) < 1
    }

    private static func constrainedRestoreFrame(_ frame: NSRect, for window: NSWindow) -> NSRect {
        let intersectingScreen = NSScreen.screens
            .map { screen in
                let intersection = frame.intersection(screen.visibleFrame)
                let area = intersection.isNull ? 0 : intersection.width * intersection.height
                return (screen, area)
            }
            .max { $0.1 < $1.1 }
        let screen = if let intersectingScreen, intersectingScreen.1 > 0 {
            intersectingScreen.0
        } else {
            window.screen ?? NSScreen.main
        }
        guard let screen else { return frame }
        return window.constrainFrameRect(frame, to: screen)
    }
}

private struct WindowTitlebarInteractionModifier: ViewModifier {
    var alignsWindowButtons: Bool

    func body(content: Content) -> some View {
        content
            .background(WindowTitlebarInteraction(alignsWindowButtons: alignsWindowButtons))
    }
}

extension View {
    func windowTitlebarInteraction(alignsWindowButtons: Bool = false) -> some View {
        modifier(WindowTitlebarInteractionModifier(alignsWindowButtons: alignsWindowButtons))
    }
}

struct DetailView: View {
    @ObservedObject var model: AppModel
    @Binding var sidebarCollapsed: Bool
    @State private var hasOpenedFileManager = false

    var body: some View {
        VStack(spacing: 0) {
            titlebar
                .background(Theme.contentBackground)
                .zIndex(1)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            detailContent
                .onChange(of: model.isFileManagerActive) { _, active in
                    if active { hasOpenedFileManager = true }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground.ignoresSafeArea())
        .task(id: model.gitMetadataTaskKey) {
            guard let entry = model.selectedAttachedEntry else { return }
            while !Task.isCancelled {
                await model.refreshGitMetadata(for: entry)
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    private var detailContent: some View {
        ZStack {
            terminal
                .clipped()
                .opacity(model.isFileManagerActive ? 0 : 1)
                .allowsHitTesting(!model.isFileManagerActive)
            if model.showsPiLaunch, model.piLaunch?.revealed != true {
                PiLoadingView(model: model)
            }
            if hasOpenedFileManager {
                DeviceFilesView(model: model)
                    .opacity(model.isFileManagerActive ? 1 : 0)
                    .allowsHitTesting(model.isFileManagerActive)
            }
        }
        .onAppear {
            if model.isFileManagerActive { hasOpenedFileManager = true }
        }
    }

    // MARK: - Titlebar strip (28pt, traditional)

    private var titlebar: some View {
        HStack(spacing: 8) {
            if sidebarCollapsed {
                Spacer().frame(width: TitlebarMetrics.trafficLightClearance - 10)
                TitlebarIconButton(systemName: "sidebar.left", title: "Show Sidebar", shortcut: .toggleSidebar) {
                    sidebarCollapsed = false
                }
            }
            Group {
                if model.isFileManagerActive {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text("Files")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Spacer()
                } else if model.showsPiLaunch {
                    Text(verbatim: "Pi")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Spacer()
                } else if let shell = model.terminalHeaderShell {
                    Image(systemName: "terminal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(shell.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text(shell.device.name)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                } else if let attached = model.selectedAttachedEntry {
                    switch attached {
                    case .agent(let entry):
                        let agent = entry.agent
                        statusGlyph(agent.status)
                        Text(entry.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .codexTooltip(verbatim: (agent.cwd as NSString?)?.abbreviatingWithTildeInPath ?? "")
                        Spacer(minLength: 12)
                        AgentKindBadge(kind: agent.agent)
                        Text("\u{b7}")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textGhost)
                        gitMetadataView(
                            for: attached,
                            spaceName: model.spaceName(deviceID: entry.device.id, workspaceID: agent.workspaceID)
                        )
                        if model.showsRowDeviceBadges {
                            DeviceChip(device: entry.device)
                        }
                        paneLocationButton(agent.paneID)
                    case .terminal(let entry):
                        Image(systemName: "terminal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                        Text(entry.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .codexTooltip(verbatim: (entry.pane.cwd as NSString?)?.abbreviatingWithTildeInPath ?? "")
                        Spacer(minLength: 12)
                        gitMetadataView(
                            for: attached,
                            spaceName: model.spaceName(deviceID: entry.device.id, workspaceID: entry.pane.workspaceID)
                        )
                        if model.showsRowDeviceBadges {
                            DeviceChip(device: entry.device)
                        }
                        paneLocationButton(entry.pane.paneID)
                    }
                } else {
                    Text("No terminal selected")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                }
            }
        }
        .padding(.leading, sidebarCollapsed ? 10 : 14)
        .padding(.trailing, 12)
        .frame(height: TitlebarMetrics.height)
        .windowTitlebarInteraction(alignsWindowButtons: true)
    }

    private func paneLocationButton(_ paneID: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paneID, forType: .string)
        } label: {
            Text(verbatim: paneID)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Copy Goose Agent location") + Text(verbatim: " \(paneID)"))
        .codexTooltip("Copy Goose Agent location")
    }

    @ViewBuilder
    private func gitMetadataView(for entry: AppModel.AttachedEntry, spaceName: String) -> some View {
        Text(spaceName)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
        if let info = model.gitRepositoryInfo(for: entry.ref) {
            if info.branch != nil || info.isWorktree {
                Text(verbatim: "·")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textGhost)
            }
            if let branch = info.branch {
                Text(verbatim: branch)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(0)
            }
            if info.isWorktree {
                Text("Worktree")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 4)
                    .frame(height: 18)
                    .background(Theme.textTertiary.opacity(0.12), in: Capsule())
                Text(verbatim: info.repositoryName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .codexTooltip(verbatim: info.repositoryName)
            }
        }
    }

    @ViewBuilder
    private func statusGlyph(_ status: AgentStatus) -> some View {
        switch status {
        case .working:
            SpinnerView(color: Theme.working).frame(width: 13, height: 13)
        case .blocked:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.warning)
        case .done:
            EmptyView()
        case .idle, .unknown:
            EmptyView()
        }
    }

    @ViewBuilder
    private func statusPill(_ status: AgentStatus) -> some View {
        let label: String? = {
            switch status {
            case .working: return String(localized: "Working")
            case .blocked: return String(localized: "Needs input")
            case .done: return nil
            case .idle, .unknown: return nil
            }
        }()
        if let label {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.statusColor(status))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Theme.statusColor(status).opacity(0.13), in: Capsule())
        }
    }

    // MARK: - Terminal

    @AppStorage(TerminalDefaults.fontNameKey) private var terminalFontName = ""
    @AppStorage(TerminalDefaults.fontSizeKey) private var terminalFontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.thinStrokesKey) private var terminalThinStrokes = true
    @AppStorage(TerminalDefaults.fontWeightKey) private var terminalFontWeight = TerminalDefaults.defaultFontWeight
    @AppStorage(TerminalDefaults.lineSpacingKey) private var terminalLineSpacing = TerminalDefaults.defaultLineSpacing
    @AppStorage("terminal.mouseReporting") private var terminalMouseReporting = true
    @Environment(\.colorScheme) private var colorScheme
    /// Per-entry attach state, keyed by `AttachedEntry.id`. `endedAttach` holds the exit
    /// code of a dead attach that *survived* refresh (nil code = no status, e.g. killed
    /// by a signal); a present key drives that entry's reconnect overlay. Ctrl+D / a
    /// normal shell exit closes the pane, so refresh drops the attach and this stays
    /// empty — otherwise the overlay would flash on the way out. `attachRetry` is a
    /// generation the Reconnect button bumps to rebuild just that one terminal.
    /// Per-entry so one dead terminal's overlay never covers another and Reconnect
    /// rebuilds only its own.
    @State private var endedAttach: [String: Int32?] = [:]
    @State private var attachRetry: [String: Int] = [:]
    @State private var uploadingAttachment = false

    @ViewBuilder
    private var terminal: some View {
        ZStack {
            TerminalSplitLayout(trees: model.splitTrees) {
                ForEach(model.attachSessions) { session in
                    if model.terminalLeafIsAlive(session.id, group: session.id) {
                        attachChild(session, isSelected: model.terminalGroupID == session.id)
                            .layoutValue(key: TerminalLeafLayoutKey.self, value: session.id)
                            .opacity(leafOpacity(session.id, group: session.id))
                    }
                }
                ForEach(model.shellSessions) { session in
                    if model.terminalLeafIsAlive(session.id.uuidString, group: session.id.uuidString) {
                        shellChild(id: session.id, group: session.id.uuidString, device: session.device, cwd: nil,
                                   onExit: {
                            if model.splitTrees[session.id.uuidString] != nil {
                                model.closeTerminalLeaf(session.id.uuidString, group: session.id.uuidString)
                            } else { model.closeShellSession(session.id) }
                        })
                    }
                }
                ForEach(model.splitShells) { shell in
                    shellChild(id: shell.id, group: shell.group, device: .local, cwd: shell.workingDirectory,
                               onExit: { model.closeTerminalLeaf(shell.id.uuidString, group: shell.group) })
                }
            }
            TerminalPaneHandles(model: model)
            TerminalSplitDividers(tree: model.layoutSplitTree, onRatio: model.setSplitRatio)
            if model.terminalGroupID == nil { terminalPlaceholder }
        }
        .background(Theme.terminalBackground)
        .overlay(alignment: .bottomTrailing) {
            if uploadingAttachment { uploadIndicator }
        }
        .onChange(of: model.terminalGroupID) { _, _ in
            uploadingAttachment = false
            model.restoreTerminalFocus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow else { return }
            let target = model.splitAgentView?.window
            var shouldRestore = false
            if model.pendingCreatedSessionFocus, window === target {
                shouldRestore = true
            }
            if model.pendingSplitAgentFocus {
                model.pendingSplitAgentFocus = false
                if window === target { shouldRestore = true }
            }
            if shouldRestore { model.restoreTerminalFocus() }
        }
    }

    private func paneHandleInset(group: String) -> CGFloat {
        (model.splitTrees[group]?.leaves.count ?? 1) > 1 ? TerminalPaneHandleMetrics.height : 0
    }

    private func leafOpacity(_ id: String, group: String) -> Double {
        guard model.terminalGroupID == group else { return 0 }
        return model.currentSplitTree?.focusedID == id ? 1 : 0.55
    }

    private func shellChild(id: UUID, group: String, device: Device, cwd: String?, onExit: @escaping () -> Void) -> some View {
        ShellTerminalView(
            sessionID: id, device: device, workingDirectory: cwd,
            fontName: terminalFontName, fontSize: terminalFontSize,
            thinStrokes: terminalThinStrokes, fontWeight: terminalFontWeight,
            lineSpacing: terminalLineSpacing, dark: colorScheme == .dark,
            mouseReporting: terminalMouseReporting, onExit: { _ in onExit() },
            onFocus: { model.focusTerminalLeaf(id.uuidString, group: group) }
        )
        .padding(.horizontal, 10).padding(.vertical, 8)
        .padding(.top, paneHandleInset(group: group))
        .background(Theme.terminalBackground)
        .opacity(leafOpacity(id.uuidString, group: group))
        .allowsHitTesting(model.terminalGroupID == group)
        .accessibilityHidden(model.terminalGroupID != group)
        .layoutValue(key: TerminalLeafLayoutKey.self, value: id.uuidString)
    }

    private var terminalPlaceholder: some View {
        VStack(spacing: 16) {
            if let url = Bundle.main.url(forResource: "EmptyState", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .accessibilityHidden(true)
            }
            Text(placeholderText)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(8)
                .frame(maxWidth: 360)
                .textSelection(.enabled)
            placeholderAction
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground)
    }


    /// One kept-alive attach. Stays in the hierarchy while deselected (opacity 0, no hit
    /// testing) so its content survives; the selected one is visible and interactive.
    @ViewBuilder
    private func attachChild(_ session: AppModel.AttachedEntry, isSelected: Bool) -> some View {
        let attachmentCapabilities: AgentAttachmentCapabilities? = {
            guard case .agent(let agentEntry) = session else { return nil }
            return model.attachmentCapabilities(
                deviceID: agentEntry.device.id,
                agentKind: agentEntry.agent.agentKindRaw
            )
        }()
        ZStack {
            AttachTerminalView(
                device: session.device,
                target: session.attachTarget,
                sessionID: session.id,
                serverVersion: model.serverVersion(deviceID: session.device.id),
                attachmentCapabilities: attachmentCapabilities,
                fontName: terminalFontName,
                fontSize: terminalFontSize,
                thinStrokes: terminalThinStrokes,
                fontWeight: terminalFontWeight,
                lineSpacing: terminalLineSpacing,
                dark: colorScheme == .dark,
                mouseReporting: terminalMouseReporting,
                onAttachmentError: { model.actionError = $0 },
                onAttachmentUploadingChanged: { uploadingAttachment = $0 },
                onExit: { code in confirmAttachEnded(session, code: code) },
                onFocus: { model.focusTerminalLeaf(session.id, group: session.id) },
                inputSuppressed: model.showsPiLaunch && model.piLaunch?.pane == session.ref
            )
                // Keyed on the retry generation only — NOT colorScheme. A theme toggle
                // must re-theme live via updateNSView (as the split shell already does);
                // rebuilding here would tear down every kept-alive terminal at once and
                // throw away the very content this keeps alive.
                .id("attach-\(session.id)-\(attachRetry[session.id] ?? 0)")
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .padding(.top, paneHandleInset(group: session.id))
            if isSelected, endedAttach[session.id] != nil,
               !model.closingPanes.contains(session.ref) {
                attachEndedOverlay(session)
            }
        }
        // Ghostty's Metal layer is non-opaque (clear background), and the
        // `.opacity` below forces SwiftUI to composite this child offscreen —
        // where glyph anti-aliasing falls back to a transparent backdrop and
        // renders pale (worst on dense CJK strokes). A solid backdrop inside
        // the compositing group gives the text an opaque background to blend
        // against, matching the pre-keep-alive single-view rendering.
        .background(Theme.terminalBackground)
        .opacity(isSelected ? 1 : 0)
        .allowsHitTesting(isSelected && !model.showsPiLaunch)
        .accessibilityHidden(!isSelected || model.showsPiLaunch)
    }

    /// Wait for the snapshot before surfacing Reconnect. A normal close (Ctrl+D,
    /// the far-end shell exiting) removes the pane; showing the overlay in that
    /// gap is the flash the user sees. Takeover and a dropped SSH path leave the
    /// pane in place, and that is the only case the overlay is for.
    private func confirmAttachEnded(_ session: AppModel.AttachedEntry, code: Int32?) {
        Task {
            await model.refresh(session.device.id)
            guard model.attachSessions.contains(where: { $0.id == session.id }) else { return }
            endedAttach[session.id] = code
        }
    }

    /// ssh exits 255 for transport failures; everything else is the far end closing
    /// (takeover by another client, or gooseagent stopping while the pane remains).
    private func attachEndedOverlay(_ entry: AppModel.AttachedEntry) -> some View {
        let dropped = (endedAttach[entry.id] ?? nil) == 255
        return VStack(spacing: 10) {
            Image(systemName: dropped ? "bolt.horizontal.circle" : "rectangle.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textGhost)
            Text(dropped ? String(localized: "Connection to \(entry.device.name) dropped") : String(localized: "Terminal session ended"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Text(dropped
                ? String(localized: "The SSH connection behind this terminal went away.")
                : String(localized: "Another client took this pane over, or the attach closed."))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
            Button("Reconnect") {
                endedAttach[entry.id] = nil
                attachRetry[entry.id, default: 0] += 1
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
            .focusEffectDisabled()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground.opacity(0.94))
    }

    private var uploadIndicator: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Uploading…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.trailing, 20)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var placeholderAction: some View {
        switch model.connection {
        case .connecting:
            EmptyView()
        case .failed, .idle:
            if model.hasReconnectableDevice {
                Button("Reconnect") {
                    model.reconnectFailedDevices()
                }
                .controlSize(.large)
                .focusEffectDisabled()
            }
        default:
            Button("New Terminal") {
                model.quickNewTerminal()
            }
            .controlSize(.large)
            .focusEffectDisabled()
        }
    }

    private var placeholderText: String {
        switch model.connection {
        case .connecting: return String(localized: "Connecting…")
        case .failed(let reason): return reason
        case .idle: return String(localized: "Not connected")
        default:
            if model.selectedSpace != nil && model.visibleSessions.isEmpty {
                return String(localized: "This space has no terminals")
            }
            return String(localized: "Select an agent or terminal, or start a new one")
        }
    }

}

struct AddDeviceSheet: View {
    enum Transport: String, CaseIterable {
        case ssh
        case tailcat
    }

    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var target = ""
    @State private var transport: Transport = .ssh
    @State private var token = ""

    private var canAdd: Bool {
        switch transport {
        case .ssh: return !target.trimmingCharacters(in: .whitespaces).isEmpty
        case .tailcat: return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "desktopcomputer",
                title: String(localized: "Add Device"),
                subtitle: transport == .ssh
                    ? String(localized: "Uses OpenSSH config, agent, Tailscale SSH, or password")
                    : String(localized: "WireGuard tunnel to a Goose Agent behind NAT — no VPN, no account")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $transport) {
                    Text(String(localized: "SSH")).tag(Transport.ssh)
                    Text(String(localized: "Tailcat")).tag(Transport.tailcat)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer().frame(height: 4)
                SheetSectionLabel("NAME")
                TextField("mac-studio", text: $name)
                    .textFieldStyle(.roundedBorder)
                Spacer().frame(height: 8)
                Group {
                    if transport == .ssh {
                        SheetSectionLabel("SSH TARGET")
                        TextField("user@192.0.2.10", text: $target)
                            .textFieldStyle(.roundedBorder)
                        Text("user@host, a ~/.ssh/config alias, or user@host:port for a custom port.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        SheetSectionLabel("TAILCAT TOKEN")
                        TextField("tcpGFwWCD…", text: $token)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Text(String(localized: "On the remote Mac: `gooseagent plugin install lbr77/gooseagent-plugin-tailcat`, then `gooseagent plugin action invoke gooseagent.tailcat.token` and paste the token here. The WireGuard tunnel is built in — no external tool. The token is stored in the Keychain. Standalone shells and the Files workspace need SSH."))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(alignment: .topLeading)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .focusEffectDisabled()
                Button("Add Device") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    switch transport {
                    case .ssh:
                        let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
                        model.addDevice(
                            name: trimmedName.isEmpty ? trimmedTarget : trimmedName,
                            sshTarget: trimmedTarget
                        )
                    case .tailcat:
                        model.addTailcatDevice(
                            name: trimmedName.isEmpty ? String(localized: "Tailcat Device") : trimmedName,
                            token: token.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .focusEffectDisabled()
                .disabled(!canAdd)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheetFixedWidth(SheetLayout.narrow)
        .gooseagentHideFocusRing()
    }
}

struct SSHAuthenticationSheet: View {
    @ObservedObject var model: AppModel
    let request: SSHAuthenticationRequest
    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "key.fill",
                title: String(localized: "SSH Authentication"),
                subtitle: request.target
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("PASSWORD")
                SecureField("SSH password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($passwordFocused)
                Label(String(localized: "Saved in your macOS login Keychain"), systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelSSHAuthentication(for: request)
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    model.saveSSHPassword(password, for: request)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .focusEffectDisabled()
                .disabled(password.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheetFixedWidth(SheetLayout.narrow)
        .gooseagentHideFocusRing()
        .onAppear { passwordFocused = true }
    }
}

/// Shared chrome for the app's sheets: icon-badge header, hairline sections, footer actions.
struct SheetHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(alignment: .topLeading)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private enum SheetCardMetrics {
    static let height: CGFloat = 54
    static let cornerRadius: CGFloat = 10
    static let iconSize: CGFloat = 18
    static let gridSpacing: CGFloat = 8
}

/// Stable sheet widths — prefer min/ideal/max equal so AppKit doesn't reflow on click.
enum SheetLayout {
    static let usage: CGFloat = 320
    static let narrow: CGFloat = 400
    static let search: CGFloat = 440
    static let medium: CGFloat = 540
    static let wide: CGFloat = 580
    static let directoryBrowserHeight: CGFloat = 220
    static let spaceListHeight: CGFloat = 240
    static let sessionBodyHeight: CGFloat = 480
}

private extension View {
    func sheetFixedWidth(_ width: CGFloat) -> some View {
        frame(minWidth: width, idealWidth: width, maxWidth: width)
    }
}

struct SheetSectionLabel: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .kerning(0.4)
            .foregroundStyle(Theme.textTertiary)
            .padding(.bottom, 4)
    }
}

/// Compact selectable card used for sheet choices instead of native Picker menus.
struct SheetChoiceCard<Icon: View>: View {
    let title: String
    let subtitle: String?
    let selected: Bool
    let action: () -> Void
    let icon: Icon

    init(
        title: String,
        subtitle: String? = nil,
        selected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) {
        self.title = title
        self.subtitle = subtitle
        self.selected = selected
        self.action = action
        self.icon = icon()
    }

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        selected: Bool,
        action: @escaping () -> Void
    ) where Icon == Image {
        self.init(title: title, subtitle: subtitle, selected: selected, action: action) {
            Image(systemName: systemImage)
        }
    }


    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                icon
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    .frame(width: SheetCardMetrics.iconSize, height: SheetCardMetrics.iconSize)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: SheetCardMetrics.height)
            .background(
                RoundedRectangle(cornerRadius: SheetCardMetrics.cornerRadius)
                    .fill(selected ? AnyShapeStyle(Theme.accentWash) : AnyShapeStyle(Theme.itemWash))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SheetCardMetrics.cornerRadius)
                    .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: SheetCardMetrics.cornerRadius))
        }
        .buttonStyle(.plain)
        .gooseagentHideFocusRing()
    }
}


/// One sheet for the session about to be opened: the space on top, then what to
/// open in it. Priority sessions and All Spaces show every space at once, so the
/// remembered filter can disagree with the focused session — the sheet asks
/// instead of creating in whichever space the filter happens to name, and it is
/// also where a space gets created without leaving the sheet.
struct NewItemSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var spaceID: String?
    @State private var kind: String?

    private var spaces: [AppModel.SpaceEntry] { model.visibleSpaces }

    private var selectedSpace: AppModel.SpaceEntry? {
        spaces.first { $0.id == spaceID } ?? spaces.first
    }

    private var catalogDeviceID: UUID {
        selectedSpace?.device.id ?? Device.local.id
    }

    private var catalog: AgentCatalogState {
        model.session(catalogDeviceID).agentCatalog
    }

    private var kinds: [String] {
        AgentKindOrder.visibleSorted(catalog.kinds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "plus",
                title: String(localized: "New"),
                subtitle: String(localized: "Choose a space and an agent")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    spaceSection
                    Spacer().frame(height: 12)
                    agentSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 480)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .focusEffectDisabled()
                Button("New") {
                    guard let space = selectedSpace, let kind else { return }
                    model.createNewItem(space: space, kind: kind)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .focusEffectDisabled()
                .disabled(selectedSpace == nil || kind == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheetFixedWidth(SheetLayout.medium)
        .gooseagentHideFocusRing()
        .onAppear { syncDefaults() }
        .onChange(of: spaceID) { _, _ in
            model.reloadAgentCatalog(deviceID: catalogDeviceID)
            syncKindIfNeeded()
        }
        .onChange(of: catalogSignature) { _, _ in
            syncKindIfNeeded()
        }
    }

    private var catalogSignature: String {
        "\(catalogDeviceID.uuidString)|\(kinds.joined(separator: ","))"
    }

    @ViewBuilder
    private var spaceSection: some View {
        SheetSectionLabel("SPACE")
        if spaces.isEmpty {
            emptyHint(String(localized: "Create a space first to start an agent."))
            Button("New Space") {
                dismiss()
                model.showNewSpace = true
            }
            .focusEffectDisabled()
        } else {
            let deviceIDs = spaces.map(\.device.id).reduce(into: [UUID]()) { ids, id in
                if !ids.contains(id) { ids.append(id) }
            }
            ForEach(deviceIDs, id: \.self) { deviceID in
                let deviceSpaces = spaces.filter { $0.device.id == deviceID }
                VStack(alignment: .leading, spacing: 8) {
                    if deviceIDs.count > 1, let device = deviceSpaces.first?.device {
                        Text(device.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: SheetCardMetrics.gridSpacing), count: 4),
                        spacing: SheetCardMetrics.gridSpacing
                    ) {
                        ForEach(deviceSpaces) { entry in
                            SheetChoiceCard(
                                title: entry.workspace.label,
                                selected: selectedSpace?.id == entry.id
                            ) {
                                spaceID = entry.id
                            } icon: {
                                ProjectSpaceIcon(
                                    path: model.spaceIconPath(device: entry.device, workspaceID: entry.workspace.workspaceID),
                                    size: 16,
                                    slot: SheetCardMetrics.iconSize
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var agentSection: some View {
        SheetSectionLabel("AGENT")
        switch catalog {
        case .loading:
            emptyHint(String(localized: "Checking installed agent CLIs…"))
        case .failed(let reason):
            emptyHint(String(format: String(localized: "Couldn’t detect agents: %@"), reason))
        case .loaded(let loaded, _) where loaded.isEmpty:
            emptyHint(String(localized: "No agents detected"))
        case .loaded:
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: SheetCardMetrics.gridSpacing), count: 4),
                spacing: SheetCardMetrics.gridSpacing
            ) {
                ForEach(kinds, id: \.self) { item in
                    SheetChoiceCard(
                        title: AgentKindDisplay.name(for: item),
                        selected: kind == item
                    ) {
                        kind = item
                    } icon: {
                        if let resource = BrandIconLoader.agentIcon(for: item) {
                            BrandIcon(resource: resource, size: 16)
                        } else {
                            Image(systemName: "sparkles")
                        }
                    }
                }
            }
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func syncDefaults() {
        if spaceID == nil {
            spaceID = model.newSessionDefaultSpace.flatMap { ref in
                spaces.first { $0.ref == ref }?.id
            } ?? spaces.first?.id
        }
        model.reloadAgentCatalog(deviceID: catalogDeviceID)
        syncKindIfNeeded()
    }

    private func syncKindIfNeeded() {
        if let kind, kinds.contains(kind) { return }
        let currentKind = model.selectedShell == nil ? model.selectedEntry?.agent.agentKindRaw : nil
        kind = currentKind.flatMap { kinds.contains($0) ? $0 : nil } ?? kinds.first
    }
}

private struct NewSessionSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// `.choose` offers the type grid; a type fixed by a shortcut (⌘T, an Agent
    /// kind) hides it, because that question is already answered.
    private let request: NewSessionType
    @State private var space: SpaceRef?
    @State private var type: NewSessionType
    /// The space this sheet created, so Confirm opens in the root shell gooseagent
    /// made with it instead of stacking a second tab on a space seconds old.
    @State private var createdSpace: CreatedSpace?
    @State private var showsNewSpaceForm = false
    @State private var newSpaceDeviceID: UUID
    @State private var directory = ""
    @State private var label = ""
    @State private var isCreatingSpace = false
    @State private var spaceFormError: String?

    private static let spaceColumns = Array(
        repeating: GridItem(.flexible(), spacing: SheetCardMetrics.gridSpacing),
        count: 2
    )
    private static let typeColumns = Array(
        repeating: GridItem(.flexible(), spacing: SheetCardMetrics.gridSpacing),
        count: 4
    )

    init(model: AppModel, request: NewSessionType) {
        self.model = model
        self.request = request
        let defaultSpace = model.newSessionDefaultSpace
        _space = State(initialValue: defaultSpace)
        _type = State(initialValue: request == .choose ? .terminal : request)
        let device = defaultSpace.flatMap { model.device($0.deviceID) }
            ?? model.deviceFilter.flatMap { model.device($0) }
            ?? model.devices.first ?? .local
        _newSpaceDeviceID = State(initialValue: device.id)
        _directory = State(initialValue: device.isLocal ? "" : "~")
    }

    /// Resolved against the live list, so a space closed while the sheet is open
    /// creates nothing rather than silently landing in another one.
    private var chosenEntry: AppModel.SpaceEntry? {
        model.visibleSpaces.first { $0.ref == space }
    }

    private var chosenDevice: Device { model.device(newSpaceDeviceID) ?? .local }

    /// Agent kinds gooseagent reports for the chosen space's device, in the user's
    /// order and minus the kinds switched off in Settings.
    private var agentKinds: [String] {
        guard let device = chosenEntry?.device else { return [] }
        return AgentKindOrder.visibleSorted(model.session(device.id).agentCatalog.kinds)
    }

    /// The root shell of the space this sheet created. Any other space needs a
    /// normal tab, so the reuse stops the moment the selection moves on.
    private var rootPaneID: String? {
        guard let createdSpace, createdSpace.ref == space else { return nil }
        return createdSpace.rootPaneID
    }

    private var headerIcon: String {
        switch request {
        case .choose, .terminal: return "terminal"
        case .agent: return "sparkles"
        }
    }

    private var subtitle: String {
        switch request {
        case .choose: return String(localized: "Choose a space and what to open in it")
        case .terminal: return String(localized: "Choose a space for the new terminal")
        case .agent: return String(localized: "Choose a space for the new agent")
        }
    }

    /// A space that vanished stays named instead of being swapped for another one.
    private var spaceNotice: String? {
        space != nil && chosenEntry == nil ? String(localized: "That space no longer exists") : nil
    }

    /// A kind the shortcut fixed — or the grid has selected — that this device
    /// does not offer, which keeps Confirm off instead of creating the wrong
    /// session. A catalog that is still loading gets the benefit of the doubt:
    /// agent.start reports the real failure.
    private var unavailableAgent: String? {
        guard case .agent(let kind) = type, let device = chosenEntry?.device else { return nil }
        let offered: Bool
        switch model.session(device.id).agentCatalog {
        case .loading:
            return nil
        case .failed:
            offered = false
        case .loaded:
            offered = agentKinds.contains(kind)
        }
        guard !offered else { return nil }
        return String(localized: "\(AgentKindLabel.display(kind)) is not available on this device")
    }

    /// What the type grid says while the device has nothing to launch.
    private var emptyCatalogNotice: String? {
        guard request == .choose, let device = chosenEntry?.device else { return nil }
        switch model.session(device.id).agentCatalog {
        case .loading:
            return String(localized: "Loading agents…")
        case .failed:
            return String(localized: "No agents available on this device")
        case .loaded:
            return agentKinds.isEmpty ? String(localized: "No agents available on this device") : nil
        }
    }

    private var canCreate: Bool {
        guard !showsNewSpaceForm, !isCreatingSpace, chosenEntry != nil, unavailableAgent == nil else { return false }
        return type != .choose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(systemImage: headerIcon, title: String(localized: "New Session"), subtitle: subtitle)
            Rectangle().fill(Theme.hairline).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !showsNewSpaceForm {
                        spaceSection
                        if let spaceNotice { notice(spaceNotice, color: Theme.danger) }
                        if let unavailableAgent { notice(unavailableAgent, color: Theme.danger) }
                    }
                    newSpaceSection
                    if !showsNewSpaceForm, request == .choose {
                        typeSection
                        if let emptyCatalogNotice { notice(emptyCatalogNotice, color: Theme.textTertiary) }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(showsNewSpaceForm)
            .frame(maxHeight: SheetLayout.sessionBodyHeight)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .focusEffectDisabled()
                Button("Create") {
                    model.createNewSession(in: space, type: type, rootPaneID: rootPaneID)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                // While the space form is open Return belongs to it, so
                // half-typed input cannot fire as a session elsewhere.
                .keyboardShortcut(showsNewSpaceForm ? nil : .defaultAction)
                .focusEffectDisabled()
                .disabled(!canCreate)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheetFixedWidth(SheetLayout.medium)
        .gooseagentHideFocusRing()
    }

    private var spaceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetSectionLabel("SPACE")
            if model.visibleSpaces.isEmpty {
                Text("Create a space on this device before opening a session.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                LazyVGrid(columns: Self.spaceColumns, spacing: SheetCardMetrics.gridSpacing) {
                    ForEach(model.visibleSpaces) { entry in
                        spaceCard(entry)
                    }
                }
            }
        }
    }

    /// Name first, then whatever tells same-named spaces on two devices apart.
    private func spaceCard(_ entry: AppModel.SpaceEntry) -> some View {
        let isSelected = entry.ref == space
        let detail = [
            model.showsRowDeviceBadges ? entry.device.name : nil,
            model.spacePath(for: entry),
        ].compactMap { $0 }.joined(separator: " · ")
        return Button {
            space = entry.ref
        } label: {
            HStack(spacing: 8) {
                ProjectSpaceIcon(
                    path: model.spaceIconPath(device: entry.device, workspaceID: entry.workspace.workspaceID)
                )
                .foregroundStyle(isSelected ? Theme.textSecondary : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.workspace.label)
                        .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: SheetCardMetrics.height)
            .background(
                RoundedRectangle(cornerRadius: SheetCardMetrics.cornerRadius)
                    .fill(isSelected ? AnyShapeStyle(Theme.accentWash) : AnyShapeStyle(Theme.itemWash))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SheetCardMetrics.cornerRadius)
                    .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: SheetCardMetrics.cornerRadius))
        }
        .buttonStyle(.plain)
        .gooseagentHideFocusRing()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Editing replaces the list and type grid so the form fits in the sheet.
    private var newSpaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showsNewSpaceForm.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showsNewSpaceForm ? "minus" : "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("New Space")
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .gooseagentHideFocusRing()

            if showsNewSpaceForm { newSpaceForm }
        }
    }

    private var newSpaceForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.showsDeviceBadges {
                SheetSectionLabel("DEVICE")
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: SheetCardMetrics.gridSpacing), count: 4),
                    spacing: SheetCardMetrics.gridSpacing
                ) {
                    ForEach(model.devices) { device in
                        SheetChoiceCard(
                            title: device.name,
                            systemImage: device.isLocal ? "laptopcomputer" : "desktopcomputer",
                            selected: newSpaceDeviceID == device.id
                        ) {
                            newSpaceDeviceID = device.id
                            directory = device.isLocal ? "" : "~"
                        }
                    }
                }
            }

            SheetSectionLabel("NAME")
            TextField("Defaults to the folder name", text: $label)
                .textFieldStyle(.roundedBorder)

            SheetSectionLabel("DIRECTORY")
            DirectoryPickerField(device: chosenDevice, path: $directory)

            Text("Creating a space does not start a session.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)

            if let spaceFormError { notice(spaceFormError, color: Theme.danger) }

            HStack(spacing: 8) {
                Spacer()
                if isCreatingSpace { ProgressView().controlSize(.small) }
                Button("New Space") { createSpace() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                    .focusEffectDisabled()
                    .disabled(isCreatingSpace || directory.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: SheetCardMetrics.cornerRadius).fill(Theme.contentBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SheetCardMetrics.cornerRadius)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetSectionLabel("TYPE")
            LazyVGrid(columns: Self.typeColumns, spacing: SheetCardMetrics.gridSpacing) {
                SheetChoiceCard(
                    title: String(localized: "Terminal"),
                    systemImage: "terminal",
                    selected: type == .terminal
                ) {
                    type = .terminal
                }
                ForEach(agentKinds, id: \.self) { kind in
                    SheetChoiceCard(
                        title: AgentKindLabel.display(kind),
                        selected: type == .agent(kind)
                    ) {
                        type = .agent(kind)
                    } icon: {
                        if let resource = BrandIconLoader.agentIcon(for: kind) {
                            BrandIcon(resource: resource, size: SheetCardMetrics.iconSize, fallbackSystemName: "sparkles")
                        } else {
                            Image(systemName: "sparkles")
                        }
                    }
                }
            }
        }
    }

    private func notice(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Selecting the new space and keeping the chosen type is the whole point:
    /// creating a space here must not silently open a session in it too.
    private func createSpace() {
        guard !isCreatingSpace else { return }
        let device = chosenDevice
        let directory = self.directory
        let label = self.label
        isCreatingSpace = true
        spaceFormError = nil
        Task {
            do {
                let created = try await model.createSpace(device: device, directory: directory, label: label)
                model.revealCreatedSpace(created)
                space = created.ref
                createdSpace = created
                showsNewSpaceForm = false
            } catch {
                spaceFormError = model.actionErrorMessage(error, device: device)
            }
            isCreatingSpace = false
        }
    }
}

struct NewSpaceSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var deviceID: UUID
    @State private var directory = ""
    @State private var label = ""
    @State private var isCreatingSpace = false
    @State private var spaceError: String?

    init(model: AppModel) {
        self.model = model
        let device = model.deviceFilter.flatMap { model.device($0) } ?? model.devices.first ?? .local
        _deviceID = State(initialValue: device.id)
        _directory = State(initialValue: device.isLocal ? "" : "~")
    }

    private var chosenDevice: Device {
        model.device(deviceID) ?? .local
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "plus",
                title: String(localized: "New Space"),
                subtitle: String(localized: "New space on \(chosenDevice.name)")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            // Scroll the form; keep footer pinned so Cancel / New Space never clip.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.showsDeviceBadges {
                        SheetSectionLabel("DEVICE")
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: SheetCardMetrics.gridSpacing), count: 4),
                            spacing: SheetCardMetrics.gridSpacing
                        ) {
                            ForEach(model.devices) { device in
                                SheetChoiceCard(
                                    title: device.name,
                                    systemImage: device.isLocal ? "laptopcomputer" : "desktopcomputer",
                                    selected: deviceID == device.id
                                ) {
                                    deviceID = device.id
                                    directory = device.isLocal ? "" : "~"
                                }
                            }
                        }

                        Spacer().frame(height: 12)
                    }

                    SheetSectionLabel("NAME")
                    TextField("Defaults to the folder name", text: $label)
                        .textFieldStyle(.roundedBorder)

                    Spacer().frame(height: 12)

                    SheetSectionLabel("DIRECTORY")
                    DirectoryPickerField(device: chosenDevice, path: $directory)

                    Text("Creating a space does not start a session.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)

                    if let spaceError {
                        Text(spaceError)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.danger)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 480)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                if isCreatingSpace { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .focusEffectDisabled()
                Button("New Space") {
                    guard !isCreatingSpace else { return }
                    isCreatingSpace = true
                    spaceError = nil
                    let device = chosenDevice
                    let directory = directory
                    let label = label
                    Task {
                        do {
                            model.revealCreatedSpace(try await model.createSpace(
                                device: device, directory: directory, label: label
                            ))
                            dismiss()
                        } catch {
                            spaceError = model.actionErrorMessage(error, device: device)
                        }
                        isCreatingSpace = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .focusEffectDisabled()
                .disabled(isCreatingSpace || directory.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheetFixedWidth(SheetLayout.medium)
        .gooseagentHideFocusRing()
    }
}

/// Local folders use the system picker; remote paths remain editable because the
/// macOS picker cannot browse another device's filesystem.
struct DirectoryPickerField: View {
    let device: Device
    @Binding var path: String

    var body: some View {
        Group {
            if device.isLocal {
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.begin { response in
                        if response == .OK, let url = panel.url { path = url.path }
                    }
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: path.isEmpty ? "folder.badge.plus" : "folder.fill")
                            .font(.system(size: 23))
                            .foregroundStyle(Theme.accent)
                        Text(path.isEmpty ? String(localized: "Choose folder") : (path as NSString).lastPathComponent)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.text)
                        if !path.isEmpty {
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 104)
                    .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: SheetCardMetrics.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: SheetCardMetrics.cornerRadius)
                        .strokeBorder(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityHint(Text("Browse…"))
            } else {
                TextField("~/Projects/foo", text: $path)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

struct RenameSpaceSheet: View {
    @ObservedObject var model: AppModel
    let entry: AppModel.SpaceEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: String(localized: "Rename Space"),
                subtitle: String(localized: "Rename \(entry.workspace.label) on \(entry.device.name)")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Space name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .focusEffectDisabled()
                Button("Rename") {
                    model.renameSpace(entry, label: name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .focusEffectDisabled()
                .disabled(trimmedName.isEmpty || trimmedName == entry.workspace.label)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheetFixedWidth(SheetLayout.narrow)
        .gooseagentHideFocusRing()
        .onAppear { name = entry.workspace.label }
    }
}

struct RenameAgentSheet: View {
    @ObservedObject var model: AppModel
    let entry: AppModel.AgentEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: String(localized: "Rename Agent"),
                subtitle: String(localized: "Rename \(entry.title) on \(entry.device.name)")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Agent name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("Chinese, spaces, and punctuation are allowed.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .focusEffectDisabled()
                Button("Rename") {
                    model.renameAgent(entry, name: name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .focusEffectDisabled()
                .disabled(trimmedName.isEmpty || trimmedName == entry.title)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheetFixedWidth(SheetLayout.narrow)
        .gooseagentHideFocusRing()
        .onAppear { name = entry.title }
    }
}

struct RenameTerminalSheet: View {
    @ObservedObject var model: AppModel
    let entry: AppModel.TerminalEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: String(localized: "Rename Terminal"),
                subtitle: String(localized: "Rename \(entry.title) on \(entry.device.name)")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Terminal name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("Chinese, spaces, and punctuation are allowed.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .focusEffectDisabled()
                Button("Rename") {
                    model.renameTerminal(entry, name: name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .focusEffectDisabled()
                .disabled(trimmedName.isEmpty || trimmedName == entry.title)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheetFixedWidth(SheetLayout.narrow)
        .gooseagentHideFocusRing()
        .onAppear { name = entry.title }
    }
}

struct EditDeviceSheet: View {
    @ObservedObject var model: AppModel
    let device: Device
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var target = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: String(localized: "Edit Device"),
                subtitle: String(localized: "Changing the SSH target reconnects the device")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Spacer().frame(height: 8)
                SheetSectionLabel("SSH TARGET")
                TextField("SSH target", text: $target)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .focusEffectDisabled()
                Button("Save") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
                    model.updateDevice(
                        device.id,
                        name: trimmedName.isEmpty ? trimmedTarget : trimmedName,
                        sshTarget: trimmedTarget
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .focusEffectDisabled()
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheetFixedWidth(SheetLayout.narrow)
        .gooseagentHideFocusRing()
        .onAppear {
            name = device.name
            target = device.sshTarget ?? ""
        }
    }
}
