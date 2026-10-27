import AppKit
import Combine
import Foundation

/// One column of a file pane: this Mac or one host. Path, history, selection, sort and filter,
/// like one `SftpPane` in 1Panel.
@MainActor
final class FileColumn: ObservableObject, Identifiable {
    typealias SortKey = FileSortKey

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
        var revision: FileRevision? = nil
    }

    let fileSystem: any FileSystem
    nonisolated let id = UUID()
    @Published private(set) var directory = ""
    @Published private(set) var home = ""
    @Published private(set) var entries: [FileEntry] = []
    @Published private(set) var loading = false
    @Published var error: String?
    @Published private(set) var backStack: [String] = [] { didSet { onStateChange?() } }
    @Published private(set) var forwardStack: [String] = [] { didSet { onStateChange?() } }
    @Published var selection: Set<String> = [] { didSet { onStateChange?() } }
    @Published var filter = "" { didSet { reconcileScrollAnchor(); onStateChange?() } }
    @Published var showHidden = false { didSet { reconcileScrollAnchor(); onStateChange?() } }
    @Published var sortKey: SortKey = .kind { didSet { onStateChange?() } }
    @Published var ascending = true { didSet { onStateChange?() } }
    @Published var scrollAnchor: String? { didSet { onStateChange?() } }
    @Published var preview: Preview? { didSet { onStateChange?() } }
    @Published private(set) var readingEncoding: TextFile.Encoding?
    private var previewRequest = UUID()
    private var restoredState: FileWorkspace.Saved.Tab?
    private var anchor: Int?
    private var loadTask: Task<Void, Never>?
    /// The initial list can fail before `directory` has a successfully loaded value.
    private var attemptedPath: String?
    /// False until `start` has its first folder; an `open` before then replaces that folder.
    private var started = false
    private var startOverride: String?
    private var initialPath: String?
    var savedPath: String? { directory.isEmpty ? startOverride ?? initialPath : directory }
    var savedScrollAnchor: String? { restoredState?.scrollAnchor ?? scrollAnchor }
    var savedPreviewPath: String? { preview?.entry.path ?? restoredState?.previewPath }
    var onDirectoryChange: ((String) -> Void)?
    var onStateChange: (() -> Void)?

    func restore(_ state: FileWorkspace.Saved.Tab) {
        restoredState = state
        initialPath = state.path
        filter = state.filter ?? ""
        selection = Set(state.selection ?? [])
        showHidden = state.showHidden ?? false
        sortKey = state.sortKey ?? .kind
        ascending = state.ascending ?? true
        readingEncoding = state.readingEncoding
        backStack = state.backStack ?? []
        forwardStack = state.forwardStack ?? []
        scrollAnchor = state.scrollAnchor
    }

    private func reconcileScrollAnchor() {
        guard !loading, !directory.isEmpty, let scrollAnchor,
              !shown.contains(where: { $0.path == scrollAnchor }) else { return }
        self.scrollAnchor = nil
    }

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
            let order: ComparisonResult
            switch sortKey {
            case .name:
                order = a.name.localizedStandardCompare(b.name)
            case .modified:
                order = (a.modified ?? .distantPast).compare(b.modified ?? .distantPast)
            case .size:
                order = a.size == b.size ? .orderedSame : a.size < b.size ? .orderedAscending : .orderedDescending
            case .kind:
                order = Self.kind(of: a).localizedStandardCompare(Self.kind(of: b))
            }
            // Type direction affects groups only; names within a type (including folders)
            // always stay in natural ascending order.
            if sortKey == .kind, order == .orderedSame {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            let stable = order == .orderedSame ? a.name.localizedStandardCompare(b.name) : order
            return stable == (ascending ? .orderedAscending : .orderedDescending)
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
        return ext.lowercased()
    }

    // MARK: Navigation

    func start(at path: String?) {
        guard !started, !loading else { return }
        initialPath = path
        loading = true
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
        guard let path = directory.isEmpty ? attemptedPath : directory else { return }
        load(path, record: false, keepSelection: true)
    }

    /// `fallback` opens instead when `path` fails, e.g. a restored folder that was deleted.
    private func load(_ path: String, record: Bool, keepSelection: Bool = false, fallback: String? = nil) {
        loadTask?.cancel()
        attemptedPath = path
        loading = true
        error = nil
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
                if let restored = restoredState {
                    restoredState = nil
                    selection = Set(restored.selection ?? []).intersection(Set(listed.map(\.path)))
                    filter = restored.filter ?? ""
                    scrollAnchor = restored.scrollAnchor
                    if let path = restored.previewPath, let entry = listed.first(where: { $0.path == path }), !entry.isDirectory {
                        showPreview(entry, using: restored.readingEncoding)
                    }
                } else if changed || !keepSelection {
                    selection = []
                    anchor = nil
                    filter = ""
                    scrollAnchor = nil
                } else {
                    let paths = Set(listed.map(\.path))
                    selection = selection.intersection(paths)
                }
                loading = false
                reconcileScrollAnchor()
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

    func showPreview(_ entry: FileEntry, using encoding: TextFile.Encoding? = nil) {
        readingEncoding = encoding
        let request = UUID()
        previewRequest = request
        preview = Preview(entry: entry, decoded: nil, truncated: false, error: nil)
        let limit = FileBrowserLayout.previewByteLimit
        Task {
            do {
                let revision = try await fileSystem.revision(entry.path)
                let data = try await fileSystem.read(entry.path, limit: limit + 1)
                guard previewRequest == request, preview?.entry == entry else { return }
                guard try await fileSystem.revision(entry.path) == revision else { throw FileSafety.changed() }
                guard previewRequest == request, preview?.entry == entry else { return }
                let truncated = data.count > limit
                let decoded = TextFile.decodePreview(Data(data.prefix(limit)), using: encoding, truncated: truncated)
                preview = Preview(
                    entry: entry, decoded: decoded, truncated: truncated,
                    error: decoded == nil ? String(localized: "Not a text file") : nil,
                    revision: revision
                )
            } catch {
                guard previewRequest == request, preview?.entry == entry else { return }
                preview?.error = error.localizedDescription
            }
        }
    }

    func reloadPreview(using encoding: TextFile.Encoding?) {
        guard let current = preview, !current.isQuickLook else { return }
        showPreview(current.entry, using: encoding)
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

    /// Conversion always decodes the full current file, never the preview's truncated sample.
    func savePreviewFormat(encoding: TextFile.Encoding, lineEnding: TextFile.LineEnding?) async throws -> String? {
        guard let current = preview, let expected = current.revision, !current.isQuickLook else {
            throw FileError.message(String(localized: "Refresh the preview before converting"))
        }
        let snapshot = try await fileSystem.readComplete(current.entry.path, maximumBytes: 8 * 1024 * 1024)
        guard snapshot.revision == expected else { throw FileSafety.changed() }
        guard let decoded = TextFile.decode(snapshot.data, using: readingEncoding) else {
            throw FileError.message(String(localized: "Not a text file"))
        }
        let output = try TextFile.encode(decoded.text, encoding: encoding, lineEnding: lineEnding,
                                         includeBOM: encoding == decoded.encoding ? decoded.hasBOM : nil)
        let backup = try await fileSystem.replaceFile(output, at: current.entry.path, expected: expected)
        showPreview(current.entry, using: encoding)
        refresh()
        return backup
    }

    func convertPreviewToUTF8LF() async throws {
        _ = try await savePreviewFormat(encoding: .utf8, lineEnding: .lf)
    }

}

/// One window's independent file page: local browsing on the left, movable remote tabs on the right.
@MainActor
final class FileWorkspace: ObservableObject {
    /// One pane of the grid: its tabs and which one is shown.
    struct Group: Identifiable {
        let id: UUID
        var tabs: [FileColumn] = []
        var activeID: UUID?

        var active: FileColumn? { tabs.first { $0.id == activeID } }
    }

    typealias Saved = FileWorkspaceSnapshot

    let localGroupID: UUID
    private(set) var remoteGroupID: UUID
    @Published private(set) var layout: PaneNode
    @Published private(set) var groups: [UUID: Group] = [:]
    /// The pane last clicked or opened. ⌘W closes its current tab.
    @Published private(set) var focusedGroupID: UUID
    /// Panes in the order they were focused, latest last: "the other pane" for transfers.
    private var focusHistory: [UUID] = []
    /// Where hosts chosen in the host picker open; nil picks a pane as `openRemote` does.
    var pickerGroupID: UUID?
    /// Shared by the sidebar's vertical tab list and the pane grid it drops onto.
    let tabDrag = FileTabDragTracker()
    weak var model: AppModel?
    weak var windowState: WindowState?
    var onChange: ((Saved) -> Void)?

    init(saved: Saved?, model: AppModel, window: WindowState, loadImmediately: Bool = true) {
        self.model = model
        windowState = window
        let saved = saved ?? Saved()
        let restored = saved.fixedColumns()
        let keepsLayout = saved.hasRestorableLayout
        let localID = keepsLayout ? saved.localGroupID! : UUID()
        let remoteID = keepsLayout ? saved.remoteGroupID! : UUID()
        localGroupID = localID
        remoteGroupID = remoteID
        func column(_ tab: Saved.Tab) -> FileColumn {
            let result = FileColumn(fileSystem: fileSystem(for: tab.host))
            result.restore(tab)
            if loadImmediately { result.start(at: tab.path) }
            return result
        }
        if keepsLayout {
            groups = Dictionary(uniqueKeysWithValues: saved.groups.map { item in
                var group = Group(id: item.id, tabs: item.tabs.map(column))
                group.activeID = group.tabs.isEmpty ? nil : group.tabs[min(max(0, item.active), group.tabs.count - 1)].id
                return (item.id, group)
            })
            layout = saved.layout!
            focusedGroupID = saved.focused.flatMap { id in saved.groups.contains { $0.id == id } ? id : nil } ?? localID
        } else {
            var local = Group(id: localID, tabs: restored.local.map(column))
            var remote = Group(id: remoteID, tabs: restored.remote.map(column))
            if local.tabs.isEmpty { local.tabs = [column(Saved.Tab(host: nil, path: NSHomeDirectory()))] }
            local.activeID = local.tabs[min(restored.activeLocal, local.tabs.count - 1)].id
            remote.activeID = remote.tabs.isEmpty ? nil : remote.tabs[min(restored.activeRemote, remote.tabs.count - 1)].id
            groups = [localID: local, remoteID: remote]
            let restoredRatio: CGFloat
            if case .split(let old)? = saved.layout { restoredRatio = min(0.7, max(0.3, old.ratio)) }
            else { restoredRatio = 0.5 }
            layout = .split(SplitNode(id: UUID(), axis: .vertical, ratio: restoredRatio,
                                     leading: .leaf(localID), trailing: .leaf(remoteID)))
            focusedGroupID = restored.focusRemote && remote.active != nil ? remoteID : localID
        }
        focusHistory = groupIDs.filter { $0 != focusedGroupID } + [focusedGroupID]
        for column in allTabs { observe(column) }
    }

    func startColumns() {
        for column in allTabs { column.start(at: column.savedPath) }
    }

    var localColumn: FileColumn { groups[localGroupID]!.active! }
    var remoteColumn: FileColumn? { groups[remoteGroupID]?.active }
    var remoteTabs: [FileColumn] { allTabs.filter(\.isRemote) }
    var localLocations: [FileColumn] { groups[localGroupID]?.tabs ?? [] }
    var activeHost: String? { remoteColumn?.fileSystem.host }
    var selectedPreviewColumn: FileColumn? {
        if let focusedColumn, focusedColumn.preview != nil { return focusedColumn }
        return openColumns.first { $0.preview != nil }
    }

    /// The workspace presents one modal preview at a time, including restored previews.
    func dismissPreview() {
        for column in allTabs where column.preview != nil { column.preview = nil }
    }

    func browseRemote(host: String, at path: String? = nil) { openRemote(host: host, at: path) }
    func browseLocal(at path: String) { showLocal(path) }

    /// Panes in reading order.
    var groupIDs: [UUID] { WorkspaceBoard.leafIDs(layout) }
    /// All browsing locations, including inactive tabs in each pane.
    var allTabs: [FileColumn] { groupIDs.flatMap { groups[$0]?.tabs ?? [] } }
    /// One visible browsing location per pane.
    var openColumns: [FileColumn] { groupIDs.compactMap { groups[$0]?.active } }
    var focusedColumn: FileColumn? { groups[focusedGroupID]?.active }

    func groupID(of column: FileColumn) -> UUID? {
        groups.first { $0.value.tabs.contains { $0 === column } }?.key
    }

    /// The fixed opposite endpoint, independent of keyboard focus history.
    func other(than column: FileColumn) -> FileColumn? {
        column.isRemote ? localColumn : remoteColumn
    }

    func focus(_ column: FileColumn) {
        guard let id = groupID(of: column) else { return }
        focusGroup(id)
    }

    func focusGroup(_ id: UUID) {
        guard groups[id] != nil else { return }
        if let window = windowState { model?.focusFiles(in: window) }
        focusedGroupID = id
        if id != localGroupID { remoteGroupID = id }
        focusHistory.removeAll { $0 == id }
        focusHistory.append(id)
        save()
    }

    func selectGroup(_ id: UUID) {
        focusGroup(id)
        save()
    }

    // MARK: Tabs

    @discardableResult
    func addLocalTab(at path: String?, in groupID: UUID? = nil) -> FileColumn {
        let target = localGroupID
        let current = groups[target]?.active.flatMap { $0.isRemote ? nil : $0.directory }
        let column = makeColumn(host: nil, path: path ?? current ?? NSHomeDirectory())
        insert(column, into: target, at: nil)
        return column
    }

    @discardableResult
    func addRemoteTab(host: String, at path: String? = nil, in groupID: UUID? = nil) -> FileColumn {
        let column = makeColumn(host: host, path: path)
        let target = groupID.flatMap { $0 != localGroupID && groups[$0] != nil ? $0 : nil } ?? remoteGroupID
        insert(column, into: target, at: nil)
        return column
    }

    /// The host's tab if one is open (in `groupID` when given), moved to `path` when given;
    /// otherwise a new tab there.
    func openRemote(host: String, at path: String?, in groupID: UUID? = nil) {
        let candidates = ([remoteColumn].compactMap { $0 } + remoteTabs)
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

    /// A transfer needs both ends visible. Reuse saved columns and their paths instead of
    /// sending the user through pane-switching menus or resetting the local directory.
    func prepareTransferPanes() { save() }

    func activate(_ column: FileColumn) {
        guard let id = groupID(of: column) else { return }
        groups[id]?.activeID = column.id
        focusGroup(id)
        save()
    }

    func close(_ column: FileColumn) {
        guard let id = groupID(of: column) else { return }
        if id == localGroupID, localLocations.count == 1 { return }
        detach(column, from: id)
        removeIfEmpty(id)
        if focusedGroupID == id, groups[id]?.active == nil { focusGroup(localGroupID) }
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
        guard column.isRemote, target != localGroupID, let source = groupID(of: column),
              let destination = groups[target] else { return false }
        if source == target { return edge != .center && destination.tabs.count > 1 }
        return !destination.tabs.isEmpty || edge == .center
    }

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

    /// Keep one remote destination available; close an emptied split without disturbing the local pane.
    private func removeIfEmpty(_ id: UUID) {
        guard id != localGroupID, groups[id]?.tabs.isEmpty == true, groups.count > 2,
              let remaining = PaneLayout.remove(id, from: layout) else { return }
        groups[id] = nil
        layout = remaining
        focusHistory.removeAll { $0 == id }
        if pickerGroupID == id { pickerGroupID = nil }
        if remoteGroupID == id {
            remoteGroupID = focusHistory.reversed().first { $0 != localGroupID && groups[$0] != nil }
                ?? groupIDs.first { $0 != localGroupID }!
        }
        if focusedGroupID == id { focusGroup(remoteGroupID) }
    }

    private func observe(_ column: FileColumn) {
        column.onDirectoryChange = { [weak self] _ in self?.save() }
        column.onStateChange = { [weak self] in
            self?.objectWillChange.send()
            self?.save()
        }
    }

    private func makeColumn(host: String?, path: String?) -> FileColumn {
        let column = Self.makeColumn(host: host, path: path)
        observe(column)
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
            Saved.Tab(host: column.fileSystem.host, path: column.savedPath,
                      selection: Array(column.selection), filter: column.filter, showHidden: column.showHidden,
                      sortKey: column.sortKey, ascending: column.ascending,
                      previewPath: column.savedPreviewPath, readingEncoding: column.readingEncoding,
                      backStack: column.backStack, forwardStack: column.forwardStack,
                      scrollAnchor: column.savedScrollAnchor)
        }
        var state = Saved()
        state.layout = layout
        state.groups = groupIDs.compactMap { id in
            guard let group = groups[id] else { return nil }
            return Saved.SavedGroup(id: id, tabs: group.tabs.map(saved),
                                    active: group.tabs.firstIndex { $0.id == group.activeID } ?? 0)
        }
        state.focused = focusedGroupID
        state.localGroupID = localGroupID
        state.remoteGroupID = remoteGroupID
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
        let destination = directory ?? column.directory
        let target = column.fileSystem
        Task { @MainActor in
            guard await FileTransfer.confirmDrop(items, from: source, to: target, into: destination, window: window) else { return }
            FileTransferQueue.shared.enqueue(items, from: source, to: target, into: destination, window: window)
        }
    }

    private func transfer(_ items: [FileTransfer.Item], from source: any FileSystem, to column: FileColumn,
                          into directory: String, window: NSWindow?) {
        guard !items.isEmpty, !directory.isEmpty else { return }
        FileTransferQueue.shared.enqueue(items, from: source, to: column.fileSystem,
                                         into: directory, window: window)
    }

    func rename(_ entry: FileEntry, in column: FileColumn, window: NSWindow?) {
        guard let name = FileBrowserDialogs.askRename(entry.name), name != entry.name else { return }
        let target = FileRules.join(FileRules.parent(of: entry.path), name)
        Task {
            do {
                try await column.fileSystem.rename(entry.path, to: target)
                if column.preview?.entry.path == entry.path { column.preview = nil }
                column.selection = [target]
                column.refresh()
            } catch {
                column.error = error.localizedDescription
                TransferToast.shared.fail(nil, error.localizedDescription, in: window)
            }
        }
    }

    /// Two confirmations, as in 1Panel: deleted files do not go to the Trash.
    func delete(_ entries: [FileEntry], in column: FileColumn, window: NSWindow?) {
        guard !entries.isEmpty else { return }
        for entry in entries {
            let home = column.isRemote ? nil : NSHomeDirectory()
            if let refusal = FileRules.deleteRefusal(entry.path, remote: column.isRemote, home: home) {
                column.error = refusal
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
                column.refresh()
            } catch {
                column.error = error.localizedDescription
                TransferToast.shared.fail(nil, error.localizedDescription, in: window)
            }
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
                column.error = error.localizedDescription
                TransferToast.shared.fail(nil, error.localizedDescription, in: window)
            }
        }
    }

    /// A folder opens in place; any file opens in the preview drawer, as text when it can be read
    /// as text, otherwise as Quick Look.
    func open(_ entry: FileEntry, in column: FileColumn, window: NSWindow?) {
        focus(column)
        if !entry.isDirectory {
            for other in allTabs where other !== column && other.preview != nil { other.preview = nil }
        }
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

    func existingWorkspace(for window: WindowState) -> FileWorkspace? { workspaces[window.id] }

    /// Restore tab metadata for the overview without opening directories or SSH connections.
    func previewWorkspace(for window: WindowState, model: AppModel) -> FileWorkspace? {
        if let existing = workspaces[window.id] { return existing }
        guard UserDefaults.standard.data(forKey: Self.tabsKey) != nil else { return nil }
        return workspace(for: window, model: model, loadImmediately: false)
    }

    func workspace(for window: WindowState, model: AppModel, loadImmediately: Bool = true) -> FileWorkspace {
        if let existing = workspaces[window.id] {
            if loadImmediately { existing.startColumns() }
            return existing
        }
        let defaults = UserDefaults.standard
        if let original = defaults.data(forKey: Self.tabsKey), defaults.data(forKey: Self.tabsKey + ".beforeIndependentPage") == nil {
            defaults.set(original, forKey: Self.tabsKey + ".beforeIndependentPage")
        }
        let saved = defaults.data(forKey: Self.tabsKey)
            .flatMap { try? JSONDecoder().decode(FileWorkspace.Saved.self, from: $0) }
        let created = FileWorkspace(saved: saved, model: model, window: window, loadImmediately: loadImmediately)
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
        let alert = FamilyAlert()
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

    static func askRename(_ current: String) -> String? {
        let alert = FamilyAlert()
        alert.messageText = String(localized: "Rename")
        let field = FamilyNativeTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        return name
    }

    static func askName(folder: Bool) -> String? {
        let alert = FamilyAlert()
        alert.messageText = folder ? String(localized: "New Folder") : String(localized: "New File")
        alert.informativeText = folder
            ? String(localized: "Folder name")
            : String(localized: "File name (created empty)")
        let field = FamilyNativeTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = folder ? String(localized: "New Folder") : String(localized: "New File.txt")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Create"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        return name
    }
}
