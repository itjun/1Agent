import AppKit
import Foundation

enum TabDropHighlight: Equatable {
    case edge(UUID, SplitEdge)
    case sidebarRow(UUID)
    case sidebar
    /// A whole sidebar block is the landing zone (a block or a multi-drag merging into it).
    case block(SidebarBlock)
}

/// Top-level sidebar blocks. Workspaces, Local Group, and Ungrouped can be reordered.
/// Local Group and Ungrouped are loose groups: plain lists the user fills however they like.
/// Every window has its own two loose groups; a workspace is shown in exactly one window.
enum SidebarBlock: Equatable, Hashable, Codable {
    case workspace(UUID)
    case localGroup
    case ungrouped

    var isLoose: Bool {
        switch self {
        case .workspace: return false
        case .localGroup, .ungrouped: return true
        }
    }
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
    var content: PaneContent = .terminal
    /// Remote shell directory last reported through OSC 7. Memory only.
    var remoteDirectory: String? = nil

    var sessionID: String { "\(id.uuidString)#\(generation)" }

    /// A local login shell. An SSH alias wins when both are set.
    var isLocal: Bool {
        if let alias, !alias.isEmpty { return false }
        if let directory, !directory.isEmpty { return true }
        return false
    }

    /// SSH host, local shell, or a preview / file pane. Empty placeholder tabs are none of these.
    var isSession: Bool {
        if !content.isTerminal { return true }
        if let alias, !alias.isEmpty { return true }
        return isLocal
    }

    /// A session that runs in a terminal view.
    var hasTerminal: Bool {
        content.isTerminal && isSession
    }

    /// Unexpected disconnect that still needs a clear closed mark.
    var showsDisconnected: Bool {
        exited && !reconnecting
    }
}

/// Shared store. Terminals, workspaces, and hosts are global; each `WindowState` is one view onto them.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var hosts: [SSHHost] = []
    @Published private(set) var configFailed = false
    @Published private(set) var tabs: [TerminalTab] = []
    @Published private(set) var launchEnvironment: [String] = []
    /// Ordered membership and independently selectable display panels, including single-session workspaces.
    @Published private(set) var workspaces: [Workspace] = []
    /// The one main window. Every terminal and workspace shows in its sidebar.
    let mainWindow = WindowState()
    /// Kept for the loops that walk every window; there is only ever the main one.
    var windows: [WindowState] { [mainWindow] }
    @Published var showingSettings = false
    /// Set once the app starts quitting. Windows then close without taking their terminals along,
    /// so the snapshot written at exit still lists every session.
    var isQuitting = false
    private var lastExternalKey = ""
    private var lastExternalAt = Date.distantPast
    /// Writes wait until the saved session has been read, so an empty launch cannot erase it.
    private var acceptSessionWrites = false
    /// Set once the saved terminals are back (or there were none).
    private var sessionRestored = false
    /// Opens from Finder, `open`, other apps, or the command line that arrived before the
    /// saved session was back. A cold launch delivers them before `restoreLastSession` runs.
    private var openRequestsAwaitingRestore: [() -> Void] = []
    /// Text a new local shell types once, keyed by tab. Memory only; never saved with the session.
    private var pendingInitialInput: [UUID: String] = [:]
    /// Delayed auto-reconnect work keyed by tab.
    private var autoReconnectTasks: [UUID: Task<Void, Never>] = [:]
    /// Clears the reconnect counter once a session has stayed up briefly.
    private var stableConnectionTasks: [UUID: Task<Void, Never>] = [:]

    static let maxAutoReconnectAttempts = 3
    /// Backoff before automatic attempt 1, 2, 3.
    private static let autoReconnectDelays: [TimeInterval] = [1, 3, 8]
    private static let stableConnectionNanoseconds: UInt64 = 5_000_000_000
    /// A connection that dies faster than this never really worked (auth, config, refused).
    /// Retrying would only repeat the password prompt, so it is left to the user.
    static let shortLivedConnectionSeconds: TimeInterval = 3
    private var configWatcher: SSHConfigWatcher?

    // MARK: - Windows

    /// The main window. Optional only so the callers that fall back with `??` keep compiling.
    var keyWindow: WindowState? {
        mainWindow
    }

    func window(for id: UUID) -> WindowState? {
        windows.first { $0.id == id }
    }

    /// The window whose sidebar lists this terminal.
    func window(containing tab: UUID) -> WindowState? {
        windows.first { sidebarOrder(in: $0).contains(tab) }
    }

    func window(showing workspaceID: UUID) -> WindowState? {
        windows.first { $0.blocks.contains(.workspace(workspaceID)) }
    }

    /// The main window is closing, which quits the app. The snapshot written here is what the next launch restores.
    func windowClosed(_ window: WindowState) {
        persistSession()
    }

    // MARK: - Reading

    func selectedTab(in window: WindowState) -> TerminalTab? {
        guard let id = window.selectedTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    /// The tab whose current terminal is `sessionID`. Nil once a reconnect replaced that session.
    func tab(forSession sessionID: String) -> TerminalTab? {
        tabs.first { $0.sessionID == sessionID }
    }

    /// Host badge for a remote session, the short directory for a local one.
    func sessionTitle(_ tab: TerminalTab) -> String {
        if let title = tab.contentTitle {
            return title
        }
        if tab.isLocal, let directory = tab.directory {
            return LocalTerminal.displayPath(directory)
        }
        let alias = tab.alias ?? ""
        return host(alias)?.sessionBadge ?? alias
    }

    /// The pane is drawn in the main window right now, and that window is on screen.
    func isPaneOnScreen(_ id: UUID) -> Bool {
        guard let nsWindow = MainWindowManager.shared.window(for: mainWindow),
              nsWindow.isVisible, !nsWindow.isMiniaturized else { return false }
        if let zoomed = zoomedPane(in: mainWindow) {
            return zoomed == id
        }
        guard let root = displayRoot(in: mainWindow) else { return false }
        return WorkspaceBoard.leafIDs(root).contains(id)
    }

    // MARK: - Zoom

    func selectedPanel(in window: WindowState) -> TerminalPanel? {
        guard let selected = window.selectedTabID,
              let index = WorkspaceBoard.index(containing: selected, in: workspaces) else { return nil }
        return workspaces[index].panel(containing: selected)
    }

    private func clearPanelZoom(for ids: [UUID]) {
        let wanted = Set(ids)
        let panels = workspaces.flatMap(\.panels).filter { !wanted.isDisjoint(with: WorkspaceBoard.leafIDs($0.layout)) }
        for window in windows {
            for panel in panels { window.zoomedPanes[panel.id] = nil }
        }
    }

    /// Zoom belongs to a display panel, independently of the workspace's other panels.
    func zoomedPane(in window: WindowState) -> UUID? {
        guard let selected = window.selectedTabID, let panel = selectedPanel(in: window),
              window.zoomedPanes[panel.id] == selected,
              WorkspaceBoard.leafIDs(panel.layout).count >= 2 else { return nil }
        return selected
    }

    func toggleSplitZoom(in window: WindowState) {
        guard let selected = window.selectedTabID, let panel = selectedPanel(in: window),
              WorkspaceBoard.leafIDs(panel.layout).count >= 2 else { return }
        window.zoomedPanes[panel.id] = window.zoomedPanes[panel.id] == selected ? nil : selected
        if let tab = tabs.first(where: { $0.id == selected }), tab.hasTerminal, !tab.exited {
            SSHTerminalRegistry.focus(tab.sessionID)
        }
    }

    private func endZoomIfSwitching(to id: UUID, in window: WindowState) {
        guard let index = WorkspaceBoard.index(containing: id, in: workspaces),
              let panel = workspaces[index].panel(containing: id) else { return }
        if let zoomed = window.zoomedPanes[panel.id], zoomed != id {
            window.zoomedPanes[panel.id] = nil
        }
    }

    func displayRoot(in window: WindowState) -> PaneNode? {
        guard let selected = window.selectedTabID,
              tabs.first(where: { $0.id == selected })?.isSession == true else { return nil }
        return selectedPanel(in: window)?.layout ?? .leaf(selected)
    }

    func tabs(in workspace: Workspace) -> [TerminalTab] {
        var members: [TerminalTab] = []
        for id in workspace.members {
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

    /// The loose group a standalone terminal falls into when nobody has placed it yet.
    private func defaultLooseGroup(for tab: TerminalTab?) -> SidebarBlock {
        guard let tab else { return .ungrouped }
        switch tab.content {
        case .terminal:
            return tab.isLocal ? .localGroup : .ungrouped
        case .preview:
            return .localGroup
        }
    }

    /// Standalone terminals that no window lists. They show in the first window's default groups
    /// so nothing can disappear; `syncLooseMembers` then writes them down.
    private func unlistedStandalone() -> [TerminalTab] {
        var listed = Set<UUID>()
        for window in windows {
            for list in window.looseMembers.values {
                listed.formUnion(list)
            }
        }
        return standaloneTabs.filter { !listed.contains($0.id) }
    }

    /// Members of a loose group in sidebar order.
    func looseTabs(in block: SidebarBlock, window: WindowState) -> [TerminalTab] {
        guard block.isLoose else { return [] }
        let standalone = standaloneTabs
        var result: [TerminalTab] = []
        for id in window.looseMembers[block] ?? [] {
            if let tab = standalone.first(where: { $0.id == id }) {
                result.append(tab)
            }
        }
        if window.id == windows.first?.id {
            for tab in unlistedStandalone() where defaultLooseGroup(for: tab) == block {
                result.append(tab)
            }
        }
        return result
    }

    /// Sidebar members of any block, in sidebar order.
    func members(of block: SidebarBlock, in window: WindowState) -> [UUID] {
        switch block {
        case .workspace(let id):
            guard let workspace = workspace(for: id) else { return [] }
            return workspace.members
        case .localGroup, .ungrouped:
            return looseTabs(in: block, window: window).map(\.id)
        }
    }

    /// Sidebar order of one window: block order, then each block's independent member order.
    func sidebarOrder(in window: WindowState) -> [UUID] {
        var ids: [UUID] = []
        for block in window.blocks {
            ids.append(contentsOf: members(of: block, in: window))
        }
        return ids
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

    func host(_ alias: String) -> SSHHost? {
        hosts.first { $0.alias == alias }
    }

    /// How many terminals of this alias are open right now.
    func openSessionCount(alias: String) -> Int {
        tabs.filter { $0.alias == alias }.count
    }

    /// Palette slot when this host alias appears more than once anywhere.
    func duplicateHostMark(for tabID: UUID) -> Int? {
        guard let alias = tabs.first(where: { $0.id == tabID })?.alias, !alias.isEmpty else { return nil }
        var aliases: [String] = []
        for window in windows {
            for id in sidebarOrder(in: window) {
                guard let name = tabs.first(where: { $0.id == id })?.alias, !name.isEmpty else { continue }
                aliases.append(name)
            }
        }
        return DuplicateHostColor.index(for: alias, among: aliases)
    }

    // MARK: - Sync

    /// Every live workspace shows in exactly one window; Local Group and Ungrouped exist in every window.
    /// Workspaces that no window lists go to the window that holds their first member, else the first window.
    private func syncBlocks() {
        guard !windows.isEmpty else { return }
        let known = Set(workspaces.map(\.id))
        var seenWorkspace = Set<UUID>()
        for window in windows {
            var next: [SidebarBlock] = []
            var hasLocal = false
            var hasRemote = false
            for block in window.blocks {
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
            if !hasLocal {
                next.append(.localGroup)
            }
            if !hasRemote {
                next.append(.ungrouped)
            }
            if next != window.blocks {
                window.blocks = next
            }
        }
        for workspace in workspacesByNumber where seenWorkspace.insert(workspace.id).inserted {
            let home = windows[0]
            var blocks = home.blocks
            if let localIndex = blocks.firstIndex(of: .localGroup) {
                blocks.insert(.workspace(workspace.id), at: localIndex)
            } else if let remoteIndex = blocks.firstIndex(of: .ungrouped) {
                blocks.insert(.workspace(workspace.id), at: remoteIndex)
            } else {
                blocks.append(.workspace(workspace.id))
            }
            home.blocks = blocks
        }
    }

    /// Writes the normalized loose lists back so the stored order matches what the sidebar shows.
    private func syncLooseMembers() {
        for window in windows {
            var next: [SidebarBlock: [UUID]] = [:]
            for block in [SidebarBlock.localGroup, .ungrouped] {
                next[block] = looseTabs(in: block, window: window).map(\.id)
            }
            if next != window.looseMembers {
                window.looseMembers = next
            }
        }
    }

    /// A window's selection must point at something it shows.
    private func syncSelection(in window: WindowState) {
        let order = sidebarOrder(in: window)
        if let selected = window.selectedTabID, order.contains(selected) {
            let pruned = window.sidebarSelection.filter { order.contains($0) }
            if pruned != window.sidebarSelection {
                window.sidebarSelection = pruned
            }
            return
        }
        window.selectedTabID = order.first
        window.sidebarSelection = order.first.map { [$0] } ?? []
        window.sidebarAnchor = order.first
    }

    // MARK: - Blocks

    /// Moves a block so that it sits at `index` of the window's order (index counted before removal).
    func reorderSidebarBlock(_ dragged: SidebarBlock, toIndex index: Int, in window: WindowState) {
        guard let from = window.blocks.firstIndex(of: dragged) else {
            endBlockDrag(in: window)
            return
        }
        var blocks = window.blocks
        blocks.remove(at: from)
        var destination = index
        if from < destination {
            destination -= 1
        }
        destination = min(max(destination, 0), blocks.count)
        blocks.insert(dragged, at: destination)
        if blocks != window.blocks {
            window.blocks = blocks
            persistSession()
        }
        endBlockDrag(in: window)
    }

    func beginBlockDrag(_ block: SidebarBlock, in window: WindowState) {
        window.draggingTabID = nil
        window.draggingTabIDs = []
        window.draggingBlock = block
        window.dropHighlight = nil
    }

    func endBlockDrag(in window: WindowState) {
        window.draggingBlock = nil
        window.dropHighlight = nil
        for other in windows where other.dropHighlight != nil {
            other.dropHighlight = nil
        }
    }

    // MARK: - Hosts

    func reloadHosts() {
        let result = SSHConfig.load()
        if result.hosts != hosts {
            hosts = result.hosts
        }
        if result.failed != configFailed {
            configFailed = result.failed
        }
    }

    /// Keeps `hosts` in step with the files on disk. Call once at launch.
    func watchSSHConfig() {
        let watcher = SSHConfigWatcher { [weak self] in
            self?.reloadHosts()
        }
        watcher.start()
        configWatcher = watcher
    }

    /// ⌘T. Another terminal like the selected one, as its own sidebar row.
    /// With nothing selected (empty sidebar) it falls back to the host picker.
    func newTab(in window: WindowState? = nil) {
        guard let target = window ?? keyWindow else { return }
        // The picker sheet owns the keyboard; do not duplicate behind it.
        if target.hostPickerPresented { return }
        if let selected = selectedTab(in: target), selected.hasTerminal {
            duplicateAsTab(selected.id, in: target)
            return
        }
        openHostPicker(in: target)
    }

    /// ⌘O. Reloads the SSH config and shows the host picker. `.files` opens the chosen hosts as
    /// remote tabs in the Files area instead of terminals.
    func openHostPicker(in window: WindowState? = nil, purpose: HostPickerPurpose = .terminal) {
        reloadHosts()
        guard let target = window ?? keyWindow else { return }
        target.hostPickerPurpose = purpose
        target.hostPickerPresented = true
    }

    // MARK: - Selection

    func selectTab(_ id: UUID, in window: WindowState) {
        endZoomIfSwitching(to: id, in: window)
        window.selectedTabID = id
        window.section = .terminals
        if window.sidebarAnchor == nil {
            window.sidebarAnchor = id
        }
        persistSession()
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        TerminalActivity.shared.clearBell(sessionID: tab.sessionID)
        guard tab.hasTerminal, !tab.exited else { return }
        SSHTerminalRegistry.focus(tab.sessionID)
    }

    /// A plain click, including a pane header. The sidebar selection becomes this one host.
    func selectOnly(_ id: UUID, in window: WindowState) {
        window.sidebarSelection = [id]
        window.sidebarAnchor = id
        selectTab(id, in: window)
    }

    func isSidebarSelected(_ id: UUID, in window: WindowState) -> Bool {
        if window.sidebarSelection.isEmpty {
            return window.selectedTabID == id
        }
        return window.sidebarSelection.contains(id)
    }

    /// Command toggles one host. Shift selects the contiguous sidebar range from the anchor.
    func clickSidebar(_ id: UUID, command: Bool, shift: Bool, in window: WindowState) {
        if window.sidebarAnchor == nil {
            window.sidebarAnchor = window.selectedTabID
        }
        let order = sidebarOrder(in: window)
        if shift, let anchor = window.sidebarAnchor,
           let start = order.firstIndex(of: anchor), let end = order.firstIndex(of: id) {
            let lower = min(start, end)
            let upper = max(start, end)
            window.sidebarSelection = Set(order[lower...upper])
            selectTab(id, in: window)
            return
        }
        if command {
            var next = window.sidebarSelection
            if next.isEmpty, let selectedTabID = window.selectedTabID {
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
            window.sidebarSelection = next
            window.sidebarAnchor = id
            selectTab(id, in: window)
            return
        }
        selectOnly(id, in: window)
    }

    /// Detach is available only for sessions currently sharing a display panel.
    func sidebarSplits(_ ids: [UUID]) -> Bool {
        ids.contains { id in
            guard let i = WorkspaceBoard.index(containing: id, in: workspaces),
                  let panel = workspaces[i].panel(containing: id) else { return false }
            return WorkspaceBoard.leafIDs(panel.layout).count > 1
        }
    }

    func sidebarCanCreateArea(_ ids: [UUID]) -> Bool {
        !ids.isEmpty && !workspaces.contains { Set($0.members) == Set(ids) }
    }

    /// Right-click on a selected row applies to the whole set. Any other row applies to itself.
    func sidebarTargets(clicking id: UUID, in window: WindowState) -> [UUID] {
        if window.sidebarSelection.contains(id) {
            let chosen = window.sidebarSelection
            return sidebarOrder(in: window).filter { chosen.contains($0) }
        }
        return [id]
    }

    /// The terminal became first responder. Do not ask it to focus again.
    /// A multi-select stays put so focusing a pane does not drop the set.
    func notePaneFocused(_ id: UUID, in window: WindowState) {
        endZoomIfSwitching(to: id, in: window)
        window.selectedTabID = id
        if window.sidebarSelection.count <= 1 {
            window.sidebarSelection = [id]
            window.sidebarAnchor = id
        }
        if let tab = tabs.first(where: { $0.id == id }) {
            TerminalActivity.shared.clearBell(sessionID: tab.sessionID)
        }
        persistSession()
    }

    // MARK: - Opening

    func openHost(_ alias: String, in window: WindowState? = nil) {
        openHosts([alias], in: window)
    }

    /// `ghostty://open?…` from 1Panel. The same URL delivered twice in a short window
    /// (AppDelegate and SwiftUI) is ignored. Unknown aliases are reported, not run.
    func openExternalURL(_ url: URL) {
        guard let request = ExternalOpen.request(from: url), !request.isEmpty else { return }
        let key = url.absoluteString
        let now = Date()
        if key == lastExternalKey, now.timeIntervalSince(lastExternalAt) < 0.4 {
            return
        }
        lastExternalKey = key
        lastExternalAt = now
        runAfterRestore { [weak self] in
            self?.openExternalRequest(request)
        }
    }

    private func openExternalRequest(_ request: ExternalOpenRequest) {
        reloadHosts()

        var aliases = request.hosts
        if let group = request.group {
            aliases += hosts.filter { $0.source == group }.map(\.alias)
        }
        var seen = Set<String>()
        aliases = aliases.filter { seen.insert($0).inserted }
        let known = Set(hosts.map(\.alias))
        let unknown = aliases.filter { !known.contains($0) }
        aliases.removeAll { unknown.contains($0) }
        if !unknown.isEmpty {
            reportUnknownHosts(unknown)
        }
        guard !aliases.isEmpty else { return }

        // There is one window now; `window=new` in the URL is accepted and ignored.
        let target = mainWindow
        if request.reuse {
            openReusing(aliases, in: target, layout: request.layout, name: request.name)
        } else {
            openHosts(aliases, in: target, layout: request.layout, name: request.name)
        }
    }

    /// `reuse=1`: aliases that are already open are focused; only the missing ones start.
    /// With several aliases the whole set becomes one workspace, preserving an exact existing group.
    private func openReusing(_ aliases: [String], in target: WindowState, layout: WorkspaceLayout?, name: String?) {
        var existing: [UUID] = []
        var missing: [String] = []
        for alias in aliases {
            if let tab = tabs.first(where: { $0.alias == alias }) {
                existing.append(tab.id)
            } else {
                missing.append(alias)
            }
        }
        if missing.isEmpty, aliases.count == 1, let only = existing.first {
            // Nothing to open: bring the existing terminal forward.
            let home = window(containing: only) ?? target
            activate(home)
            selectOnly(only, in: home)
            return
        }
        target.hostPickerPresented = false
        activate(target)
        target.section = .terminals
        Task {
            let environment = await SSHLaunchEnvironment.shared.get()
            guard !Task.isCancelled else { return }
            launchEnvironment = environment
            var created: [UUID] = []
            for alias in missing {
                let tab = TerminalTab(id: UUID(), alias: alias, generation: 0, exited: false)
                tabs.append(tab)
                created.append(tab.id)
            }
            let all = aliases.compactMap { alias in tabs.first { $0.alias == alias }?.id }
            if all.count >= 2 {
                createWorkspace(from: all, atBlockIndex: target.blocks.count, in: target)
                applyRequestedLayout(layout, name: name, to: all)
                select(all, in: target)
            } else if let only = created.first {
                place([only], intoLoose: .ungrouped, in: target, beside: nil, after: true)
                select([only], in: target)
            }
            persistSession()
        }
    }

    private func applyRequestedLayout(_ layout: WorkspaceLayout?, name: String?, to ids: [UUID]) {
        guard let first = ids.first, let index = WorkspaceBoard.index(containing: first, in: workspaces) else { return }
        let workspaceID = workspaces[index].id
        if let layout, ids.count >= 2 {
            applyWorkspaceLayout(workspaceID, layout)
        }
        if let name {
            renameWorkspace(workspaceID, to: name)
        }
    }

    private func reportUnknownHosts(_ aliases: [String]) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Some hosts are not in your SSH config")
        alert.informativeText = String(
            format: String(localized: "Not opened: %@. Add them to ~/.ssh/config (or config.d) first."),
            aliases.joined(separator: ", ")
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate()
        alert.runModal()
    }

    /// Multiple hosts share workspace membership, with independent panels unless a layout was requested.
    func openHosts(_ aliases: [String], in window: WindowState? = nil, layout: WorkspaceLayout? = nil, name: String? = nil) {
        let aliases = aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !aliases.isEmpty else { return }
        let target = window ?? mainWindow
        target.hostPickerPresented = false
        activate(target)
        target.section = .terminals
        // A host 1Panel wrote a moment ago should show its address, not just the alias.
        reloadHosts()
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
                createWorkspace(from: created, atBlockIndex: target.blocks.count, in: target)
                applyRequestedLayout(layout, name: name, to: created)
                select(created, in: target)
            } else if let only = created.first {
                place([only], intoLoose: .ungrouped, in: target, beside: nil, after: true)
                target.selectedTabID = only
                target.sidebarSelection = [only]
                target.sidebarAnchor = only
            }
            persistSession()
        }
    }

    /// Opens a local login shell, in the user home directory unless `path` names another folder.
    /// `initialInput` is typed into the new shell once, right after it starts.
    func openLocalTerminal(at path: String? = nil, initialInput: String? = nil, in window: WindowState? = nil) {
        let directory = LocalTerminal.launchDirectory(path ?? LocalTerminal.homeDirectory)
        guard let target = window ?? keyWindow else { return }
        target.hostPickerPresented = false
        activate(target)
        target.section = .terminals
        Task {
            let environment = await SSHLaunchEnvironment.shared.get()
            guard !Task.isCancelled else { return }
            launchEnvironment = environment
            let tab = TerminalTab(id: UUID(), alias: nil, directory: directory, generation: 0, exited: false)
            if let initialInput {
                pendingInitialInput[tab.id] = initialInput
            }
            tabs.append(tab)
            place([tab.id], intoLoose: .localGroup, in: target, beside: nil, after: true)
            target.selectedTabID = tab.id
            target.sidebarSelection = [tab.id]
            target.sidebarAnchor = tab.id
            persistSession()
        }
    }

    /// Finder "New Ghostty Tab/Window Here", `open` of a folder or script, and `-e` from the
    /// command line. Waits for the saved session on a cold launch, then adds and selects.
    /// Multiple folders from "Window Here" share a workspace with independent panels;
    /// a single folder opens as a plain local terminal either way.
    func openLocalTerminals(at directories: [String], asWorkspace: Bool, initialInput: String? = nil) {
        guard !directories.isEmpty else { return }
        runAfterRestore { [weak self] in
            guard let self else { return }
            NSApp.activate()
            if asWorkspace && directories.count >= 2 {
                self.openLocalWorkspace(directories)
                return
            }
            for directory in directories {
                self.openLocalTerminal(at: directory, initialInput: initialInput)
            }
        }
    }

    private func openLocalWorkspace(_ directories: [String]) {
        let target = mainWindow
        target.hostPickerPresented = false
        activate(target)
        target.section = .terminals
        Task {
            let environment = await SSHLaunchEnvironment.shared.get()
            guard !Task.isCancelled else { return }
            launchEnvironment = environment
            var created: [UUID] = []
            for directory in directories {
                let tab = TerminalTab(
                    id: UUID(),
                    alias: nil,
                    directory: LocalTerminal.launchDirectory(directory),
                    generation: 0,
                    exited: false
                )
                tabs.append(tab)
                created.append(tab.id)
            }
            createWorkspace(from: created, atBlockIndex: target.blocks.count, in: target)
            persistSession()
        }
    }

    /// Folders and files from `open`, Finder, or the Dock. A folder opens a shell there. A file opens
    /// a shell in its folder and types the quoted path plus Return, so a script runs and the shell stays.
    /// Files only run after the user allows them; the prompt waits for the restored session on a cold launch.
    func openFiles(_ urls: [URL]) {
        var items: [(path: String, isDirectory: Bool)] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            items.append((path: path, isDirectory: isDirectory.boolValue))
        }
        let opened = ExternalOpen.splitOpenedPaths(items)
        for directory in opened.directories {
            openLocalTerminals(at: [directory], asWorkspace: false)
        }
        if opened.files.isEmpty {
            return
        }
        runAfterRestore { [weak self] in
            guard let self else { return }
            if !self.confirmExecution(of: opened.files) {
                return
            }
            for path in opened.files {
                let folder = (path as NSString).deletingLastPathComponent
                let input = ExternalOpen.shellQuoted(path) + "\r"
                self.openLocalTerminals(at: [folder], asWorkspace: false, initialInput: input)
            }
        }
    }

    /// Allow is the default button, as in Ghostty.
    private func confirmExecution(of files: [String]) -> Bool {
        let prompt = ExternalOpen.executionPrompt(for: files)
        let alert = NSAlert()
        alert.messageText = prompt.title
        if let detail = prompt.detail {
            alert.informativeText = detail
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// `--working-directory` / `-e` from the command line, possibly handed over by a second instance.
    func openRunRequest(_ request: ExternalRunRequest) {
        let directory = request.directory ?? LocalTerminal.homeDirectory
        let input = ExternalOpen.initialInput(for: request)
        openLocalTerminals(at: [directory], asWorkspace: false, initialInput: input)
    }

    /// Hands a new local shell its one-time input. Nil for every later call.
    func takeInitialInput(for id: UUID) -> String? {
        pendingInitialInput.removeValue(forKey: id)
    }

    /// Reopens the main window and the terminals that were on screen when the app last quit.
    /// The window appears at once; terminals follow as soon as the login environment is known.
    func restoreLastSession() {
        let snapshot = SessionSnapshot.load()
        guard let snapshot, !snapshot.tabs.isEmpty else {
            mainWindow.frame = snapshot?.restoredFrame()
            MainWindowManager.shared.show(mainWindow, model: self)
            acceptSessionWrites = true
            finishRestore()
            return
        }
        let known = Set(snapshot.tabs.map(\.id))
        snapshot.apply(to: mainWindow, keeping: known)
        MainWindowManager.shared.show(mainWindow, model: self)
        Task {
            let environment = await SSHLaunchEnvironment.shared.get()
            guard !Task.isCancelled else {
                acceptSessionWrites = true
                finishRestore()
                return
            }
            if !tabs.isEmpty {
                acceptSessionWrites = true
                persistSession()
                finishRestore()
                return
            }
            launchEnvironment = environment
            tabs = snapshot.tabs.compactMap { item in
                if let preview = item.preview {
                    guard FileManager.default.fileExists(atPath: preview) else { return nil }
                    return TerminalTab(id: item.id, alias: nil, generation: 0, exited: false, content: .preview(path: preview))
                }
                if item.files != nil {
                    return nil
                }
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
            let live = Set(tabs.map(\.id))
            workspaces = Self.workspaces(snapshot.workspaces, keeping: live)
            syncBlocks()
            syncLooseMembers()
            for window in windows {
                syncSelection(in: window)
            }
            acceptSessionWrites = true
            persistSession()
            finishRestore()
        }
    }

    private func finishRestore() {
        sessionRestored = true
        let queued = openRequestsAwaitingRestore
        openRequestsAwaitingRestore = []
        for open in queued {
            open()
        }
    }

    private func runAfterRestore(_ open: @escaping () -> Void) {
        if sessionRestored {
            open()
            return
        }
        openRequestsAwaitingRestore.append(open)
    }

    func persistSessionIfReady() {
        persistSession()
    }

    func toggleSettings() {
        SettingsWindowController.shared.toggle(model: self)
    }

    // MARK: - Reconnect

    func reconnect(_ tabID: UUID) {
        beginReconnect(tabID, automatic: false)
        if let window = window(containing: tabID) {
            window.selectedTabID = tabID
        }
    }

    /// Reconnects every closed terminal in the workspace, in place.
    /// Terminals that are still connected are left alone.
    func reconnectWorkspace(_ workspaceID: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        let closed = tabs(in: workspace).filter { $0.isSession && $0.exited }.map(\.id)
        for id in closed {
            beginReconnect(id, automatic: false)
        }
    }

    /// The shell reported its directory. Only a local terminal is titled by its path; a remote path
    /// would be on another machine, so an SSH tab keeps its host title and only remembers the path
    /// as where uploads and the file pane go.
    func noteWorkingDirectory(_ report: String, forSession sessionID: String) {
        guard let index = tabs.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        var path = report
        if report.hasPrefix("file://"), let url = URL(string: report) {
            path = url.path
        }
        guard path.hasPrefix("/") else { return }
        guard tabs[index].isLocal else {
            if tabs[index].remoteDirectory != path {
                tabs[index].remoteDirectory = path
            }
            return
        }
        // Saving the session reads the kernel's resolved path (/private/tmp for /tmp); keep the same
        // form so the title does not flip between the two.
        var resolved = path
        if let real = realpath(path, nil) {
            resolved = String(cString: real)
            free(real)
        }
        if tabs[index].directory != resolved {
            tabs[index].directory = resolved
        }
    }

    /// SSH transport ended. A link that held for a while is retried with growing delays, up to three
    /// times. One that died right away is not: that is an auth or config problem, not the network.
    func markClosed(_ tabID: UUID, lived: TimeInterval) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        cancelStableConnection(tabID)
        tabs[index].exited = true
        if tabs[index].isLocal {
            tabs[index].reconnecting = false
            cancelAutoReconnect(tabID)
            return
        }
        let shortLived = lived < Self.shortLivedConnectionSeconds
        if !shortLived, tabs[index].reconnectAttempts < Self.maxAutoReconnectAttempts {
            scheduleAutoReconnect(tabID)
        } else {
            tabs[index].reconnecting = false
            cancelAutoReconnect(tabID)
        }
    }

    /// Runs ssh again inside the same terminal. The old output stays on screen above a divider.
    private func beginReconnect(_ tabID: UUID, automatic: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard tabs[index].hasTerminal, !tabs[index].isLocal else { return }
        let notice: String
        if automatic {
            guard tabs[index].exited else { return }
            guard tabs[index].reconnectAttempts < Self.maxAutoReconnectAttempts else {
                tabs[index].reconnecting = false
                return
            }
            tabs[index].reconnectAttempts += 1
            notice = String(
                format: String(localized: "Connection lost, reconnecting (%lld/%lld)"),
                tabs[index].reconnectAttempts,
                Self.maxAutoReconnectAttempts
            )
        } else {
            cancelAutoReconnect(tabID)
            tabs[index].reconnectAttempts = 0
            notice = String(localized: "Reconnecting")
        }
        tabs[index].reconnecting = false
        tabs[index].exited = false
        if !SSHTerminalRegistry.restart(tabs[index].sessionID, notice: notice) {
            // No live terminal to reuse (should not happen); fall back to a fresh surface.
            SSHTerminalRegistry.destroy(tabs[index].sessionID)
            tabs[index].generation += 1
        }
        scheduleStableConnection(tabID)
    }

    private func scheduleAutoReconnect(_ tabID: UUID) {
        cancelAutoReconnect(tabID)
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard tabs[index].exited, !tabs[index].isLocal else { return }
        let attempt = tabs[index].reconnectAttempts
        guard attempt < Self.maxAutoReconnectAttempts else {
            tabs[index].reconnecting = false
            return
        }
        tabs[index].reconnecting = true
        let delay = Self.autoReconnectDelays[min(attempt, Self.autoReconnectDelays.count - 1)]
        autoReconnectTasks[tabID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.autoReconnectTasks[tabID] = nil
                self.beginReconnect(tabID, automatic: true)
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

    // MARK: - Closing

    func closeTab(_ id: UUID) {
        closeTab(id, focusNext: true)
    }

    func closeTabs(_ ids: [UUID]) {
        let window = ids.first.flatMap { window(containing: $0) }
        for id in ids {
            closeTab(id, focusNext: false)
        }
        guard let window, let selected = window.selectedTabID,
              let tab = tabs.first(where: { $0.id == selected }),
              tab.hasTerminal, !tab.exited else { return }
        SSHTerminalRegistry.focus(tab.sessionID)
    }

    private func closeTab(_ id: UUID, focusNext: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let owner = window(containing: id)
        var nextSelection: UUID?
        if let owner, owner.selectedTabID == id {
            var workspaceMembers: [UUID] = []
            if let workspaceIndex = WorkspaceBoard.index(containing: id, in: workspaces) {
                workspaceMembers = workspaces[workspaceIndex].panel(containing: id).map { WorkspaceBoard.leafIDs($0.layout) } ?? []
            }
            nextSelection = WorkspaceBoard.selectionAfterClosing(
                id,
                workspaceMembers: workspaceMembers,
                sidebarOrder: sidebarOrder(in: owner)
            )
        }
        cancelAutoReconnect(id)
        cancelStableConnection(id)
        pendingInitialInput[id] = nil
        TerminalFind.shared.forget(tabs[index].sessionID)
        TerminalActivity.shared.forget(sessionID: tabs[index].sessionID)
        TerminalProgress.shared.forget(sessionID: tabs[index].sessionID)
        SSHTerminalRegistry.destroy(tabs[index].sessionID)
        tabs.remove(at: index)
        workspaces = WorkspaceBoard.extract(id, from: workspaces)
        for window in windows {
            for key in window.looseMembers.keys {
                window.looseMembers[key]?.removeAll { $0 == id }
            }
            window.sidebarSelection.remove(id)
            window.zoomedPanes = window.zoomedPanes.filter { $0.value != id }
            if window.sidebarAnchor == id {
                window.sidebarAnchor = nil
            }
        }
        if let owner {
            let order = sidebarOrder(in: owner)
            if owner.selectedTabID == id {
                if let nextSelection, order.contains(nextSelection) {
                    owner.selectedTabID = nextSelection
                } else {
                    owner.selectedTabID = order.first
                }
            }
            syncSelection(in: owner)
            if focusNext, let next = owner.selectedTabID,
               let tab = tabs.first(where: { $0.id == next }), tab.hasTerminal, !tab.exited {
                SSHTerminalRegistry.focus(tab.sessionID)
            }
        }
        persistSession()
    }

    func closeSelectedTab(in window: WindowState) {
        guard let selected = window.selectedTabID else { return }
        closeTab(selected)
    }

    // MARK: - Duplicate

    /// Alias or launch directory for another session like `source`: the same SSH host, or a local
    /// shell in the directory the source is in right now. Nil when the source cannot be copied.
    private func duplicateTarget(of source: TerminalTab) -> (alias: String?, directory: String?)? {
        if source.isLocal {
            let live = SSHTerminalRegistry.currentWorkingDirectory(for: source.sessionID) ?? source.directory
            guard let live, !live.isEmpty else { return nil }
            return (alias: nil, directory: LocalTerminal.launchDirectory(live))
        }
        guard let alias = source.alias, !alias.isEmpty else { return nil }
        return (alias: alias, directory: nil)
    }

    /// Opens another session of the same host, or another local shell in the same directory, and splits it.
    func duplicate(_ id: UUID, edge: SplitEdge) {
        guard edge == .right || edge == .bottom else { return }
        guard let source = tabs.first(where: { $0.id == id }) else { return }
        guard let target = duplicateTarget(of: source) else { return }
        duplicateSession(id, alias: target.alias, directory: target.directory, edge: edge)
    }

    /// Opens another session of the same host, or another local shell in the same directory, as a
    /// standalone sidebar row (no split). It goes into the loose group of its kind (Local Group or
    /// Ungrouped): right after the source when the source is in that group, else at the group's end.
    /// The copy becomes the selection.
    func duplicateAsTab(_ id: UUID, in window: WindowState) {
        guard let source = tabs.first(where: { $0.id == id }) else { return }
        guard let target = duplicateTarget(of: source) else { return }
        Task {
            let environment = await SSHLaunchEnvironment.shared.get()
            guard !Task.isCancelled else { return }
            guard tabs.contains(where: { $0.id == id }) else { return }
            launchEnvironment = environment
            // A source that only shows through the unlisted fallback is written down first,
            // so `place` can find it and put the copy right behind it.
            syncLooseMembers()
            let copy = TerminalTab(id: UUID(), alias: target.alias, directory: target.directory, generation: 0, exited: false)
            tabs.append(copy)
            let group = defaultLooseGroup(for: copy)
            var neighbor: UUID? = nil
            if looseTabs(in: group, window: window).contains(where: { $0.id == id }) {
                neighbor = id
            }
            place([copy.id], intoLoose: group, in: window, beside: neighbor, after: true)
            window.sidebarSelection = [copy.id]
            window.sidebarAnchor = copy.id
            selectTab(copy.id, in: window)
            persistSession()
        }
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
            guard let window = window(containing: id) else { return }
            let copy = TerminalTab(id: UUID(), alias: alias, directory: directory, generation: 0, exited: false)
            tabs.insert(copy, at: sourceIndex + 1)
            let block = window.blocks.first { block in
                if case .workspace = block { return false }
                return members(of: block, in: window).contains(id)
            }
            workspaces = WorkspaceBoard.drop(dragged: copy.id, onto: id, edge: edge, in: workspaces)
            adoptNewWorkspaces(in: window, replacing: block, near: id)
            window.sidebarSelection = [copy.id]
            window.sidebarAnchor = copy.id
            selectTab(copy.id, in: window)
        }
    }

    // MARK: - Opening panes beside a terminal

    /// Finder files dropped on a terminal's split, New Tab, or transfer circle. A folder opens a
    /// local shell there; a file opens a preview pane.
    func openDropped(_ urls: [URL], zone: DropZone, on id: UUID, in window: WindowState) {
        let placement: PanePlacement
        switch zone {
        case .splitLeft: placement = .split(.left)
        case .splitRight: placement = .split(.right)
        case .newTab: placement = .newTab
        case .transfer:
            guard let tab = tabs.first(where: { $0.id == id }) else { return }
            DropTransfer.run(urls, for: tab, model: self)
            return
        case .insertPath, .openInPlace:
            return
        }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                openLocalTerminal(at: url.path, placement: placement, beside: id, in: window)
            } else {
                open(.preview(path: url.path), placement: placement, beside: id, in: window)
            }
        }
    }

    /// A preview pane as its own sidebar row, or split beside `id`.
    func open(_ content: PaneContent, placement: PanePlacement, beside id: UUID, in window: WindowState) {
        let tab = TerminalTab(id: UUID(), alias: nil, generation: 0, exited: false, content: content)
        add(tab, placement: placement, beside: id, in: window)
    }

    /// A local shell in `directory`, as its own sidebar row or split beside `id`.
    func openLocalTerminal(at directory: String, placement: PanePlacement, beside id: UUID, in window: WindowState) {
        Task {
            let environment = await SSHLaunchEnvironment.shared.get()
            guard !Task.isCancelled else { return }
            launchEnvironment = environment
            let tab = TerminalTab(
                id: UUID(),
                alias: nil,
                directory: LocalTerminal.launchDirectory(directory),
                generation: 0,
                exited: false
            )
            add(tab, placement: placement, beside: id, in: window)
        }
    }

    /// An ssh session to `host` that changes to `directory` once the remote shell is up.
    func openRemoteTerminal(_ host: String, at directory: String, placement: PanePlacement, beside id: UUID, in window: WindowState) {
        Task {
            let environment = await SSHLaunchEnvironment.shared.get()
            guard !Task.isCancelled else { return }
            launchEnvironment = environment
            let tab = TerminalTab(id: UUID(), alias: host, generation: 0, exited: false)
            pendingInitialInput[tab.id] = "cd \(FileRules.shellQuote(directory))\r"
            add(tab, placement: placement, beside: id, in: window)
        }
    }

    // MARK: - Files area

    func showSection(_ section: AppSection, in window: WindowState) {
        guard window.section != section else { return }
        window.section = section
        if section != .terminals {
            // A hidden terminal must not keep typing focus.
            MainWindowManager.shared.window(for: window)?.makeFirstResponder(nil)
        }
        if section == .terminals, let id = window.selectedTabID,
           let tab = tabs.first(where: { $0.id == id }), tab.hasTerminal {
            SSHTerminalRegistry.focus(tab.sessionID)
        }
        persistSession()
    }

    func fileWorkspace(for window: WindowState) -> FileWorkspace {
        FileBrowserStore.shared.workspace(for: window, model: self)
    }

    /// The Files area on the host of terminal `id`, in its current folder: that host's tab (a new
    /// one on the right), or a tab on this Mac. Without a terminal it just opens.
    func showFiles(for id: UUID?, in window: WindowState) {
        if let id, let tab = tabs.first(where: { $0.id == id }) {
            let workspace = fileWorkspace(for: window)
            if let alias = tab.alias, !alias.isEmpty {
                workspace.openRemote(host: alias, at: tab.remoteDirectory)
            } else {
                workspace.showLocal(localFolder(of: tab))
            }
        }
        showSection(.files, in: window)
    }

    /// Sidebar rows dropped on a pane of the Files area (`group`) or on the Files button (nil): one
    /// tab per host (an open one is reused), and a new tab for each terminal on this Mac.
    func openFiles(forTabs ids: [UUID], in group: UUID? = nil, window: WindowState) {
        let workspace = fileWorkspace(for: window)
        var seenHosts = Set<String>()
        for id in ids {
            guard let tab = tabs.first(where: { $0.id == id }) else { continue }
            if let alias = tab.alias, !alias.isEmpty {
                guard seenHosts.insert(alias).inserted else { continue }
                workspace.openRemote(host: alias, at: tab.remoteDirectory, in: group)
            } else if let folder = localFolder(of: tab) {
                workspace.addLocalTab(at: folder, in: group)
            }
        }
        showSection(.files, in: window)
    }

    /// Hosts chosen in the picker while it opens file tabs, in the pane whose + opened it.
    func openFilesTabs(hosts aliases: [String], in window: WindowState) {
        window.hostPickerPresented = false
        let workspace = fileWorkspace(for: window)
        for alias in aliases {
            workspace.openRemote(host: alias, at: nil, in: workspace.pickerGroupID)
        }
        showSection(.files, in: window)
    }

    private func localFolder(of tab: TerminalTab) -> String? {
        if tab.hasTerminal {
            return SSHTerminalRegistry.currentWorkingDirectory(for: tab.sessionID) ?? tab.directory
        }
        if case .preview(let path) = tab.content {
            return (path as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// ⌥⌘O: from a terminal to its files, and back.
    func toggleSection(in window: WindowState) {
        if window.section == .files {
            showSection(.terminals, in: window)
        } else {
            showFiles(for: window.selectedTabID, in: window)
        }
    }

    /// "Open in Terminal" from the Files area: a new terminal row in `folder`, on `host` or this Mac.
    func openTerminal(at folder: String, host: String?, in window: WindowState) {
        showSection(.terminals, in: window)
        let beside = window.selectedTabID ?? UUID()
        if let host {
            openRemoteTerminal(host, at: folder, placement: .newTab, beside: beside, in: window)
        } else {
            openLocalTerminal(at: folder, placement: .newTab, beside: beside, in: window)
        }
    }

    private func add(_ tab: TerminalTab, placement: PanePlacement, beside id: UUID, in window: WindowState) {
        let sourceIndex = tabs.firstIndex { $0.id == id }
        switch placement {
        case .split(let edge) where sourceIndex != nil:
            tabs.insert(tab, at: sourceIndex! + 1)
            let block = window.blocks.first { block in
                if case .workspace = block { return false }
                return members(of: block, in: window).contains(id)
            }
            workspaces = WorkspaceBoard.drop(dragged: tab.id, onto: id, edge: edge, in: workspaces)
            adoptNewWorkspaces(in: window, replacing: block, near: id)
        default:
            syncLooseMembers()
            tabs.append(tab)
            let group = defaultLooseGroup(for: tab)
            var neighbor: UUID? = nil
            if looseTabs(in: group, window: window).contains(where: { $0.id == id }) {
                neighbor = id
            }
            place([tab.id], intoLoose: group, in: window, beside: neighbor, after: true)
        }
        window.sidebarSelection = [tab.id]
        window.sidebarAnchor = tab.id
        selectTab(tab.id, in: window)
    }

    func duplicateFocused(downward: Bool, in window: WindowState) {
        guard let selected = window.selectedTabID else { return }
        duplicate(selected, edge: downward ? .bottom : .right)
    }

    // MARK: - Pane focus

    /// Next or previous pane of the visible workspace in sidebar order, wrapping at the ends.
    /// Returns false when there is nothing to switch to, so the key can reach the terminal.
    func focusAdjacentPane(forward: Bool, in window: WindowState) -> Bool {
        guard let selected = window.selectedTabID, let root = displayRoot(in: window) else { return false }
        let ids = WorkspaceBoard.leafIDs(root)
        guard ids.count >= 2, let index = ids.firstIndex(of: selected) else { return false }
        var next = index + (forward ? 1 : -1)
        if next < 0 {
            next = ids.count - 1
        } else if next >= ids.count {
            next = 0
        }
        selectTab(ids[next], in: window)
        return true
    }

    /// ⌘1…⌘8 pick a sidebar position and ⌘9 the last terminal (`number` nil). False when there is no such
    /// terminal, so the key can reach the terminal.
    func selectTerminal(number: Int?, in window: WindowState) -> Bool {
        let order = sidebarOrder(in: window)
        var target: UUID?
        if let number {
            target = WorkspaceBoard.terminal(number: number, in: order)
        } else {
            target = order.last
        }
        guard let target else { return false }
        selectOnly(target, in: window)
        return true
    }

    /// ⇧⌘[ / ⇧⌘]: previous or next terminal in sidebar order, across workspaces, wrapping at the ends.
    func selectAdjacentTerminal(forward: Bool, in window: WindowState) -> Bool {
        let order = sidebarOrder(in: window)
        guard let target = WorkspaceBoard.adjacentTerminal(to: window.selectedTabID, forward: forward, in: order) else {
            return false
        }
        selectOnly(target, in: window)
        return true
    }

    /// The pane on that side of the current one, by on-screen position. At the edge of a split the key is still consumed.
    func focusPane(toward direction: PaneDirection, in window: WindowState) -> Bool {
        guard let selected = window.selectedTabID, let root = displayRoot(in: window) else { return false }
        let frames = PaneLayout.frames(of: root, in: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        guard frames.count >= 2 else { return false }
        guard let target = PaneLayout.neighbor(of: selected, toward: direction, frames: frames) else {
            return true
        }
        selectTab(target, in: window)
        return true
    }

    /// Moves the focused pane one step in `direction`, past its nearest neighbor on that side.
    func movePane(toward direction: PaneDirection, in window: WindowState) -> Bool {
        guard let selected = window.selectedTabID, let root = displayRoot(in: window) else { return false }
        let frames = PaneLayout.frames(of: root, in: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        guard frames.count >= 2 else { return false }
        if let panel = selectedPanel(in: window) {
            window.zoomedPanes[panel.id] = nil
        }
        guard let neighbor = PaneLayout.neighbor(of: selected, toward: direction, frames: frames) else {
            return true
        }
        let edge: SplitEdge
        switch direction {
        case .left: edge = .left
        case .right: edge = .right
        case .up: edge = .top
        case .down: edge = .bottom
        }
        workspaces = WorkspaceBoard.drop(dragged: selected, onto: neighbor, edge: edge, in: workspaces)
        persistSession()
        return true
    }

    // MARK: - Merge / split from the sidebar menu

    func mergeSidebar(_ ids: [UUID], onto target: UUID, as layout: WorkspaceLayout, in window: WindowState) {
        let ordered = sidebarOrder(in: window).filter { ids.contains($0) }
        guard ordered.count >= 2 else { return }
        let targetBlock = window.blocks.first { members(of: $0, in: window).contains(target) }
        clearPanelZoom(for: ordered)
        workspaces = WorkspaceBoard.combine(ordered, onto: target, as: layout, in: workspaces)
        removeFromLooseGroups(ordered)
        adoptNewWorkspaces(in: window, replacing: targetBlock, near: target)
        window.sidebarSelection = Set(ordered)
        window.sidebarAnchor = target
        selectTab(target, in: window)
        persistSession()
    }

    func createAreaFromSidebar(_ ids: [UUID], in window: WindowState) {
        let ordered = sidebarOrder(in: window).filter { ids.contains($0) }
        guard sidebarCanCreateArea(ordered) else { return }
        createWorkspace(from: ordered, atBlockIndex: blockIndex(ofFirst: ordered, in: window), in: window)
    }

    func splitSidebar(_ ids: [UUID], in window: WindowState) {
        clearPanelZoom(for: ids)
        workspaces = WorkspaceBoard.detach(sessionIDs(ids), in: workspaces)
        persistSession()
        if let selected = window.selectedTabID { selectTab(selected, in: window) }
    }

    func removeSidebarFromWorkspace(_ ids: [UUID], in window: WindowState) {
        let ordered = sidebarOrder(in: window).filter { ids.contains($0) }
        for id in ordered {
            let tab = tabs.first { $0.id == id }
            place([id], intoLoose: defaultLooseGroup(for: tab), in: window, beside: nil, after: true)
        }
        select(ordered, in: window)
        persistSession()
    }

    func splitWorkspacePanels(_ workspaceID: UUID) {
        guard let workspace = workspace(for: workspaceID) else { return }
        clearPanelZoom(for: workspace.members)
        workspaces = WorkspaceBoard.detach(workspace.members, in: workspaces)
        persistSession()
    }

    /// Where the block holding the first of `ids` sits, so a new workspace appears near it.
    private func blockIndex(ofFirst ids: [UUID], in window: WindowState) -> Int {
        for (index, block) in window.blocks.enumerated() {
            let members = members(of: block, in: window)
            if ids.contains(where: { members.contains($0) }) {
                return index
            }
        }
        return window.blocks.count
    }

    // MARK: - Drag and drop

    /// Dragging a selected row takes the whole selection along, in sidebar order.
    func beginDrag(_ id: UUID, in window: WindowState) {
        guard tabs.contains(where: { $0.id == id && $0.isSession }) else { return }
        window.draggingBlock = nil
        var ids = sidebarTargets(clicking: id, in: window).filter { candidate in
            tabs.contains { $0.id == candidate && $0.isSession }
        }
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        }
        ids.insert(id, at: 0)
        window.draggingTabID = id
        window.draggingTabIDs = ids
        window.dropEpoch += 1
    }

    func endDrag(in window: WindowState) {
        window.draggingTabID = nil
        window.draggingTabIDs = []
        window.draggingBlock = nil
        window.dropHighlight = nil
        window.dropEpoch += 1
        for other in windows where other.dropHighlight != nil {
            other.dropHighlight = nil
        }
    }

    /// After a drop the moved terminals are the selection, with the first one focused.
    private func select(_ ids: [UUID], in window: WindowState) {
        guard let first = ids.first else { return }
        window.selectedTabID = first
        window.sidebarSelection = Set(ids)
        window.sidebarAnchor = first
    }

    /// Live session terminals among `ids`, in the given order, without repeats.
    private func sessionIDs(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { id in
            guard seen.insert(id).inserted else { return false }
            return tabs.contains { $0.id == id && $0.isSession }
        }
    }

    /// Every dragged terminal lands on `target`'s `edge` in `window`. The first splits the target;
    /// the rest line up after it on the same axis, so a group stays together.
    func dropTabs(_ ids: [UUID], onto target: UUID, edge: SplitEdge, in window: WindowState) {
        let dragged = sessionIDs(ids).filter { $0 != target }
        guard let first = dragged.first else { return }
        guard tabs.contains(where: { $0.id == target && $0.isSession }) else { return }
        let sources = Set(dragged.compactMap { self.window(containing: $0)?.id })
        let targetBlock = window.blocks.first { members(of: $0, in: window).contains(target) }
        clearPanelZoom(for: dragged + [target])
        var next = WorkspaceBoard.drop(dragged: first, onto: target, edge: edge, in: workspaces)
        var previous = first
        for id in dragged.dropFirst() {
            next = WorkspaceBoard.drop(dragged: id, onto: previous, edge: WorkspaceBoard.continuation(of: edge), in: next)
            previous = id
        }
        workspaces = next
        removeFromLooseGroups(dragged)
        adoptNewWorkspaces(in: window, replacing: targetBlock, near: target)
        select(dragged, in: window)
        for source in sources.compactMap({ self.window(for: $0) }) where source.id != window.id {
            syncSelection(in: source)
        }
        persistSession()
    }

    /// Dragged terminals join `workspaceID` beside `target`, or at its end when `target` is nil.
    /// Members that are already inside only move; the split shape is kept for them.
    func joinWorkspace(_ ids: [UUID], _ workspaceID: UUID, beside target: UUID?, after: Bool, detach: Bool = false) {
        let dragged = sessionIDs(ids).filter { $0 != target }
        guard !dragged.isEmpty else { return }
        let sources = Set(dragged.compactMap { self.window(containing: $0)?.id })
        if detach { clearPanelZoom(for: dragged) }
        var next = detach ? WorkspaceBoard.detach(dragged, in: workspaces) : workspaces
        var anchor = target
        var anchorAfter = after
        for id in dragged {
            if let anchor {
                next = WorkspaceBoard.join(id, beside: anchor, after: anchorAfter, to: workspaceID, in: next)
            } else {
                next = WorkspaceBoard.join(id, to: workspaceID, in: next)
            }
            anchor = id
            anchorAfter = true
        }
        guard next != workspaces else { return }
        workspaces = next
        removeFromLooseGroups(dragged)
        if let home = window(showing: workspaceID) {
            select(dragged, in: home)
            for source in sources.compactMap({ self.window(for: $0) }) where source.id != home.id {
                syncSelection(in: source)
            }
        }
        persistSession()
    }

    /// Dragged terminals leave their workspaces and become standalone rows of `block` in `window`,
    /// beside `target` when it is in that group, otherwise at the end.
    func moveToLooseGroup(_ ids: [UUID], _ block: SidebarBlock, in window: WindowState, beside target: UUID?, after: Bool) {
        let dragged = sessionIDs(ids).filter { $0 != target }
        guard block.isLoose, !dragged.isEmpty else { return }
        let sources = Set(dragged.compactMap { self.window(containing: $0)?.id })
        place(dragged, intoLoose: block, in: window, beside: target, after: after)
        select(dragged, in: window)
        for source in sources.compactMap({ self.window(for: $0) }) where source.id != window.id {
            syncSelection(in: source)
        }
        persistSession()
    }

    /// Creates a workspace with independent panels at the requested sidebar position.
    func createWorkspace(from ids: [UUID], atBlockIndex blockIndex: Int, in window: WindowState) {
        let dragged = sessionIDs(ids)
        guard !dragged.isEmpty else { return }
        let sources = Set(dragged.compactMap { self.window(containing: $0)?.id })
        let before = Set(workspaces.map(\.id))
        let next = WorkspaceBoard.create(dragged, in: workspaces)
        guard next != workspaces else { return }
        workspaces = next
        removeFromLooseGroups(dragged)
        if let created = workspaces.first(where: { !before.contains($0.id) }) {
            for other in windows {
                other.blocks.removeAll { $0 == .workspace(created.id) }
            }
            var blocks = window.blocks
            blocks.insert(.workspace(created.id), at: min(max(blockIndex, 0), blocks.count))
            window.blocks = blocks
        }
        select(dragged, in: window)
        for source in sources.compactMap({ self.window(for: $0) }) where source.id != window.id {
            syncSelection(in: source)
        }
        persistSession()
    }

    /// A whole block's members merge into another block of `target` window.
    func mergeBlock(_ dragged: SidebarBlock, from source: WindowState, into targetBlock: SidebarBlock, in target: WindowState) {
        guard dragged != targetBlock || source.id != target.id else { return }
        let ids = members(of: dragged, in: source)
        guard !ids.isEmpty else { return }
        switch targetBlock {
        case .workspace(let workspaceID):
            if case .workspace(let sourceID) = dragged {
                workspaces = WorkspaceBoard.joinWorkspace(sourceID, to: workspaceID, in: workspaces)
                select(ids, in: target)
                syncSelection(in: source)
                persistSession()
            } else {
                joinWorkspace(ids, workspaceID, beside: nil, after: true)
            }
        case .localGroup, .ungrouped:
            moveToLooseGroup(ids, targetBlock, in: target, beside: nil, after: true)
        }
    }

    /// A whole block lands on a pane edge in a content area.
    func dropBlock(_ dragged: SidebarBlock, from source: WindowState, onto target: UUID, edge: SplitEdge, in window: WindowState) {
        let ids = members(of: dragged, in: source)
        guard !ids.isEmpty, !ids.contains(target) else { return }
        dropTabs(ids, onto: target, edge: edge, in: window)
    }

    /// A block dragged into a sidebar gap moves to that position.
    func dropBlock(_ dragged: SidebarBlock, from source: WindowState, intoGap index: Int, of target: WindowState) {
        reorderSidebarBlock(dragged, toIndex: index, in: target)
    }

    /// Puts standalone terminals into a loose list, pulling them out of any workspace and every other list first.
    private func place(_ ids: [UUID], intoLoose block: SidebarBlock, in window: WindowState, beside target: UUID?, after: Bool) {
        guard block.isLoose else { return }
        for id in ids {
            workspaces = WorkspaceBoard.extract(id, from: workspaces)
        }
        removeFromLooseGroups(ids)
        var list = window.looseMembers[block] ?? []
        var destination = list.count
        if let target, let index = list.firstIndex(of: target) {
            destination = after ? index + 1 : index
        }
        list.insert(contentsOf: ids, at: destination)
        window.looseMembers[block] = list
    }

    private func removeFromLooseGroups(_ ids: [UUID]) {
        let set = Set(ids)
        for window in windows {
            for key in window.looseMembers.keys {
                window.looseMembers[key]?.removeAll { set.contains($0) }
            }
        }
    }

    /// A drop or duplicate may have created a workspace out of a standalone pane. That new block
    /// takes the place the pane had in `window`'s sidebar (`replacing`), or goes right before the loose groups.
    private func adoptNewWorkspaces(in window: WindowState, replacing block: SidebarBlock?, near tab: UUID) {
        var listed = Set<UUID>()
        for other in windows {
            for case .workspace(let id) in other.blocks {
                listed.insert(id)
            }
        }
        for workspace in workspaces where !listed.contains(workspace.id) {
            var blocks = window.blocks
            var index = blocks.count
            if let block, let found = blocks.firstIndex(of: block) {
                index = found
            } else if let found = blocks.firstIndex(where: { $0.isLoose }) {
                index = found
            }
            blocks.insert(.workspace(workspace.id), at: index)
            window.blocks = blocks
        }
    }

    // MARK: - Workspace menu

    /// Stores a sidebar title. A blank name returns to the generated title.
    func renameWorkspace(_ id: UUID, to name: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored: String? = trimmed.isEmpty ? nil : trimmed
        if workspaces[index].name == stored { return }
        workspaces[index].name = stored
        persistSession()
    }

    /// Drops the workspace. Members stay open in the same window's loose groups.
    func dissolveWorkspace(_ workspaceID: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        let home = window(showing: workspaceID) ?? keyWindow
        let members = workspace.members
        workspaces = WorkspaceBoard.dissolve(workspaceID, in: workspaces)
        if let home {
            for id in members {
                let tab = tabs.first { $0.id == id }
                place([id], intoLoose: defaultLooseGroup(for: tab), in: home, beside: nil, after: true)
            }
        }
        persistSession()
    }

    func applyWorkspaceLayout(_ workspaceID: UUID, _ layout: WorkspaceLayout) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        clearPanelZoom(for: workspaces[index].members)
        workspaces[index] = WorkspaceBoard.apply(layout, to: workspaces[index])
        persistSession()
    }

    func setSplitRatio(_ id: UUID, to ratio: CGFloat) {
        workspaces = WorkspaceBoard.setRatio(id, to: ratio, in: workspaces)
        persistSession()
    }

    /// Double-click on a divider: size the split so every pane along it gets the same share.
    func evenOutSplit(_ id: UUID) {
        for panel in workspaces.flatMap(\.panels) {
            if let ratio = PaneLayout.evenRatio(for: id, in: panel.layout) {
                setSplitRatio(id, to: ratio)
                return
            }
        }
    }

    /// Start of a drag on one divider segment. Returns the split that segment resizes from now on,
    /// nil when the layout cannot be separated there (the caller then resizes the whole split).
    func detachDividerSegment(_ segment: Int, of splitID: UUID, in rect: CGRect) -> UUID? {
        for index in workspaces.indices {
            for panelIndex in workspaces[index].panels.indices {
                guard let detached = PaneLayout.detachSegment(segment, of: splitID, in: workspaces[index].panels[panelIndex].layout, rect: rect) else { continue }
                workspaces[index].panels[panelIndex].layout = detached.0
                persistSession()
                return detached.1
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func activate(_ window: WindowState) {
        MainWindowManager.shared.show(window, model: self)
    }

    private func persistSession() {
        guard acceptSessionWrites else { return }
        for index in tabs.indices where tabs[index].isLocal {
            guard let live = SSHTerminalRegistry.currentWorkingDirectory(for: tabs[index].sessionID) else { continue }
            if tabs[index].directory != live {
                tabs[index].directory = live
            }
        }
        syncBlocks()
        syncLooseMembers()
        let snapshot = SessionSnapshot(
            tabs: tabs.compactMap { tab in
                switch tab.content {
                case .terminal:
                    break
                case .preview(let path):
                    return SessionSnapshot.Tab(id: tab.id, alias: nil, preview: path)
                }
                if let alias = tab.alias, !alias.isEmpty {
                    return SessionSnapshot.Tab(id: tab.id, alias: alias, directory: nil)
                }
                guard let directory = tab.directory, !directory.isEmpty else { return nil }
                return SessionSnapshot.Tab(id: tab.id, alias: nil, directory: directory)
            },
            workspaces: workspaces,
            windows: windows.map { window in
                SessionSnapshot.Window(
                    id: window.id,
                    name: nil,
                    frame: window.frame.map { SessionSnapshot.Frame($0) },
                    blocks: window.blocks,
                    localGroup: window.looseMembers[.localGroup] ?? [],
                    ungrouped: window.looseMembers[.ungrouped] ?? [],
                    selected: window.selectedTabID,
                    section: window.section
                )
            },
            keyWindow: mainWindow.id
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: SessionSnapshot.storageKey)
    }

    private static func workspaces(_ workspaces: [Workspace], keeping known: Set<UUID>) -> [Workspace] {
        WorkspaceBoard.keeping(known, in: workspaces)
    }

}

/// What is written to UserDefaults. Older snapshots had one implicit window; those fields still decode.
private struct SessionSnapshot: Codable {
    struct Tab: Codable {
        var id: UUID
        var alias: String?
        var directory: String? = nil
        var preview: String? = nil
        /// File panes of an earlier build; such tabs are dropped at launch.
        var files: FileBrowserTarget? = nil
    }

    struct Frame: Codable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }

        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    struct Window: Codable {
        var id: UUID
        var name: String?
        var frame: Frame?
        var blocks: [SidebarBlock]
        var localGroup: [UUID]
        var ungrouped: [UUID]
        var selected: UUID?
        var section: AppSection? = nil
    }

    static let storageKey = "session.openTabs"

    enum CodingKeys: String, CodingKey {
        case tabs
        case workspaces
        case windows
        case keyWindow
        case selected
        case layout
        case sidebarBlocks
        case localGroup
        case ungrouped
    }

    var tabs: [Tab]
    var workspaces: [Workspace]
    var windows: [Window]?
    var keyWindow: UUID?
    /// Pre-multi-window fields, read only when `windows` is missing.
    var selected: UUID?
    var layout: PaneNode?
    var sidebarBlocks: [SidebarBlock]?
    var localGroup: [UUID]?
    var ungrouped: [UUID]?

    init(tabs: [Tab], workspaces: [Workspace], windows: [Window], keyWindow: UUID?) {
        self.tabs = tabs
        self.workspaces = workspaces
        self.windows = windows
        self.keyWindow = keyWindow
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
        localGroup = try container.decodeIfPresent([UUID].self, forKey: .localGroup)
        ungrouped = try container.decodeIfPresent([UUID].self, forKey: .ungrouped)
        windows = try container.decodeIfPresent([Window].self, forKey: .windows)
        keyWindow = try container.decodeIfPresent(UUID.self, forKey: .keyWindow)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(workspaces, forKey: .workspaces)
        try container.encodeIfPresent(windows, forKey: .windows)
        try container.encodeIfPresent(keyWindow, forKey: .keyWindow)
    }

    /// The window that was key when the snapshot was written, else the first one listed.
    private var keyWindowEntry: Window? {
        guard let windows, !windows.isEmpty else { return nil }
        if let found = windows.first(where: { $0.id == keyWindow }) {
            return found
        }
        return windows[0]
    }

    /// Where the main window goes at launch.
    func restoredFrame() -> CGRect? {
        keyWindowEntry?.frame?.rect
    }

    /// Fills the main window from the snapshot. A pre-multi-window snapshot has one implicit window.
    /// Several windows (an older multi-window session) are merged into one: workspace blocks in
    /// order, Local Group and Ungrouped once at the end, loose lists joined, frame from the key window.
    @MainActor
    func apply(to window: WindowState, keeping known: Set<UUID>) {
        guard let windows, let key = keyWindowEntry else {
            window.blocks = sidebarBlocks ?? [.localGroup, .ungrouped]
            window.looseMembers = [
                .localGroup: (localGroup ?? []).filter { known.contains($0) },
                .ungrouped: (ungrouped ?? []).filter { known.contains($0) },
            ]
            if let selected, known.contains(selected) {
                window.selectedTabID = selected
            }
            return
        }
        window.frame = key.frame?.rect
        if windows.count == 1 {
            window.blocks = key.blocks
            window.looseMembers = [
                .localGroup: key.localGroup.filter { known.contains($0) },
                .ungrouped: key.ungrouped.filter { known.contains($0) },
            ]
        } else {
            var blocks: [SidebarBlock] = []
            var localGroup: [UUID] = []
            var ungrouped: [UUID] = []
            for item in windows {
                for block in item.blocks where !block.isLoose && !blocks.contains(block) {
                    blocks.append(block)
                }
                localGroup += item.localGroup.filter { known.contains($0) && !localGroup.contains($0) }
                ungrouped += item.ungrouped.filter { known.contains($0) && !ungrouped.contains($0) }
            }
            blocks.append(.localGroup)
            blocks.append(.ungrouped)
            window.blocks = blocks
            window.looseMembers = [.localGroup: localGroup, .ungrouped: ungrouped]
        }
        if let selected = key.selected, known.contains(selected) {
            window.selectedTabID = selected
        }
        window.section = key.section ?? .terminals
    }

    static func load() -> SessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }
}
