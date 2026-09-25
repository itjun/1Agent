import AppKit
import Foundation

enum TabDropHighlight: Equatable {
    case edge(UUID, SplitEdge)
    case sidebarRow(UUID)
    case sidebar
}

struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    var alias: String?
    var generation: Int
    var exited: Bool

    var sessionID: String { "\(id.uuidString)#\(generation)" }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var hosts: [SSHHost] = []
    @Published private(set) var configFailed = false
    @Published private(set) var tabs: [TerminalTab] = []
    @Published var selectedTabID: UUID?
    @Published private(set) var launchEnvironment: [String] = []
    /// Nil when the visible area is a single tab. A split survives while another tab is selected.
    @Published private(set) var layout: PaneNode?
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

    /// What the terminal area shows. A selected tab outside the split is shown on its own.
    func displayRoot() -> PaneNode? {
        guard let selectedTabID else { return nil }
        guard tabs.first(where: { $0.id == selectedTabID })?.alias != nil else { return nil }
        if let layout, PaneLayout.contains(selectedTabID, in: layout) {
            return layout
        }
        return .leaf(selectedTabID)
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
        showingSettings = false
        selectedTabID = id
        persistSession()
        guard let tab = tabs.first(where: { $0.id == id }), tab.alias != nil, !tab.exited else { return }
        SSHTerminalRegistry.focus(tab.sessionID)
    }

    /// The terminal became first responder. Do not ask it to focus again.
    func notePaneFocused(_ id: UUID) {
        selectedTabID = id
        persistSession()
    }

    func openHost(_ alias: String) {
        openHosts([alias])
    }

    /// Opens one tab per SSH config alias. The same URL delivered twice in a short
    /// window (AppDelegate and SwiftUI) is ignored.
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
        NSApp.activate()
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
            break
        }
        Task {
            let environment = await SSHLaunchEnvironment.shared.get()
            guard !Task.isCancelled else { return }
            launchEnvironment = environment
            var lastID: UUID?
            for alias in aliases {
                let tab = TerminalTab(id: UUID(), alias: alias, generation: 0, exited: false)
                tabs.append(tab)
                lastID = tab.id
            }
            selectedTabID = lastID
            showingSettings = false
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
            tabs = snapshot.tabs.map {
                TerminalTab(id: $0.id, alias: $0.alias, generation: 0, exited: false)
            }
            let known = Set(tabs.map(\.id))
            layout = Self.layout(snapshot.layout, keeping: known)
            if let selected = snapshot.selected, known.contains(selected) {
                selectedTabID = selected
            } else {
                selectedTabID = tabs.last?.id
            }
            showingSettings = false
            acceptSessionWrites = true
            persistSession()
        }
    }

    func persistSessionIfReady() {
        persistSession()
    }

    func toggleSettings() {
        showingSettings.toggle()
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

    func markClosed(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].exited = true
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if let layout {
            self.layout = PaneLayout.splitRoot(PaneLayout.remove(id, from: layout))
        }
        guard selectedTabID == id else { return }
        let next = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        selectedTabID = next
        if let next, let tab = tabs.first(where: { $0.id == next }), tab.alias != nil, !tab.exited {
            SSHTerminalRegistry.focus(tab.sessionID)
        }
        persistSession()
    }

    func beginDrag(_ id: UUID) {
        guard tabs.first(where: { $0.id == id })?.alias != nil else { return }
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
        guard tabs.contains(where: { $0.id == dragged && $0.alias != nil }) else { endDrag(); return }
        guard tabs.contains(where: { $0.id == target && $0.alias != nil }) else { endDrag(); return }
        var root = layout ?? .leaf(target)
        if PaneLayout.contains(dragged, in: root) {
            root = PaneLayout.remove(dragged, from: root) ?? .leaf(target)
        }
        guard PaneLayout.contains(target, in: root) else { endDrag(); return }
        layout = PaneLayout.splitRoot(PaneLayout.split(root, target: target, with: dragged, edge: edge))
        selectedTabID = dragged
        endDrag()
        persistSession()
    }

    func receiveSidebarDrop(_ dragged: UUID, before target: UUID?) {
        guard tabs.contains(where: { $0.id == dragged }) else { endDrag(); return }
        if let layout, PaneLayout.contains(dragged, in: layout) {
            self.layout = PaneLayout.splitRoot(PaneLayout.remove(dragged, from: layout))
        }
        if let target, target != dragged {
            moveTab(dragged, before: target)
        }
        selectedTabID = dragged
        endDrag()
        persistSession()
    }

    func setSplitRatio(_ id: UUID, to ratio: CGFloat) {
        guard let layout else { return }
        self.layout = PaneLayout.setRatio(id, to: ratio, in: layout)
        persistSession()
    }

    private func moveTab(_ id: UUID, before other: UUID) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        let destination = tabs.firstIndex(where: { $0.id == other }) ?? tabs.count
        tabs.insert(tab, at: destination)
    }

    func closeSelectedTab() {
        guard let selectedTabID else { return }
        closeTab(selectedTabID)
    }

    private func persistSession() {
        guard acceptSessionWrites else { return }
        let snapshot = SessionSnapshot(
            tabs: tabs.compactMap { tab in
                guard let alias = tab.alias, !alias.isEmpty else { return nil }
                return SessionSnapshot.Tab(id: tab.id, alias: alias)
            },
            selected: selectedTabID,
            layout: layout
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: SessionSnapshot.storageKey)
    }

    private static func layout(_ node: PaneNode?, keeping known: Set<UUID>) -> PaneNode? {
        guard var node else { return nil }
        for id in leafIDs(node) where !known.contains(id) {
            guard let next = PaneLayout.remove(id, from: node) else { return nil }
            node = next
        }
        return PaneLayout.splitRoot(node)
    }

    private static func leafIDs(_ node: PaneNode) -> [UUID] {
        switch node {
        case .leaf(let id):
            return [id]
        case .split(let split):
            return leafIDs(split.leading) + leafIDs(split.trailing)
        }
    }
}

private struct SessionSnapshot: Codable {
    struct Tab: Codable {
        var id: UUID
        var alias: String
    }

    static let storageKey = "session.openTabs"

    var tabs: [Tab]
    var selected: UUID?
    var layout: PaneNode?

    static func load() -> SessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }
}
