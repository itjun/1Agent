import AppKit
import Foundation

enum TabDropHighlight: Equatable {
    case edge(UUID, SplitEdge)
    case sidebarRow(UUID)
    case sidebar
    case workspace(UUID)
}

/// Top-level sidebar blocks. Workspaces, Local Group, and Ungrouped can be reordered.
enum SidebarBlock: Equatable, Hashable, Codable {
    case workspace(UUID)
    case localGroup
    case ungrouped
}

struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    var alias: String?
    /// Local shell directory. Nil for an SSH host.
    var directory: String? = nil
    var generation: Int
    var exited: Bool
    /// Auto-reconnects already started after the latest disconnect streak.
    var reconnectAttempts: Int = 0
    /// Waiting for or starting an automatic reconnect.
    var reconnecting: Bool = false

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

    /// Unexpected disconnect that still needs a clear closed mark.
    var showsDisconnected: Bool {
        exited && !reconnecting
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
    /// Sidebar block order: workspaces, Local Group, Ungrouped. Persisted with the session.
    @Published private(set) var sidebarBlocks: [SidebarBlock] = [.localGroup, .ungrouped]
    @Published var draggingTabID: UUID?
    @Published var draggingBlock: SidebarBlock?
    @Published var dropHighlight: TabDropHighlight?
    @Published var hostPickerPresented = false
    @Published var showingSettings = false
    private var dropEpoch = 0
    private var lastExternalKey = ""
    private var lastExternalAt = Date.distantPast
    /// Writes wait until the saved session has been read, so an empty launch cannot erase it.
    private var acceptSessionWrites = false
    /// Delayed auto-reconnect work keyed by tab.
    private var autoReconnectTasks: [UUID: Task<Void, Never>] = [:]
    /// Clears the reconnect counter once a session has stayed up briefly.
    private var stableConnectionTasks: [UUID: Task<Void, Never>] = [:]

    private static let maxAutoReconnectAttempts = 3
    private static let autoReconnectDelayNanoseconds: UInt64 = 1_000_000_000
    private static let stableConnectionNanoseconds: UInt64 = 5_000_000_000

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

    func workspace(for id: UUID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    func workspaceContains(_ tab: UUID, _ workspaceID: UUID) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return false }
        return WorkspaceBoard.index(containing: tab, in: workspaces) == index
    }

    /// Keeps every live workspace in `sidebarBlocks`, and always retains Local Group / Ungrouped slots.
    func syncSidebarBlocks() {
        let known = Set(workspaces.map(\.id))
        var next: [SidebarBlock] = []
        var seenWorkspace = Set<UUID>()
        var hasLocal = false
        var hasRemote = false
        for block in sidebarBlocks {
            switch block {
            case .workspace(let id):
                guard known.contains(id), seenWorkspace.insert(id).inserted else { continue }
                next.append(block)
            case .localGroup:
                guard !hasLocal else { continue }
                hasLocal = true
                next.append(block)
            case .ungrouped:
                guard !hasRemote else { continue }
                hasRemote = true
                next.append(block)
            }
        }
        for workspace in workspacesByNumber where seenWorkspace.insert(workspace.id).inserted {
            if let localIndex = next.firstIndex(of: .localGroup) {
                next.insert(.workspace(workspace.id), at: localIndex)
            } else if let remoteIndex = next.firstIndex(of: .ungrouped) {
                next.insert(.workspace(workspace.id), at: remoteIndex)
            } else {
                next.append(.workspace(workspace.id))
            }
        }
        if !hasLocal {
            next.append(.localGroup)
        }
        if !hasRemote {
            next.append(.ungrouped)
        }
        if next != sidebarBlocks {
            sidebarBlocks = next
        }
    }

    func reorderSidebarBlock(_ dragged: SidebarBlock, beside target: SidebarBlock, after: Bool) {
        guard dragged != target else {
            draggingBlock = nil
            return
        }
        guard let from = sidebarBlocks.firstIndex(of: dragged) else {
            draggingBlock = nil
            return
        }
        var blocks = sidebarBlocks
        blocks.remove(at: from)
        guard let targetIndex = blocks.firstIndex(of: target) else {
            draggingBlock = nil
            return
        }
        var destination = targetIndex
        if after {
            destination += 1
        }
        blocks.insert(dragged, at: destination)
        sidebarBlocks = blocks
        draggingBlock = nil
        persistSession()
    }

    func beginBlockDrag(_ block: SidebarBlock) {
        draggingTabID = nil
        draggingBlock = block
        dropHighlight = nil
    }

    func endBlockDrag() {
        draggingBlock = nil
        dropHighlight = nil
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

    /// Sidebar order: follows `sidebarBlocks`, members in pane order inside each workspace.
    func sidebarOrder() -> [UUID] {
        var ids: [UUID] = []
        let standalone = standaloneTabs
        for block in sidebarBlocks {
            switch block {
            case .workspace(let id):
                guard let workspace = workspace(for: id) else { continue }
                ids.append(contentsOf: WorkspaceBoard.leafIDs(workspace.layout))
            case .localGroup:
                ids.append(contentsOf: standalone.filter(\.isLocal).map(\.id))
            case .ungrouped:
                ids.append(contentsOf: standalone.filter { !$0.isLocal }.map(\.id))
            }
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

    /// A proper subset of one workspace (two or more) can leave that group as a new workspace.
    func sidebarCanCreateArea(_ ids: [UUID]) -> Bool {
        guard ids.count >= 2 else { return false }
        guard let first = ids.first,
              let index = WorkspaceBoard.index(containing: first, in: workspaces) else {
            return false
        }
        for id in ids {
            if WorkspaceBoard.index(containing: id, in: workspaces) != index {
                return false
            }
        }
        let members = Set(WorkspaceBoard.leafIDs(workspaces[index].layout))
        return Set(ids).isStrictSubset(of: members)
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
            sidebarBlocks = snapshot.sidebarBlocks ?? []
            syncSidebarBlocks()
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
            guard !Task.isCancelled else { return }
            beginReconnect(tabID, environment: environment, automatic: false)
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
            for id in closed {
                beginReconnect(id, environment: environment, automatic: false)
            }
        }
    }

    /// SSH transport ended. Auto-reconnects up to three times, then stays marked closed.
    func markClosed(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        cancelStableConnection(tabID)
        tabs[index].exited = true
        if tabs[index].isLocal {
            tabs[index].reconnecting = false
            cancelAutoReconnect(tabID)
            return
        }
        if tabs[index].reconnectAttempts < Self.maxAutoReconnectAttempts {
            scheduleAutoReconnect(tabID)
        } else {
            tabs[index].reconnecting = false
            cancelAutoReconnect(tabID)
        }
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
        cancelAutoReconnect(id)
        cancelStableConnection(id)
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

    /// Next or previous pane of the visible workspace in sidebar order, wrapping at the ends.
    /// Returns false when there is nothing to switch to, so the key can reach the terminal.
    func focusAdjacentPane(forward: Bool) -> Bool {
        guard let selectedTabID, let root = displayRoot() else { return false }
        let ids = WorkspaceBoard.leafIDs(root)
        guard ids.count >= 2, let index = ids.firstIndex(of: selectedTabID) else { return false }
        var next = index + (forward ? 1 : -1)
        if next < 0 {
            next = ids.count - 1
        } else if next >= ids.count {
            next = 0
        }
        selectTab(ids[next])
        return true
    }

    /// The pane on that side of the current one, by on-screen position. At the edge of a split the key is still consumed.
    func focusPane(toward direction: PaneDirection) -> Bool {
        guard let selectedTabID, let root = displayRoot() else { return false }
        let frames = PaneLayout.frames(of: root, in: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        guard frames.count >= 2 else { return false }
        guard let target = PaneLayout.neighbor(of: selectedTabID, toward: direction, frames: frames) else {
            return true
        }
        selectTab(target)
        return true
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

    /// Moves a proper subset of a workspace into a newly numbered workspace.
    func createAreaFromSidebar(_ ids: [UUID]) {
        guard sidebarCanCreateArea(ids) else { return }
        mergeSidebar(ids)
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
        draggingBlock = nil
        draggingTabID = id
        dropEpoch += 1
    }

    func endDrag() {
        draggingTabID = nil
        draggingBlock = nil
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

    private func beginReconnect(_ tabID: UUID, environment: [String], automatic: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard tabs[index].isSession, !tabs[index].isLocal else { return }
        if automatic {
            guard tabs[index].exited else { return }
            guard tabs[index].reconnectAttempts < Self.maxAutoReconnectAttempts else {
                tabs[index].reconnecting = false
                return
            }
            tabs[index].reconnectAttempts += 1
        } else {
            cancelAutoReconnect(tabID)
            tabs[index].reconnectAttempts = 0
        }
        // The new surface is starting; keep the closed mark only while waiting to retry.
        tabs[index].reconnecting = false
        launchEnvironment = environment
        tabs[index].generation += 1
        tabs[index].exited = false
        scheduleStableConnection(tabID)
    }

    private func scheduleAutoReconnect(_ tabID: UUID) {
        cancelAutoReconnect(tabID)
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard tabs[index].exited, !tabs[index].isLocal else { return }
        guard tabs[index].reconnectAttempts < Self.maxAutoReconnectAttempts else {
            tabs[index].reconnecting = false
            return
        }
        tabs[index].reconnecting = true
        autoReconnectTasks[tabID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.autoReconnectDelayNanoseconds)
            guard !Task.isCancelled else { return }
            let environment = await SSHLaunchEnvironment.shared.get()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.autoReconnectTasks[tabID] = nil
                self.beginReconnect(tabID, environment: environment, automatic: true)
            }
        }
    }

    private func cancelAutoReconnect(_ tabID: UUID) {
        autoReconnectTasks[tabID]?.cancel()
        autoReconnectTasks[tabID] = nil
    }

    private func scheduleStableConnection(_ tabID: UUID) {
        cancelStableConnection(tabID)
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let generation = tabs[index].generation
        stableConnectionTasks[tabID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.stableConnectionNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.stableConnectionTasks[tabID] = nil
                guard let index = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                guard self.tabs[index].generation == generation, !self.tabs[index].exited else { return }
                self.tabs[index].reconnectAttempts = 0
                self.tabs[index].reconnecting = false
            }
        }
    }

    private func cancelStableConnection(_ tabID: UUID) {
        stableConnectionTasks[tabID]?.cancel()
        stableConnectionTasks[tabID] = nil
    }

    private func persistSession() {
        guard acceptSessionWrites else { return }
        for index in tabs.indices where tabs[index].isLocal {
            guard let live = SSHTerminalRegistry.currentWorkingDirectory(for: tabs[index].sessionID) else { continue }
            if tabs[index].directory != live {
                tabs[index].directory = live
            }
        }
        syncSidebarBlocks()
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
            workspaces: workspaces,
            sidebarBlocks: sidebarBlocks
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
    var sidebarBlocks: [SidebarBlock]?

    enum CodingKeys: String, CodingKey {
        case tabs
        case selected
        case layout
        case workspaces
        case sidebarBlocks
    }

    init(
        tabs: [Tab],
        selected: UUID?,
        layout: PaneNode?,
        workspaces: [Workspace],
        sidebarBlocks: [SidebarBlock]? = nil
    ) {
        self.tabs = tabs
        self.selected = selected
        self.layout = layout
        self.workspaces = workspaces
        self.sidebarBlocks = sidebarBlocks
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
        sidebarBlocks = try container.decodeIfPresent([SidebarBlock].self, forKey: .sidebarBlocks)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tabs, forKey: .tabs)
        try container.encodeIfPresent(selected, forKey: .selected)
        try container.encodeIfPresent(layout, forKey: .layout)
        try container.encode(workspaces, forKey: .workspaces)
        try container.encodeIfPresent(sidebarBlocks, forKey: .sidebarBlocks)
    }

    static func load() -> SessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }
}
