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

/// Shared store. Terminals, workspaces, and hosts are global; each `WindowState` is one view onto them.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var hosts: [SSHHost] = []
    @Published private(set) var configFailed = false
    @Published private(set) var tabs: [TerminalTab] = []
    @Published private(set) var launchEnvironment: [String] = []
    /// Merged terminals. A single host is not stored here. Each workspace is one split tree.
    @Published private(set) var workspaces: [Workspace] = []
    /// Open main windows, in creation order.
    @Published private(set) var windows: [WindowState] = []
    /// The window that last became key. Menu commands and external opens go here.
    @Published private(set) var keyWindowID: UUID?
    @Published var showingSettings = false
    /// Set once the app starts quitting. Windows then close without taking their terminals along,
    /// so the snapshot written at exit still lists every session.
    var isQuitting = false
    private var lastExternalKey = ""
    private var lastExternalAt = Date.distantPast
    /// Writes wait until the saved session has been read, so an empty launch cannot erase it.
    private var acceptSessionWrites = false
    /// Delayed auto-reconnect work keyed by tab.
    private var autoReconnectTasks: [UUID: Task<Void, Never>] = [:]
    /// Clears the reconnect counter once a session has stayed up briefly.
    private var stableConnectionTasks: [UUID: Task<Void, Never>] = [:]

    private static let maxAutoReconnectAttempts = 3
    /// Backoff before automatic attempt 1, 2, 3.
    private static let autoReconnectDelays: [TimeInterval] = [1, 3, 8]
    private static let stableConnectionNanoseconds: UInt64 = 5_000_000_000
    /// A connection that dies faster than this never really worked (auth, config, refused).
    /// Retrying would only repeat the password prompt, so it is left to the user.
    static let shortLivedConnectionSeconds: TimeInterval = 3
    private var configWatcher: SSHConfigWatcher?

    // MARK: - Windows

    /// The key window, or the first one. Nil only before any window exists.
    var keyWindow: WindowState? {
        if let keyWindowID, let window = windows.first(where: { $0.id == keyWindowID }) {
            return window
        }
        return windows.first
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

    /// "Window 3" unless the user gave it a name.
    func windowTitle(_ window: WindowState) -> String {
        if let name = window.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let index = windows.firstIndex(where: { $0.id == window.id }) ?? 0
        return String(format: String(localized: "Window %lld"), index + 1)
    }

    func renameWindow(_ window: WindowState, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        window.name = trimmed.isEmpty ? nil : trimmed
        persistSession()
    }

    func noteKeyWindow(_ window: WindowState) {
        for other in windows where other.id != window.id && other.isKey {
            other.isKey = false
        }
        if !window.isKey {
            window.isKey = true
        }
        if keyWindowID != window.id {
            keyWindowID = window.id
        }
    }

    /// Opens an empty window. It becomes key, so the next ⌘T lands in it.
    @discardableResult
    func newWindow() -> WindowState {
        let window = WindowState()
        windows.append(window)
        MainWindowManager.shared.show(window, model: self)
        persistSession()
        return window
    }

    /// The user closed a window. Its terminals end with it, unless this was the last window and
    /// the app is about to quit; then everything stays in the snapshot for next launch.
    func windowClosed(_ window: WindowState, remaining: Int) {
        guard remaining > 0, !isQuitting else {
            persistSession()
            return
        }
        for id in sidebarOrder(in: window) {
            closeTab(id, focusNext: false)
        }
        windows.removeAll { $0.id == window.id }
        if keyWindowID == window.id {
            keyWindowID = windows.first?.id
        }
        persistSession()
    }

    /// Moves terminals into a fresh window. A whole workspace moves as one block; anything else
    /// leaves its group and lands in the new window's loose groups.
    func openInNewWindow(_ ids: [UUID]) {
        let chosen = sessionIDs(ids)
        guard !chosen.isEmpty else { return }
        let target = newWindow()
        moveTabs(chosen, to: target)
    }

    func openBlockInNewWindow(_ block: SidebarBlock, from source: WindowState) {
        let ids = members(of: block, in: source)
        guard !ids.isEmpty else { return }
        let target = newWindow()
        if case .workspace = block {
            moveBlock(block, from: source, to: target, atIndex: 0)
        } else {
            moveTabs(ids, to: target)
        }
    }

    /// Terminals whose current window is not `target` go there. Workspaces move whole when every
    /// member is in the set; otherwise the members are pulled out one by one.
    func moveTabs(_ ids: [UUID], to target: WindowState) {
        let chosen = sessionIDs(ids)
        var remaining = chosen
        for workspace in workspaces {
            let members = WorkspaceBoard.leafIDs(workspace.layout)
            guard members.allSatisfy({ remaining.contains($0) }) else { continue }
            if let source = window(showing: workspace.id), source.id != target.id {
                moveBlock(.workspace(workspace.id), from: source, to: target, atIndex: target.blocks.count)
            }
            remaining.removeAll { members.contains($0) }
        }
        for id in remaining {
            guard let source = window(containing: id) else { continue }
            if source.id == target.id, WorkspaceBoard.index(containing: id, in: workspaces) == nil { continue }
            let tab = tabs.first { $0.id == id }
            let group = defaultLooseGroup(for: tab)
            place([id], intoLoose: group, in: target, beside: nil, after: true)
            syncSelection(in: source)
        }
        if let first = chosen.first {
            target.selectedTabID = first
            target.sidebarSelection = [first]
            target.sidebarAnchor = first
        }
        for window in windows {
            syncSelection(in: window)
        }
        persistSession()
    }

    /// A workspace block moves from one window's sidebar to another's.
    func moveBlock(_ block: SidebarBlock, from source: WindowState, to target: WindowState, atIndex index: Int) {
        guard case .workspace = block, source.id != target.id else { return }
        source.blocks.removeAll { $0 == block }
        var blocks = target.blocks
        blocks.removeAll { $0 == block }
        blocks.insert(block, at: min(max(index, 0), blocks.count))
        target.blocks = blocks
        syncSelection(in: source)
        if let first = members(of: block, in: target).first {
            target.selectedTabID = first
            target.sidebarSelection = [first]
            target.sidebarAnchor = first
        }
        persistSession()
    }

    // MARK: - Reading

    func selectedTab(in window: WindowState) -> TerminalTab? {
        guard let id = window.selectedTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    /// What the terminal area shows. A selected terminal outside every workspace is shown on its own.
    func displayRoot(in window: WindowState) -> PaneNode? {
        guard let selectedTabID = window.selectedTabID else { return nil }
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

    /// The loose group a standalone terminal falls into when nobody has placed it yet.
    private func defaultLooseGroup(for tab: TerminalTab?) -> SidebarBlock {
        tab?.isLocal == true ? .localGroup : .ungrouped
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
            return WorkspaceBoard.leafIDs(workspace.layout)
        case .localGroup, .ungrouped:
            return looseTabs(in: block, window: window).map(\.id)
        }
    }

    /// Sidebar order of one window: block order, members in pane order inside each block.
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

    func newTab(in window: WindowState? = nil) {
        reloadHosts()
        guard let target = window ?? keyWindow else { return }
        target.hostPickerPresented = true
    }

    // MARK: - Selection

    func selectTab(_ id: UUID, in window: WindowState) {
        window.selectedTabID = id
        if window.sidebarAnchor == nil {
            window.sidebarAnchor = id
        }
        persistSession()
        guard let tab = tabs.first(where: { $0.id == id }), tab.isSession, !tab.exited else { return }
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
        window.selectedTabID = id
        if window.sidebarSelection.count <= 1 {
            window.sidebarSelection = [id]
            window.sidebarAnchor = id
        }
        persistSession()
    }

    // MARK: - Opening

    func openHost(_ alias: String, in window: WindowState? = nil) {
        openHosts([alias], in: window)
    }

    /// `oneagent://open?…` from 1Panel. The same URL delivered twice in a short window
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

        let target = request.newWindow ? newWindow() : (keyWindow ?? newWindow())
        if request.reuse {
            openReusing(aliases, in: target, layout: request.layout, name: request.name)
        } else {
            openHosts(aliases, in: target, layout: request.layout, name: request.name)
        }
    }

    /// `reuse=1`: aliases that are already open are focused; only the missing ones start.
    /// With several aliases the whole set, old and new, becomes one workspace.
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
                moveTabs(existing, to: target)
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
        if let layout, WorkspaceBoard.availableLayouts(paneCount: ids.count).contains(layout) {
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

    /// One host stays under Ungrouped. Two or more become a workspace in the default layout,
    /// or in `layout` when the caller asked for one.
    func openHosts(_ aliases: [String], in window: WindowState? = nil, layout: WorkspaceLayout? = nil, name: String? = nil) {
        let aliases = aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !aliases.isEmpty else { return }
        let target = window ?? keyWindow ?? newWindow()
        target.hostPickerPresented = false
        activate(target)
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

    /// Opens a local login shell in the user home directory.
    func openLocalTerminal(in window: WindowState? = nil) {
        let directory = LocalTerminal.launchDirectory(LocalTerminal.homeDirectory)
        guard let target = window ?? keyWindow else { return }
        target.hostPickerPresented = false
        activate(target)
        Task {
            let environment = await SSHLaunchEnvironment.shared.get()
            guard !Task.isCancelled else { return }
            launchEnvironment = environment
            let tab = TerminalTab(id: UUID(), alias: nil, directory: directory, generation: 0, exited: false)
            tabs.append(tab)
            place([tab.id], intoLoose: .localGroup, in: target, beside: nil, after: true)
            target.selectedTabID = tab.id
            target.sidebarSelection = [tab.id]
            target.sidebarAnchor = tab.id
            persistSession()
        }
    }

    /// Reopens the windows and terminals that were on screen when the app last quit.
    /// Windows appear at once; terminals follow as soon as the login environment is known.
    func restoreLastSession() {
        let snapshot = SessionSnapshot.load()
        guard let snapshot, !snapshot.tabs.isEmpty else {
            if windows.isEmpty {
                let window = WindowState(frame: snapshot?.windows?.first?.frame?.rect)
                windows.append(window)
                MainWindowManager.shared.show(window, model: self)
            }
            acceptSessionWrites = true
            return
        }
        let known = Set(snapshot.tabs.map(\.id))
        for window in snapshot.windowStates(keeping: known) {
            windows.append(window)
        }
        if windows.isEmpty {
            windows.append(WindowState())
        }
        for window in windows {
            MainWindowManager.shared.show(window, model: self)
        }
        if let key = snapshot.keyWindow, let window = window(for: key) {
            MainWindowManager.shared.show(window, model: self)
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
            let live = Set(tabs.map(\.id))
            workspaces = Self.workspaces(snapshot.workspaces, keeping: live)
            syncBlocks()
            syncLooseMembers()
            for window in windows {
                syncSelection(in: window)
            }
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
        guard tabs[index].isSession, !tabs[index].isLocal else { return }
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
              tab.isSession, !tab.exited else { return }
        SSHTerminalRegistry.focus(tab.sessionID)
    }

    private func closeTab(_ id: UUID, focusNext: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let owner = window(containing: id)
        cancelAutoReconnect(id)
        cancelStableConnection(id)
        SSHTerminalRegistry.destroy(tabs[index].sessionID)
        tabs.remove(at: index)
        workspaces = WorkspaceBoard.extract(id, from: workspaces)
        for window in windows {
            for key in window.looseMembers.keys {
                window.looseMembers[key]?.removeAll { $0 == id }
            }
            window.sidebarSelection.remove(id)
            if window.sidebarAnchor == id {
                window.sidebarAnchor = nil
            }
        }
        if let owner {
            let order = sidebarOrder(in: owner)
            if owner.selectedTabID == id {
                owner.selectedTabID = order.first
            }
            syncSelection(in: owner)
            if focusNext, let next = owner.selectedTabID,
               let tab = tabs.first(where: { $0.id == next }), tab.isSession, !tab.exited {
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

    func mergeSidebar(_ ids: [UUID], in window: WindowState) {
        let ordered = sidebarOrder(in: window).filter { ids.contains($0) }
        guard ordered.count >= 2 else { return }
        let index = blockIndex(ofFirst: ordered, in: window)
        createWorkspace(from: ordered, atBlockIndex: index, in: window)
        window.sidebarSelection = Set(ordered)
        window.sidebarAnchor = ordered[0]
        selectTab(ordered[0], in: window)
    }

    /// Moves a proper subset of a workspace into a newly numbered workspace.
    func createAreaFromSidebar(_ ids: [UUID], in window: WindowState) {
        guard sidebarCanCreateArea(ids) else { return }
        mergeSidebar(ids, in: window)
    }

    /// Pulls these hosts out of their workspace. A workspace with one host left dissolves.
    func splitSidebar(_ ids: [UUID], in window: WindowState) {
        let ordered = sidebarOrder(in: window).filter { ids.contains($0) }
        guard sidebarSplits(ordered) else { return }
        for id in ordered {
            let tab = tabs.first { $0.id == id }
            place([id], intoLoose: defaultLooseGroup(for: tab), in: window, beside: nil, after: true)
        }
        window.sidebarSelection = Set(ordered)
        window.sidebarAnchor = ordered[0]
        selectTab(ordered[0], in: window)
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
    func joinWorkspace(_ ids: [UUID], _ workspaceID: UUID, beside target: UUID?, after: Bool) {
        let dragged = sessionIDs(ids).filter { $0 != target }
        guard !dragged.isEmpty else { return }
        let sources = Set(dragged.compactMap { self.window(containing: $0)?.id })
        var next = workspaces
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

    /// Two or more dragged terminals become a new workspace whose block sits at `blockIndex` of `window`.
    func createWorkspace(from ids: [UUID], atBlockIndex blockIndex: Int, in window: WindowState) {
        let dragged = sessionIDs(ids)
        guard dragged.count >= 2 else { return }
        let sources = Set(dragged.compactMap { self.window(containing: $0)?.id })
        let before = Set(workspaces.map(\.id))
        let next = WorkspaceBoard.merge(dragged, in: workspaces)
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
            joinWorkspace(ids, workspaceID, beside: nil, after: true)
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

    /// A block dragged into a different window's sidebar gap. Workspaces move; loose groups pour their members over.
    func dropBlock(_ dragged: SidebarBlock, from source: WindowState, intoGap index: Int, of target: WindowState) {
        if source.id == target.id {
            reorderSidebarBlock(dragged, toIndex: index, in: target)
            return
        }
        if case .workspace = dragged {
            moveBlock(dragged, from: source, to: target, atIndex: index)
        } else {
            let ids = members(of: dragged, in: source)
            for id in ids {
                let tab = tabs.first { $0.id == id }
                place([id], intoLoose: defaultLooseGroup(for: tab), in: target, beside: nil, after: true)
            }
            syncSelection(in: source)
            persistSession()
        }
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
        let members = WorkspaceBoard.leafIDs(workspace.layout)
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
        workspaces[index] = WorkspaceBoard.apply(layout, to: workspaces[index])
        persistSession()
    }

    func setSplitRatio(_ id: UUID, to ratio: CGFloat) {
        workspaces = WorkspaceBoard.setRatio(id, to: ratio, in: workspaces)
        persistSession()
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
                    name: window.name,
                    frame: window.frame.map { SessionSnapshot.Frame($0) },
                    blocks: window.blocks,
                    localGroup: window.looseMembers[.localGroup] ?? [],
                    ungrouped: window.looseMembers[.ungrouped] ?? [],
                    selected: window.selectedTabID
                )
            },
            keyWindow: keyWindowID
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

/// What is written to UserDefaults. Older snapshots had one implicit window; those fields still decode.
private struct SessionSnapshot: Codable {
    struct Tab: Codable {
        var id: UUID
        var alias: String?
        var directory: String? = nil
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

    /// Window states to recreate. An old single-window snapshot becomes one window.
    @MainActor
    func windowStates(keeping known: Set<UUID>) -> [WindowState] {
        if let windows, !windows.isEmpty {
            return windows.map { item in
                let state = WindowState(id: item.id, name: item.name, frame: item.frame?.rect)
                state.blocks = item.blocks
                state.looseMembers = [
                    .localGroup: item.localGroup.filter { known.contains($0) },
                    .ungrouped: item.ungrouped.filter { known.contains($0) },
                ]
                if let selected = item.selected, known.contains(selected) {
                    state.selectedTabID = selected
                }
                return state
            }
        }
        let state = WindowState()
        state.blocks = sidebarBlocks ?? [.localGroup, .ungrouped]
        state.looseMembers = [
            .localGroup: (localGroup ?? []).filter { known.contains($0) },
            .ungrouped: (ungrouped ?? []).filter { known.contains($0) },
        ]
        if let selected, known.contains(selected) {
            state.selectedTabID = selected
        }
        return [state]
    }

    static func load() -> SessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }
}
