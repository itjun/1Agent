import GhosttyTheme
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppShortcuts.revisionKey) private var shortcutsRevision = 0
    @AppStorage(TabPlacement.storageKey) private var tabLayoutRaw = TabPlacement.vertical.rawValue
    @AppStorage(TerminalAppearance.storageKey) private var appearanceRaw = TerminalAppearance.system.rawValue
    @AppStorage(TerminalThemeFamily.storageKey) private var themeFamilyRaw = TerminalThemeFamily.github.rawValue
    @AppStorage("appearance.sidebarCollapsed") private var sidebarCollapsed = false

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
                        horizontalTabs
                            .padding(.leading, 78)
                            .padding(.top, 8)
                        Rectangle().fill(chrome.hairline).frame(height: 1)
                        detail
                    }
                case .bottom:
                    VStack(spacing: 0) {
                        detail
                        Rectangle().fill(chrome.hairline).frame(height: 1)
                        horizontalTabs
                            .padding(.bottom, 6)
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if sidebarCollapsed {
                HStack(spacing: 8) {
                    windowControls
                    settingsEntry
                        .frame(width: 88)
                }
                .padding(.leading, 78)
                .padding(.top, 10)
            }
        }
        .frame(minWidth: 880, minHeight: 520)
        .background(chrome.background)
        .environment(\.windowChrome, chrome)
        .ignoresSafeArea(edges: .top)
        .preferredColorScheme(appearance.preferredColorScheme)
        .gooseagentHideFocusRing()
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
        .sheet(isPresented: $model.hostPickerPresented) {
            HostPicker(model: model)
                .frame(width: SheetLayout.search, height: SheetLayout.sessionBodyHeight)
                .environment(\.windowChrome, chrome)
                .gooseagentHideFocusRing()
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
                Text("Tabs")
                    .font(Theme.sidebarGroupHeader)
                    .foregroundStyle(chrome.text)
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
                        ForEach(model.tabs) { tab in
                            tabRow(tab, compact: false)
                        }
                        Color.clear
                            .frame(height: 36)
                            .onDrop(of: TabDrag.types, isTargeted: nil) { _ in
                                guard let dragged = model.draggingTabID else { return false }
                                model.receiveSidebarDrop(dragged, before: nil)
                                return true
                            }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
            settingsEntry
        }
        .onDrop(of: TabDrag.types, isTargeted: sidebarTargeted) { _ in
            guard let dragged = model.draggingTabID else { return false }
            model.receiveSidebarDrop(dragged, before: nil)
            return true
        }
    }

    private var horizontalTabs: some View {
        HStack(spacing: 6) {
            windowControls
                .padding(.leading, 8)

            if model.tabs.isEmpty {
                Text("No open terminals")
                    .font(Theme.sidebarRowMeta)
                    .foregroundStyle(chrome.secondary)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.tabs) { tab in
                            tabRow(tab, compact: true)
                                .frame(width: 180)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.trailing, 8)
                }
            }
            settingsEntry
                .frame(width: 88)
        }
        .frame(height: 44)
        .onDrop(of: TabDrag.types, isTargeted: sidebarTargeted) { _ in
            guard let dragged = model.draggingTabID else { return false }
            model.receiveSidebarDrop(dragged, before: nil)
            return true
        }
    }

    private var settingsHelp: String {
        String(format: String(localized: "Settings (%@)"), AppShortcuts.display(for: .settings))
    }

    private var settingsEntry: some View {
        Button {
            model.toggleSettings()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                Text("Settings")
                    .font(Theme.sidebarRowTitle)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(chrome.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(model.showingSettings ? chrome.accent.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(settingsHelp)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(chrome.hairline).frame(height: 1)
        }
    }

    private var sidebarTargeted: Binding<Bool> {
        Binding(
            get: { model.dropHighlight == .sidebar },
            set: { isTargeted in
                if isTargeted {
                    model.noteDropEntered()
                    model.dropHighlight = .sidebar
                } else if model.dropHighlight == .sidebar {
                    model.dropHighlight = nil
                }
            }
        )
    }

    private func tabRow(_ tab: TerminalTab, compact: Bool) -> some View {
        let selected = model.selectedTabID == tab.id && !model.showingSettings
        let host = tab.alias.flatMap { model.host($0) }
        return HStack(spacing: 6) {
            Button {
                model.selectTab(tab.id)
            } label: {
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFill(selected: selected, tabID: tab.id))
        )
        .onDrag {
            guard tab.alias != nil else { return NSItemProvider() }
            model.beginDrag(tab.id)
            return NSItemProvider(object: (tab.alias ?? "") as NSString)
        }
        .onDrop(of: TabDrag.types, isTargeted: rowTargeted(tab.id)) { _ in
            guard let dragged = model.draggingTabID else { return false }
            model.receiveSidebarDrop(dragged, before: tab.id)
            return true
        }
    }

    private func rowFill(selected: Bool, tabID: UUID) -> Color {
        if model.dropHighlight == .sidebarRow(tabID) || model.dropHighlight == .sidebar {
            return chrome.accent.opacity(0.28)
        }
        return selected ? chrome.accent.opacity(0.16) : Color.clear
    }

    private func rowTargeted(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { model.dropHighlight == .sidebarRow(id) },
            set: { isTargeted in
                if isTargeted {
                    model.noteDropEntered()
                    model.dropHighlight = .sidebarRow(id)
                } else if model.dropHighlight == .sidebarRow(id) {
                    model.noteDropExited()
                }
            }
        )
    }

    private var detail: some View {
        ZStack {
            TerminalCanvas(
                model: model,
                dark: appearance.isDark(system: colorScheme),
                usesCatalogTheme: true
            )
            .opacity(model.showingSettings ? 0 : 1)
            .allowsHitTesting(!model.showingSettings)
            if model.showingSettings {
                SettingsView()
            } else if model.selectedTab == nil {
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
}

private enum TabDrag {
    static let types: [UTType] = [.plainText, .utf8PlainText]
}

private final class CanvasDropRelay: ObservableObject, DropDelegate {
    var frames: [UUID: CGRect] = [:]
    weak var modelBox: AppModel?

    func dropEntered(info: DropInfo) {
        modelBox?.noteDropEntered()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let model = modelBox, let dragged = model.draggingTabID else { return nil }
        guard let hit = Self.hit(info.location, frames: frames, dragged: dragged) else {
            model.dropHighlight = nil
            return DropProposal(operation: .move)
        }
        model.noteDropEntered()
        model.dropHighlight = .edge(hit.0, hit.1)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        modelBox?.noteDropExited()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let model = modelBox, let dragged = model.draggingTabID else { return false }
        guard let hit = Self.hit(info.location, frames: frames, dragged: dragged) else {
            model.endDrag()
            return false
        }
        model.dropTab(dragged, onto: hit.0, edge: hit.1)
        return true
    }

    private static func hit(_ point: CGPoint, frames: [UUID: CGRect], dragged: UUID) -> (UUID, SplitEdge)? {
        for (id, frame) in frames where frame.contains(point) {
            let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
            if let edge = SplitEdge.at(local, in: frame.size), id != dragged {
                return (id, edge)
            }
        }
        return nil
    }
}

private struct TerminalCanvas: View {
    /// Room above the terminal text for the host badge, so the two do not share a line.
    static let headerHeight: CGFloat = 44

    @Environment(\.windowChrome) private var chrome
    @ObservedObject var model: AppModel
    var dark: Bool
    var usesCatalogTheme: Bool
    @StateObject private var dropRelay = CanvasDropRelay()
    @State private var ratioDrag: (id: UUID, start: CGFloat)?

    var body: some View {
        GeometryReader { geo in
            let root = model.displayRoot()
            let bounds = CGRect(origin: .zero, size: geo.size)
            let frames = root.map { PaneLayout.frames(of: $0, in: bounds) } ?? [:]
            let dividers = root.map { PaneLayout.dividers(of: $0, in: bounds) } ?? []
            let _ = dropRelay.sync(frames: frames, model: model)
            ZStack(alignment: .topLeading) {
                chrome.background
                ForEach(model.tabs.filter { $0.alias != nil }) { tab in
                    let content = frames[tab.id].map(Self.contentFrame)
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
                        paneChrome(tab, frame: frame)
                    }
                }
                if model.draggingTabID != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onDrop(of: TabDrag.types, delegate: dropRelay)
                        .zIndex(5)
                }
                if case .edge(let target, let edge) = model.dropHighlight, let frame = frames[target] {
                    let band = PaneLayout.highlight(for: edge, in: frame)
                    ZStack(alignment: .center) {
                        Rectangle().fill(chrome.accent.opacity(0.28))
                        Text("Split")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(chrome.text)
                    }
                    .frame(width: band.width, height: band.height)
                    .offset(x: band.minX, y: band.minY)
                    .allowsHitTesting(false)
                    .zIndex(6)
                }
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
            return find(split.leading) ?? find(split.trailing)
        }
        guard let layout = model.layout else { return 0.5 }
        return find(layout) ?? 0.5
    }

    @ViewBuilder
    private func paneChrome(_ tab: TerminalTab, frame: CGRect) -> some View {
        let alias = tab.alias ?? ""
        let focused = model.selectedTabID == tab.id
        ZStack {
            chrome.background
            Text(model.host(alias)?.sessionBadge ?? alias)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(chrome.text)
                .lineLimit(1)
                .help(String(localized: "Drag onto an edge to split, or back to the sidebar to dock."))
                .onDrag {
                    model.beginDrag(tab.id)
                    return NSItemProvider(object: (model.host(alias)?.sessionBadge ?? alias) as NSString)
                }
        }
        .frame(width: frame.width, height: Self.headerHeight)
        .position(x: frame.midX, y: frame.minY + Self.headerHeight / 2)
        .zIndex(4)
        if focused, tab.exited {
            Button("Reconnect") { model.reconnect(tab.id) }
                .position(x: frame.midX, y: frame.maxY - 28)
                .zIndex(4)
        }
    }
}

private extension TerminalCanvas {
    static func contentFrame(_ frame: CGRect) -> CGRect {
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
