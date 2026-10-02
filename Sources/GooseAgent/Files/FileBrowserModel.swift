import AppKit
import Combine
import Foundation

/// One column of a file pane: this Mac or one host. Path, history, selection, sort and filter,
/// like one `SftpPane` in 1Panel.
@MainActor
final class FileColumn: ObservableObject, Identifiable {
    enum SortKey {
        case name
        case modified
        case size
        case kind
    }

    /// Text, or a Quick Look of any other file, shown in the preview drawer.
    struct Preview: Equatable {
        var entry: FileEntry
        var decoded: TextFile.Decoded?
        /// Only the first `FileBrowserLayout.previewByteLimit` bytes are shown.
        var truncated: Bool
        var error: String?
        /// A local copy for Quick Look. Images, PDFs and the like; text files leave it nil.
        var quickLook: URL? = nil
        var isQuickLook = false
    }

    let fileSystem: any FileSystem
    nonisolated let id = UUID()
    @Published private(set) var directory = ""
    @Published private(set) var home = ""
    @Published private(set) var entries: [FileEntry] = []
    @Published private(set) var loading = false
    @Published var error: String?
    @Published private(set) var backStack: [String] = []
    @Published private(set) var forwardStack: [String] = []
    @Published var selection: Set<String> = []
    @Published var filter = ""
    @Published var showHidden = false
    @Published var sortKey: SortKey = .name
    @Published var ascending = true
    @Published var preview: Preview?
    private var anchor: Int?
    private var loadTask: Task<Void, Never>?
    /// False until `start` has its first folder; an `open` before then replaces that folder.
    private var started = false
    private var startOverride: String?
    var onDirectoryChange: ((String) -> Void)?

    init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
    }

    var title: String {
        fileSystem.host ?? String(localized: "This Mac")
    }

    var isRemote: Bool { fileSystem.isRemote }

    /// Folders first, then the chosen column; hidden files and the filter applied.
    var shown: [FileEntry] {
        let keyword = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = entries.filter { entry in
            if !showHidden, entry.isHidden { return false }
            if !keyword.isEmpty, !entry.name.lowercased().contains(keyword) { return false }
            return true
        }
        return visible.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order: Bool
            switch sortKey {
            case .name:
                order = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .modified:
                order = (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
            case .size:
                order = a.size < b.size
            case .kind:
                order = Self.kind(of: a).localizedStandardCompare(Self.kind(of: b)) == .orderedAscending
            }
            return ascending ? order : !order
        }
    }

    var selectedEntries: [FileEntry] {
        shown.filter { selection.contains($0.path) }
    }

    var hasHiddenEntries: Bool { entries.contains(where: \.isHidden) }

    static func kind(of entry: FileEntry) -> String {
        if entry.isDirectory { return String(localized: "Folder") }
        let ext = (entry.name as NSString).pathExtension
        guard !ext.isEmpty, !entry.name.hasPrefix(".") || entry.name.dropFirst().contains(".") else {
            return String(localized: "File")
        }
        return ext.uppercased()
    }

    // MARK: Navigation

    func start(at path: String?) {
        Task {
            do {
                home = try await fileSystem.home()
            } catch {
                self.error = error.localizedDescription
            }
            let first = startOverride ?? path.flatMap { $0.isEmpty ? nil : $0 } ?? (home.isEmpty ? "/" : home)
            started = true
            load(first, record: false, fallback: home.isEmpty || first == home ? nil : home)
        }
    }

    func open(_ path: String) {
        let clean = FileRules.normalize(path)
        guard started else {
            startOverride = clean
            return
        }
        guard clean != directory else { return }
        load(clean, record: true)
    }

    func back() {
        guard let previous = backStack.popLast() else { return }
        if !directory.isEmpty { forwardStack.append(directory) }
        load(previous, record: false)
    }

    func forward() {
        guard let next = forwardStack.popLast() else { return }
        if !directory.isEmpty { backStack.append(directory) }
        load(next, record: false)
    }

    func goHome() {
        guard !home.isEmpty else { return }
        open(home)
    }

    func refresh() {
        guard !directory.isEmpty else { return }
        load(directory, record: false, keepSelection: true)
    }

    /// `fallback` opens instead when `path` fails, e.g. a restored folder that was deleted.
    private func load(_ path: String, record: Bool, keepSelection: Bool = false, fallback: String? = nil) {
        loadTask?.cancel()
        loading = true
        let previous = directory
        loadTask = Task {
            do {
                let listed = try await fileSystem.list(path)
                guard !Task.isCancelled else { return }
                if record, !previous.isEmpty, previous != path {
                    backStack.append(previous)
                    forwardStack.removeAll()
                }
                let changed = directory != path
                directory = path
                entries = listed
                error = nil
                if changed || !keepSelection {
                    selection = []
                    anchor = nil
                    filter = ""
                } else {
                    let paths = Set(listed.map(\.path))
                    selection = selection.intersection(paths)
                }
                loading = false
                if changed { onDirectoryChange?(path) }
            } catch {
                guard !Task.isCancelled else { return }
                if let fallback {
                    load(fallback, record: false)
                    return
                }
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    // MARK: Selection

    /// Click, ⌘-click toggles, ⇧-click selects the range from the last plain click.
    func click(_ entry: FileEntry, modifiers: NSEvent.ModifierFlags) {
        let list = shown
        guard let index = list.firstIndex(of: entry) else { return }
        if modifiers.contains(.shift), let anchor, anchor < list.count {
            let range = min(anchor, index)...max(anchor, index)
            selection = Set(list[range].map(\.path))
            return
        }
        if modifiers.contains(.command) {
            if selection.contains(entry.path) {
                selection.remove(entry.path)
            } else {
                selection.insert(entry.path)
            }
            anchor = index
            return
        }
        selection = [entry.path]
        anchor = index
    }

    /// Right-click on a row outside the selection selects just that row.
    func prepareContextMenu(for entry: FileEntry) {
        guard !selection.contains(entry.path) else { return }
        selection = [entry.path]
        anchor = shown.firstIndex(of: entry)
    }

    func clearSelection() {
        selection = []
        anchor = nil
    }

    func selectAll() {
        let list = shown
        selection = Set(list.map(\.path))
        anchor = list.isEmpty ? nil : 0
    }

    /// ↑ / ↓. Returns the newly selected row so the list can scroll to it.
    @discardableResult
    func moveSelection(by delta: Int) -> FileEntry? {
        let list = shown
        guard !list.isEmpty else { return nil }
        var index = list.lastIndex { selection.contains($0.path) } ?? (delta > 0 ? -1 : 0)
        index = min(list.count - 1, max(0, index + delta))
        selection = [list[index].path]
        anchor = index
        return list[index]
    }

    func toggleSort(_ key: SortKey) {
        if sortKey == key {
            ascending.toggle()
        } else {
            sortKey = key
            ascending = true
        }
    }

    // MARK: Preview

    func showPreview(_ entry: FileEntry) {
        preview = Preview(entry: entry, decoded: nil, truncated: false, error: nil)
        let limit = FileBrowserLayout.previewByteLimit
        Task {
            do {
                let data = try await fileSystem.read(entry.path, limit: limit + 1)
                guard preview?.entry == entry else { return }
                let truncated = data.count > limit
                let decoded = TextFile.decode(truncated ? data.prefix(limit) : data)
                preview = Preview(
                    entry: entry, decoded: decoded, truncated: truncated,
                    error: decoded == nil ? String(localized: "Not a text file") : nil
                )
            } catch {
                guard preview?.entry == entry else { return }
                preview?.error = error.localizedDescription
            }
        }
    }

    /// Quick Look of a non-text file. A file on the host is downloaded to a temporary folder first.
    func showQuickLook(_ entry: FileEntry, window: NSWindow?) {
        guard isRemote else {
            preview = Preview(
                entry: entry, decoded: nil, truncated: false, error: nil,
                quickLook: URL(fileURLWithPath: entry.path), isQuickLook: true
            )
            return
        }
        preview = Preview(entry: entry, decoded: nil, truncated: false, error: nil, isQuickLook: true)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-open-\(UUID().uuidString)")
        Task {
            var toast: Int?
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let paths = try await FileTransfer.run(
                    [FileTransfer.Item(path: entry.path, isDirectory: false)],
                    from: fileSystem, to: LocalFileSystem(), into: staging.path, choice: .rename,
                    window: window, started: { toast = $0 }
                )
                guard preview?.entry == entry, let path = paths.first else { return }
                preview?.quickLook = URL(fileURLWithPath: path)
            } catch {
                TransferToast.shared.fail(toast, error.localizedDescription, in: window)
                guard preview?.entry == entry else { return }
                preview?.error = error.localizedDescription
            }
        }
    }

    /// Rewrites the previewed file as UTF-8 with LF line endings, after copying it to `name.bak`.
    func convertPreviewToUTF8LF() async throws {
        guard let current = preview, let decoded = current.decoded, !current.truncated else { return }
        let backup = current.entry.path + ".bak"
        let existing = try await fileSystem.existingNames(
            in: FileRules.parent(of: current.entry.path), among: [(backup as NSString).lastPathComponent]
        )
        if !existing.isEmpty {
            try await fileSystem.delete([backup])
        }
        try await fileSystem.copy(current.entry.path, to: backup)
        try await fileSystem.write(TextFile.utf8LF(decoded.text), to: current.entry.path)
        showPreview(current.entry)
        refresh()
    }
}

/// The Files area of one window: panes arranged in a grid like the terminal canvas, each with any
/// number of tabs on this Mac or on hosts. Tabs move within and between panes, and a tab dropped on
/// a pane's edge splits it. Transfers go to the current tab of the pane focused before this one.
@MainActor
final class FileWorkspace: ObservableObject {
    /// One pane of the grid: its tabs and which one is shown.
    struct Group: Identifiable {
        let id: UUID
        var tabs: [FileColumn] = []
        var activeID: UUID?

        var active: FileColumn? { tabs.first { $0.id == activeID } }
    }

    /// What `files.tabs` holds: the grid, and each pane's tabs (host and folder) and current tab.
    /// Older versions saved `left` / `right` (or `local` / `remote`) lists; those load as two panes.
    struct Saved: Codable {
        struct Tab: Codable {
            var host: String?
            var path: String?
        }

        struct SavedGroup: Codable {
            var id: UUID
            var tabs: [Tab]
            var active: Int
        }

        var layout: PaneNode?
        var groups: [SavedGroup] = []
        var focused: UUID?

        private enum CodingKeys: String, CodingKey {
            case layout, groups, focused
            case left, right, activeLeft, activeRight
            case local, remote, activeLocal, activeRemote
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let groups = try values.decodeIfPresent([SavedGroup].self, forKey: .groups) {
                self.groups = groups
                layout = try values.decodeIfPresent(PaneNode.self, forKey: .layout)
                focused = try values.decodeIfPresent(UUID.self, forKey: .focused)
                return
            }
            let left = try values.decodeIfPresent([Tab].self, forKey: .left)
                ?? values.decodeIfPresent([Tab].self, forKey: .local) ?? []
            let right = try values.decodeIfPresent([Tab].self, forKey: .right)
                ?? values.decodeIfPresent([Tab].self, forKey: .remote) ?? []
            let activeLeft = try values.decodeIfPresent(Int.self, forKey: .activeLeft)
                ?? values.decodeIfPresent(Int.self, forKey: .activeLocal) ?? 0
            let activeRight = try values.decodeIfPresent(Int.self, forKey: .activeRight)
                ?? values.decodeIfPresent(Int.self, forKey: .activeRemote) ?? 0
            let leading = SavedGroup(id: UUID(), tabs: left, active: activeLeft)
            let trailing = SavedGroup(id: UUID(), tabs: right, active: activeRight)
            groups = [leading, trailing]
            layout = .split(SplitNode(id: UUID(), axis: .vertical, ratio: 0.5,
                                      leading: .leaf(leading.id), trailing: .leaf(trailing.id)))
            focused = leading.id
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encodeIfPresent(layout, forKey: .layout)
            try values.encode(groups, forKey: .groups)
            try values.encodeIfPresent(focused, forKey: .focused)
        }
    }

    @Published private(set) var layout: PaneNode
    @Published private(set) var groups: [UUID: Group] = [:]
    /// The pane last clicked or opened. ⌘W closes its current tab.
    @Published private(set) var focusedGroupID: UUID
    /// Panes in the order they were focused, latest last: "the other pane" for transfers.
    private var focusHistory: [UUID] = []
    /// Where hosts chosen in the host picker open; nil picks a pane as `openRemote` does.
    var pickerGroupID: UUID?
    weak var model: AppModel?
    weak var windowState: WindowState?
    var onChange: ((Saved) -> Void)?

    init(saved: Saved?, model: AppModel, window: WindowState) {
        self.model = model
        windowState = window
        let saved = saved ?? Saved()
        var groups: [UUID: Group] = [:]
        for savedGroup in saved.groups {
            var group = Group(id: savedGroup.id)
            group.tabs = savedGroup.tabs.map { Self.makeColumn(host: $0.host.flatMap { $0.isEmpty ? nil : $0 }, path: $0.path) }
            if !group.tabs.isEmpty {
                group.activeID = group.tabs[min(max(savedGroup.active, 0), group.tabs.count - 1)].id
            }
            groups[group.id] = group
        }
        var layout = saved.layout
        // Keep only panes that both the grid and the list know, and drop empty ones.
        if let current = layout {
            for id in WorkspaceBoard.leafIDs(current) where groups[id]?.tabs.isEmpty ?? true {
                layout = layout.flatMap { PaneLayout.remove(id, from: $0) }
            }
        }
        if let current = layout {
            let leaves = Set(WorkspaceBoard.leafIDs(current))
            groups = groups.filter { leaves.contains($0.key) }
        }
        if layout == nil || groups.isEmpty {
            var group = Group(id: UUID())
            let home = Self.makeColumn(host: nil, path: NSHomeDirectory())
            group.tabs = [home]
            group.activeID = home.id
            groups = [group.id: group]
            layout = .leaf(group.id)
        }
        let root = layout!
        self.groups = groups
        self.layout = root
        let leaves = WorkspaceBoard.leafIDs(root)
        focusedGroupID = saved.focused.flatMap { leaves.contains($0) ? $0 : nil } ?? leaves[0]
        focusHistory = leaves.filter { $0 != focusedGroupID } + [focusedGroupID]
        for column in allTabs {
            column.onDirectoryChange = { [weak self] _ in self?.save() }
        }
    }

    /// Panes in reading order.
    var groupIDs: [UUID] { WorkspaceBoard.leafIDs(layout) }
    var allTabs: [FileColumn] { groupIDs.flatMap { groups[$0]?.tabs ?? [] } }
    var focusedColumn: FileColumn? { groups[focusedGroupID]?.active }

    func groupID(of column: FileColumn) -> UUID? {
        groups.first { $0.value.tabs.contains { $0 === column } }?.key
    }

    /// The current tab of the pane focused before `column`'s, where "Upload" and "Download" send to.
    func other(than column: FileColumn) -> FileColumn? {
        let own = groupID(of: column)
        for id in focusHistory.reversed() where id != own {
            if let active = groups[id]?.active { return active }
        }
        return nil
    }

    func focus(_ column: FileColumn) {
        guard let id = groupID(of: column) else { return }
        focusGroup(id)
    }

    private func focusGroup(_ id: UUID) {
        focusedGroupID = id
        focusHistory.removeAll { $0 == id }
        focusHistory.append(id)
    }

    // MARK: Tabs

    @discardableResult
    func addLocalTab(at path: String?, in groupID: UUID? = nil) -> FileColumn {
        let target = groupID ?? preferredGroup(remote: false)
        let current = groups[target]?.active.flatMap { $0.isRemote ? nil : $0.directory }
        let column = makeColumn(host: nil, path: path ?? current ?? NSHomeDirectory())
        insert(column, into: target, at: nil)
        return column
    }

    @discardableResult
    func addRemoteTab(host: String, at path: String? = nil, in groupID: UUID? = nil) -> FileColumn {
        let column = makeColumn(host: host, path: path)
        insert(column, into: groupID ?? preferredGroup(remote: true), at: nil)
        return column
    }

    /// The host's tab if one is open (in `groupID` when given), moved to `path` when given;
    /// otherwise a new tab there.
    func openRemote(host: String, at path: String?, in groupID: UUID? = nil) {
        let candidates = groupID.map { groups[$0]?.tabs ?? [] } ?? allTabs
        if let existing = candidates.first(where: { $0.fileSystem.host == host }) {
            activate(existing)
            if let path, !path.isEmpty {
                existing.open(path)
            }
            return
        }
        addRemoteTab(host: host, at: path, in: groupID)
    }

    /// A tab on this Mac moves to `path`: the focused pane's current tab, else another pane's
    /// current tab, else any; without any, a new tab.
    func showLocal(_ path: String?) {
        let current = ([focusedGroupID] + focusHistory.reversed()).compactMap { groups[$0]?.active }
        guard let column = current.first(where: { !$0.isRemote }) ?? allTabs.first(where: { !$0.isRemote }) else {
            addLocalTab(at: path)
            return
        }
        activate(column)
        if let path, !path.isEmpty {
            column.open(path)
        }
    }

    /// Where a new tab of that kind goes: the focused pane if its current tab is of that kind, else
    /// the most recent pane showing that kind. Without one, a host gets a new pane on the right of
    /// the focused one, so this Mac and the host sit side by side.
    private func preferredGroup(remote: Bool) -> UUID {
        for id in [focusedGroupID] + focusHistory.reversed() {
            if let active = groups[id]?.active, active.isRemote == remote { return id }
        }
        if let empty = groupIDs.first(where: { groups[$0]?.tabs.isEmpty ?? false }) { return empty }
        if remote, groups.count == 1 {
            let id = UUID()
            groups[id] = Group(id: id)
            layout = PaneLayout.split(layout, target: focusedGroupID, with: id, edge: .right)
            return id
        }
        return focusedGroupID
    }

    func activate(_ column: FileColumn) {
        guard let id = groupID(of: column) else { return }
        groups[id]?.activeID = column.id
        focusGroup(id)
        save()
    }

    func close(_ column: FileColumn) {
        guard let id = groupID(of: column) else { return }
        detach(column, from: id)
        removeIfEmpty(id)
        save()
    }

    /// ⌘W in the Files area. False when there is nothing to close there.
    func closeFocusedTab() -> Bool {
        guard let column = focusedColumn else { return false }
        close(column)
        return true
    }

    /// Dragging within a tab strip: `column` takes `target`'s place.
    func reorder(_ column: FileColumn, toward target: FileColumn) {
        guard target !== column, let id = groupID(of: column), var group = groups[id],
              let from = group.tabs.firstIndex(where: { $0 === column }),
              let to = group.tabs.firstIndex(where: { $0 === target }) else { return }
        group.tabs.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        groups[id] = group
        activate(column)
    }

    /// Whether dropping `column` on pane `groupID` toward `edge` changes anything: a tab cannot join
    /// its own pane, and the only tab of a pane cannot split that pane.
    func canDrop(_ column: FileColumn, on target: UUID, edge: SplitEdge) -> Bool {
        guard let source = groupID(of: column), groups[target] != nil else { return false }
        guard source == target else { return true }
        return edge != .center && (groups[source]?.tabs.count ?? 0) > 1
    }

    /// A tab dropped on a pane: `.center` joins its tabs (before `before`, else last), an edge splits
    /// the pane and gives the tab a new pane there. A pane left without tabs closes.
    func drop(_ column: FileColumn, on target: UUID, edge: SplitEdge, before: FileColumn? = nil) {
        guard canDrop(column, on: target, edge: edge), let source = groupID(of: column) else { return }
        detach(column, from: source)
        if edge == .center {
            let index = before.flatMap { before in groups[target]?.tabs.firstIndex { $0 === before } }
            insert(column, into: target, at: index)
        } else {
            let id = UUID()
            groups[id] = Group(id: id)
            layout = PaneLayout.split(layout, target: target, with: id, edge: edge)
            insert(column, into: id, at: nil)
        }
        removeIfEmpty(source)
        save()
    }

    func setSplitRatio(_ id: UUID, to ratio: CGFloat) {
        layout = PaneLayout.setRatio(id, to: ratio, in: layout)
        save()
    }

    func evenOutSplit(_ id: UUID) {
        guard let ratio = PaneLayout.evenRatio(for: id, in: layout) else { return }
        setSplitRatio(id, to: ratio)
    }

    func ratio(of splitID: UUID) -> CGFloat {
        func find(_ node: PaneNode) -> CGFloat? {
            guard case .split(let split) = node else { return nil }
            if split.id == splitID { return split.ratio }
            return find(split.leading) ?? find(split.trailing)
        }
        return find(layout) ?? 0.5
    }

    private func insert(_ column: FileColumn, into id: UUID, at index: Int?) {
        guard var group = groups[id] else { return }
        group.tabs.insert(column, at: min(index ?? group.tabs.count, group.tabs.count))
        groups[id] = group
        activate(column)
    }

    private func detach(_ column: FileColumn, from id: UUID) {
        guard var group = groups[id], let index = group.tabs.firstIndex(where: { $0 === column }) else { return }
        group.tabs.remove(at: index)
        if group.activeID == column.id {
            group.activeID = group.tabs.isEmpty ? nil : group.tabs[min(index, group.tabs.count - 1)].id
        }
        groups[id] = group
    }

    /// The last pane stays, empty, so the area always has somewhere to open tabs.
    private func removeIfEmpty(_ id: UUID) {
        guard groups[id]?.tabs.isEmpty == true, groups.count > 1,
              let remaining = PaneLayout.remove(id, from: layout) else { return }
        groups[id] = nil
        layout = remaining
        focusHistory.removeAll { $0 == id }
        if pickerGroupID == id { pickerGroupID = nil }
        if focusedGroupID == id, let last = focusHistory.last ?? groupIDs.first {
            focusGroup(last)
        }
    }

    private func makeColumn(host: String?, path: String?) -> FileColumn {
        let column = Self.makeColumn(host: host, path: path)
        column.onDirectoryChange = { [weak self] _ in
            self?.save()
        }
        return column
    }

    private static func makeColumn(host: String?, path: String?) -> FileColumn {
        let fileSystem: any FileSystem = host.map { RemoteFileSystem(alias: $0) } ?? LocalFileSystem()
        let column = FileColumn(fileSystem: fileSystem)
        column.start(at: path)
        return column
    }

    private func save() {
        func saved(_ column: FileColumn) -> Saved.Tab {
            Saved.Tab(host: column.fileSystem.host, path: column.directory.isEmpty ? nil : column.directory)
        }
        var state = Saved()
        state.layout = layout
        state.groups = groupIDs.compactMap { id in
            guard let group = groups[id] else { return nil }
            return Saved.SavedGroup(id: id, tabs: group.tabs.map(saved),
                                    active: group.tabs.firstIndex { $0.id == group.activeID } ?? 0)
        }
        state.focused = focusedGroupID
        onChange?(state)
    }

    // MARK: Actions

    /// "Send to the other side": the selection goes to the other side's current folder.
    func send(_ entries: [FileEntry], from column: FileColumn, into directory: String? = nil, window: NSWindow?) {
        guard let destination = other(than: column) else { return }
        transfer(entries.map { FileTransfer.Item(path: $0.path, isDirectory: $0.isDirectory) },
                 from: column.fileSystem, to: destination, into: directory ?? destination.directory, window: window)
    }

    /// Files from Finder, or from another tab, dropped on `column`.
    func receive(_ items: [FileTransfer.Item], from source: any FileSystem, on column: FileColumn,
                 into directory: String? = nil, window: NSWindow?) {
        transfer(items, from: source, to: column, into: directory ?? column.directory, window: window)
    }

    private func transfer(_ items: [FileTransfer.Item], from source: any FileSystem, to column: FileColumn,
                          into directory: String, window: NSWindow?) {
        guard !items.isEmpty, !directory.isEmpty else { return }
        Task {
            var toast: Int?
            do {
                guard let prepared = try await UploadCheck.prepare(
                    items, from: source, to: column.fileSystem, window: window
                ) else { return }
                defer { prepared.cleanUp() }
                let existing = try await FileTransfer.conflicts(
                    prepared.items, from: source, to: column.fileSystem, into: directory
                )
                guard let choice = await FileTransfer.askAboutConflicts(existing, in: window) else { return }
                _ = try await FileTransfer.run(
                    prepared.items, from: source, to: column.fileSystem, into: directory, choice: choice,
                    window: window, started: { toast = $0 }
                )
                column.refresh()
            } catch {
                TransferToast.shared.fail(toast, error.localizedDescription, in: window)
                column.refresh()
            }
        }
    }

    /// Two confirmations, as in 1Panel: deleted files do not go to the Trash.
    func delete(_ entries: [FileEntry], in column: FileColumn, window: NSWindow?) {
        guard !entries.isEmpty else { return }
        for entry in entries {
            let home = column.isRemote ? nil : NSHomeDirectory()
            if let refusal = FileRules.deleteRefusal(entry.path, remote: column.isRemote, home: home) {
                TransferToast.shared.fail(nil, refusal, in: window)
                return
            }
        }
        guard FileBrowserDialogs.confirmDelete(entries, again: false),
              FileBrowserDialogs.confirmDelete(entries, again: true) else { return }
        Task {
            do {
                try await column.fileSystem.delete(entries.map(\.path))
                let toast = TransferToast.shared.begin(String(localized: "Deleting…"), in: window)
                TransferToast.shared.finish(toast, String(localized: "Deleted"))
            } catch {
                TransferToast.shared.fail(nil, error.localizedDescription, in: window)
            }
            column.refresh()
        }
    }

    func create(folder: Bool, in column: FileColumn, window: NSWindow?) {
        guard let name = FileBrowserDialogs.askName(folder: folder) else { return }
        let path = FileRules.join(column.directory, name)
        Task {
            do {
                if folder {
                    try await column.fileSystem.makeDirectory(path)
                } else {
                    try await column.fileSystem.createFile(path)
                }
                let toast = TransferToast.shared.begin(String(localized: "Creating…"), in: window)
                TransferToast.shared.finish(toast, String(localized: "Created"))
                column.refresh()
                column.selection = [path]
            } catch {
                TransferToast.shared.fail(nil, error.localizedDescription, in: window)
            }
        }
    }

    /// A folder opens in place; any file opens in the preview drawer, as text when it can be read
    /// as text, otherwise as Quick Look.
    func open(_ entry: FileEntry, in column: FileColumn, window: NSWindow?) {
        if entry.isDirectory {
            column.open(entry.path)
        } else if TextFile.isTextName(entry.name) {
            column.showPreview(entry)
        } else {
            column.showQuickLook(entry, window: window)
        }
    }

    func copyPaths(_ entries: [FileEntry], in column: FileColumn) {
        let paths = entries.isEmpty ? [column.directory] : entries.map(\.path)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    /// A new terminal in the selected folder, or in this column's folder, in the Terminals area.
    func openTerminal(_ entries: [FileEntry], in column: FileColumn) {
        guard let model, let windowState else { return }
        let folder = entries.count == 1 && entries[0].isDirectory ? entries[0].path : column.directory
        guard !folder.isEmpty else { return }
        model.openTerminal(at: folder, host: column.fileSystem.host, in: windowState)
    }
}

/// One `FileWorkspace` per window, kept while the app runs. The tabs are also saved for the next launch.
@MainActor
final class FileBrowserStore {
    static let shared = FileBrowserStore()
    static let tabsKey = "files.tabs"
    private var workspaces: [UUID: FileWorkspace] = [:]

    func workspace(for window: WindowState, model: AppModel) -> FileWorkspace {
        if let existing = workspaces[window.id] { return existing }
        let saved = UserDefaults.standard.data(forKey: Self.tabsKey)
            .flatMap { try? JSONDecoder().decode(FileWorkspace.Saved.self, from: $0) }
        let created = FileWorkspace(saved: saved, model: model, window: window)
        created.onChange = { saved in
            if let data = try? JSONEncoder().encode(saved) {
                UserDefaults.standard.set(data, forKey: Self.tabsKey)
            }
        }
        workspaces[window.id] = created
        return created
    }

    /// Something outside the Files area changed files on `host` (nil: this Mac).
    func refresh(host: String?) {
        for workspace in workspaces.values {
            for column in workspace.allTabs where column.fileSystem.host == host {
                column.refresh()
            }
        }
    }
}

/// Rows dragged out of a file column. The pasteboard carries their paths as text, which a
/// terminal types at the prompt; a drop on the other column reads the paths from here.
@MainActor
/// SwiftUI reuses the last drag's item provider without calling `onDrag` again, so the payload is
/// never cleared; a drag is ours while the drag pasteboard still holds the text it wrote.
enum FileBrowserDrag {
    struct Payload {
        var column: FileColumn
        var entries: [FileEntry]
        var text: String
    }

    static var current: Payload?

    static var active: Payload? {
        guard let current, NSPasteboard(name: .drag).string(forType: .string) == current.text else { return nil }
        return current
    }
}

/// Modal questions of the file pane, worded as in 1Panel.
@MainActor
enum FileBrowserDialogs {
    static func confirmDelete(_ entries: [FileEntry], again: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        let first = entries[0]
        if entries.count > 1 {
            alert.messageText = again
                ? String(format: String(localized: "Confirm again: delete these %d items?"), entries.count)
                : String(format: String(localized: "Delete these %d items?"), entries.count)
        } else if first.isDirectory {
            alert.messageText = again
                ? String(format: String(localized: "Confirm again: delete the folder “%@”?"), first.name)
                : String(format: String(localized: "Delete the folder “%@”?"), first.name)
        } else {
            alert.messageText = again
                ? String(format: String(localized: "Confirm again: delete the file “%@”?"), first.name)
                : String(format: String(localized: "Delete the file “%@”?"), first.name)
        }
        var lines = entries.prefix(6).map(\.name)
        if entries.count > 6 {
            lines.append(String(format: String(localized: "and %d more"), entries.count - 6))
        }
        let note: String
        if again {
            note = String(localized: "Confirm again: deleted items cannot be restored.")
        } else if entries.contains(where: \.isDirectory) {
            note = String(localized: "Everything inside the folders is deleted too and cannot be restored.")
        } else {
            note = String(localized: "Deleted items cannot be restored.")
        }
        alert.informativeText = (entries.count > 1 ? lines.joined(separator: "\n") + "\n\n" : "") + note
        alert.addButton(withTitle: again ? String(localized: "Confirm Delete") : String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func askName(folder: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = folder ? String(localized: "New Folder") : String(localized: "New File")
        alert.informativeText = folder
            ? String(localized: "Folder name")
            : String(localized: "File name (created empty)")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = folder ? String(localized: "New Folder") : String(localized: "New File.txt")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Create"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        return name
    }
}
