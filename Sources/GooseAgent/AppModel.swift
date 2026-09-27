import AppKit
import Foundation

enum TabDropHighlight: Equatable {
    case edge(UUID, SplitEdge)
    case sidebarRow(UUID)
    case sidebar
    case workspace(UUID)
}

struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    var alias: String?
    /// Local shell directory. Nil for an SSH host.
    var directory: String? = nil
    var generation: Int
    var exited: Bool

    var sessionID: String { "\(id.uuidString)#\(generation)" }

    /// A local login shell. An SSH alias wins when both are set.
    var isLocal: Bool {
        if let alias, !alias.isEmpty { return false }
        if let directory, !directory.isEmpty { return true }
        return false
    }

    /// SSH host or local shell. Empty placeholder tabs are neither.
    var isSession: Bool {
        if let alias, !alias.isEmpty { return true }
        return isLocal
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var hosts: [SSHHost] = []
    @Published private(set) var configFailed = false
    @Published private(set) var tabs: [TerminalTab] = []
    @Published var selectedTabID: UUID?
    /// Sidebar multi-select. Not written into the session snapshot.
    @Published private(set) var sidebarSelection: Set<UUID> = []
    private var sidebarAnchor: UUID?
    @Published private(set) var launchEnvironment: [String] = []
    /// Merged terminals. A single host is not stored here. Each workspace is one split tree.
    @Published private(set) var workspaces: [Workspace] = []
    @Published var draggingTabID: UUID?
    @Published var dropHighlight: TabDropHighlight?
    @Published var hostPickerPresented = false
    @Published var showingSettings = false
    private var dropEpoch = 0
    private var lastExternalKey = ""
    private var lastExternalAt = Date.distantPast
    /// Writes wait until the saved session has been read, so an empty launch cannot erase it.
    private var acceptSessionWrites = false

    var selectedTab: TerminalTab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    /// What the terminal area shows. A selected terminal outside every workspace is shown on its own.
    func displayRoot() -> PaneNode? {
        guard let selectedTabID else { return nil }
        guard tabs.first(where: { $0.id == selectedTabID })?.isSession == true else { return nil }
        if let found = WorkspaceBoard.index(containing: selectedTabID, in: workspaces) {
            return workspaces[found].layout
        }
        return .leaf(selectedTabID)
    }

    func tabs(in workspace: Workspace) -> [TerminalTab] {
        var members: [TerminalTab] = []
        for id in WorkspaceBoard.leafIDs(workspace.layout) {
            if let tab = tabs.first(where: { $0.id == id }) {
                members.append(tab)
            }
        }
        return members
    }

    var standaloneTabs: [TerminalTab] {
        tabs.filter { tab in
            WorkspaceBoard.index(containing: tab.id, in: workspaces) == nil
        }
    }

    var workspacesByNumber: [Workspace] {
        workspaces.sorted { $0.number < $1.number }
    }

    func workspaceContains(_ tab: UUID, _ workspaceID: UUID) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return false }
        return WorkspaceBoard.index(containing: tab, in: workspaces) == index
    }

    func host(_ alias: String) -> SSHHost? {
        hosts.first { $0.alias == alias }
    }

    func reloadHosts() {
        let result = SSHConfig.load()
        hosts = result.hosts
        configFailed = result.failed
    }

    func newTab() {
        reloadHosts()
        hostPickerPresented = true
    }

    func selectTab(_ id: UUID) {
        selectedTabID = id
        if sidebarAnchor == nil {
            sidebarAnchor = id
        }
        persistSession()
        guard let tab = tabs.first(where: { $0.id == id }), tab.isSession, !tab.exited else { return }
        SSHTerminalRegistry.focus(tab.sessionID)
    }

    /// A plain click, including a pane header. The sidebar selection becomes this one host.
    func selectOnly(_ id: UUID) {
        sidebarSelection = [id]
        sidebarAnchor = id
        selectTab(id)
    }

    func isSidebarSelected(_ id: UUID) -> Bool {
        if sidebarSelection.isEmpty {
            return selectedTabID == id
        }
        return sidebarSelection.contains(id)
    }

    /// Sidebar order: workspaces by number, members in pane order, then ungrouped hosts.
    func sidebarOrder() -> [UUID] {
        var ids: [UUID] = []
        for workspace in workspacesByNumber {
            ids.append(contentsOf: WorkspaceBoard.leafIDs(workspace.layout))
        }
        for tab in standaloneTabs {
            ids.append(tab.id)
        }
        return ids
    }

    /// Command toggles one host. Shift selects the contiguous sidebar range from the anchor.
    func clickSidebar(_ id: UUID, command: Bool, shift: Bool) {
        if sidebarAnchor == nil {
            sidebarAnchor = selectedTabID
        }
        let order = sidebarOrder()
        if shift, let anchor = sidebarAnchor, let start = order.firstIndex(of: anchor), let end = order.firstIndex(of: id) {
            let lower = min(start, end)
            let upper = max(start, end)
            sidebarSelection = Set(order[lower...upper])
            selectTab(id)
            return
        }
        if command {
            var next = sidebarSelection
            if next.isEmpty, let selectedTabID {
                next.insert(selectedTabID)
            }
            if next.contains(id) {
                next.remove(id)
                if next.isEmpty {
                    next.insert(id)
                }
            } else {
                next.insert(id)
            }
            sidebarSelection = next
            sidebarAnchor = id
            selectTab(id)
            return
        }
        selectOnly(id)
    }

    /// Palette slot when this host alias appears more than once, in a workspace or under Ungrouped.
    func duplicateHostMark(for tabID: UUID) -> Int? {
        guard let alias = tabs.first(where: { $0.id == tabID })?.alias, !alias.isEmpty else { return nil }
        var aliases: [String] = []
        for id in sidebarOrder() {
            guard let name = tabs.first(where: { $0.id == id })?.alias, !name.isEmpty else { continue }
            aliases.append(name)
        }
        return DuplicateHostColor.index(for: alias, among: aliases)
    }

    /// Hosts that already share one workspace are split back out, not merged again.
    func sidebarSplits(_ ids: [UUID]) -> Bool {
        guard let first = ids.first else { return false }
        guard let workspace = WorkspaceBoard.index(containing: first, in: workspaces) else { return false }
        for id in ids {
            if WorkspaceBoard.index(containing: id, in: workspaces) != workspace {
                return false
            }
        }
        return true
    }

    /// Right-click on a selected row applies to the whole set. Any other row applies to itself.
    func sidebarTargets(clicking id: UUID) -> [UUID] {
        if sidebarSelection.contains(id) {
            let chosen = sidebarSelection
            return sidebarOrder().filter { chosen.contains($0) }
        }
        return [id]
    }

    /// The terminal became first responder. Do not ask it to focus again.
    /// A multi-select stays put so focusing a pane does not drop the set.
    func notePaneFocused(_ id: UUID) {
        selectedTabID = id
        if sidebarSelection.count <= 1 {
            sidebarSelection = [id]
            sidebarAnchor = id
        }
        persistSession()
    }

    func openHost(_ alias: String) {
        openHosts([alias])
    }

    /// Opens one tab per SSH config alias. The same URL delivered twice in a short
    /// window (AppDelegate and SwiftUI) is ignored.
    /// One host stays under Ungrouped. Two or three stack vertically.
    /// Four or more open as a grid.
    func openExternalURL(_ url: URL) {
        let aliases = ExternalOpen.hostAliases(from: url)
        guard !aliases.isEmpty else { return }
        let key = aliases.joined(separator: "\n")
        let now = Date()
        if key == lastExternalKey, now.timeIntervalSince(lastExternalAt) < 0.4 {
            return
        }
        lastExternalKey = key
        lastExternalAt = now
        openHosts(aliases)
    }

    func openHosts(_ aliases: [String]) {
        let aliases = aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !aliases.isEmpty else { return }
        hostPickerPresented = false
        activateMainWindow()
        Task {
            let environment = await SSHLaunchEnvironment.shared.get()
            guard !Task.isCancelled else { return }
            launchEnvironment = environment
            var created: [UUID] = []
            for alias in aliases {
                let tab = TerminalTab(id: UUID(), alias: alias, generation: 0, exited: false)
                tabs.append(tab)
                created.append(tab.id)
            }
            if created.count >= 2 {
                workspaces = WorkspaceBoard.merge(created, in: workspaces)
                let layout: WorkspaceLayout = created.count >= 4 ? .grid : .rows
                if let index = WorkspaceBoard.index(containing: created[0], in: workspaces) {
                    workspaces[index] = WorkspaceBoard.apply(layout, to: workspaces[index])
                }
                sidebarSelection = Set(created)
                sidebarAnchor = created[0]
                selectedTabID = created[0]
            } else if let only = created.first {
                selectedTabID = only
                sidebarSelection = [only]
                sidebarAnchor = only
            }
            persistSession()
        }
    }

    /// Opens a local login shell in the user home directory.
    func openLocalTerminal() {
        let directory = LocalTerminal.launchDirectory(LocalTerminal.homeDirectory)
        hostPickerPresented = false
        activateMainWindow()
        Task {
            let environment = await SSHLaunchEnvironment.shared.get()
            guard !Task.isCancelled else { return }
            launchEnvironment = environment
            let tab = TerminalTab(id: UUID(), alias: nil, directory: directory, generation: 0, exited: false)
            tabs.append(tab)
            selectedTabID = tab.id
            sidebarSelection = [tab.id]
            sidebarAnchor = tab.id
            persistSession()
        }
    }

    /// Reopens the tabs that were on screen when the app last quit, including a split.
    func restoreLastSession() {
        guard let snapshot = SessionSnapshot.load(), !snapshot.tabs.isEmpty else {
            acceptSessionWrites = true
            return
        }
        Task {
            let environment = await SSHLaunchEnvironment.shared.get()
            guard !Task.isCancelled else {
                acceptSessionWrites = true
                return
            }
            if !tabs.isEmpty {
                acceptSessionWrites = true
                persistSession()
                return
            }
            launchEnvironment = environment
            tabs = snapshot.tabs.compactMap { item in
                if let alias = item.alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
                    return TerminalTab(id: item.id, alias: alias, generation: 0, exited: false)
                }
                if let directory = item.directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
                    return TerminalTab(
                        id: item.id,
                        alias: nil,
                        directory: LocalTerminal.launchDirectory(directory),
                        generation: 0,
                        exited: false
                    )
                }
                return nil
            }
            if tabs.isEmpty {
                acceptSessionWrites = true
                return
            }
            let known = Set(tabs.map(\.id))
            workspaces = Self.workspaces(snapshot.workspaces, keeping: known)
            if let selected = snapshot.selected, known.contains(selected) {
                selectedTabID = selected
            } else {
                selectedTabID = tabs.last?.id
            }
            if let selectedTabID {
                sidebarSelection = [selectedTabID]
            } else {
                sidebarSelection = []
            }
            sidebarAnchor = selectedTabID
            acceptSessionWrites = true
            persistSession()
        }
    }

    func persistSessionIfReady() {
        persistSession()
    }

    func toggleSettings() {
        SettingsWindowController.shared.toggle(model: self)
    }

    func reconnect(_ tabID: UUID) {
        Task {
            let environment = await SSHLaunchEnvironment.shared.get()
            guard !Task.isCancelled, let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
            launchEnvironment = environment
            tabs[index].generation += 1
            tabs[index].exited = false
            selectedTabID = tabID
        }
    }

    /// Starts a new session for every closed terminal in the workspace.
    /// Terminals that are still connected keep their current session.
    func reconnectWorkspace(_ workspaceID: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        let closed = tabs(in: workspace).filter { $0.isSession && $0.exited }.map(\.id)
        guard !closed.isEmpty else { return }
        Task {
            let environment = await SSHLaunchEnvironment.shared.get()
            guard !Task.isCancelled else { return }
            launchEnvironment = environment
            for id in closed {
                guard let index = tabs.firstIndex(where: { $0.id == id }) else { continue }
                guard tabs[index].exited else { continue }
                tabs[index].generation += 1
                tabs[index].exited = false
            }
        }
    }

    func markClosed(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].exited = true
    }

    func closeTab(_ id: UUID) {
        closeTab(id, focusNext: true)
    }

    func closeTabs(_ ids: [UUID]) {
        for id in ids {
            closeTab(id, focusNext: false)
        }
        guard let selectedTabID,
              let tab = tabs.first(where: { $0.id == selectedTabID }),
              tab.isSession,
              !tab.exited else { return }
        SSHTerminalRegistry.focus(tab.sessionID)
    }

    private func closeTab(_ id: UUID, focusNext: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        workspaces = WorkspaceBoard.extract(id, from: workspaces)
        if selectedTabID == id {
            let next = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
            selectedTabID = next
            if focusNext, let next, let tab = tabs.first(where: { $0.id == next }), tab.isSession, !tab.exited {
                SSHTerminalRegistry.focus(tab.sessionID)
            }
        }
        sidebarSelection.remove(id)
        if sidebarAnchor == id {
            sidebarAnchor = selectedTabID
        }
        if sidebarSelection.isEmpty, let selectedTabID {
            sidebarSelection = [selectedTabID]
        }
        persistSession()
    }

    /// Opens another session of the same host, or another local shell in the same directory, and splits it.
    func duplicate(_ id: UUID, edge: SplitEdge) {
        guard edge == .right || edge == .bottom else { return }
        guard let source = tabs.first(where: { $0.id == id }) else { return }
        if source.isLocal {
            let live = SSHTerminalRegistry.currentWorkingDirectory(for: source.sessionID) ?? source.directory
            guard let live, !live.isEmpty else { return }
            duplicateSession(id, alias: nil, directory: LocalTerminal.launchDirectory(live), edge: edge)
            return
        }
        guard let alias = source.alias, !alias.isEmpty else { return }
        duplicateSession(id, alias: alias, directory: nil, edge: edge)
    }

    private func duplicateSession(_ id: UUID, alias: String?, directory: String?, edge: SplitEdge) {
        Task {
            let environment = await SSHLaunchEnvironment.shared.get()
            guard !Task.isCancelled else { return }
            guard let sourceIndex = tabs.firstIndex(where: { $0.id == id }) else { return }
            if let alias {
                guard tabs[sourceIndex].alias == alias else { return }
            } else {
                guard tabs[sourceIndex].isLocal else { return }
            }
            launchEnvironment = environment
            let copy = TerminalTab(id: UUID(), alias: alias, directory: directory, generation: 0, exited: false)
            tabs.insert(copy, at: sourceIndex + 1)
            workspaces = WorkspaceBoard.drop(dragged: copy.id, onto: id, edge: edge, in: workspaces)
            sidebarSelection = [copy.id]
            sidebarAnchor = copy.id
            selectTab(copy.id)
        }
    }

    func duplicateFocused(downward: Bool) {
        guard let selectedTabID else { return }
        duplicate(selectedTabID, edge: downward ? .bottom : .right)
    }

    func mergeSidebar(_ ids: [UUID]) {
        let ordered = sidebarOrder().filter { ids.contains($0) }
        guard ordered.count >= 2 else { return }
        let next = WorkspaceBoard.merge(ordered, in: workspaces)
        guard next != workspaces else { return }
        workspaces = next
        sidebarSelection = Set(ordered)
        if let first = ordered.first {
            sidebarAnchor = first
            selectTab(first)
        }
    }

    /// Pulls these hosts out of their workspace. A workspace with one host left dissolves.
    func splitSidebar(_ ids: [UUID]) {
        let ordered = sidebarOrder().filter { ids.contains($0) }
        guard sidebarSplits(ordered) else { return }
        var next = workspaces
        for id in ordered {
            next = WorkspaceBoard.extract(id, from: next)
        }
        guard next != workspaces else { return }
        workspaces = next
        sidebarSelection = Set(ordered)
        if let first = ordered.first {
            sidebarAnchor = first
            selectTab(first)
        }
    }

    func beginDrag(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id && $0.isSession }) else { return }
        draggingTabID = id
        dropEpoch += 1
    }

    func endDrag() {
        draggingTabID = nil
        dropHighlight = nil
        dropEpoch += 1
    }

    func noteDropEntered() {
        dropEpoch += 1
    }

    /// Clears a drag that left every drop target, without racing a move onto the sidebar.
    func noteDropExited() {
        dropHighlight = nil
        let epoch = dropEpoch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.dropEpoch == epoch else { return }
                self.endDrag()
            }
        }
    }

    /// The canvas missed the drop. A sidebar drop in the same mouse-up bumps the epoch first.
    func finishDragIfIdle() {
        let epoch = dropEpoch
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.draggingTabID != nil, self.dropEpoch == epoch else { return }
                self.endDrag()
            }
        }
    }

    func dropTab(_ dragged: UUID, onto target: UUID, edge: SplitEdge) {
        guard dragged != target else { endDrag(); return }
        guard tabs.contains(where: { $0.id == dragged && $0.isSession }) else { endDrag(); return }
        guard tabs.contains(where: { $0.id == target && $0.isSession }) else { endDrag(); return }
        workspaces = WorkspaceBoard.drop(dragged: dragged, onto: target, edge: edge, in: workspaces)
        selectedTabID = dragged
        endDrag()
        persistSession()
    }

    /// Sidebar order and the content panes are the same leaf sequence.
    func reorderWorkspaceMember(_ dragged: UUID, beside target: UUID, after: Bool) {
        guard dragged != target else { endDrag(); return }
        let next = WorkspaceBoard.moveLeaf(dragged, beside: target, after: after, in: workspaces)
        guard next != workspaces else { endDrag(); return }
        workspaces = next
        selectedTabID = dragged
        endDrag()
        persistSession()
    }

    /// A standalone host, or a member of another group, joins this workspace beside the chosen member.
    func joinWorkspace(_ dragged: UUID, _ workspaceID: UUID, beside target: UUID, after: Bool) {
        guard tabs.contains(where: { $0.id == dragged && $0.isSession }) else { endDrag(); return }
        let next = WorkspaceBoard.join(dragged, beside: target, after: after, to: workspaceID, in: workspaces)
        guard next != workspaces else { endDrag(); return }
        workspaces = next
        selectedTabID = dragged
        endDrag()
        persistSession()
    }

    /// A standalone host, or a member of another group, joins this workspace at the end of its sidebar order.
    func joinWorkspace(_ dragged: UUID, _ workspaceID: UUID) {
        guard tabs.contains(where: { $0.id == dragged && $0.isSession }) else { endDrag(); return }
        let next = WorkspaceBoard.join(dragged, to: workspaceID, in: workspaces)
        guard next != workspaces else { endDrag(); return }
        workspaces = next
        selectedTabID = dragged
        endDrag()
        persistSession()
    }

    func receiveSidebarDrop(_ dragged: UUID, beside target: UUID?, after: Bool) {
        guard tabs.contains(where: { $0.id == dragged }) else { endDrag(); return }
        workspaces = WorkspaceBoard.extract(dragged, from: workspaces)
        if let target, target != dragged, WorkspaceBoard.index(containing: target, in: workspaces) == nil {
            moveTab(dragged, beside: target, after: after)
        }
        selectedTabID = dragged
        endDrag()
        persistSession()
    }

    /// Stores a sidebar title. A blank name returns to the generated title.
    func renameWorkspace(_ id: UUID, to name: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored: String? = trimmed.isEmpty ? nil : trimmed
        if workspaces[index].name == stored { return }
        workspaces[index].name = stored
        persistSession()
    }

    /// Drops the workspace. Members stay open. Local shells show under Local Group; hosts show under Ungrouped.
    func dissolveWorkspace(_ workspaceID: UUID) {
        let next = WorkspaceBoard.dissolve(workspaceID, in: workspaces)
        guard next != workspaces else { return }
        workspaces = next
        persistSession()
    }

    func applyWorkspaceLayout(_ workspaceID: UUID, _ layout: WorkspaceLayout) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index] = WorkspaceBoard.apply(layout, to: workspaces[index])
        persistSession()
    }

    func setSplitRatio(_ id: UUID, to ratio: CGFloat) {
        workspaces = WorkspaceBoard.setRatio(id, to: ratio, in: workspaces)
        persistSession()
    }

    private func moveTab(_ id: UUID, beside other: UUID, after: Bool) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard let targetIndex = tabs.firstIndex(where: { $0.id == other }) else { return }
        var destination = targetIndex
        if after {
            destination += 1
        }
        if from < destination {
            destination -= 1
        }
        guard from != destination else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: destination)
    }

    func closeSelectedTab() {
        guard let selectedTabID else { return }
        closeTab(selectedTabID)
    }

    private func activateMainWindow() {
        NSApp.activate()
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }

    private func persistSession() {
        guard acceptSessionWrites else { return }
        for index in tabs.indices where tabs[index].isLocal {
            guard let live = SSHTerminalRegistry.currentWorkingDirectory(for: tabs[index].sessionID) else { continue }
            if tabs[index].directory != live {
                tabs[index].directory = live
            }
        }
        let snapshot = SessionSnapshot(
            tabs: tabs.compactMap { tab in
                if let alias = tab.alias, !alias.isEmpty {
                    return SessionSnapshot.Tab(id: tab.id, alias: alias, directory: nil)
                }
                guard let directory = tab.directory, !directory.isEmpty else { return nil }
                return SessionSnapshot.Tab(id: tab.id, alias: nil, directory: directory)
            },
            selected: selectedTabID,
            layout: nil,
            workspaces: workspaces
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: SessionSnapshot.storageKey)
    }

    private static func workspaces(_ workspaces: [Workspace], keeping known: Set<UUID>) -> [Workspace] {
        var kept: [Workspace] = []
        for workspace in workspaces {
            guard let layout = Self.layout(workspace.layout, keeping: known) else { continue }
            var workspace = workspace
            workspace.layout = layout
            kept.append(workspace)
        }
        return kept
    }

    private static func layout(_ node: PaneNode?, keeping known: Set<UUID>) -> PaneNode? {
        guard var node else { return nil }
        for id in WorkspaceBoard.leafIDs(node) where !known.contains(id) {
            guard let next = PaneLayout.remove(id, from: node) else { return nil }
            node = next
        }
        return PaneLayout.splitRoot(node)
    }
}

private struct SessionSnapshot: Codable {
    struct Tab: Codable {
        var id: UUID
        var alias: String?
        var directory: String? = nil
    }

    static let storageKey = "session.openTabs"

    var tabs: [Tab]
    var selected: UUID?
    /// Old snapshots stored one split here. New snapshots leave it nil and use `workspaces`.
    var layout: PaneNode?
    var workspaces: [Workspace]

    enum CodingKeys: String, CodingKey {
        case tabs
        case selected
        case layout
        case workspaces
    }

    init(tabs: [Tab], selected: UUID?, layout: PaneNode?, workspaces: [Workspace]) {
        self.tabs = tabs
        self.selected = selected
        self.layout = layout
        self.workspaces = workspaces
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try container.decode([Tab].self, forKey: .tabs)
        selected = try container.decodeIfPresent(UUID.self, forKey: .selected)
        layout = try container.decodeIfPresent(PaneNode.self, forKey: .layout)
        let stored = try container.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        if !stored.isEmpty {
            workspaces = stored
        } else if let layout, case .split = layout {
            workspaces = [Workspace(id: UUID(), number: 1, layout: layout)]
        } else {
            workspaces = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tabs, forKey: .tabs)
        try container.encodeIfPresent(selected, forKey: .selected)
        try container.encodeIfPresent(layout, forKey: .layout)
        try container.encode(workspaces, forKey: .workspaces)
    }

    static func load() -> SessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }
}
