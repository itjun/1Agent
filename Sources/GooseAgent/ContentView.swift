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
    @StateObject private var dropRelay = CanvasDropRelay()
    @State private var renamingWorkspaceID: UUID?
    @State private var workspaceNameDraft = ""
    @State private var skipWorkspaceRenameCommit = false
    @FocusState private var workspaceNameFocused: Bool
    @State private var renamingWindow = false
    @State private var windowNameDraft = ""
    @FocusState private var windowNameFocused: Bool

    private var chrome: WindowChrome {
        WindowChrome.resolve(isDark: appearanceDriver.isDark)
    }

    /// Selection and focus take the accent only in the key window; other windows go neutral, so
    /// one glance tells which window keystrokes will reach.
    private var activeAccent: Color {
        window.isKey ? chrome.accent : chrome.secondary
    }

    var body: some View {
        let _ = shortcutsRevision
        HStack(spacing: 0) {
            sidebar
                .frame(width: 248)
            Rectangle().fill(chrome.hairline).frame(width: 1)
            detail
        }
        .frame(minWidth: 880, minHeight: 520)
        .background(chrome.background)
        .environment(\.windowChrome, chrome)
        .environment(\.isKeyWindow, window.isKey)
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
        }
        .onChange(of: lightThemeRaw) { _, _ in
            GhosttyRuntime.applySelectedThemes()
        }
        .onChange(of: darkThemeRaw) { _, _ in
            GhosttyRuntime.applySelectedThemes()
        }
        .background(WindowTitleSync(title: windowTitle))
        .sheet(isPresented: $window.hostPickerPresented) {
            HostPicker(model: model, window: window)
                .frame(width: SheetLayout.search, height: SheetLayout.sessionBodyHeight)
                .environment(\.windowChrome, chrome)
                .preferredColorScheme(appearanceDriver.interfaceColorScheme)
                .oneagentHideFocusRing()
        }
    }

    private var newTabHelp: String {
        String(format: String(localized: "New Tab (%@)"), AppShortcuts.display(for: .newTab))
    }

    /// "Window 2 · root@host". Shown in the title bar, Mission Control, and the Window menu.
    private var windowTitle: String {
        let name = model.windowTitle(window)
        if selectedSessionBadge.isEmpty {
            return name
        }
        return "\(name) · \(selectedSessionBadge)"
    }

    /// The window's own name in the sidebar top bar, right of the traffic lights. A 6pt accent dot
    /// marks the key window. Double-click to rename.
    private var windowNameLabel: some View {
        HStack(spacing: 6) {
            if renamingWindow {
                TextField("Window name", text: $windowNameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(chrome.text)
                    .focused($windowNameFocused)
                    .onAppear { windowNameFocused = true }
                    .onSubmit { commitWindowRename() }
                    .onExitCommand {
                        renamingWindow = false
                    }
                    .onChange(of: windowNameFocused) { _, focused in
                        if !focused, renamingWindow {
                            commitWindowRename()
                        }
                    }
            } else {
                if window.isKey {
                    Circle()
                        .fill(chrome.accent)
                        .frame(width: 6, height: 6)
                }
                Text(model.windowTitle(window))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(window.isKey ? chrome.text : chrome.secondary)
                    .lineLimit(1)
                if model.windows.count > 1 {
                    let position = (model.windows.firstIndex(where: { $0.id == window.id }) ?? 0) + 1
                    Text(verbatim: "\(position) / \(model.windows.count)")
                        .font(Theme.sidebarRowMeta)
                        .foregroundStyle(chrome.secondary)
                        .fixedSize()
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        // Opaque fill so AppKit does not treat the double-click as window-drag or zoom.
        .background(chrome.background)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            windowNameDraft = model.windowTitle(window)
            renamingWindow = true
        }
        .help(String(localized: "Double-click to rename this window."))
    }

    private func commitWindowRename() {
        guard renamingWindow else { return }
        model.renameWindow(window, to: windowNameDraft)
        renamingWindow = false
    }

    private var windowControls: some View {
        Button(action: { model.newTab(in: window) }) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                // Opaque fill so AppKit does not treat the hit as window-drag.
                .background(chrome.background)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(newTabHelp)
        .accessibilityLabel(Text("New Tab"))
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                windowNameLabel
                Spacer(minLength: 0)
                windowControls
            }
            .padding(.leading, 74)
            .padding(.trailing, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if model.sidebarOrder(in: window).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No open terminals")
                        .font(Theme.sidebarRowTitle)
                        .foregroundStyle(chrome.text)
                    Text(String(format: String(localized: "Press %@ to open a terminal."), AppShortcuts.display(for: .newTab)))
                        .font(Theme.sidebarRowMeta)
                        .foregroundStyle(chrome.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        // Loose groups stay visible while anything is being dragged, so there is
                        // always a place to drop a terminal that leaves its workspace.
                        let dragging = model.windows.contains { $0.draggingTabID != nil || $0.draggingBlock != nil }
                        ForEach(window.blocks, id: \.self) { block in
                            switch block {
                            case .workspace(let id):
                                if let workspace = model.workspace(for: id) {
                                    VStack(spacing: 2) {
                                        workspaceHeader(workspace)
                                        ForEach(model.tabs(in: workspace)) { tab in
                                            tabRow(tab, compact: false, indent: 12)
                                        }
                                    }
                                    .background(blockFill(block))
                                    .background(SidebarBlockAnchor(block: block, relay: dropRelay))
                                }
                            case .localGroup, .ungrouped:
                                let members = model.looseTabs(in: block, window: window)
                                if !members.isEmpty || dragging {
                                    VStack(spacing: 2) {
                                        sidebarSectionHeader(block == .localGroup ? "Local Group" : "Ungrouped", block: block)
                                        ForEach(members) { tab in
                                            tabRow(tab, compact: false, indent: 12)
                                        }
                                        if members.isEmpty {
                                            Color.clear
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 28)
                                        }
                                    }
                                    .background(blockFill(block))
                                    .background(SidebarBlockAnchor(block: block, relay: dropRelay))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(BoundsAnchor { dropRelay.sidebarAnchor = $0 })
        .background(chrome.background)
    }

    private var selectedSessionBadge: String {
        guard let tab = model.selectedTab(in: window) else { return "" }
        if tab.isLocal, let directory = tab.directory {
            return LocalTerminal.displayPath(directory)
        }
        if let host = tab.alias.flatMap({ model.host($0) }) {
            return host.sessionBadge
        }
        return tab.alias ?? ""
    }


    private func hostTitleColor(_ tab: TerminalTab) -> Color {
        if tab.showsDisconnected || tab.reconnecting {
            return chrome.danger
        }
        return chrome.text
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
        return HStack(spacing: 6) {
            DuplicateHostDot(mark: model.duplicateHostMark(for: tab.id))
            Text(sidebarTitle(tab))
                .font(Theme.sidebarRowTitle)
                .foregroundStyle(hostTitleColor(tab))
                .lineLimit(1)
                .truncationMode(tab.isLocal ? .head : .tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsReconnecting {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(chrome.danger)
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
        .padding(.leading, 16 + indent)
        .padding(.trailing, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Rectangle().fill(rowFill(selected: selected, tabID: tab.id)))
        .background(RowAnchor(id: tab.id, relay: dropRelay))
        .overlay {
            TabDragHandle(
                onClick: { command, shift in
                    model.clickSidebar(tab.id, command: command, shift: shift, in: window)
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
                        openInNewWindow: { model.openInNewWindow(targets) },
                        close: { model.closeTabs(targets) },
                        copyInfo: { copySessionInfo(tab, model: model) }
                    )
                }
            )
        }
    }

    private func sidebarTitle(_ tab: TerminalTab) -> String {
        if tab.isLocal, let directory = tab.directory {
            return LocalTerminal.displayPath(directory)
        }
        return tab.alias ?? String(localized: "New Tab")
    }

    private func sidebarSectionHeader(_ title: LocalizedStringKey, block: SidebarBlock) -> some View {
        Text(title)
            .font(Theme.sidebarRowMeta)
            .foregroundStyle(chrome.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 2)
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
        let members = model.tabs(in: workspace)
        if !members.isEmpty {
            if members.allSatisfy(\.isLocal) {
                return String(localized: "Local Group")
            }
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
        return Group {
            if renaming {
                TextField("Workspace name", text: $workspaceNameDraft)
                    .textFieldStyle(.plain)
                    .font(Theme.sidebarRowMeta)
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
                    .font(Theme.sidebarRowMeta)
                    .foregroundStyle(chrome.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
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
                    onOpenInNewWindow: { model.openBlockInNewWindow(.workspace(workspace.id), from: window) },
                    onDissolve: { model.dissolveWorkspace(workspace.id) },
                    onDragBegan: { dropRelay.blockDragBegan(.workspace(workspace.id)) },
                    onDragMoved: { dropRelay.blockDragMoved(windowPoint: $0) },
                    onDragEnded: { dropRelay.blockDragEnded(windowPoint: $0) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func rowFill(selected: Bool, tabID: UUID) -> Color {
        if window.dropHighlight == .sidebarRow(tabID) || window.dropHighlight == .sidebar {
            return chrome.accent.opacity(0.28)
        }
        return selected ? activeAccent.opacity(0.16) : Color.clear
    }

    /// Whole-block outline while a block or a multi-selection is about to merge into it.
    private func blockFill(_ block: SidebarBlock) -> some View {
        let active = window.dropHighlight == .block(block)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(chrome.accent.opacity(active ? 0.14 : 0))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(chrome.accent.opacity(active ? 0.9 : 0), lineWidth: 2)
            )
            .padding(.horizontal, 6)
    }

    private var detail: some View {
        ZStack {
            TerminalCanvas(
                model: model,
                window: window,
                dropRelay: dropRelay,
                dark: appearanceDriver.isDark
            )
            if model.selectedTab(in: window) == nil {
                VStack(spacing: 8) {
                    Text("No open terminals")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(chrome.text)
                    Text(String(format: String(localized: "Press %@ to open a terminal."), AppShortcuts.display(for: .newTab)))
                        .font(.system(size: 13))
                        .foregroundStyle(chrome.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(chrome.background)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(chrome.background)
    }
}

enum SheetLayout {
    static let search: CGFloat = 440
    static let sessionBodyHeight: CGFloat = 520
    static let settings: CGFloat = 880
    static let settingsBodyHeight: CGFloat = 720
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

private struct IsKeyWindowKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False in a window that is open but not key. Views then drop the accent from selection cues.
    var isKeyWindow: Bool {
        get { self[IsKeyWindowKey.self] }
        set { self[IsKeyWindowKey.self] = newValue }
    }
}
