import AppKit
import GhosttyTheme
import QuartzCore
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var appearanceDriver = AppearanceDriver.shared
    @AppStorage(AppShortcuts.revisionKey) private var shortcutsRevision = 0
    @AppStorage(TerminalAppearance.storageKey) private var appearanceRaw = TerminalAppearance.system.rawValue
    @AppStorage(TerminalThemeFamily.storageKey) private var themeFamilyRaw = TerminalThemeFamily.claude.rawValue
    @StateObject private var dropRelay = CanvasDropRelay()
    @State private var renamingWorkspaceID: UUID?
    @State private var workspaceNameDraft = ""
    @State private var skipWorkspaceRenameCommit = false
    @FocusState private var workspaceNameFocused: Bool

    private var chrome: WindowChrome {
        WindowChrome.resolve(isDark: appearanceDriver.isDark)
    }

    private var themeFamily: TerminalThemeFamily {
        TerminalThemeFamily.from(raw: themeFamilyRaw)
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
        .ignoresSafeArea(edges: .top)
        .preferredColorScheme(appearanceDriver.interfaceColorScheme)
        .onChange(of: appearanceRaw) { _, _ in
            appearanceDriver.reapply()
        }
        .oneagentHideFocusRing()
        .task { model.reloadHosts() }
        .onOpenURL { model.openExternalURL($0) }
        .onAppear {
            TerminalAppearance.migrateLegacyThemeIfNeeded()
            TerminalThemeFamily.migrateIfNeeded()
            GhosttyRuntime.apply(family: themeFamily)
            appearanceDriver.reapply()
        }
        .onChange(of: themeFamilyRaw) { _, _ in
            GhosttyRuntime.apply(family: themeFamily)
        }
        .background(WindowTitleSync(title: selectedSessionBadge.isEmpty ? String(localized: "1Agent") : selectedSessionBadge))
        .sheet(isPresented: $model.hostPickerPresented) {
            HostPicker(model: model)
                .frame(width: SheetLayout.search, height: SheetLayout.sessionBodyHeight)
                .environment(\.windowChrome, chrome)
                .preferredColorScheme(appearanceDriver.interfaceColorScheme)
                .oneagentHideFocusRing()
        }
    }

    private var newTabHelp: String {
        String(format: String(localized: "New Tab (%@)"), AppShortcuts.display(for: .newTab))
    }

    private var windowControls: some View {
        Button(action: { model.newTab() }) {
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
                Spacer()
                windowControls
            }
            .padding(.leading, 78)
            .padding(.trailing, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if model.tabs.isEmpty {
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
                        let grouped = model.workspacesByNumber
                        let standalone = model.standaloneTabs
                        let localStandalone = standalone.filter(\.isLocal)
                        let remoteStandalone = standalone.filter { !$0.isLocal }
                        ForEach(grouped) { workspace in
                            VStack(spacing: 2) {
                                workspaceHeader(workspace)
                                ForEach(model.tabs(in: workspace)) { tab in
                                    tabRow(tab, compact: false, indent: 12)
                                }
                            }
                            .background(WorkspaceAnchor(id: workspace.id, relay: dropRelay))
                        }
                        if !localStandalone.isEmpty {
                            VStack(spacing: 2) {
                                sidebarSectionTitle("Local Group")
                                ForEach(localStandalone) { tab in
                                    tabRow(tab, compact: false, indent: 12)
                                }
                            }
                        }
                        if !remoteStandalone.isEmpty {
                            VStack(spacing: 2) {
                                sidebarSectionTitle("Ungrouped")
                                ForEach(remoteStandalone) { tab in
                                    tabRow(tab, compact: false)
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
        guard let tab = model.selectedTab else { return "" }
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
        if let mark = model.duplicateHostMark(for: tab.id) {
            return Theme.duplicateHostMark(mark)
        }
        return chrome.text
    }

    private func tabRow(_ tab: TerminalTab, compact: Bool, indent: CGFloat = 0) -> some View {
        let selected = model.isSidebarSelected(tab.id)
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
                    model.clickSidebar(tab.id, command: command, shift: shift)
                },
                onBegan: { dropRelay.dragBegan(tab.id) },
                onMoved: { dropRelay.dragMoved(windowPoint: $0) },
                onEnded: { dropRelay.dragEnded(windowPoint: $0) },
                prepareContextMenu: {
                    let targets = model.sidebarTargets(clicking: tab.id)
                    let splits = model.sidebarSplits(targets)
                    return TabContextMenu(
                        showsDuplicate: targets.count == 1,
                        splits: splits,
                        canMerge: targets.count >= 2,
                        duplicateRight: { model.duplicate(targets[0], edge: .right) },
                        duplicateDown: { model.duplicate(targets[0], edge: .bottom) },
                        merge: {
                            if splits {
                                model.splitSidebar(targets)
                            } else {
                                model.mergeSidebar(targets)
                            }
                        },
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

    private func sidebarSectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(Theme.sidebarRowMeta)
            .foregroundStyle(chrome.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 2)
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
        .overlay {
            if !renaming {
                WorkspaceHeaderMenu(
                    layouts: layouts,
                    titles: layouts.map { workspaceLayoutTitle($0) },
                    canReconnect: model.tabs(in: workspace).contains { $0.isSession && $0.exited },
                    onLayout: { model.applyWorkspaceLayout(workspace.id, $0) },
                    onReconnect: { model.reconnectWorkspace(workspace.id) },
                    onRename: { beginWorkspaceRename(workspace) },
                    onDissolve: { model.dissolveWorkspace(workspace.id) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func rowFill(selected: Bool, tabID: UUID) -> Color {
        if model.dropHighlight == .sidebarRow(tabID) || model.dropHighlight == .sidebar {
            return chrome.accent.opacity(0.28)
        }
        return selected ? chrome.accent.opacity(0.16) : Color.clear
    }

    private var detail: some View {
        ZStack {
            TerminalCanvas(
                model: model,
                dropRelay: dropRelay,
                dark: appearanceDriver.isDark,
                usesCatalogTheme: true
            )
            if model.selectedTab == nil {
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

private final class AnchorBox {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}

private final class CanvasDropRelay: ObservableObject {
    var frames: [UUID: CGRect] = [:]
    weak var modelBox: AppModel?
    weak var catcher: PaneDropCatcherView?
    weak var sidebarAnchor: NSView?
    var rowAnchors: [UUID: AnchorBox] = [:]
    var workspaceAnchors: [UUID: AnchorBox] = [:]
    var dragTitle = ""

    func dragBegan(_ id: UUID) {
        MainActor.assumeIsolated {
            guard let model = modelBox else { return }
            if let tab = model.tabs.first(where: { $0.id == id }), tab.isLocal, let directory = tab.directory {
                dragTitle = LocalTerminal.displayPath(directory)
            } else {
                let alias = model.tabs.first { $0.id == id }?.alias ?? ""
                dragTitle = model.host(alias)?.sessionBadge ?? alias
            }
            model.beginDrag(id)
        }
    }

    func dragMoved(windowPoint: NSPoint) {
        let frames = frames
        let title = dragTitle
        guard let catcher else { return }
        catcher.layoutSubtreeIfNeeded()
        let overCanvas = catcher.contains(windowPoint) && catcher.bounds.width > 2
        let swiftPoint = catcher.swiftPoint(windowPoint)
        if overCanvas {
            let zone = MainActor.assumeIsolated { () -> CGRect? in
                guard let model = modelBox, let dragged = model.draggingTabID else { return nil }
                guard let hit = PaneLayout.dropTarget(at: swiftPoint, frames: frames, dragged: dragged) else {
                    model.dropHighlight = nil
                    return nil
                }
                let next = TabDropHighlight.edge(hit.0, hit.1)
                if model.dropHighlight != next { model.dropHighlight = next }
                guard let frame = frames[hit.0] else { return nil }
                return Self.previewZone(for: hit.1, in: frame)
            }
            catcher.present(over: catcher, zone: zone, title: title)
            return
        }
        let workspaceHit = workspaceTarget(windowPoint)
        let sidebarHit = sidebarRowHit(windowPoint)
        let onSidebar = sidebarAnchorContains(windowPoint)
        let preview = MainActor.assumeIsolated { () -> (NSView, CGRect)? in
            guard let model = modelBox, let dragged = model.draggingTabID else { return nil }
            model.dropHighlight = nil
            if let workspaceHit {
                if model.workspaceContains(dragged, workspaceHit) {
                    guard let row = sidebarHit, row.id != dragged, model.workspaceContains(row.id, workspaceHit) else {
                        return nil
                    }
                    return Self.sidebarLine(sidebar: sidebarAnchor, over: row.view, after: row.after)
                }
                if let slot = self.workspaceInsert(windowPoint: windowPoint, workspaceID: workspaceHit) {
                    return slot.line
                }
                guard let group = workspaceAnchors[workspaceHit]?.view else { return nil }
                return Self.sidebarLine(sidebar: sidebarAnchor, over: group, after: true)
            }
            if let slot = self.standaloneInsert(windowPoint: windowPoint) {
                return slot.line
            }
            guard onSidebar else { return nil }
            return Self.listEndLine(sidebar: sidebarAnchor, groups: workspaceAnchors)
        }
        if let preview {
            catcher.present(over: preview.0, zone: preview.1, title: title, insertionLine: true)
        } else {
            catcher.present(over: catcher, zone: nil, title: title)
        }
    }

    /// The insertion gap among standalone hosts closest to the pointer.
    /// The line can sit above the first row or below the last row.
    private func standaloneInsert(windowPoint: NSPoint) -> (id: UUID, after: Bool, line: (NSView, CGRect))? {
        let ids = MainActor.assumeIsolated {
            self.modelBox?.standaloneTabs.map(\.id) ?? []
        }
        return nearestRowEdge(windowPoint: windowPoint, ids: ids)
    }

    /// Where a host from outside this workspace would land among its members.
    private func workspaceInsert(windowPoint: NSPoint, workspaceID: UUID) -> (id: UUID, after: Bool, line: (NSView, CGRect))? {
        let ids = MainActor.assumeIsolated { () -> [UUID] in
            guard let model = self.modelBox,
                  let workspace = model.workspaces.first(where: { $0.id == workspaceID }) else {
                return []
            }
            return model.tabs(in: workspace).map(\.id)
        }
        return nearestRowEdge(windowPoint: windowPoint, ids: ids)
    }

    private func nearestRowEdge(windowPoint: NSPoint, ids: [UUID]) -> (id: UUID, after: Bool, line: (NSView, CGRect))? {
        guard let sidebar = sidebarAnchor, sidebar.window != nil else { return nil }
        let local = sidebar.convert(windowPoint, from: nil)
        guard sidebar.bounds.contains(local) else { return nil }
        var rows: [(id: UUID, frame: CGRect)] = []
        for id in ids {
            guard let view = rowAnchors[id]?.view, view.window != nil else { continue }
            let frame = sidebar.convert(view.bounds, from: view)
            rows.append((id, frame))
        }
        rows.sort { $0.frame.minY < $1.frame.minY }
        guard let last = rows.last else { return nil }
        var edges: [(id: UUID, after: Bool, y: CGFloat)] = []
        for row in rows {
            edges.append((row.id, false, row.frame.minY))
        }
        edges.append((last.id, true, last.frame.maxY))
        var best = edges[0]
        var bestDistance = abs(local.y - best.y)
        for edge in edges.dropFirst() {
            let distance = abs(local.y - edge.y)
            if distance < bestDistance {
                best = edge
                bestDistance = distance
            }
        }
        let y = min(max(best.y - 1.5, 0), max(sidebar.bounds.height - 3, 0))
        let line = CGRect(x: 0, y: y, width: sidebar.bounds.width, height: 3)
        return (best.id, best.after, (sidebar, line))
    }

    /// A 3pt bar across the whole sidebar column, on the top or bottom edge of `view`.
    /// Coordinates grow downward.
    private static func sidebarLine(sidebar: NSView?, over view: NSView, after: Bool) -> (NSView, CGRect)? {
        guard let sidebar, sidebar.window != nil, view.window != nil else { return nil }
        let frame = sidebar.convert(view.bounds, from: view)
        let edge = after ? frame.maxY : frame.minY
        let y = min(max(edge - 1.5, 0), max(sidebar.bounds.height - 3, 0))
        let line = CGRect(x: 0, y: y, width: sidebar.bounds.width, height: 3)
        return (sidebar, line)
    }

    /// Line under the last workspace, where a host lands when it leaves every group.
    private static func listEndLine(sidebar: NSView?, groups: [UUID: AnchorBox]) -> (NSView, CGRect)? {
        guard let sidebar, sidebar.window != nil else { return nil }
        var bottom: CGFloat = 46
        for box in groups.values {
            guard let view = box.view, view.window != nil else { continue }
            let frame = sidebar.convert(view.bounds, from: view)
            bottom = max(bottom, frame.maxY)
        }
        let y = min(bottom + 4, max(sidebar.bounds.height - 3, 0))
        let line = CGRect(x: 0, y: y, width: sidebar.bounds.width, height: 3)
        return (sidebar, line)
    }

    /// The landing half, slightly inset. Kept in the canvas's own coordinates.
    private static func previewZone(for edge: SplitEdge, in frame: CGRect) -> CGRect {
        let raw = PaneLayout.highlight(for: edge, in: frame)
        let inset = min(8, min(raw.width, raw.height) / 4)
        let padded = raw.insetBy(dx: inset, dy: inset)
        if padded.width >= 32, padded.height >= 32 {
            return padded
        }
        return raw
    }

    func dragEnded(windowPoint: NSPoint) {
        let frames = frames
        let swiftPoint = catcher?.swiftPoint(windowPoint) ?? .zero
        let overCanvas = catcher.map { $0.contains(windowPoint) && $0.bounds.width > 2 } ?? false
        let sidebarHit = sidebarRowHit(windowPoint)
        let onSidebar = sidebarAnchorContains(windowPoint)
        catcher?.hide()
        MainActor.assumeIsolated {
            guard let model = modelBox, let dragged = model.draggingTabID else { return }
            if overCanvas, let hit = PaneLayout.dropTarget(at: swiftPoint, frames: frames, dragged: dragged) {
                model.dropTab(dragged, onto: hit.0, edge: hit.1)
                return
            }
            if let workspaceHit = self.workspaceTarget(windowPoint) {
                if model.workspaceContains(dragged, workspaceHit) {
                    if let sidebarHit, sidebarHit.id != dragged {
                        model.reorderWorkspaceMember(dragged, beside: sidebarHit.id, after: sidebarHit.after)
                    } else {
                        model.endDrag()
                    }
                } else if let slot = self.workspaceInsert(windowPoint: windowPoint, workspaceID: workspaceHit) {
                    model.joinWorkspace(dragged, workspaceHit, beside: slot.id, after: slot.after)
                } else {
                    model.joinWorkspace(dragged, workspaceHit)
                }
                return
            }
            if onSidebar || sidebarHit != nil {
                let slot = self.standaloneInsert(windowPoint: windowPoint)
                model.receiveSidebarDrop(dragged, beside: slot?.id, after: slot?.after ?? false)
                return
            }
            model.endDrag()
        }
    }

    private func sidebarAnchorContains(_ windowPoint: NSPoint) -> Bool {
        guard let sidebarAnchor, sidebarAnchor.window != nil else { return false }
        let local = sidebarAnchor.convert(windowPoint, from: nil)
        return sidebarAnchor.bounds.contains(local)
    }

    private func workspaceTarget(_ windowPoint: NSPoint) -> UUID? {
        for (id, box) in workspaceAnchors {
            guard let view = box.view, view.window != nil else { continue }
            let local = view.convert(windowPoint, from: nil)
            if view.bounds.contains(local) { return id }
        }
        return nil
    }

    private func sidebarRowHit(_ windowPoint: NSPoint) -> (id: UUID, after: Bool, view: NSView)? {
        for (id, box) in rowAnchors {
            guard let view = box.view, view.window != nil else { continue }
            let local = view.convert(windowPoint, from: nil)
            if view.bounds.contains(local) {
                let after = local.y >= view.bounds.midY
                return (id, after, view)
            }
        }
        return nil
    }
}

/// Drawn above the terminal while a tab is dragged. It does not take clicks.
/// AppKit y grows upward. `preview` is already in that space.
private final class DropSessionOverlay: NSView {
    let chip = DragChipView()
    var preview: CGRect?
    var drawsInsertionLine = false
    var accent: NSColor = .controlAccentColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.zPosition = 20_000
        addSubview(chip)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let preview else { return }
        if drawsInsertionLine {
            let path = NSBezierPath(roundedRect: preview, xRadius: 1.5, yRadius: 1.5)
            accent.setFill()
            path.fill()
            return
        }
        let rect = preview.insetBy(dx: 1, dy: 1)
        guard rect.width > 2, rect.height > 2 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.28).setFill()
        path.fill()
        accent.withAlphaComponent(0.62).setFill()
        path.fill()
        accent.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    /// `zone` uses the canvas layout: origin at the top, y downward.
    func show(zone: CGRect?, canvasHeight: CGFloat, title: String, insertionLine: Bool = false) {
        drawsInsertionLine = insertionLine
        guard let zone else {
            preview = nil
            chip.isHidden = true
            needsDisplay = true
            return
        }
        let preview = CGRect(
            x: zone.minX,
            y: canvasHeight - zone.maxY,
            width: zone.width,
            height: zone.height
        )
        self.preview = preview
        needsDisplay = true
        if insertionLine {
            chip.isHidden = true
            return
        }
        let size = DragChipView.size(for: title)
        let width = min(size.width, max(preview.width - 16, 44))
        let height = min(size.height, max(preview.height - 16, 22))
        chip.isHidden = false
        chip.title = title
        chip.frame = CGRect(
            x: preview.midX - width / 2,
            y: preview.midY - height / 2,
            width: width,
            height: height
        )
        chip.needsDisplay = true
    }
}

/// Anchor for the terminal area. Stays unflipped so SwiftUI places it on the canvas.
private final class PaneDropCatcherView: NSView {
    weak var relay: CanvasDropRelay?
    let overlay = DropSessionOverlay()

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit {
        overlay.removeFromSuperview()
    }

    func contains(_ windowPoint: NSPoint) -> Bool {
        guard window != nil else { return false }
        return bounds.contains(convert(windowPoint, from: nil))
    }

    /// Canvas layout point: origin at the top, y downward.
    func swiftPoint(_ windowPoint: NSPoint) -> CGPoint {
        let local = convert(windowPoint, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    /// `zone` is inside `anchor`, origin at the top, y downward.
    func present(over anchor: NSView, zone: CGRect?, title: String, insertionLine: Bool = false) {
        guard anchor.bounds.width > 2, let window else { return }
        let host = window.contentView?.superview ?? window.contentView
        guard let host else { return }
        overlay.frame = anchor.convert(anchor.bounds, to: host)
        let aboveContent = host === window.contentView ? nil : window.contentView
        host.addSubview(overlay, positioned: .above, relativeTo: aboveContent)
        overlay.layer?.zPosition = 20_000
        overlay.show(zone: zone, canvasHeight: anchor.bounds.height, title: title, insertionLine: insertionLine)
        // Mouse tracking does not refresh the screen by itself, and the terminal
        // metal layer covers a preview left inside the SwiftUI view.
        overlay.display()
        CATransaction.flush()
    }

    func hide() {
        overlay.show(zone: nil, canvasHeight: bounds.height, title: "")
        overlay.removeFromSuperview()
        CATransaction.flush()
    }
}

private struct PaneDropCatcher: NSViewRepresentable {
    var relay: CanvasDropRelay
    var accent: NSColor

    func makeNSView(context: Context) -> PaneDropCatcherView {
        let view = PaneDropCatcherView()
        view.relay = relay
        view.overlay.accent = accent
        relay.catcher = view
        return view
    }

    func updateNSView(_ view: PaneDropCatcherView, context: Context) {
        view.relay = relay
        view.overlay.accent = accent
        relay.catcher = view
    }
}

/// Keeps Mission Control title in sync while forcing a transparent, title-less
/// titlebar so SwiftUI can draw one custom title without system duplication.
private struct WindowTitleSync: NSViewRepresentable {
    var title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.apply(title: title, to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(title: title, to: view.window) }
    }

    private static func apply(title: String, to window: NSWindow?) {
        guard let window else { return }
        if window.title != title {
            window.title = title
        }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Keep false so SwiftUI controls in the titlebar band (e.g. New Tab) receive clicks.
        // Pane titles still move the window through their own drag handles.
        window.isMovableByWindowBackground = false
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.toolbar = nil
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .none
        }
        // Hide any leftover separator view the system still inserts under the traffic lights.
        Self.hideSeparatorViews(in: window.contentView?.superview)
    }

    private static func hideSeparatorViews(in root: NSView?) {
        guard let root else { return }
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            let name = String(describing: type(of: view))
            if name.contains("Separator") || name.contains("TitlebarSeparator") {
                view.isHidden = true
                view.alphaValue = 0
            }
            stack.append(contentsOf: view.subviews)
        }
    }
}

private final class DragChipView: NSView {
    var title = ""

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.white.setFill()
        path.fill()
        NSColor(white: 0.78, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(white: 0.15, alpha: 1),
            .paragraphStyle: paragraph,
        ]
        let textRect = CGRect(x: 10, y: (bounds.height - 16) / 2, width: max(bounds.width - 32, 8), height: 16)
        (title as NSString).draw(in: textRect, withAttributes: attributes)

        let markRect = CGRect(x: bounds.width - 18, y: (bounds.height - 10) / 2, width: 10, height: 10)
        if let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil) {
            let mark = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)) ?? image
            mark.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 0.55)
        }
    }

    static func size(for title: String) -> CGSize {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        return CGSize(width: max(size.width + 42, 72), height: max(size.height + 12, 26))
    }
}

/// Right-click on a workspace title. Scroll events pass through to the sidebar.
private struct WorkspaceHeaderMenu: NSViewRepresentable {
    var layouts: [WorkspaceLayout]
    var titles: [String]
    var canReconnect: Bool
    var onLayout: (WorkspaceLayout) -> Void
    var onReconnect: () -> Void
    var onRename: () -> Void
    var onDissolve: () -> Void

    func makeNSView(context: Context) -> WorkspaceHeaderMenuView {
        WorkspaceHeaderMenuView()
    }

    func updateNSView(_ view: WorkspaceHeaderMenuView, context: Context) {
        view.layouts = layouts
        view.titles = titles
        view.canReconnect = canReconnect
        view.onLayout = onLayout
        view.onReconnect = onReconnect
        view.onRename = onRename
        view.onDissolve = onDissolve
        view.toolTip = String(localized: "Right-click to reconnect closed terminals, rename the workspace, or arrange its panes.")
    }
}

private final class WorkspaceHeaderMenuView: NSView {
    var layouts: [WorkspaceLayout] = []
    var titles: [String] = []
    var canReconnect = false
    var onLayout: (WorkspaceLayout) -> Void = { _ in }
    var onReconnect: () -> Void = {}
    var onRename: () -> Void = {}
    var onDissolve: () -> Void = {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let reconnect = NSMenuItem(
            title: String(localized: "Reconnect"),
            action: #selector(reconnectFromMenu(_:)),
            keyEquivalent: ""
        )
        reconnect.target = self
        menu.addItem(reconnect)
        if !layouts.isEmpty {
            menu.addItem(.separator())
        }
        for index in layouts.indices {
            let title = titles.indices.contains(index) ? titles[index] : ""
            let item = NSMenuItem(title: title, action: #selector(chooseLayout(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let rename = NSMenuItem(
            title: String(localized: "Rename"),
            action: #selector(renameFromMenu(_:)),
            keyEquivalent: ""
        )
        rename.target = self
        menu.addItem(rename)
        menu.addItem(TerminalCloseMenu.item(
            title: String(localized: "Dissolve Workspace"),
            action: #selector(dissolveFromMenu(_:)),
            target: self
        ))
        return menu
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(reconnectFromMenu(_:)) {
            return canReconnect
        }
        return true
    }

    @objc private func chooseLayout(_ sender: NSMenuItem) {
        guard layouts.indices.contains(sender.tag) else { return }
        onLayout(layouts[sender.tag])
    }

    @objc private func reconnectFromMenu(_: Any?) {
        onReconnect()
    }

    @objc private func renameFromMenu(_: Any?) {
        onRename()
    }

    @objc private func dissolveFromMenu(_: Any?) {
        onDissolve()
    }
}

/// Follows the pointer until mouse-up. A system drag session does not report the landing point reliably.
private struct TabContextMenu {
    var showsDuplicate: Bool
    var splits: Bool
    var canMerge: Bool
    var duplicateRight: () -> Void
    var duplicateDown: () -> Void
    var merge: () -> Void
    var close: () -> Void
    var copyInfo: () -> Void
}

private final class TabDragHandleView: NSView {
    var onClick: (Bool, Bool) -> Void = { _, _ in }
    var onHover: (Bool) -> Void = { _ in }
    var onBegan: () -> Void = {}
    var onMoved: (NSPoint) -> Void = { _ in }
    var onEnded: (NSPoint) -> Void = { _ in }
    var onClose: (() -> Void)?
    var onSecondaryClick: (() -> Void)?
    var prepareContextMenu: (() -> TabContextMenu)?
    private var contextMenuActions: TabContextMenu?
    /// The pane title sits in the transparent titlebar. Freeze window movement
    /// while the pointer is already over the title, or the window moves with the pane drag.
    var freezesWindow = false {
        didSet {
            guard oldValue != freezesWindow else { return }
            window?.invalidateCursorRects(for: self)
            installTrackingIfNeeded(force: true)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard freezesWindow, bounds.width > 1, bounds.height > 1 else { return }
        addCursorRect(bounds, cursor: .openHand)
    }

    private var trackedBounds: NSRect = .zero

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        installTrackingIfNeeded(force: false)
    }

    override func layout() {
        super.layout()
        installTrackingIfNeeded(force: false)
    }

    private func installTrackingIfNeeded(force: Bool) {
        if !force, bounds == trackedBounds {
            return
        }
        trackedBounds = bounds
        installTrackingAreas()
    }

    /// Rebuilding tracking areas on every SwiftUI update sends a false mouse-exit.
    private func installTrackingAreas() {
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        if freezesWindow {
            options.formUnion([.mouseMoved, .cursorUpdate])
        }
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        if freezesWindow {
            NSCursor.openHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    /// Titlebar dragging is decided when the button goes down. The header has to
    /// freeze the window while the pointer is already over it, not after mouseDown.
    private var pressLocksWindow = false

    private func freezeWindowMovement() {
        window?.isMovable = false
    }

    private func restoreWindowMovementIfPointerLeft() {
        guard !pressLocksWindow, let window else { return }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !bounds.contains(local) {
            window.isMovable = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard freezesWindow, !pressLocksWindow else { return }
        freezeWindowMovement()
    }

    override func mouseEntered(with event: NSEvent) {
        if freezesWindow {
            if !pressLocksWindow {
                freezeWindowMovement()
            }
            NSCursor.openHand.set()
            return
        }
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        if !freezesWindow {
            onHover(false)
            restoreWindowMovementIfPointerLeft()
            return
        }
        NSCursor.arrow.set()
        restoreWindowMovementIfPointerLeft()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let local = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if self.bounds.contains(local) {
                if !self.pressLocksWindow {
                    self.freezeWindowMovement()
                }
                NSCursor.openHand.set()
            } else {
                self.restoreWindowMovementIfPointerLeft()
            }
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // The pane title sits in the transparent titlebar. Keep the window still
        // for the whole press so this drag merges panes instead of moving the window.
        pressLocksWindow = true
        window.isMovable = false
        defer {
            pressLocksWindow = false
            let local = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            window.isMovable = !self.bounds.contains(local)
        }
        let start = event.locationInWindow
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        var dragging = false
        var pushedHand = false
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: 3600,
            mode: .eventTracking
        ) { event, stop in
            guard let event else {
                if pushedHand {
                    NSCursor.pop()
                }
                stop.pointee = true
                return
            }
            window.isMovable = false
            let point = event.locationInWindow
            if event.type == .leftMouseUp {
                if dragging {
                    self.onEnded(point)
                } else {
                    self.onClick(command, shift)
                }
                if pushedHand {
                    NSCursor.pop()
                }
                stop.pointee = true
                return
            }
            if !dragging, hypot(point.x - start.x, point.y - start.y) >= 6 {
                dragging = true
                if self.freezesWindow {
                    NSCursor.closedHand.push()
                    pushedHand = true
                }
                self.onBegan()
            }
            if dragging {
                self.onMoved(point)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if freezesWindow {
            window?.isMovable = false
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if let onSecondaryClick {
            onSecondaryClick()
            restoreWindowMovementIfPointerLeft()
            return
        }
        if let prepareContextMenu {
            let actions = prepareContextMenu()
            contextMenuActions = actions
            NSMenu.popUpContextMenu(sidebarMenu(for: actions), with: event, for: self)
            return
        }
        guard onClose != nil else {
            super.rightMouseUp(with: event)
            return
        }
        let menu = NSMenu()
        menu.addItem(TerminalCloseMenu.item(action: #selector(closeFromMenu(_:)), target: self))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func sidebarMenu(for actions: TabContextMenu) -> NSMenu {
        let menu = NSMenu()
        let copyInfo = NSMenuItem(
            title: String(localized: "Copy Info"),
            action: #selector(copyInfoFromMenu(_:)),
            keyEquivalent: ""
        )
        copyInfo.target = self
        menu.addItem(copyInfo)
        menu.addItem(.separator())
        if actions.showsDuplicate {
            menu.addItem(shortcutItem(
                title: String(localized: "Duplicate Right"),
                chord: AppShortcuts.chord(for: .duplicateRight),
                action: #selector(duplicateRightFromMenu(_:))
            ))
            menu.addItem(shortcutItem(
                title: String(localized: "Duplicate Down"),
                chord: AppShortcuts.chord(for: .duplicateDown),
                action: #selector(duplicateDownFromMenu(_:))
            ))
        }
        let mergeTitle = actions.splits
            ? String(localized: "Split Terminals")
            : String(localized: "Merge Terminals")
        let merge = NSMenuItem(
            title: mergeTitle,
            action: #selector(mergeFromMenu(_:)),
            keyEquivalent: ""
        )
        merge.target = self
        merge.isEnabled = actions.splits || actions.canMerge
        menu.addItem(merge)
        menu.addItem(TerminalCloseMenu.item(action: #selector(closeFromMenu(_:)), target: self))
        return menu
    }

    private func shortcutItem(title: String, chord: KeyChord, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: chord.key)
        item.keyEquivalentModifierMask = chord.menuModifierMask
        item.target = self
        return item
    }

    @objc private func copyInfoFromMenu(_: Any?) {
        contextMenuActions?.copyInfo()
    }

    @objc private func duplicateRightFromMenu(_: Any?) {
        contextMenuActions?.duplicateRight()
    }

    @objc private func duplicateDownFromMenu(_: Any?) {
        contextMenuActions?.duplicateDown()
    }

    @objc private func mergeFromMenu(_: Any?) {
        contextMenuActions?.merge()
    }

    @objc private func closeFromMenu(_: Any?) {
        if let contextMenuActions {
            contextMenuActions.close()
            return
        }
        onClose?()
    }
}

private struct TabDragHandle: NSViewRepresentable {
    var onClick: (Bool, Bool) -> Void
    var onHover: (Bool) -> Void = { _ in }
    var onBegan: () -> Void
    var onMoved: (NSPoint) -> Void
    var onEnded: (NSPoint) -> Void
    var onClose: (() -> Void)? = nil
    var onSecondaryClick: (() -> Void)? = nil
    var prepareContextMenu: (() -> TabContextMenu)? = nil
    var freezesWindow = false

    func makeNSView(context: Context) -> TabDragHandleView { TabDragHandleView() }

    func updateNSView(_ view: TabDragHandleView, context: Context) {
        view.onClick = onClick
        view.onHover = onHover
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
        view.onClose = onClose
        view.onSecondaryClick = onSecondaryClick
        view.prepareContextMenu = prepareContextMenu
        view.freezesWindow = freezesWindow
        view.window?.invalidateCursorRects(for: view)
    }
}

private final class BoundsAnchorView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct BoundsAnchor: NSViewRepresentable {
    var onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> BoundsAnchorView { BoundsAnchorView() }

    func updateNSView(_ view: BoundsAnchorView, context: Context) {
        onResolve(view)
    }
}

private struct WorkspaceAnchor: NSViewRepresentable {
    var id: UUID
    var relay: CanvasDropRelay

    func makeNSView(context: Context) -> BoundsAnchorView { BoundsAnchorView() }

    func updateNSView(_ view: BoundsAnchorView, context: Context) {
        relay.workspaceAnchors[id] = AnchorBox(view)
    }
}

private struct RowAnchor: NSViewRepresentable {
    var id: UUID
    var relay: CanvasDropRelay

    func makeNSView(context: Context) -> BoundsAnchorView { BoundsAnchorView() }

    func updateNSView(_ view: BoundsAnchorView, context: Context) {
        relay.rowAnchors[id] = AnchorBox(view)
    }
}

private struct TerminalCanvas: View {
    /// One title line. Dragging this line merges panes.
    static let sidebarHeaderHeight: CGFloat = 18
    /// Room outside every pane so the focus stroke never covers the terminal.
    static let focusLine: CGFloat = 2

    @Environment(\.windowChrome) private var chrome
    @ObservedObject var model: AppModel
    var dropRelay: CanvasDropRelay
    var dark: Bool
    var usesCatalogTheme: Bool
    @State private var ratioDrag: (id: UUID, start: CGFloat)?

    private var headerHeight: CGFloat { Self.sidebarHeaderHeight }

    var body: some View {
        GeometryReader { geo in
            let root = model.displayRoot()
            let bounds = CGRect(origin: .zero, size: geo.size)
            let layout = Self.layoutBounds(bounds)
            let frames = root.map { PaneLayout.frames(of: $0, in: layout) } ?? [:]
            let dividers = root.map { PaneLayout.dividers(of: $0, in: layout) } ?? []
            let headerH = headerHeight
            let _ = dropRelay.sync(frames: frames, model: model)
            ZStack(alignment: .topLeading) {
                chrome.background
                ForEach(model.tabs.filter(\.isSession)) { tab in
                    let content = frames[tab.id].map { Self.contentFrame($0, headerHeight: headerH) }
                    SSHTerminalView(
                        sessionID: tab.sessionID,
                        alias: tab.alias ?? "",
                        directory: tab.isLocal ? tab.directory : nil,
                        environment: model.launchEnvironment,
                        dark: dark,
                        usesCatalogTheme: usesCatalogTheme,
                        onExit: { code in
                            // A local shell exit closes the tab. ssh uses 255 when the connection itself fails.
                            if tab.isLocal {
                                model.closeTab(tab.id)
                            } else if let code, code != 255 {
                                model.closeTab(tab.id)
                            } else {
                                model.markClosed(tab.id)
                            }
                        },
                        onClose: { model.closeTab(tab.id) },
                        onFocus: { model.notePaneFocused(tab.id) }
                    )
                    .id(tab.sessionID)
                    .frame(
                        width: max(content?.width ?? 1, 1),
                        height: max(content?.height ?? 1, 1)
                    )
                    .position(
                        x: content?.midX ?? -1000,
                        y: content?.midY ?? -1000
                    )
                    .opacity(content == nil ? 0 : 1)
                    .allowsHitTesting(content != nil)
                    .accessibilityHidden(content == nil)
                    .zIndex(content == nil ? 0 : 1)
                }
                ForEach(dividers) { divider in
                    dividerControl(divider)
                }
                ForEach(model.tabs.filter { frames[$0.id] != nil }) { tab in
                    if let frame = frames[tab.id] {
                        paneChrome(tab, frame: frame, headerHeight: headerH)
                    }
                }
                if let selected = model.selectedTabID, let frame = frames[selected] {
                    focusRing(around: frame)
                        .allowsHitTesting(false)
                        .zIndex(5)
                }
            }
            .overlay {
                PaneDropCatcher(relay: dropRelay, accent: NSColor(chrome.accent))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
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

    private func hostTitleColor(_ tab: TerminalTab) -> Color {
        if tab.showsDisconnected || tab.reconnecting {
            return chrome.danger
        }
        if let mark = model.duplicateHostMark(for: tab.id) {
            return Theme.duplicateHostMark(mark)
        }
        return chrome.text
    }

    @ViewBuilder
    private func paneChrome(_ tab: TerminalTab, frame: CGRect, headerHeight: CGFloat) -> some View {
        let focused = model.selectedTabID == tab.id
        if headerHeight > 0 {
            ZStack {
                chrome.background
                    .allowsHitTesting(false)
                HStack(spacing: 6) {
                    Text(paneTitle(tab))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(hostTitleColor(tab))
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
                    onClick: { _, _ in model.selectOnly(tab.id) },
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
            Button("Reconnect") { model.reconnect(tab.id) }
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
private func copySessionInfo(_ tab: TerminalTab, model: AppModel) {
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

private extension TerminalCanvas {
    /// Panes sit inside a margin the same width as the focus stroke.
    /// The stroke occupies that margin, so selecting a pane does not cover its content.
    static func layoutBounds(_ bounds: CGRect) -> CGRect {
        let margin = focusLine * 2
        guard bounds.width > margin, bounds.height > margin else { return bounds }
        return bounds.insetBy(dx: focusLine, dy: focusLine)
    }

    private func focusRing(around frame: CGRect) -> some View {
        let line = Self.focusLine
        let outer = frame.insetBy(dx: -line, dy: -line)
        return Rectangle()
            .strokeBorder(chrome.accent.opacity(0.45), lineWidth: line)
            .frame(width: max(outer.width, 1), height: max(outer.height, 1))
            .offset(x: outer.minX, y: outer.minY)
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

private extension CanvasDropRelay {
    func sync(frames: [UUID: CGRect], model: AppModel) {
        self.frames = frames
        self.modelBox = model
    }
}

private struct HostPicker: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject var model: AppModel
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [SSHHost] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return model.hosts }
        return model.hosts.filter {
            $0.alias.lowercased().contains(needle) || $0.subtitle.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Open a Terminal")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(chrome.text)
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 12)

            Button {
                model.openLocalTerminal()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local Terminal")
                        .font(Theme.sidebarRowTitle)
                        .foregroundStyle(chrome.text)
                    Text(LocalTerminal.homeDirectory)
                        .font(Theme.sidebarRowMeta)
                        .foregroundStyle(chrome.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Rectangle()
                .fill(chrome.hairline)
                .frame(height: 1)
                .padding(.horizontal, 28)
                .padding(.bottom, 12)

            TextField("Search hosts", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
                .onAppear { searchFocused = true }

            if model.configFailed {
                Text("Could not read SSH config.")
                    .font(Theme.sidebarRowMeta)
                    .foregroundStyle(chrome.secondary)
                    .padding(.horizontal, 28)
                Spacer()
            } else if filtered.isEmpty {
                Group {
                    if model.hosts.isEmpty {
                        Text("SSH config has no hosts to connect to.")
                    } else {
                        Text("No matching hosts")
                    }
                }
                .font(Theme.sidebarRowMeta)
                .foregroundStyle(chrome.secondary)
                .padding(.horizontal, 28)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { host in
                            Button {
                                model.openHost(host.alias)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.alias)
                                        .font(Theme.sidebarRowTitle)
                                        .foregroundStyle(chrome.text)
                                    if !host.subtitle.isEmpty {
                                        Text(host.subtitle)
                                            .font(Theme.sidebarRowMeta)
                                            .foregroundStyle(chrome.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.hostPickerPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(chrome.background)
    }
}
