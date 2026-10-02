import AppKit
import QuartzCore
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @ObservedObject private var appearanceDriver = AppearanceDriver.shared
    @ObservedObject private var themePreview = ThemePreview.shared
    /// An edited theme file re-renders the chrome when it is the theme in use.
    @ObservedObject private var userThemes = UserThemeStore.shared
    @AppStorage(AppShortcuts.revisionKey) private var shortcutsRevision = 0
    @AppStorage(TerminalAppearance.storageKey) private var appearanceRaw = TerminalAppearance.system.rawValue
    @AppStorage(TerminalAppearance.lightThemeKey) private var lightThemeRaw = TerminalThemeChoice.defaultLightName
    @AppStorage(TerminalAppearance.darkThemeKey) private var darkThemeRaw = TerminalThemeChoice.defaultDarkName
    @AppStorage(SidebarLayout.widthKey) private var sidebarWidth: Double = SidebarLayout.defaultWidth
    @AppStorage(TerminalSettings.backgroundOpacityKey) private var backgroundOpacity = TerminalSettings.defaults.backgroundOpacity
    @AppStorage(TerminalSettings.backgroundBlurKey) private var backgroundBlur = false
    /// Width while the divider is being dragged. Nil when idle; the layout follows it so writes to
    /// `sidebarWidth` during the drag do not move anything.
    @State private var liveSidebarWidth: CGFloat?
    @StateObject private var dropRelay = CanvasDropRelay()
    @State private var renamingWorkspaceID: UUID?
    @State private var workspaceNameDraft = ""
    @State private var skipWorkspaceRenameCommit = false
    @State private var hoveredTabID: UUID?
    @State private var sidebarHovered = false
    @FocusState private var workspaceNameFocused: Bool

    private var chrome: WindowChrome {
        WindowChrome.resolve(isDark: appearanceDriver.isDark)
    }

    /// Below 100% background opacity every layer behind the terminals turns clear, so the desktop
    /// (or the blur) shows through. The sidebar and pane titles keep their own opaque fills.
    private var terminalTranslucent: Bool {
        backgroundOpacity < 1
    }

    @ViewBuilder
    private var terminalBackdrop: some View {
        if !terminalTranslucent {
            chrome.background
        } else if backgroundBlur {
            TerminalBlurBackdrop()
        } else {
            Color.clear
        }
    }

    var body: some View {
        let _ = shortcutsRevision
        HStack(spacing: 0) {
            sidebar
                .frame(width: currentSidebarWidth)
            SidebarDivider(chrome: chrome, storedWidth: $sidebarWidth, liveWidth: $liveSidebarWidth)
                // Above both neighbours so the wide hit area wins over the rows and the terminal.
                .zIndex(1)
            ZStack {
                // Terminals stay in the view tree while Files is shown, so no session is torn down.
                detail
                    .opacity(window.section == .terminals ? 1 : 0)
                    .allowsHitTesting(window.section == .terminals)
                if window.section == .files {
                    FilesWorkspaceView(model: model, window: window, relay: dropRelay)
                }
            }
        }
        .frame(minWidth: 880, minHeight: 520)
        .background(terminalTranslucent ? Color.clear : chrome.background)
        .environment(\.windowChrome, chrome)
        .ignoresSafeArea(edges: .top)
        .preferredColorScheme(appearanceDriver.interfaceColorScheme)
        .onChange(of: appearanceRaw) { _, _ in
            appearanceDriver.reapply()
        }
        .oneagentHideFocusRing()
        .task { model.reloadHosts() }
        .onAppear {
            window.relay = dropRelay
            dropRelay.windowBox = window
            GhosttyRuntime.applySelectedThemes()
            appearanceDriver.reapply()
            MainWindowManager.shared.applyBackgroundOpacity(backgroundOpacity, to: window)
        }
        .onChange(of: terminalTranslucent) { _, _ in
            MainWindowManager.shared.applyBackgroundOpacity(backgroundOpacity, to: window)
        }
        .onChange(of: lightThemeRaw) { _, _ in
            GhosttyRuntime.applySelectedThemes()
        }
        .onChange(of: darkThemeRaw) { _, _ in
            GhosttyRuntime.applySelectedThemes()
        }
        .background(WindowTitleSync(title: windowTitle))
        .sheet(isPresented: $window.hostPickerPresented, onDismiss: { window.hostPickerPurpose = .terminal }) {
            HostPicker(model: model, window: window)
                .frame(width: SheetLayout.search, height: SheetLayout.sessionBodyHeight)
                .environment(\.windowChrome, chrome)
                .preferredColorScheme(appearanceDriver.interfaceColorScheme)
                .oneagentHideFocusRing()
        }
    }

    private var openHostHelp: String {
        String(format: String(localized: "Open Host (%@)"), AppShortcuts.display(for: .openHost))
    }

    /// The width the sidebar is laid out at right now: the drag preview if any, else the stored width.
    private var currentSidebarWidth: CGFloat {
        if let liveSidebarWidth {
            return liveSidebarWidth
        }
        return SidebarLayout.clamped(CGFloat(sidebarWidth))
    }

    /// Empty-state hint naming the host picker and local terminal shortcuts.
    private var emptyHint: String {
        String(
            format: String(localized: "Press %@ to open a host, or %@ for a local terminal."),
            AppShortcuts.display(for: .openHost),
            AppShortcuts.display(for: .newLocalTerminal)
        )
    }

    /// "root@host" or "~/path" for the selected terminal, else the app name.
    /// Shown in Mission Control and the Window menu.
    private var windowTitle: String {
        if selectedSessionBadge.isEmpty {
            return "Ghostty"
        }
        return selectedSessionBadge
    }

    private var filesButton: some View {
        let showing = window.section == .files
        let targeted = window.filesDropTarget == .button
        return SidebarIconButton(
            symbol: showing ? "folder.fill" : "folder",
            help: String(format: String(localized: "Files (%@)"), AppShortcuts.display(for: .openFileBrowser)),
            accessibilityLabel: "Files",
            fill: chrome.sidebarBackground,
            hoverFill: chrome.elevated,
            tint: showing || targeted ? chrome.accent : nil,
            highlighted: targeted,
            action: { model.toggleSection(in: window) }
        )
        .background(BoundsAnchor { dropRelay.filesButtonAnchor = $0 })
        .opacity(sidebarHovered || showing || targeted ? 1 : 0)
        .allowsHitTesting(sidebarHovered || showing)
    }

    private var windowControls: some View {
        SidebarIconButton(
            symbol: "plus",
            help: openHostHelp,
            accessibilityLabel: "Open Host…",
            fill: chrome.sidebarBackground,
            hoverFill: chrome.elevated,
            action: { model.openHostPicker(in: window) }
        )
        .opacity(sidebarHovered ? 1 : 0)
        .allowsHitTesting(sidebarHovered)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                WindowDragArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                filesButton
                windowControls
            }
            .padding(.leading, SidebarLayout.trafficLightInset)
            .padding(.trailing, Theme.Space.s)
            .frame(height: SidebarLayout.headerHeight)
            .padding(.bottom, SidebarLayout.headerBottomGap)

            if model.sidebarOrder(in: window).isEmpty {
                Text(emptyHint)
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.top, Theme.Space.s)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: Theme.Space.xs) {
                        // Loose groups stay visible while anything is being dragged, so there is
                        // always a place to drop a terminal that leaves its workspace.
                        let dragging = model.windows.contains { $0.draggingTabID != nil || $0.draggingBlock != nil }
                        let visibleBlocks = window.blocks.filter { sidebarBlockVisible($0, dragging: dragging) }
                        ForEach(visibleBlocks, id: \.self) { block in
                            if block != visibleBlocks.first {
                                Rectangle()
                                    .fill(chrome.hairline)
                                    .frame(height: 1)
                                    .padding(.horizontal, Theme.Space.m)
                            }
                            switch block {
                            case .workspace(let id):
                                if let workspace = model.workspace(for: id) {
                                    VStack(spacing: 2) {
                                        workspaceHeader(workspace)
                                        ForEach(model.tabs(in: workspace)) { tab in
                                            tabRow(tab, compact: false, indent: Theme.Space.xs)
                                        }
                                    }
                                    .padding(.vertical, Theme.Space.xs)
                                    .overlay(blockFill(block))
                                    .padding(.horizontal, Theme.Space.s)
                                    .background(SidebarBlockAnchor(block: block, relay: dropRelay))
                                }
                            case .localGroup, .ungrouped:
                                let members = model.looseTabs(in: block, window: window)
                                if !members.isEmpty || dragging {
                                    VStack(spacing: 2) {
                                        sidebarSectionHeader(
                                            block == .localGroup ? "Local Group" : "Ungrouped",
                                            block: block,
                                            isFirst: block == visibleBlocks.first
                                        )
                                        ForEach(members) { tab in
                                            tabRow(tab, compact: false, indent: Theme.Space.xs)
                                        }
                                        if members.isEmpty {
                                            Color.clear
                                                .frame(maxWidth: .infinity)
                                                .frame(height: SidebarLayout.rowHeight)
                                        }
                                    }
                                    .overlay(blockFill(block))
                                    .padding(.horizontal, Theme.Space.s)
                                    .background(SidebarBlockAnchor(block: block, relay: dropRelay))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Theme.Space.xs)
                    .padding(.bottom, Theme.Space.m)
                }
            }
        }
        .background(BoundsAnchor { dropRelay.sidebarAnchor = $0 })
        .background(chrome.sidebarBackground)
        .onHover { inside in
            sidebarHovered = inside
        }
        // The relay already ignores anchors that left the window; clearing is a second guard.
        .onDisappear { dropRelay.sidebarAnchor = nil }
    }

    private var selectedSessionBadge: String {
        guard let tab = model.selectedTab(in: window) else { return "" }
        if let title = tab.contentTitle {
            return title
        }
        if tab.isLocal, let directory = tab.directory {
            return LocalTerminal.displayPath(directory)
        }
        if let host = tab.alias.flatMap({ model.host($0) }) {
            return host.sessionBadge
        }
        return tab.alias ?? ""
    }

    private func tabRow(_ tab: TerminalTab, compact: Bool, indent: CGFloat = 0) -> some View {
        let selected = model.isSidebarSelected(tab.id, in: window)
        let host = tab.alias.flatMap { model.host($0) }
        let showsClosed = !compact && tab.showsDisconnected
        let showsReconnecting = !compact && tab.reconnecting
        let compactHelp: String
        if showsReconnecting {
            compactHelp = String(localized: "Reconnecting…")
        } else if showsClosed {
            compactHelp = String(localized: "Connection closed")
        } else if tab.isLocal, let directory = tab.directory {
            compactHelp = LocalTerminal.displayPath(directory)
        } else {
            compactHelp = host?.sessionBadge ?? ""
        }
        let hovered = hoveredTabID == tab.id
        return HStack(spacing: 6) {
            DuplicateHostDot(mark: model.duplicateHostMark(for: tab.id))
            Text(sidebarTitle(tab))
                .font(selected ? Theme.Font.row.weight(.medium) : Theme.Font.row)
                .foregroundStyle(chrome.text)
                .lineLimit(1)
                .truncationMode(tab.isLocal ? .head : .tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            SidebarBellMark(sessionID: tab.sessionID)
            if showsReconnecting {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(chrome.warning)
                    .frame(width: 14, height: 14)
                    .accessibilityLabel(Text("Reconnecting…"))
            } else if showsClosed {
                Image(systemName: "link.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(chrome.danger)
                    .frame(width: 14, height: 14)
                    .accessibilityLabel(Text("Connection closed"))
            }
        }
        .help(tab.isLocal || compact || showsClosed || showsReconnecting ? compactHelp : "")
        .padding(.leading, Theme.Space.s + indent)
        .padding(.trailing, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SidebarLayout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(rowFill(selected: selected, hovered: hovered, tabID: tab.id))
                .padding(.horizontal, SidebarLayout.rowInset)
        )
        .background(RowAnchor(id: tab.id, relay: dropRelay))
        .overlay {
            TabDragHandle(
                onClick: { command, shift in
                    model.clickSidebar(tab.id, command: command, shift: shift, in: window)
                },
                // The handle owns the row's mouse tracking, so hover comes from it, not from SwiftUI.
                onHover: { inside in
                    if inside {
                        hoveredTabID = tab.id
                    } else if hoveredTabID == tab.id {
                        hoveredTabID = nil
                    }
                },
                onBegan: { dropRelay.dragBegan(tab.id) },
                onMoved: { dropRelay.dragMoved(windowPoint: $0) },
                onEnded: { dropRelay.dragEnded(windowPoint: $0) },
                prepareContextMenu: {
                    let targets = model.sidebarTargets(clicking: tab.id, in: window)
                    let splits = model.sidebarSplits(targets)
                    let canCreateArea = model.sidebarCanCreateArea(targets)
                    return TabContextMenu(
                        showsDuplicate: targets.count == 1,
                        splits: splits,
                        canMerge: targets.count >= 2,
                        canCreateArea: canCreateArea,
                        duplicateRight: { model.duplicate(targets[0], edge: .right) },
                        duplicateDown: { model.duplicate(targets[0], edge: .bottom) },
                        merge: {
                            if splits {
                                model.splitSidebar(targets, in: window)
                            } else {
                                model.mergeSidebar(targets, in: window)
                            }
                        },
                        createArea: { model.createAreaFromSidebar(targets, in: window) },
                        close: { model.closeTabs(targets) },
                        copyInfo: { copySessionInfo(tab, model: model) }
                    )
                }
            )
        }
    }

    /// Loose groups show while anything is being dragged, so there is always a drop target.
    private func sidebarBlockVisible(_ block: SidebarBlock, dragging: Bool) -> Bool {
        switch block {
        case .workspace(let id):
            return model.workspace(for: id) != nil
        case .localGroup, .ungrouped:
            return dragging || !model.looseTabs(in: block, window: window).isEmpty
        }
    }

    private func sidebarTitle(_ tab: TerminalTab) -> String {
        if let title = tab.contentTitle {
            return title
        }
        if tab.isLocal, let directory = tab.directory {
            return LocalTerminal.displayPath(directory)
        }
        return tab.alias ?? String(localized: "New Tab")
    }

    /// The first header sits right under the sidebar header gap, without the extra section inset.
    private func sidebarSectionHeader(_ title: LocalizedStringKey, block: SidebarBlock, isFirst: Bool) -> some View {
        Text(title)
            .font(Theme.Font.sidebarSection)
            .foregroundStyle(chrome.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, isFirst ? 0 : SidebarLayout.sectionTopInset)
            .padding(.bottom, Theme.Space.xs)
            .contentShape(Rectangle())
            .overlay {
                BlockDragHandle(
                    onBegan: { dropRelay.blockDragBegan(block) },
                    onMoved: { dropRelay.blockDragMoved(windowPoint: $0) },
                    onEnded: { dropRelay.blockDragEnded(windowPoint: $0) }
                )
            }
    }

    private func workspaceTitle(_ workspace: Workspace) -> String {
        if let name = workspace.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return String(format: String(localized: "Workspace %lld"), workspace.number)
    }

    private func beginWorkspaceRename(_ workspace: Workspace) {
        workspaceNameDraft = workspaceTitle(workspace)
        skipWorkspaceRenameCommit = false
        workspaceNameFocused = false
        renamingWorkspaceID = workspace.id
    }

    private func commitWorkspaceRename() {
        guard let id = renamingWorkspaceID else { return }
        model.renameWorkspace(id, to: workspaceNameDraft)
        renamingWorkspaceID = nil
    }

    private func workspaceLayoutTitle(_ layout: WorkspaceLayout) -> String {
        switch layout {
        case .columns:
            return String(localized: "Equal Columns")
        case .rows:
            return String(localized: "Equal Rows")
        case .grid:
            return String(localized: "Grid")
        case .leadingSide:
            return String(localized: "Leading Pane on the Left")
        case .leadingTop:
            return String(localized: "Leading Pane on the Top")
        }
    }

    private func workspaceHeader(_ workspace: Workspace) -> some View {
        let count = WorkspaceBoard.leafIDs(workspace.layout).count
        let layouts = WorkspaceBoard.availableLayouts(paneCount: count)
        let renaming = renamingWorkspaceID == workspace.id
        return HStack(spacing: Theme.Space.s) {
            if renaming {
                TextField("Workspace name", text: $workspaceNameDraft)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.sidebarSection)
                    .foregroundStyle(chrome.text)
                    .focused($workspaceNameFocused)
                    .onAppear {
                        workspaceNameFocused = true
                    }
                    .onSubmit { commitWorkspaceRename() }
                    .onExitCommand {
                        skipWorkspaceRenameCommit = true
                        renamingWorkspaceID = nil
                        workspaceNameFocused = false
                    }
                    .onChange(of: workspaceNameFocused) { _, focused in
                        if focused {
                            DispatchQueue.main.async {
                                NSApp.keyWindow?.fieldEditor(false, for: nil)?.selectAll(nil)
                            }
                            return
                        }
                        if skipWorkspaceRenameCommit {
                            skipWorkspaceRenameCommit = false
                            return
                        }
                        commitWorkspaceRename()
                    }
            } else {
                Text(workspaceTitle(workspace))
                    .font(Theme.Font.sidebarSection)
                    .foregroundStyle(chrome.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // Pane count. The capsule shows the bare number; the label spells it out.
            Text(verbatim: String(count))
                .font(Theme.Font.rowMeta)
                .foregroundStyle(chrome.secondary)
                .padding(.horizontal, Theme.Space.xs)
                .frame(minWidth: SidebarLayout.badgeHeight)
                .frame(height: SidebarLayout.badgeHeight)
                .background(Capsule().fill(chrome.hairline))
                .accessibilityLabel(Text(String(format: String(localized: "%lld panes"), count)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SidebarLayout.rowHeight)
        .padding(.horizontal, Theme.Space.m)
        .contentShape(Rectangle())
        .overlay {
            if !renaming {
                WorkspaceHeaderMenu(
                    layouts: layouts,
                    titles: layouts.map { workspaceLayoutTitle($0) },
                    canReconnect: model.tabs(in: workspace).contains { $0.isSession && $0.exited },
                    onLayout: { model.applyWorkspaceLayout(workspace.id, $0) },
                    onReconnect: { model.reconnectWorkspace(workspace.id) },
                    onRename: { beginWorkspaceRename(workspace) },
                    onDissolve: { model.dissolveWorkspace(workspace.id) },
                    onDragBegan: { dropRelay.blockDragBegan(.workspace(workspace.id)) },
                    onDragMoved: { dropRelay.blockDragMoved(windowPoint: $0) },
                    onDragEnded: { dropRelay.blockDragEnded(windowPoint: $0) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func rowFill(selected: Bool, hovered: Bool, tabID: UUID) -> Color {
        if window.dropHighlight == .sidebarRow(tabID) || window.dropHighlight == .sidebar {
            return chrome.accent.opacity(0.28)
        }
        if selected {
            return chrome.accentFill
        }
        if hovered {
            return chrome.hairline
        }
        return Color.clear
    }

    /// Whole-block outline while a block or a multi-selection is about to merge into it.
    /// Laid over the block; never takes the mouse.
    private func blockFill(_ block: SidebarBlock) -> some View {
        let active = window.dropHighlight == .block(block)
        return RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(chrome.accent.opacity(active ? 0.14 : 0))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(chrome.accent.opacity(active ? 0.9 : 0), lineWidth: 2)
            )
            .allowsHitTesting(false)
    }

    private var detail: some View {
        ZStack {
            TerminalCanvas(
                model: model,
                window: window,
                dropRelay: dropRelay,
                dark: appearanceDriver.isDark,
                translucent: terminalTranslucent
            )
            if model.selectedTab(in: window) == nil {
                TerminalEmptyState(
                    chrome: chrome,
                    hint: emptyHint,
                    localTerminalShortcut: AppShortcuts.display(for: .newLocalTerminal),
                    openHostShortcut: AppShortcuts.display(for: .openHost),
                    onLocalTerminal: { model.openLocalTerminal(in: window) },
                    onOpenHost: { model.openHostPicker(in: window) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(terminalBackdrop)
    }
}

/// Blur behind a translucent terminal area. Ghostty's own `background-blur` does nothing when
/// embedded, so the app draws it. The material follows the window's light / dark appearance.
struct TerminalBlurBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Sidebar geometry. The user drags the divider between `minWidth` and `maxWidth`.
enum SidebarLayout {
    static let defaultWidth: CGFloat = 260
    static let minWidth: CGFloat = 200
    static let maxWidth: CGFloat = 420
    /// Top strip that holds the window controls and the new-tab button. As tall as the system
    /// title bar, so its content lines up with the traffic lights.
    static let headerHeight: CGFloat = Theme.PaneStyle.titlebarHeight
    /// Space between the header and the list. A list scroll view flush with the title bar
    /// edge takes over clicks on the header buttons.
    static let headerBottomGap: CGFloat = 12
    static let rowHeight: CGFloat = 28
    /// Width the traffic lights take from the window's left edge.
    static let trafficLightInset: CGFloat = 78
    /// Horizontal gap between a row's selection/hover shape and the block edge.
    static let rowInset: CGFloat = 6
    /// Space above a Local Group / Ungrouped title.
    static let sectionTopInset: CGFloat = 10
    /// Pane-count capsule on a workspace card.
    static let badgeHeight: CGFloat = 16
    /// Icon buttons in the header.
    static let iconButtonSize: CGFloat = 28
    /// Grab area around the 1pt divider line.
    static let dividerHitWidth: CGFloat = 9
    /// UserDefaults key for the user width.
    static let widthKey = "sidebar.width"

    static func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, SidebarLayout.minWidth), SidebarLayout.maxWidth)
    }
}

/// 28×28 icon button for the sidebar header.
struct SidebarIconButton: View {
    var symbol: String
    var help: String
    var accessibilityLabel: LocalizedStringKey
    /// Opaque base; also what shows when the pointer is elsewhere.
    var fill: Color
    var hoverFill: Color
    /// Symbol color when the button stands for the current state; nil keeps the default.
    var tint: Color? = nil
    /// Drawn with the hover fill even without the pointer, e.g. while something is dragged onto it.
    var highlighted = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .frame(width: SidebarLayout.iconButtonSize, height: SidebarLayout.iconButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(hovering || highlighted ? hoverFill : Color.clear)
                )
                // Opaque fill so AppKit does not treat the hit as window-drag.
                .background(fill)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

/// Fills the terminal area while nothing is open: a glyph, the hint, and the two ways to start.
struct TerminalEmptyState: View {
    var chrome: WindowChrome
    var hint: String
    var localTerminalShortcut: String
    var openHostShortcut: String
    var onLocalTerminal: () -> Void
    var onOpenHost: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "terminal")
                .font(Theme.Font.emptySymbol)
                .foregroundStyle(chrome.tertiary)
            Text("No open terminals")
                .font(Theme.Font.emptyTitle)
                .foregroundStyle(chrome.text)
            Text(hint)
                .font(Theme.Font.body)
                .foregroundStyle(chrome.secondary)
                .multilineTextAlignment(.center)
            HStack(alignment: .top, spacing: Theme.Space.m) {
                VStack(spacing: Theme.Space.xs) {
                    Button("Local Terminal", action: onLocalTerminal)
                        .buttonStyle(.bordered)
                    Text(localTerminalShortcut)
                        .font(Theme.Font.rowMeta)
                        .foregroundStyle(chrome.tertiary)
                }
                VStack(spacing: Theme.Space.xs) {
                    Button("Open Host…", action: onOpenHost)
                        .buttonStyle(.borderedProminent)
                    Text(openHostShortcut)
                        .font(Theme.Font.rowMeta)
                        .foregroundStyle(chrome.tertiary)
                }
            }
            .padding(.top, Theme.Space.s)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(chrome.background)
    }
}

/// The 1pt line between the sidebar and the terminal area. Drag to resize the sidebar,
/// double-click to restore the default width. The grab area is wider than the line.
struct SidebarDivider: View {
    var chrome: WindowChrome
    /// Persisted width. Written as whole points while dragging and once more on release.
    @Binding var storedWidth: Double
    /// Width shown while a drag is in progress; nil when idle.
    @Binding var liveWidth: CGFloat?
    /// Stored width when the drag began; the drag delta is applied to this.
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(chrome.hairline)
            .frame(width: 1)
            .overlay {
                // AppKit tracks the mouse itself, so a mouse-up over the terminal NSView still ends the drag.
                SidebarDividerHandle(
                    onDragChanged: { deltaX in
                        let start: CGFloat
                        if let dragStartWidth {
                            start = dragStartWidth
                        } else {
                            start = SidebarLayout.clamped(CGFloat(storedWidth))
                            dragStartWidth = start
                        }
                        let width = SidebarLayout.clamped(start + deltaX)
                        liveWidth = width
                        let rounded = Double(Int(width.rounded()))
                        if storedWidth != rounded {
                            storedWidth = rounded
                        }
                    },
                    onDragEnded: { deltaX in
                        if let dragStartWidth {
                            storedWidth = Double(SidebarLayout.clamped(dragStartWidth + deltaX))
                        }
                        liveWidth = nil
                        dragStartWidth = nil
                    },
                    onDoubleClick: {
                        storedWidth = Double(SidebarLayout.defaultWidth)
                    }
                )
                .frame(width: SidebarLayout.dividerHitWidth)
            }
    }
}

/// The grab area of `SidebarDivider`. Reports drag deltas in window points and double-clicks.
struct SidebarDividerHandle: NSViewRepresentable {
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: (CGFloat) -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> SidebarDividerView {
        SidebarDividerView()
    }

    func updateNSView(_ view: SidebarDividerView, context: Context) {
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        view.onDoubleClick = onDoubleClick
    }
}

/// Tracks the drag with `trackEvents`, so the mouse-up is delivered wherever the pointer ends up.
final class SidebarDividerView: NSView {
    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onDragEnded: (CGFloat) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func layout() {
        super.layout()
        // The handle moves with the sidebar edge; keep the cursor rect on it.
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            onDoubleClick()
            return
        }
        let startX = event.locationInWindow.x
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: 3600,
            mode: .eventTracking
        ) { event, stop in
            guard let event else {
                stop.pointee = true
                return
            }
            let deltaX = event.locationInWindow.x - startX
            if event.type == .leftMouseUp {
                self.onDragEnded(deltaX)
                stop.pointee = true
                return
            }
            self.onDragChanged(deltaX)
        }
    }
}

enum SheetLayout {
    static let search: CGFloat = 520
    static let sessionBodyHeight: CGFloat = 580
    static let settings: CGFloat = 880
    static let settingsBodyHeight: CGFloat = 720
    /// Preview of what "Import from Ghostty" would change, shown over Settings.
    static let importPreview: CGFloat = 680
    static let importPreviewBodyHeight: CGFloat = 600
    /// Search field at the top of the host picker.
    static let searchFieldHeight: CGFloat = 38
    /// One host (or the local terminal) row in the host picker.
    static let pickerRowHeight: CGFloat = 36
    /// File list in the "convert to UTF-8 + LF before upload" alert.
    static let uploadCheckListWidth: CGFloat = 460
    static let uploadCheckListMaxHeight: CGFloat = 240
}

/// Geometry of the file pane, after 1Panel's SFTP page.
enum FileBrowserLayout {
    static let titleBarHeight: CGFloat = 40
    static let toolbarHeight: CGFloat = 36
    static let headerHeight: CGFloat = 36
    static let rowHeight: CGFloat = 40
    static let filterWidth: CGFloat = 160
    /// Name, modified, size, kind. The name column takes what is left.
    static let nameMinWidth: CGFloat = 120
    static let modifiedWidth: CGFloat = 128
    static let sizeWidth: CGFloat = 72
    static let kindWidth: CGFloat = 64
    static let iconSize: CGFloat = 18
    static let toolbarButtonSize: CGFloat = 24
    static let folderColor = Color(red: 0x4C / 255, green: 0x8D / 255, blue: 0xFF / 255)
    /// Text preview drawer along the bottom of a column.
    static let previewHeightShare: CGFloat = 0.5
    static let previewByteLimit = 512 * 1024
    /// Progress toast at the bottom center of the window.
    static let toastWidth: CGFloat = 360
    static let toastHeight: CGFloat = 40
    /// From the window top; clears the tab strip.
    static let toastTopInset: CGFloat = 44
    static let toastLingerSeconds: Double = 2.5
    /// Tab strip above each side of the Files area, as in Xftp.
    static let tabStripHeight: CGFloat = 32
    static let tabMinWidth: CGFloat = 56
    static let tabMaxWidth: CGFloat = 180
    /// Share of a pane's width and height kept from each edge: dropping a tab inside joins the pane.
    static let joinZoneInset: CGFloat = 0.3
}

/// Geometry of the ⌃⇥ terminal switcher. Cards grow or shrink with the number of terminals.
enum SwitcherLayout {
    /// Gap between the switcher panel and the main window's edges.
    static let windowInset: CGFloat = 24
    /// Padding inside the panel around the grid and the hint line.
    static let panelPadding: CGFloat = 20
    static let panelCornerRadius: CGFloat = 14
    static let spacing: CGFloat = 14
    static let cardPadding: CGFloat = 6
    static let cardCornerRadius: CGFloat = 10
    static let thumbnailCornerRadius: CGFloat = 6
    static let titleHeight: CGFloat = 18
    static let titleSpacing: CGFloat = 6
    static let hintHeight: CGFloat = 28
    /// Width over height of a thumbnail.
    static let thumbnailAspect: CGFloat = 1.6
    static let minCardWidth: CGFloat = 150
    /// One card never takes more than this share of the grid width, so two terminals still read as a choice.
    static let maxCardWidthShare: CGFloat = 0.45
    static let highlightLineWidth: CGFloat = 2.5
    /// Thumbnail text is sized so a terminal row fills the thumbnail, within these bounds.
    static let thumbnailFontRange: ClosedRange<CGFloat> = 4 ... 9
    /// Monospaced glyph width and line height relative to the font size.
    static let glyphWidthRatio: CGFloat = 0.6
    static let lineHeightRatio: CGFloat = 1.2
    /// Assumed terminal width when the screen text is narrower.
    static let minTextColumns = 80
    static let maxTextColumns = 200

    struct Grid: Equatable {
        var columns: Int
        var cardWidth: CGFloat
        /// The cards hit `minCardWidth` and still do not fit, so the grid scrolls.
        var scrolls: Bool

        var thumbnailWidth: CGFloat { cardWidth - 2 * SwitcherLayout.cardPadding }
        var thumbnailHeight: CGFloat { thumbnailWidth / SwitcherLayout.thumbnailAspect }
        var cardHeight: CGFloat {
            thumbnailHeight + SwitcherLayout.titleHeight + SwitcherLayout.titleSpacing + 2 * SwitcherLayout.cardPadding
        }
    }

    /// The column count that gives `count` cards the largest size inside `area`.
    static func grid(count: Int, in area: CGSize) -> Grid {
        let count = max(count, 1)
        let chrome = titleHeight + titleSpacing + 2 * cardPadding
        let widest = area.width * maxCardWidthShare
        var best = Grid(columns: 1, cardWidth: 0, scrolls: false)
        for columns in 1 ... count {
            let rows = (count + columns - 1) / columns
            let byWidth = (area.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let rowHeight = (area.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            let byHeight = (rowHeight - chrome) * thumbnailAspect + 2 * cardPadding
            let width = min(byWidth, byHeight, widest)
            if width > best.cardWidth {
                best = Grid(columns: columns, cardWidth: width, scrolls: false)
            }
        }
        if best.cardWidth >= minCardWidth {
            return best
        }
        let fitting = Int((area.width + spacing) / (minCardWidth + spacing))
        return Grid(columns: max(1, min(fitting, count)), cardWidth: minCardWidth, scrolls: true)
    }

    /// Font size that fits `textColumns` monospaced glyphs across a thumbnail `width` points wide.
    static func thumbnailFontSize(width: CGFloat, textColumns: Int) -> CGFloat {
        let columns = CGFloat(min(max(textColumns, minTextColumns), maxTextColumns))
        let size = width / (columns * glyphWidthRatio)
        return min(max(size, thumbnailFontRange.lowerBound), thumbnailFontRange.upperBound)
    }
}

/// A small colored dot before a host title that is open more than once. The color is per alias,
/// so two panes of the same host share a dot and differ from another duplicated host.
struct DuplicateHostDot: View {
    var mark: Int?

    var body: some View {
        if let mark {
            Circle()
                .fill(Theme.duplicateHostMark(mark))
                .frame(width: 6, height: 6)
                .accessibilityLabel(Text("Opened more than once"))
        }
    }
}

/// Bell on a sidebar row whose terminal rang while the user was elsewhere (`bell-features = title`).
/// Observes the bell marks on its own, so a bell does not redraw the whole sidebar.
struct SidebarBellMark: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject private var activity = TerminalActivity.shared
    var sessionID: String

    var body: some View {
        if activity.bellMarks.contains(sessionID) {
            Image(systemName: "bell.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(chrome.warning)
                .frame(width: 14, height: 14)
                .accessibilityLabel(Text("Bell Rang"))
        }
    }
}