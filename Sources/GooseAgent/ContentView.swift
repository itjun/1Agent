import AppKit
import GhosttyTheme
import QuartzCore
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppShortcuts.revisionKey) private var shortcutsRevision = 0
    @AppStorage(TabPlacement.storageKey) private var tabLayoutRaw = TabPlacement.vertical.rawValue
    @AppStorage(TerminalAppearance.storageKey) private var appearanceRaw = TerminalAppearance.system.rawValue
    @AppStorage(TerminalThemeFamily.storageKey) private var themeFamilyRaw = TerminalThemeFamily.claude.rawValue
    @AppStorage("appearance.sidebarCollapsed") private var sidebarCollapsed = false
    @StateObject private var dropRelay = CanvasDropRelay()

    private var tabLayout: TabPlacement {
        TabPlacement(rawValue: tabLayoutRaw) ?? .vertical
    }

    private var appearance: TerminalAppearance {
        TerminalAppearance(rawValue: appearanceRaw) ?? .system
    }

    private var chrome: WindowChrome {
        WindowChrome.resolve(isDark: appearance.isDark(system: colorScheme))
    }

    private var themeFamily: TerminalThemeFamily {
        TerminalThemeFamily.from(raw: themeFamilyRaw)
    }

    private var modalPresented: Binding<Bool> {
        Binding(
            get: { model.hostPickerPresented || model.showingSettings },
            set: { isPresented in
                guard !isPresented else { return }
                model.hostPickerPresented = false
                model.showingSettings = false
            }
        )
    }

    var body: some View {
        let _ = shortcutsRevision
        Group {
            if sidebarCollapsed {
                detail
            } else {
                switch tabLayout {
                case .vertical:
                    HStack(spacing: 0) {
                        sidebar
                            .frame(width: 248)
                        Rectangle().fill(chrome.hairline).frame(width: 1)
                        detail
                    }
                case .top:
                    VStack(spacing: 0) {
                        horizontalChrome(tabsAt: .top)
                        detail
                    }
                case .bottom:
                    VStack(spacing: 0) {
                        horizontalChrome(tabsAt: .bottom)
                        detail
                        horizontalTabStrip
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if sidebarCollapsed {
                windowControls
                    .padding(.leading, 78)
                    .padding(.top, 10)
            }
        }
        .frame(minWidth: 880, minHeight: 520)
        .background(chrome.background)
        .environment(\.windowChrome, chrome)
        .ignoresSafeArea(edges: .top)
        .preferredColorScheme(appearance.preferredColorScheme)
        .oneagentHideFocusRing()
        .task { model.reloadHosts() }
        .onOpenURL { model.openExternalURL($0) }
        .onAppear {
            TerminalAppearance.migrateLegacyThemeIfNeeded()
            TerminalThemeFamily.migrateIfNeeded()
            GhosttyRuntime.apply(family: themeFamily)
        }
        .onChange(of: themeFamilyRaw) { _, _ in
            GhosttyRuntime.apply(family: themeFamily)
        }
        .background(WindowTitleSync(title: selectedSessionBadge.isEmpty ? String(localized: "1Agent") : selectedSessionBadge))
        .sheet(isPresented: modalPresented) {
            Group {
                if model.showingSettings {
                    SettingsView()
                        .frame(width: SheetLayout.settings, height: SheetLayout.settingsBodyHeight)
                } else {
                    HostPicker(model: model)
                        .frame(width: SheetLayout.search, height: SheetLayout.sessionBodyHeight)
                }
            }
            .environment(\.windowChrome, chrome)
            .oneagentHideFocusRing()
        }
    }

    private var newTabHelp: String {
        String(format: String(localized: "New Tab (%@)"), AppShortcuts.display(for: .newTab))
    }

    private var closeTabHelp: String {
        String(format: String(localized: "Close Tab (%@)"), AppShortcuts.display(for: .closeTab))
    }

    private var sidebarToggleHelp: String {
        if sidebarCollapsed {
            String(localized: "Show Sidebar")
        } else {
            String(localized: "Hide Sidebar")
        }
    }

    private var windowControls: some View {
        HStack(spacing: 8) {
            Button(action: model.newTab) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(newTabHelp)
            .accessibilityLabel(Text("New Tab"))

            Button {
                sidebarCollapsed.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(sidebarToggleHelp)
            .accessibilityLabel(Text(sidebarToggleHelp))
        }
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
                    Text(String(format: String(localized: "Press %@ to choose a host."), AppShortcuts.display(for: .newTab)))
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
                        ForEach(grouped) { workspace in
                            VStack(spacing: 2) {
                                workspaceHeader(workspace)
                                ForEach(model.tabs(in: workspace)) { tab in
                                    tabRow(tab, compact: false, indent: 12)
                                }
                            }
                            .background(WorkspaceAnchor(id: workspace.id, relay: dropRelay))
                        }
                        if !grouped.isEmpty && !standalone.isEmpty {
                            Rectangle()
                                .fill(chrome.hairline)
                                .frame(height: 1)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                        }
                        ForEach(standalone) { tab in
                            tabRow(tab, compact: false)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(BoundsAnchor { dropRelay.sidebarAnchor = $0 })
    }

    private var selectedSessionBadge: String {
        guard let tab = model.selectedTab else { return "" }
        if let host = tab.alias.flatMap({ model.host($0) }) {
            return host.sessionBadge
        }
        return tab.alias ?? ""
    }

    /// Title at the very top, then horizontal tabs. One continuous fill — no elevated strip / seam.
    private func horizontalChrome(tabsAt: TabPlacement) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 28, height: 22)
                Spacer(minLength: 0)
                if !selectedSessionBadge.isEmpty {
                    Text(selectedSessionBadge)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(chrome.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 78)
            .padding(.trailing, 10)
            .padding(.top, 14)
            .padding(.bottom, 2)

            if tabsAt == .top {
                horizontalTabStrip
            }
        }
        .background(chrome.background)
    }

    /// Shared horizontal tab strip for top and bottom placement.
    private var horizontalTabStrip: some View {
        HStack(spacing: 6) {
            ottyIconButton(
                systemName: "plus",
                help: newTabHelp,
                accessibility: String(localized: "New Tab"),
                selected: false,
                action: model.newTab
            )

            if model.tabs.isEmpty {
                Text("No open terminals")
                    .font(.system(size: 12))
                    .foregroundStyle(chrome.secondary)
                    .padding(.leading, 4)
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        let grouped = model.workspacesByNumber
                        let standalone = model.standaloneTabs
                        ForEach(grouped) { workspace in
                            Text(workspaceTitle(workspace.number))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(chrome.secondary)
                                .padding(.leading, 6)
                                .padding(.trailing, 2)
                                .contentShape(Rectangle())
                                .contextMenu { workspaceLayoutMenu(workspace) }
                                .help(workspaceLayoutHelp)
                            ForEach(model.tabs(in: workspace)) { tab in
                                ottyTabChip(tab)
                            }
                        }
                        if !grouped.isEmpty && !standalone.isEmpty {
                            Rectangle()
                                .fill(chrome.hairline)
                                .frame(width: 1, height: 16)
                                .padding(.horizontal, 6)
                        }
                        ForEach(standalone) { tab in
                            ottyTabChip(tab)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, tabLayout == .bottom ? 12 : 12)
        .padding(.trailing, 12)
        .padding(.bottom, tabLayout == .bottom ? 8 : 4)
        .frame(minHeight: 32)
        .background(BoundsAnchor { dropRelay.sidebarAnchor = $0 })
    }

    private func ottyIconButton(
        systemName: String,
        help: String,
        accessibility: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(chrome.text)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? chrome.text.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(accessibility))
    }

    private func ottyTabChip(_ tab: TerminalTab) -> some View {
        let selected = model.selectedTabID == tab.id
        let title = tab.alias ?? String(localized: "New Tab")
        return HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? chrome.text : chrome.secondary)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? chrome.text : chrome.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay {
                TabDragHandle(
                    onClick: { model.selectTab(tab.id) },
                    onBegan: { dropRelay.dragBegan(tab.id) },
                    onMoved: { dropRelay.dragMoved(windowPoint: $0) },
                    onEnded: { dropRelay.dragEnded(windowPoint: $0) }
                )
            }

            if selected || tab.exited {
                Button {
                    model.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(chrome.secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help(closeTabHelp)
                .accessibilityLabel(Text("Close Tab"))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, selected || tab.exited ? 6 : 10)
        .padding(.vertical, 5)
        .frame(minWidth: 88, maxWidth: 200, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ottyChipFill(selected: selected, tabID: tab.id))
        )
        .background(RowAnchor(id: tab.id, relay: dropRelay))
        .help(tab.alias.flatMap { model.host($0)?.sessionBadge } ?? "")
    }

    private func ottyChipFill(selected: Bool, tabID: UUID) -> Color {
        if model.dropHighlight == .sidebarRow(tabID) || model.dropHighlight == .sidebar {
            return chrome.accent.opacity(0.28)
        }
        return selected ? chrome.text.opacity(0.12) : Color.clear
    }

    private func tabRow(_ tab: TerminalTab, compact: Bool, indent: CGFloat = 0) -> some View {
        let selected = model.selectedTabID == tab.id
        let host = tab.alias.flatMap { model.host($0) }
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.alias ?? String(localized: "New Tab"))
                    .font(Theme.sidebarRowTitle)
                    .foregroundStyle(chrome.text)
                    .lineLimit(1)
                if !compact, let host, !host.subtitle.isEmpty {
                    Text(host.subtitle)
                        .font(Theme.sidebarRowMeta)
                        .foregroundStyle(chrome.secondary)
                        .lineLimit(1)
                }
                if !compact, tab.exited {
                    Text("Connection closed")
                        .font(Theme.sidebarRowMeta)
                        .foregroundStyle(chrome.danger)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(compact ? (host?.sessionBadge ?? "") : "")

            Button {
                model.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(chrome.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help(closeTabHelp)
            .accessibilityLabel(Text("Close Tab"))
        }
        .padding(.leading, 16 + indent)
        .padding(.trailing, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Rectangle().fill(rowFill(selected: selected, tabID: tab.id)))
        .background(RowAnchor(id: tab.id, relay: dropRelay))
        .overlay {
            TabDragHandle(
                onClick: { model.selectTab(tab.id) },
                onBegan: { dropRelay.dragBegan(tab.id) },
                onMoved: { dropRelay.dragMoved(windowPoint: $0) },
                onEnded: { dropRelay.dragEnded(windowPoint: $0) }
            )
        }
    }

    private func workspaceTitle(_ number: Int) -> String {
        String(format: String(localized: "Workspace %lld"), number)
    }

    private var workspaceLayoutHelp: String {
        String(localized: "Right-click to choose how the panes are arranged.")
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

    @ViewBuilder
    private func workspaceLayoutMenu(_ workspace: Workspace) -> some View {
        let count = WorkspaceBoard.leafIDs(workspace.layout).count
        ForEach(WorkspaceBoard.availableLayouts(paneCount: count), id: \.self) { layout in
            Button(workspaceLayoutTitle(layout)) {
                model.applyWorkspaceLayout(workspace.id, layout)
            }
        }
    }

    private func workspaceHeader(_ workspace: Workspace) -> some View {
        Text(workspaceTitle(workspace.number))
            .font(Theme.sidebarRowMeta)
            .foregroundStyle(chrome.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
            .contextMenu { workspaceLayoutMenu(workspace) }
            .help(workspaceLayoutHelp)
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
                dark: appearance.isDark(system: colorScheme),
                usesCatalogTheme: true,
                showsPaneHeader: tabLayout == .vertical
            )
            if model.selectedTab == nil {
                VStack(spacing: 8) {
                    Text("No open terminals")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(chrome.text)
                    Text(String(format: String(localized: "Press %@ to choose a host."), AppShortcuts.display(for: .newTab)))
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
            let alias = model.tabs.first { $0.id == id }?.alias ?? ""
            dragTitle = model.host(alias)?.sessionBadge ?? alias
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
                guard let group = workspaceAnchors[workspaceHit]?.view else { return nil }
                return Self.sidebarLine(sidebar: sidebarAnchor, over: group, after: true)
            }
            if let row = sidebarHit {
                return Self.sidebarLine(sidebar: sidebarAnchor, over: row.view, after: false)
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
                } else {
                    model.joinWorkspace(dragged, workspaceHit)
                }
                return
            }
            if onSidebar || sidebarHit != nil {
                model.receiveSidebarDrop(dragged, before: sidebarHit?.id)
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
            NSColor.controlAccentColor.setFill()
            path.fill()
            return
        }
        let rect = preview.insetBy(dx: 1, dy: 1)
        guard rect.width > 2, rect.height > 2 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.28).setFill()
        path.fill()
        NSColor(srgbRed: 0.55, green: 0.78, blue: 0.38, alpha: 0.62).setFill()
        path.fill()
        NSColor(srgbRed: 0.35, green: 0.58, blue: 0.22, alpha: 1).setStroke()
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

    func makeNSView(context: Context) -> PaneDropCatcherView {
        let view = PaneDropCatcherView()
        view.relay = relay
        relay.catcher = view
        return view
    }

    func updateNSView(_ view: PaneDropCatcherView, context: Context) {
        view.relay = relay
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

/// How close the pointer is to the pane drag bar.
private enum GripLevel: Equatable {
    /// Inside the approach zone, not yet on the bar.
    case near
    /// On the bar itself.
    case on
}

/// Follows the pointer until mouse-up. A system drag session does not report the landing point reliably.
private final class TabDragHandleView: NSView {
    var onClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var onGripLevel: (GripLevel?) -> Void = { _ in }
    var onBegan: () -> Void = {}
    var onMoved: (NSPoint) -> Void = { _ in }
    var onEnded: (NSPoint) -> Void = { _ in }
    var showsGripCursor = false {
        didSet {
            guard oldValue != showsGripCursor else { return }
            window?.invalidateCursorRects(for: self)
            installTrackingIfNeeded(force: true)
        }
    }

    /// Otty's hover hit is 60×8, a little wider than the 36pt bar.
    private var gripCursorRect: NSRect {
        let width: CGFloat = 60
        let height: CGFloat = 10
        return NSRect(
            x: (bounds.width - width) / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )
    }

    private func gripLevel(at windowPoint: NSPoint) -> GripLevel? {
        let local = convert(windowPoint, from: nil)
        guard bounds.contains(local) else { return nil }
        if gripCursorRect.contains(local) {
            return .on
        }
        return .near
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard showsGripCursor, gripCursorRect.width > 1 else { return }
        addCursorRect(gripCursorRect, cursor: .openHand)
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

    /// Rebuilding tracking areas on every SwiftUI update sends a false mouse-exit and hides the bar.
    private func installTrackingAreas() {
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let hover: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow]
        if showsGripCursor {
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: hover.union([.mouseMoved, .cursorUpdate]),
                owner: self,
                userInfo: ["role": "approach"]
            ))
            addTrackingArea(NSTrackingArea(
                rect: gripCursorRect,
                options: hover.union([.cursorUpdate]),
                owner: self,
                userInfo: ["role": "grip"]
            ))
            return
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: hover.union([.inVisibleRect]),
            owner: self,
            userInfo: nil
        ))
    }

    private var pointerOnGrip = false

    /// SwiftUI's hosting view sets the arrow after this event. Set the hand again on the next turn.
    private func applyGripCursor(_ onGrip: Bool) {
        pointerOnGrip = onGrip
        let cursor: NSCursor = onGrip ? .openHand : .arrow
        cursor.set()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pointerOnGrip == onGrip else { return }
            cursor.set()
        }
    }

    private func reportPointer(_ event: NSEvent) {
        guard showsGripCursor else {
            onHover(true)
            return
        }
        let level = gripLevel(at: event.locationInWindow)
        onGripLevel(level)
        applyGripCursor(level == .on)
    }

    override func cursorUpdate(with event: NSEvent) {
        if showsGripCursor {
            applyGripCursor(gripLevel(at: event.locationInWindow) == .on)
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard showsGripCursor else { return }
        reportPointer(event)
    }

    override func mouseEntered(with event: NSEvent) {
        let role = event.trackingArea?.userInfo?["role"] as? String
        if showsGripCursor, role == "grip" {
            onGripLevel(.on)
            applyGripCursor(true)
            return
        }
        reportPointer(event)
    }

    override func mouseExited(with event: NSEvent) {
        guard showsGripCursor else {
            onHover(false)
            return
        }
        let role = event.trackingArea?.userInfo?["role"] as? String
        if role == "grip" {
            let local = convert(event.locationInWindow, from: nil)
            if bounds.contains(local), !gripCursorRect.contains(local) {
                onGripLevel(.near)
                applyGripCursor(false)
                return
            }
        }
        onGripLevel(nil)
        applyGripCursor(false)
        // The inner area can exit after the outer one and report a point still inside the header.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let level = self.gripLevel(at: window.mouseLocationOutsideOfEventStream)
            self.onGripLevel(level)
            self.applyGripCursor(level == .on)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow
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
            let point = event.locationInWindow
            if event.type == .leftMouseUp {
                if dragging {
                    self.onEnded(point)
                } else {
                    self.onClick()
                }
                if pushedHand {
                    NSCursor.pop()
                }
                stop.pointee = true
                return
            }
            if !dragging, hypot(point.x - start.x, point.y - start.y) >= 6 {
                dragging = true
                if self.showsGripCursor {
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

}

private struct TabDragHandle: NSViewRepresentable {
    var onClick: () -> Void
    var onHover: (Bool) -> Void = { _ in }
    var onGripLevel: (GripLevel?) -> Void = { _ in }
    var onBegan: () -> Void
    var onMoved: (NSPoint) -> Void
    var onEnded: (NSPoint) -> Void
    var showsGripCursor = false

    func makeNSView(context: Context) -> TabDragHandleView { TabDragHandleView() }

    func updateNSView(_ view: TabDragHandleView, context: Context) {
        view.onClick = onClick
        view.onHover = onHover
        view.onGripLevel = onGripLevel
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
        view.showsGripCursor = showsGripCursor
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
    /// Room above the terminal text for the host badge (sidebar layout only).
    static let sidebarHeaderHeight: CGFloat = 44

    @Environment(\.windowChrome) private var chrome
    @ObservedObject var model: AppModel
    var dropRelay: CanvasDropRelay
    var dark: Bool
    var usesCatalogTheme: Bool
    /// Horizontal Otty chrome already shows the session title — skip the per-pane badge.
    var showsPaneHeader: Bool = true
    @State private var ratioDrag: (id: UUID, start: CGFloat)?
    @State private var gripTabID: UUID?
    @State private var gripLevel: GripLevel?

    private var headerHeight: CGFloat {
        showsPaneHeader ? Self.sidebarHeaderHeight : 0
    }

    var body: some View {
        GeometryReader { geo in
            let root = model.displayRoot()
            let bounds = CGRect(origin: .zero, size: geo.size)
            let frames = root.map { PaneLayout.frames(of: $0, in: bounds) } ?? [:]
            let dividers = root.map { PaneLayout.dividers(of: $0, in: bounds) } ?? []
            let headerH = headerHeight
            let _ = dropRelay.sync(frames: frames, model: model)
            ZStack(alignment: .topLeading) {
                chrome.background
                ForEach(model.tabs.filter { $0.alias != nil }) { tab in
                    let content = frames[tab.id].map { Self.contentFrame($0, headerHeight: headerH) }
                    SSHTerminalView(
                        sessionID: tab.sessionID,
                        alias: tab.alias ?? "",
                        environment: model.launchEnvironment,
                        dark: dark,
                        usesCatalogTheme: usesCatalogTheme,
                        onExit: { model.markClosed(tab.id) },
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
            }
            .overlay {
                PaneDropCatcher(relay: dropRelay)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
            }
        }
    }

    private func dividerControl(_ divider: PaneDivider) -> some View {
        Rectangle()
            .fill(chrome.hairline)
            .frame(width: divider.frame.width, height: divider.frame.height)
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

    @ViewBuilder
    private func paneChrome(_ tab: TerminalTab, frame: CGRect, headerHeight: CGFloat) -> some View {
        let alias = tab.alias ?? ""
        let focused = model.selectedTabID == tab.id
        if headerHeight > 0 {
            let level: GripLevel? = gripTabID == tab.id ? gripLevel : nil
            ZStack {
                chrome.background
                VStack(spacing: 2) {
                    Text(model.host(alias)?.sessionBadge ?? alias)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(chrome.text)
                        .lineLimit(1)
                        .onTapGesture { model.selectTab(tab.id) }
                    ZStack {
                        Capsule()
                            .fill(chrome.text.opacity(TerminalCanvas.gripOpacity(level)))
                            .frame(width: TerminalCanvas.gripWidth(level), height: 4)
                            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: level)
                        TabDragHandle(
                            onClick: { model.selectTab(tab.id) },
                            onGripLevel: { next in
                                if let next {
                                    gripTabID = tab.id
                                    gripLevel = next
                                } else if gripTabID == tab.id {
                                    gripTabID = nil
                                    gripLevel = nil
                                }
                            },
                            onBegan: { dropRelay.dragBegan(tab.id) },
                            onMoved: { dropRelay.dragMoved(windowPoint: $0) },
                            onEnded: { dropRelay.dragEnded(windowPoint: $0) },
                            showsGripCursor: true
                        )
                    }
                    .frame(width: 168, height: 22)
                    .help(String(localized: "Drag to the top, bottom, left, or right of a pane to merge. Drag back to the sidebar to separate it."))
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: frame.width, height: headerHeight)
            .position(x: frame.midX, y: frame.minY + headerHeight / 2)
            .zIndex(4)
        }
        if focused, tab.exited {
            Button("Reconnect") { model.reconnect(tab.id) }
                .position(x: frame.midX, y: frame.maxY - 28)
                .zIndex(4)
        }
    }
}

private extension TerminalCanvas {
    static func gripWidth(_ level: GripLevel?) -> CGFloat {
        if level == .on {
            return 36
        }
        return 16
    }

    static func gripOpacity(_ level: GripLevel?) -> Double {
        if level == .on {
            return 0.9
        }
        if level == .near {
            return 0.55
        }
        return 0
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
            Text("Choose a Host")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(chrome.text)
                .padding(.horizontal, 28)
                .padding(.top, 28)
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
