import AppKit
import QuartzCore
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @ObservedObject private var appearanceDriver = AppearanceDriver.shared
    @ObservedObject private var themePreview = ThemePreview.shared
    @AppStorage(AppShortcuts.revisionKey) private var shortcutsRevision = 0
    @AppStorage(TerminalAppearance.storageKey) private var appearanceRaw = TerminalAppearance.system.rawValue
    @AppStorage(TerminalAppearance.lightThemeKey) private var lightThemeRaw = TerminalThemeChoice.defaultLightName
    @AppStorage(TerminalAppearance.darkThemeKey) private var darkThemeRaw = TerminalThemeChoice.defaultDarkName
    @AppStorage(SidebarLayout.widthKey) private var sidebarWidth: Double = SidebarLayout.defaultWidth
    @AppStorage(RemotePalette.storageKey) private var remotePaletteRaw = RemotePalette.defaultPalette.rawValue
    @AppStorage(LocalPalette.storageKey) private var localPaletteRaw = LocalPalette.defaultPalette.rawValue
    @Environment(\.controlActiveState) private var controlActiveState
    @StateObject private var dropRelay = CanvasDropRelay()
    @StateObject private var pinnedLocationDrag = PinnedLocationDragArea()
    @State private var renamingPanelID: UUID?
    @State private var panelNameDraft = ""
    @FocusState private var panelNameFocused: Bool
    @State private var renamingWorkspaceID: UUID?
    @State private var workspaceNameDraft = ""
    @State private var skipWorkspaceRenameCommit = false
    @State private var hoveredTabID: UUID?
    @State private var availableWidth: CGFloat = 0
    @State private var sidebarHovered = false
    @State private var toolSidebarHovered = false
    @State private var toolSidebarDragStart: Double?
    @FocusState private var workspaceNameFocused: Bool

    /// The selected connection type supplies its independently saved palette.
    private var chrome: WindowChrome {
        if let id = window.selectedTabID, model.connectionGroup(for: [id]) == .remote {
            return WindowChrome.resolve(isDark: appearanceDriver.isDark, icon: RemotePalette.palette(raw: remotePaletteRaw))
        }
        return WindowChrome.resolve(isDark: appearanceDriver.isDark, icon: LocalPalette.palette(raw: localPaletteRaw))
    }

    private var sidebarChrome: WindowChrome { chrome }


    var body: some View {
        let _ = shortcutsRevision
        GeometryReader { geometry in
            let collapsed = sidebarIsCollapsed(totalWidth: geometry.size.width)
            let shownSidebarWidth = sidebarDisplayWidth(totalWidth: geometry.size.width)
            // A stable title band keeps the native split and terminal surfaces at the same Y.
            VStack(spacing: 0) {
                workspaceTitlebar(collapsed: collapsed, sidebarWidth: shownSidebarWidth, size: geometry.size)
                NativeSidebarSplit(
                    collapsed: collapsed, width: shownSidebarWidth,
                    minimumWidth: SidebarLayout.minWidth, maximumWidth: SidebarLayout.maxWidth,
                    defaultWidth: SidebarLayout.defaultWidth,
                    onWidthChange: {
                        // A temporary narrow-window fit must not replace the user's saved width.
                        if shownSidebarWidth >= CGFloat(sidebarWidth) { sidebarWidth = Double($0) }
                    }
                ) {
                    sidebar
                        .environment(\.windowChrome, sidebarChrome)
                        .tint(chrome.accent).font(Theme.Font.body)
                        .ignoresSafeArea(edges: .top)
                        .preferredColorScheme(appearanceDriver.interfaceColorScheme)

                } detail: {
                    workspaceWithTools
                        .environment(\.windowChrome, chrome)
                        .tint(chrome.accent).font(Theme.Font.body)
                        .ignoresSafeArea(edges: .top)
                        .preferredColorScheme(appearanceDriver.interfaceColorScheme)

                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        }
        .frame(minWidth: 880, minHeight: 520)
        .background(chrome.background)
        .ignoresSafeArea(edges: .top)
        .onChange(of: appearanceRaw) { _, _ in
            appearanceDriver.reapply()
        }
        .onChange(of: window.presentation.sidebarCollapsed) { _, collapsed in
            if collapsed { window.sidebarRevealed = false }
        }
        .onChange(of: panelNameFocused) { _, focused in
            if !focused { commitPanelRename() }
        }

        .task { model.reloadHosts() }
        .onAppear {
            window.relay = dropRelay
            dropRelay.windowBox = window
            GhosttyRuntime.applySelectedThemes()
            appearanceDriver.reapply()
        }
        .onChange(of: lightThemeRaw) { _, _ in
            GhosttyRuntime.applySelectedThemes()
        }
        .onChange(of: darkThemeRaw) { _, _ in
            GhosttyRuntime.applySelectedThemes()
        }
        .onChange(of: localPaletteRaw) { _, _ in
            GhosttyRuntime.applySelectedThemes()
        }
        .onChange(of: remotePaletteRaw) { _, _ in
            GhosttyRuntime.applySelectedThemes()
        }
        .background(WindowTitleSync(title: windowTitle))
        .modifier(HostInformationPresentation(model: model, window: window))
        .familySheet(isPresented: optionalBinding($window.quickCommandConfirmation), width: SheetLayout.quickCommand, height: SheetLayout.quickCommandHeight) {
            if let confirmation = window.quickCommandConfirmation {
                QuickCommandConfirmation(confirmation: confirmation, model: model, window: window) {
                    window.quickCommandConfirmation = nil
                }.id(confirmation.id)
            }
        }
        .familySheet(isPresented: $window.commandPalettePresented, width: SheetLayout.search, height: SheetLayout.commandPaletteHeight) {
            TerminalCommandPalette(model: model, window: window) { window.commandPalettePresented = false }
                .environment(\.windowChrome, chrome)
                .tint(chrome.accent)
                .preferredColorScheme(appearanceDriver.interfaceColorScheme)
        }
        .familySheet(isPresented: $window.hostPickerPresented, width: SheetLayout.search, height: SheetLayout.sessionBodyHeight) {
            HostPicker(model: model, window: window)
                .frame(width: SheetLayout.search, height: SheetLayout.sessionBodyHeight)
                .environment(\.windowChrome, chrome)
                    .tint(chrome.accent).font(Theme.Font.body)
                .preferredColorScheme(appearanceDriver.interfaceColorScheme)
        }
        .onChange(of: window.hostPickerPresented) { _, presented in
            if !presented && !filesMode {
                if let tab = model.selectedTab(in: window) {
                    SSHTerminalRegistry.focus(tab.sessionID)
                }
            }
        }
        // Environment flows inward: include every modal anchor in the workspace
        // appearance so its separate hosting view never captures the default palette.
        .environment(\.windowChrome, chrome)
        .tint(chrome.accent).font(Theme.Font.body)
        .preferredColorScheme(appearanceDriver.interfaceColorScheme)

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
            return String(localized: "1Agent")
        }
        return selectedSessionBadge
    }

    private var selectedWorkspace: Workspace? {
        guard let id = window.selectedTabID else { return nil }
        return model.workspaces.first { $0.members.contains(id) }
    }

    private var selectedIDs: [UUID] {
        model.sidebarOrder(in: window).filter { window.sidebarSelection.contains($0) }
    }

    private func sidebarIsCollapsed(totalWidth: CGFloat) -> Bool {
        model.sidebarIsCollapsed(in: window, totalWidth: totalWidth)
    }

    private func sidebarDisplayWidth(totalWidth: CGFloat) -> CGFloat {
        guard window.sidebarRevealed, filesMode else { return CGFloat(sidebarWidth) }
        let room = totalWidth - WorkspaceChromeLayout.minimumFilesWidth * 2 - WorkspaceChromeLayout.dividerWidth
        return min(CGFloat(sidebarWidth), max(SidebarLayout.minWidth, room))
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                navigationRow("Terminal", symbol: "terminal", active: !filesMode) { model.hideFiles(in: window) }
                    .accessibilityIdentifier("workspace.terminal")
                    .help(String(localized: "Switch Terminals and Files") + " (" + AppShortcuts.display(for: .openFileBrowser) + ")")
                navigationRow("Files", symbol: "folder", active: filesMode) {
                    model.selectFilesLayout(.sideBySide, in: window)
                }
                .background(BoundsAnchor { dropRelay.filesButtonAnchor = $0 })
                .accessibilityIdentifier("workspace.files")
                .help(String(localized: "Switch Terminals and Files") + " (" + AppShortcuts.display(for: .openFileBrowser) + ")")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
            Divider().padding(.horizontal, 16)

            if filesMode {
                FilesSidebar(model: model, window: window, workspace: model.fileWorkspace(for: window), dragArea: pinnedLocationDrag)
            } else {
                HStack(spacing: 6) {
                    Text("Opened").font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(sidebarChrome.secondary)
                .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 10)
                sidebarList
                if selectedPanelCount > 1 { selectionActions }
            }
        }
        .background(BoundsAnchor {
            dropRelay.sidebarAnchor = filesMode ? nil : $0
            pinnedLocationDrag.sidebar = filesMode ? $0 : nil
        })
        .background(chrome.panelHeader)
        .onChange(of: filesMode) { _, _ in
            commitPanelRename()
            clearSidebarDrag()
        }
        .background(SidebarHoverTracking { sidebarHovered = $0 })
        .onDisappear {
            dropRelay.sidebarAnchor = nil
            pinnedLocationDrag.sidebar = nil
            sidebarHovered = false
        }
    }

    private var selectedPanelCount: Int {
        model.panelRows(in: window).filter { !Set($0.leafIDs).isDisjoint(with: window.sidebarSelection) }.count
    }

    private func clearSidebarDrag() {
        dropRelay.rowAnchors.removeAll()
        dropRelay.blockAnchors.removeAll()
        model.endDrag(in: window)
        dropRelay.hidePreview()
    }

    private func navigationRow(_ title: LocalizedStringKey, symbol: String, active: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16)).frame(width: 20)
                Text(title).font(.system(size: 14, weight: active ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(active ? sidebarChrome.accent : sidebarChrome.text)
            .padding(.horizontal, 12).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(active ? sidebarChrome.accentFill : Color.clear))
            .contentShape(Rectangle())
        }.buttonStyle(FamilyButtonStyle()).accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private var sidebarList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 4) {
                    let rows = model.panelRows(in: window)
                    let blocks = model.sidebarBlocks(in: window)
                    if rows.isEmpty {
                        Text("No open terminals")
                            .font(Theme.Font.rowMeta).foregroundStyle(sidebarChrome.secondary).padding(16)
                    }
                    ForEach(SidebarConnectionGroup.allCases, id: \.self) { group in
                        let groupRows = rows.filter { model.connectionGroup(for: $0.block) == group }
                        if !groupRows.isEmpty {
                            VStack(spacing: 3) {
                                connectionGroupHeader(group, count: groupRows.count)
                                if !window.presentation.collapsedConnectionGroups.contains(group) {
                                    ForEach(blocks.filter { block in groupRows.contains { $0.block == block } }, id: \.self) { block in
                                        sidebarBlock(block, rows: groupRows.filter { $0.block == block })
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
            }
            .onChange(of: window.selectedTabID) { _, id in
                if let id, let row = model.panelRow(for: id, in: window) {
                    DispatchQueue.main.async { proxy.scrollTo(row.isSplit ? id : row.panelID) }
                }
            }
        }
    }

    private func sidebarBlock(_ block: SidebarBlock, rows: [TerminalPanelRow]) -> some View {
        let workspace: Workspace? = { if case .workspace(let id) = block { return model.workspace(for: id) }; return nil }()
        let dragging = window.draggingTabID != nil || window.draggingBlock != nil
        return VStack(spacing: 3) {
            if let workspace, workspace.isGrouped { workspaceHeader(workspace) }
            if workspace?.isGrouped != true || dragging ||
                !window.presentation.collapsedWorkspaces.contains(workspace!.id) {
                ForEach(rows) { row in
                    panelRow(row).id(row.panelID)
                    if row.isSplit {
                        ForEach(row.leafIDs, id: \.self) { id in
                            if let tab = model.tabs.first(where: { $0.id == id }) {
                                panelTerminalRow(tab).id(id)
                            }
                        }
                    }
                }
            }
        }
        .overlay(blockFill(block))
        .padding(.horizontal, 8)
        .background(SidebarBlockAnchor(block: block, relay: dropRelay))
    }

    private func connectionGroupHeader(_ group: SidebarConnectionGroup, count: Int) -> some View {
        let collapsed = window.presentation.collapsedConnectionGroups.contains(group)
        return HStack(spacing: 2) {
            Button {
                model.updatePresentation(in: window) { state in
                    if !state.collapsedConnectionGroups.insert(group).inserted {
                        state.collapsedConnectionGroups.remove(group)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                    if group == .mixed {
                        Image(systemName: group.symbol).font(.system(size: 12)).frame(width: 16)
                    }
                    Text(verbatim: group.title).font(.system(size: 12, weight: .semibold))
                    Text(verbatim: String(count)).font(Theme.Font.rowMeta).monospacedDigit()
                    Spacer(minLength: 0)
                }
                .frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(FamilyButtonStyle())
            .accessibilityIdentifier("sidebar.group.\(group.rawValue)")
            .accessibilityLabel(Text(String(format: String(localized: "Toggle %@ Group"), group.title)))
            .accessibilityValue(Text(collapsed ? "Collapsed" : "Expanded"))
            if group != .mixed {
                Button {
                    if group == .local { model.openLocalTerminal(in: window) }
                    else { model.openHostPicker(in: window) }
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(FamilyButtonStyle())
                .accessibilityIdentifier("sidebar.group.\(group.rawValue).add")
                .accessibilityLabel(Text(group == .local ? "New Local Terminal" : "Open Host…"))
                .help(shortcutHelp(group == .local ? .newLocalTerminal : .openHost))
            }
        }
        .foregroundStyle(sidebarChrome.secondary)
        .padding(.leading, 14).padding(.trailing, 10)
    }

    private var selectionActions: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(String(format: String(localized: "%lld Views Selected"), selectedPanelCount))
                .font(Theme.Font.rowMeta).foregroundStyle(sidebarChrome.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.s) { selectionActionButtons }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: Theme.Space.s) { selectionActionButtons }
            }
            .font(Theme.Font.rowMeta)
            .buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sidebarChrome.elevated)
    }

    @ViewBuilder private var selectionActionButtons: some View {
        Button("New Workspace") { model.createAreaFromSidebar(selectedIDs, in: window) }
            .disabled(!model.sidebarCanCreateArea(selectedIDs))
        moveSelectionMenu
        FamilyMenu("Merge Panels") { mergeSelectionItems }
    }

    private var moveSelectionMenu: some View {
        FamilyMenu("Move to Workspace") {
            model.workspaces.filter { $0.isGrouped && window.blocks.contains(.workspace($0.id)) }.map { workspace in
                FamilyMenuItem(title: workspaceTitle(workspace), action: {
                    model.joinWorkspace(selectedIDs, workspace.id, beside: nil, after: true)
                })
            }
        }
        .disabled(!model.workspaces.contains { window.blocks.contains(.workspace($0.id)) })
    }

    private var mergeSelectionItems: [FamilyMenuItem] {
        WorkspaceBoard.availableLayouts(paneCount: selectedIDs.count).map { layout in
            FamilyMenuItem(title: workspaceLayoutTitle(layout), action: {
                guard let target = window.selectedTabID.flatMap({ selectedIDs.contains($0) ? $0 : nil }) ?? selectedIDs.first else { return }
                model.mergeSidebar(selectedIDs, onto: target, as: layout, in: window)
            })
        }
    }

    private func sessionTitle(_ tab: TerminalTab) -> String {
        if let title = tab.contentTitle { return title }
        if tab.isLocal, let directory = tab.directory {
            let name = (directory as NSString).lastPathComponent
            return directory == FileManager.default.homeDirectoryForCurrentUser.path || name.isEmpty
                ? String(localized: "This Mac") : name
        }
        return tab.alias ?? String(localized: "New Tab")
    }

    private func numberedSessionTitle(_ tab: TerminalTab) -> String {
        guard let number = model.paneNumber(for: tab.id, in: window) else { return sessionTitle(tab) }
        return "\(number)-\(sessionTitle(tab))"
    }

    private var filesMode: Bool { window.presentation.fullFilesWorkspace }

    private var workspaceSurface: some View {
        WorkspaceContentSplit(presentation: window.presentation, onRatioChange: { _ in }) {
            detail
        } files: {
            FilesDockView(model: model, window: window, relay: dropRelay)
        }
        .background(chrome.background)
    }

    private var workspaceWithTools: some View {
        GeometryReader { geometry in
            let width = ToolSidebarLayout.visibleWidth(detailWidth: geometry.size.width,
                open: window.presentation.toolSidebarOpen, filesMode: filesMode, preferred: window.presentation.toolSidebarWidth)
            ZStack(alignment: .topLeading) {
                workspaceSurface.frame(width: max(0, geometry.size.width - (width > 0 ? width + 1 : 0)))
                if width > 0 {
                    QuickCommandSidebar(model: model, window: window)
                        .frame(width: width, height: geometry.size.height)
                        .background(SidebarHoverTracking { toolSidebarHovered = $0 })
                        .offset(x: geometry.size.width - width)
                        .onDisappear { toolSidebarHovered = false }
                    Rectangle().fill(chrome.hairline).frame(width: 1, height: geometry.size.height)
                        .overlay {
                            Color.clear.frame(width: 7).contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                                    if toolSidebarDragStart == nil { toolSidebarDragStart = Double(width) }
                                    let next = ToolSidebarLayout.storedWidth((toolSidebarDragStart ?? Double(width)) - value.translation.width)
                                    model.updatePresentation(in: window) { $0.toolSidebarWidth = next }
                                }.onEnded { _ in toolSidebarDragStart = nil })
                        }
                        .offset(x: geometry.size.width - width - 1)
                        .accessibilityLabel(Text("Resize Tool Sidebar"))
                }
            }
        }
    }

    private func workspaceTitlebar(collapsed: Bool, sidebarWidth: CGFloat, size: CGSize) -> some View {
        let inset = collapsed ? 0 : sidebarWidth + 1
        let toolWidth = ToolSidebarLayout.visibleWidth(detailWidth: size.width - inset,
            open: window.presentation.toolSidebarOpen, filesMode: filesMode, preferred: window.presentation.toolSidebarWidth)
        let detailWidth = max(1, size.width - inset - (toolWidth > 0 ? toolWidth + 1 : 0))
        let terminalHeight = size.height - Theme.PaneStyle.titlebarHeight
        let frames = TerminalCanvas.paneFrames(model.displayRoot(in: window), zoomed: model.zoomedPane(in: window),
            in: CGRect(x: 0, y: 0, width: detailWidth, height: terminalHeight))
        let topTabs = model.tabs.filter { frames[$0.id].map { $0.minY < 1 } == true }
        return ZStack(alignment: .topLeading) {
            chrome.panelHeader
            if filesMode || topTabs.isEmpty {
                Text(filesMode ? "Files" : "Terminal")
                    .font(Theme.Font.paneTitle).foregroundStyle(chrome.secondary)
                    .padding(.horizontal, 8)
                    .frame(width: detailWidth, height: Theme.PaneStyle.titlebarHeight, alignment: .leading)
                    .accessibilityIdentifier("workspace.titleMenu")
                    .offset(x: inset)
            } else {
                ForEach(topTabs) { tab in
                    if let frame = frames[tab.id] {
                        let trailingInset: CGFloat = toolWidth == 0 && frame.maxX >= detailWidth - 1
                            ? Theme.PaneStyle.titlebarAccessoryInset : 0
                        let leadingInset: CGFloat = collapsed && frame.minX < 1 ? SidebarLayout.trafficLightInset + 56 : 0
                        paneTitleMenu(tab)
                            .padding(.leading, leadingInset)
                            .padding(.trailing, trailingInset)
                            .frame(width: frame.width, height: Theme.PaneStyle.titlebarHeight)
                            .overlay(alignment: .bottom) {
                                PaneProgressBar(sessionID: tab.sessionID).allowsHitTesting(false)
                            }
                            .offset(x: inset + frame.minX)
                    }
                }
            }
            HoverRevealingRegion { hovering in
                HStack(spacing: 0) {
                    WindowDragArea().frame(maxWidth: .infinity, maxHeight: .infinity)
                    sidebarHeaderActions(collapsed: collapsed, visible: hovering || (!collapsed && sidebarHovered))
                }
                .padding(.leading, SidebarLayout.trafficLightInset)
                .padding(.trailing, collapsed ? 0 : 8)
                .frame(width: collapsed ? SidebarLayout.trafficLightInset + 56 : sidebarWidth,
                       height: Theme.PaneStyle.titlebarHeight)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workspace.sidebarHeader")
            if !filesMode {
                HoverRevealingRegion { hovering in
                    HStack {
                        Spacer(minLength: 0)
                        Button { model.toggleToolSidebar(in: window) } label: {
                            Image(systemName: "sidebar.right").frame(width: 28, height: 28)
                        }
                        .buttonStyle(FamilyButtonStyle()).foregroundStyle(chrome.secondary)
                        .help(shortcutHelp(.toggleToolSidebar))
                        .accessibilityLabel(Text(toolWidth > 0 ? "Hide Tool Sidebar" : "Show Tool Sidebar"))
                        .accessibilityIdentifier("workspace.toggleToolSidebar")
                        .opacity(hovering || toolSidebarHovered ? 1 : 0)
                        .allowsHitTesting(hovering || toolSidebarHovered)
                    }
                    .padding(.trailing, 8)
                    .frame(width: max(48, toolWidth), height: Theme.PaneStyle.titlebarHeight)
                }
                .offset(x: size.width - max(48, toolWidth))
            }
        }
        .frame(height: Theme.PaneStyle.titlebarHeight)
        .background(WindowDragArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.titlebar")
    }

    private func paneTitleMenu(_ tab: TerminalTab) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: numberedSessionTitle(tab))
                .foregroundStyle(chrome.secondary)
                .lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            RemoteTitleStatus(tab: tab)
        }
            .font(Theme.Font.paneTitle)
            .padding(.horizontal, 8)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: 520, maxHeight: .infinity)
            .allowsHitTesting(false)
            .overlay {
                // Use the same native event tracking as lower split headers: it owns
                // the press before AppKit can turn a titlebar drag into a window drag.
                TabDragHandle(
                    onClick: { _, _ in },
                    onActivate: { TerminalPaneActions.showTitleContext(model: model, window: window, tabID: tab.id, anchor: $0) },
                    onBegan: { dropRelay.dragBegan(tab.id, fromPane: true) },
                    onMoved: { dropRelay.dragMoved(windowPoint: $0) },
                    onEnded: { dropRelay.dragEnded(windowPoint: $0) },
                    freezesWindow: true
                )
            }
            .help("Click the title for session details. Drag it to move the pane.")
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { TerminalPaneActions.showTitleContext(model: model, window: window, tabID: tab.id) }
            .accessibilityLabel(Text(verbatim: numberedSessionTitle(tab)))
            .accessibilityIdentifier("workspace.titleMenu." + tab.id.uuidString)
    }

    private func shortcutHelp(_ id: AppShortcutID) -> String {
        let key = AppShortcuts.display(for: id)
        return key.isEmpty ? id.title : id.title + " (" + key + ")"
    }

    private func sidebarHeaderActions(collapsed: Bool, visible: Bool) -> some View {
        HStack(spacing: 0) {
            Button { model.openLocalTerminal(in: window) } label: {
                Image(systemName: "plus").frame(width: 28, height: 28)
            }
            .help(shortcutHelp(.newLocalTerminal))
            .accessibilityLabel(Text("New Local Terminal"))
            .accessibilityIdentifier("workspace.newLocalTerminal")
            Button { model.toggleSidebar(in: window) } label: {
                Image(systemName: "sidebar.left").frame(width: 28, height: 28)
            }
            .help(shortcutHelp(.toggleSidebar))
            .accessibilityLabel(Text(collapsed ? "Show Session Sidebar" : "Hide Session Sidebar"))
            .accessibilityIdentifier(collapsed ? "workspace.revealSidebar" : "workspace.hideSidebar")
        }
        .font(Theme.Font.body).buttonStyle(FamilyButtonStyle())
        .foregroundStyle(sidebarChrome.secondary)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
    }

    private func selectSession(_ id: UUID, command: Bool, shift: Bool) {
        model.clickSidebar(id, command: command, shift: shift, in: window)
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

    private func panelDisplayTitle(_ row: TerminalPanelRow) -> String {
        if let title = window.panelTitles[row.panelID] { return title }
        if row.isSplit { return String(localized: "Terminal Group") }
        return model.tabs.first { $0.id == row.focusedTabID }.map(sessionTitle) ?? row.name
    }

    private func renamePanel(_ row: TerminalPanelRow) {
        commitPanelRename()
        panelNameDraft = window.panelTitles[row.panelID] ?? ""
        renamingPanelID = row.panelID
        panelNameFocused = true
    }

    private func commitPanelRename() {
        guard let id = renamingPanelID else { return }
        renamingPanelID = nil
        panelNameFocused = false
        model.renamePanel(id, to: panelNameDraft, in: window)
    }

    @ViewBuilder private func panelRow(_ row: TerminalPanelRow) -> some View {
        if let tab = model.tabs.first(where: { $0.id == row.focusedTabID }) {
            let selected = window.sidebarSelection.isEmpty
                ? window.selectedTabID.map { row.leafIDs.contains($0) } ?? false
                : !Set(row.leafIDs).isDisjoint(with: window.sidebarSelection)
            let labeledSubtitle = model.sessionSubtitle(tab)
            HStack(spacing: 9) {
                TerminalPanelIcon(layout: model.workspaces.compactMap { $0.panel(containing: row.focusedTabID) }.first?.layout ?? .leaf(row.focusedTabID))
                    .font(.system(size: 15)).frame(width: 20)
                    .foregroundStyle(selected ? sidebarChrome.accent : sidebarChrome.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    if renamingPanelID == row.panelID {
                        TextField("Rename", text: $panelNameDraft, prompt: Text(verbatim: sessionTitle(tab)))
                            .textFieldStyle(.plain)
                            .focused($panelNameFocused).onSubmit { commitPanelRename() }
                            .onExitCommand {
                                renamingPanelID = nil
                                panelNameFocused = false
                            }
                            .onAppear { panelNameFocused = true }
                    } else {
                        Text(verbatim: panelDisplayTitle(row)).font(.system(size: 14, weight: selected ? .semibold : .regular))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if !row.isSplit {
                        SidebarSessionSubtitle(tab: tab, location: labeledSubtitle).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(sidebarChrome.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if row.isSplit {
                    Text(verbatim: String(row.leafIDs.count)).font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(sidebarChrome.hairline))
                }
                SidebarBellMark(sessionID: tab.sessionID)
                if tab.reconnecting || tab.showsDisconnected {
                    Image(systemName: tab.reconnecting ? "arrow.triangle.2.circlepath" : "link.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(tab.reconnecting ? sidebarChrome.warning : sidebarChrome.danger)
                }
            }
            .foregroundStyle(selected ? sidebarChrome.accent : sidebarChrome.text)
            .padding(.leading, 11).padding(.trailing, 30).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(rowFill(selected: selected,
                hovered: hoveredTabID == row.panelID, tabID: row.focusedTabID)))
            .background(PanelRowAnchor(ids: row.leafIDs, relay: dropRelay))
            .overlay {
                TabDragHandle(
                    onClick: { command, shift in selectSession(row.focusedTabID, command: command, shift: shift) },
                    onHover: { hoveredTabID = $0 ? row.panelID : nil },
                    onBegan: { dropRelay.dragBegan(row.focusedTabID) },
                    onMoved: { dropRelay.dragMoved(windowPoint: $0) },
                    onEnded: { dropRelay.dragEnded(windowPoint: $0) },
                    onSecondaryClick: {
                        SidebarActions.show(SidebarActions.panelItems(row, model: model, window: window,
                            onRename: { renamePanel(row) }), in: window)
                    },
                    dragEnabled: renamingPanelID == nil
                ).accessibilityHidden(true).allowsHitTesting(renamingPanelID != row.panelID)
            }
            .overlay(alignment: .trailing) {
                Button { renamePanel(row) } label: { Image(systemName: "pencil").frame(width: 20, height: 26) }
                    .buttonStyle(FamilyButtonStyle()).foregroundStyle(selected ? sidebarChrome.accent : sidebarChrome.secondary)
                    .help("Rename").accessibilityLabel(Text("Rename"))
                    .padding(.trailing, 5)
                    .opacity(selected || hoveredTabID == row.panelID ? 1 : 0)
                    .allowsHitTesting(selected || hoveredTabID == row.panelID)
            }
            .help(labeledSubtitle).accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: panelDisplayTitle(row)))
            .accessibilityValue(Text(verbatim: labeledSubtitle))
            .accessibilityIdentifier("sidebar.panel.\(row.panelID.uuidString)")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction { model.selectPanel(row.panelID, in: window) }
        }
    }

    private func panelTerminalRow(_ tab: TerminalTab) -> some View {
        let isSelected = window.selectedTabID == tab.id
        let subtitle = model.sessionSubtitle(tab)
        return HStack(spacing: 9) {
            TerminalPanelIcon(layout: .leaf(tab.id))
                .font(.system(size: 15)).frame(width: 20)
                .foregroundStyle(isSelected ? sidebarChrome.accent : sidebarChrome.secondary)
                .accessibilityHidden(true)
            Text(verbatim: numberedSessionTitle(tab))
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            SidebarBellMark(sessionID: tab.sessionID)
            if tab.reconnecting || tab.showsDisconnected {
                Image(systemName: tab.reconnecting ? "arrow.triangle.2.circlepath" : "link.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(tab.reconnecting ? sidebarChrome.warning : sidebarChrome.danger)
            }
        }
        .foregroundStyle(isSelected ? sidebarChrome.accent : sidebarChrome.text)
        .padding(.leading, 29).padding(.trailing, 10)
        .frame(height: Theme.Control.height)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
            .fill(isSelected ? sidebarChrome.accentFill : .clear))
        .overlay {
            TabDragHandle(
                onClick: { _, _ in model.selectOnly(tab.id, in: window) },
                onBegan: {},
                onMoved: { _ in },
                onEnded: { _ in },
                onSecondaryClick: { TerminalPaneActions.showContext(tab: tab, model: model, window: window) },
                dragEnabled: false
            ).accessibilityHidden(true)
        }
        .help(subtitle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: numberedSessionTitle(tab)))
        .accessibilityValue(Text(verbatim: subtitle))
        .accessibilityIdentifier("sidebar.terminal." + tab.id.uuidString)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { model.selectOnly(tab.id, in: window) }
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

    private func beginWorkspaceRename(_ workspace: Workspace) {
        if WorkspaceChromeLayout.temporarilyCollapseSidebar(totalWidth: availableWidth,
            sidebarWidth: CGFloat(sidebarWidth), filesVisible: window.presentation.filesVisible,
            filesWorkspace: true) {
            model.hideFiles(in: window)
        }
        model.updatePresentation(in: window) { $0.sidebarCollapsed = false }
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

    private func workspaceHeader(_ workspace: Workspace) -> some View {
        VStack(spacing: 0) {
        HStack(spacing: Theme.Space.xs) {
            Button {
                model.updatePresentation(in: window) { state in
                    if state.collapsedWorkspaces.contains(workspace.id) {
                        state.collapsedWorkspaces.remove(workspace.id)
                    } else { state.collapsedWorkspaces.insert(workspace.id) }
                }
            } label: {
                Image(systemName: window.presentation.collapsedWorkspaces.contains(workspace.id)
                      ? "chevron.right" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 20, height: SidebarLayout.rowHeight)
            }
            .buttonStyle(FamilyButtonStyle())
            .accessibilityLabel(Text(String(format: String(localized: "Toggle Workspace %@"), workspaceTitle(workspace))))

            if renamingWorkspaceID == workspace.id {
                TextField("Workspace name", text: $workspaceNameDraft)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.sidebarSection)
                    .focused($workspaceNameFocused)
                    .onAppear { workspaceNameFocused = true }
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
                        } else if skipWorkspaceRenameCommit { skipWorkspaceRenameCommit = false }
                        else { commitWorkspaceRename() }
                    }
            } else {
                HStack(spacing: Theme.Space.xs) {
                    Text(workspaceTitle(workspace)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(verbatim: String(workspace.panels.count))
                        .font(Theme.Font.rowMeta)
                        .foregroundStyle(sidebarChrome.secondary)
                }
                .font(Theme.Font.sidebarSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    BlockDragHandle(
                        onBegan: { dropRelay.blockDragBegan(.workspace(workspace.id)) },
                        onMoved: { dropRelay.blockDragMoved(windowPoint: $0) },
                        onEnded: { dropRelay.blockDragEnded(windowPoint: $0) },
                        onSecondaryClick: {
                            SidebarActions.show(workspaceContextItems(workspace), in: window)
                        }
                    )
                    .accessibilityHidden(true)
                }
            }
            FamilyMenu(items: { workspaceContextItems(workspace) }) {
                Image(systemName: "folder.badge.gearshape").frame(width: 20, height: SidebarLayout.rowHeight)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text(String(format: String(localized: "Actions for %@"), workspaceTitle(workspace))))
        }
        .foregroundStyle(sidebarChrome.text)
        .padding(.horizontal, Theme.Space.s)
        .frame(height: SidebarLayout.rowHeight)
        }
    }

    private func workspaceContextItems(_ workspace: Workspace) -> [FamilyMenuItem] {
        SidebarActions.workspaceItems(workspace, model: model, window: window,
            onRename: { beginWorkspaceRename(workspace) })
    }

    private func rowFill(selected: Bool, hovered: Bool, tabID: UUID) -> Color {
        if window.dropHighlight == .sidebarRow(tabID) || window.dropHighlight == .sidebar {
            return sidebarChrome.accent.opacity(0.28)
        }
        if selected {
            return sidebarChrome.accentFill
        }
        if hovered {
            return sidebarChrome.hairline
        }
        return Color.clear
    }

    /// Whole-block outline while a block or a multi-selection is about to merge into it.
    /// Laid over the block; never takes the mouse.
    private func blockFill(_ block: SidebarBlock) -> some View {
        let active = window.dropHighlight == .block(block)
        return RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(sidebarChrome.accent.opacity(active ? 0.14 : 0))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(sidebarChrome.accent.opacity(active ? 0.9 : 0), lineWidth: 2)
            )
            .allowsHitTesting(false)
    }

    private var detail: some View {
        ZStack {
            TerminalCanvas(
                model: model,
                window: window,
                dropRelay: dropRelay,
                dark: appearanceDriver.terminalIsDark
            )
            if model.selectedTab(in: window) == nil {
                Text("Terminal").font(Theme.Font.emptyTitle).foregroundStyle(chrome.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Every leaf maps to the same row rectangle, while drag targets use whole-panel membership.
private struct PanelRowAnchor: NSViewRepresentable {
    var ids: [UUID]
    var relay: CanvasDropRelay
    func makeNSView(context: Context) -> BoundsAnchorView { BoundsAnchorView() }
    func updateNSView(_ view: BoundsAnchorView, context: Context) {
        for id in ids { relay.rowAnchors[id] = AnchorBox(view) }
    }
}

/// File navigation owns its host and browsing position independently of the terminal selection.
private struct FilesSidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @ObservedObject var workspace: FileWorkspace
    var dragArea: PinnedLocationDragArea
    @Environment(\.windowChrome) private var chrome

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Opened").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Button { model.openHostPicker(in: window, purpose: .files) } label: {
                    Image(systemName: "plus").frame(width: 22, height: 24)
                }
                .help(String(localized: "Open Host…") + " (" + AppShortcuts.display(for: .openHost) + ")")
                .accessibilityLabel(Text("Open Host…"))
                .accessibilityIdentifier("files.openedTabs.add")
            }
            .buttonStyle(FamilyButtonStyle()).foregroundStyle(chrome.secondary)
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 6)
            openedTabs.layoutPriority(1)
            Divider().padding(.horizontal, 16)
            PinnedLocationsSidebar(workspace: workspace, dragArea: dragArea) { model.focusFiles(in: window) }
        }
        .onDisappear { workspace.tabDrag.strips.removeAll() }
    }

    /// Every remote pane's tabs as a vertical list. Each list is its pane's drag strip.
    private var openedTabs: some View {
        let remoteGroups = workspace.groupIDs.filter { $0 != workspace.localGroupID && workspace.groups[$0]?.tabs.isEmpty == false }
        return VStack(spacing: 4) {
            if remoteGroups.isEmpty {
                Text("Choose a server")
                    .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11).padding(.vertical, 8)
            }
            ForEach(remoteGroups, id: \.self) { groupID in
                if remoteGroups.first != groupID {
                    Divider().padding(.horizontal, 10)
                }
                VStack(spacing: 4) {
                    ForEach(workspace.groups[groupID]?.tabs ?? []) { column in
                        FileTabButton(workspace: workspace, column: column, groupID: groupID, tabDrag: workspace.tabDrag)
                    }
                }
                .background(BoundsAnchor { workspace.tabDrag.strips[groupID] = AnchorBox($0) })
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files.openedTabs")
    }
}

/// Sidebar geometry. The user drags the divider between `minWidth` and `maxWidth`.
enum SidebarLayout {
    static let defaultWidth: CGFloat = 236
    static let minWidth: CGFloat = 200
    static let maxWidth: CGFloat = 420
    /// Top strip that holds the window controls and the new-tab button. As tall as the system
    /// title bar, so its content lines up with the traffic lights.
    static let headerHeight: CGFloat = Theme.PaneStyle.titlebarHeight
    /// Space between the header and the list. A list scroll view flush with the title bar
    /// edge takes over clicks on the header buttons.
    static let headerBottomGap: CGFloat = 12
    static let rowHeight: CGFloat = 36
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
    /// Only drawn on hover or while highlighted, so the button itself shows the surface behind it.
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
                // The frame keeps the hit here; without any layer AppKit turns the click into a drag.
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(hovering || highlighted ? hoverFill : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(FamilyButtonStyle())
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
                        .buttonStyle(FamilyButtonStyle(kind: .secondary))
                    Text(localTerminalShortcut)
                        .font(Theme.Font.rowMeta)
                        .foregroundStyle(chrome.tertiary)
                }
                VStack(spacing: Theme.Space.xs) {
                    Button("Open Host…", action: onOpenHost)
                        .buttonStyle(FamilyButtonStyle(kind: .primary))
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

/// Geometry of the file pane, after 1Panel's SFTP page.
enum FileBrowserLayout {
    static let compactHeaderThreshold: CGFloat = 440
    static let titleBarHeight: CGFloat = 40
    static let toolbarHeight: CGFloat = 36
    static let navigationHeight: CGFloat = 40
    static let headerHeight: CGFloat = 36
    static let rowHeight: CGFloat = 40
    static let filterWidth: CGFloat = 132
    /// Match 1Panel's bounded grid, leaving spare width after the type column.
    static let nameMinWidth: CGFloat = 120
    static let nameMaxWidth: CGFloat = 240
    static let modifiedMinWidth: CGFloat = 108
    static let modifiedWidth: CGFloat = 148
    static let sizeWidth: CGFloat = 64
    static let kindWidth: CGFloat = 56
    struct TableColumns {
        var name: CGFloat
        var modified: CGFloat?
        var size: Bool
        var kind: Bool
    }
    static func tableColumns(in width: CGFloat) -> TableColumns {
        let gap = Theme.Space.s
        let available = max(0, width - Theme.Space.m * 2 - gap)
        let size = available >= nameMinWidth + sizeWidth + gap
        let modified = size && available >= nameMinWidth + sizeWidth + modifiedMinWidth + 2 * gap
        let kind = modified && available >= nameMinWidth + sizeWidth + modifiedMinWidth + kindWidth + 3 * gap
        let reserved = (size ? sizeWidth + gap : 0) + (kind ? kindWidth + gap : 0)
        if modified {
            let room = available - reserved - gap
            let growth = max(0, room - nameMinWidth - modifiedMinWidth)
            let date = modifiedMinWidth + min(modifiedWidth - modifiedMinWidth, growth / 4)
            return TableColumns(name: min(nameMaxWidth, room - date), modified: date, size: size, kind: kind)
        }
        return TableColumns(name: min(nameMaxWidth, max(0, available - reserved)), size: size, kind: kind)
    }
    static let iconSize: CGFloat = 18
    static let toolbarButtonSize: CGFloat = 28
    /// Includes the gaps on both sides, so the entire inter-folder area edits the path.
    static let pathSeparatorWidth: CGFloat = 20
    static let folderColor = Color(red: 0x4C / 255, green: 0x8D / 255, blue: 0xFF / 255)
    /// A full-height overlay follows the source pane's physical side, including moved tabs.
    static let previewMinimumWidth: CGFloat = 360
    static let previewWidthShare: CGFloat = 0.5
    static let previewScrimOpacity: Double = 0.28
    static let transferBarHeight: CGFloat = 24
    static func previewFrame(in bounds: CGRect, source: CGRect) -> CGRect {
        let width = min(bounds.width, max(previewMinimumWidth, bounds.width * previewWidthShare))
        let x = source.midX <= bounds.midX ? bounds.minX : bounds.maxX - width
        return CGRect(x: x, y: bounds.minY, width: width, height: bounds.height)
    }
    static let transferRowHeight: CGFloat = 48
    static let transferListMaxHeight: CGFloat = 144
    static let previewByteLimit = 512 * 1024
    /// Progress toast at the bottom center of the window.
    static let toastWidth: CGFloat = 360
    static let toastHeight: CGFloat = 40
    /// From the window top; clears the tab strip.
    static let toastTopInset: CGFloat = 44
    static let toastLingerSeconds: Double = 2.5
    /// Tab strip above each side of the Files area, as in Xftp.
    static let tabStripHeight: CGFloat = 40
    static let tabMinWidth: CGFloat = 56
    static let tabMaxWidth: CGFloat = 180
    /// Share of a pane's width and height kept from each edge: dropping a tab inside joins the pane.
    static let joinZoneInset: CGFloat = 0.3
}

/// Geometry of the ⌃⇥ terminal switcher. Cards grow or shrink with the number of terminals.
enum SwitcherLayout {
    /// Gap between the switcher panel and the main window's edges.
    static let windowInset: CGFloat = 24
    /// Dimming over the whole window, light enough to see the item previewed behind it.
    static let maskOpacity: CGFloat = 0.35
    /// Corner radius of a titled window without a toolbar, so the dimming does not poke past its corners.
    static let windowCornerRadius: CGFloat = 16
    /// Padding inside the panel around the grid and the hint line.
    static let panelPadding: CGFloat = 20
    static let panelCornerRadius: CGFloat = 14
    static let spacing: CGFloat = 14
    static let cardPadding: CGFloat = 6
    static let cardCornerRadius: CGFloat = 10
    static let thumbnailCornerRadius: CGFloat = 6
    static let titleHeight: CGFloat = 36
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
        let widest = min(320, area.width * maxCardWidthShare)
        var best = Grid(columns: 1, cardWidth: 0, scrolls: false)
        for columns in 1 ... count {
            let rows = (count + columns - 1) / columns
            let byWidth = (area.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let rowHeight = (area.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            let byHeight = (rowHeight - chrome) * thumbnailAspect + 2 * cardPadding
            let width = min(byWidth, byHeight, widest)
            if width >= best.cardWidth {
                best = Grid(columns: columns, cardWidth: width, scrolls: false)
            }
        }
        if best.cardWidth >= minCardWidth {
            return best
        }
        let fitting = Int((area.width + spacing) / (minCardWidth + spacing))
        return Grid(columns: max(1, min(fitting, count)), cardWidth: min(minCardWidth, max(1, area.width)), scrolls: true)
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(chrome.warning)
                .frame(width: 14, height: 14)
                .accessibilityLabel(Text("Bell Rang"))
        }
    }
}

/// The session's location, or a remote command that has been running for a moment.
struct SidebarSessionSubtitle: View {
    @ObservedObject private var status = RemoteShellStatus.shared
    var tab: TerminalTab
    var location: String

    var body: some View {
        if let command = status.runningCommand(of: tab) {
            Text(verbatim: String(format: String(localized: "Running · %@"), command))
        } else {
            Text(verbatim: location)
        }
    }
}

/// Keep hover updates inside their hosting subtree, rather than rebuilding both split hosts.
private struct HoverRevealingRegion<Content: View>: View {
    @State private var hovering = false
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        content(hovering)
            .background(SidebarHoverTracking { hovering = $0 })
            .onDisappear { hovering = false }
    }
}

/// Track the whole native hosting region without covering its interactive children.
private struct SidebarHoverTracking: NSViewRepresentable {
    var changed: (Bool) -> Void
    func makeNSView(context: Context) -> SidebarHoverTrackingView { SidebarHoverTrackingView() }
    func updateNSView(_ view: SidebarHoverTrackingView, context: Context) { view.changed = changed }
    static func dismantleNSView(_ view: SidebarHoverTrackingView, coordinator: ()) { view.stopTracking() }
}

private final class SidebarHoverTrackingView: NSView {
    var changed: (Bool) -> Void = { _ in }
    private var hovered = false
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopTracking()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged]) { [weak self] event in
            if let self, event.window === self.window {
                self.updateHover(at: event.locationInWindow)
            }
            return event
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            self.updateHover(at: window.mouseLocationOutsideOfEventStream)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { updateHover(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func updateHover(at windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        setHovered(!isHiddenOrHasHiddenAncestor && visibleRect.contains(point))
    }

    private func setHovered(_ value: Bool) {
        guard value != hovered else { return }
        hovered = value
        changed(value)
    }

    func stopTracking() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
