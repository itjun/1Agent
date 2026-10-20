import Foundation

enum FileSortKey: String, Codable {
    case name, modified, size, kind
}

/// Versioned browsing state, kept independent of views and live connections.
struct FileWorkspaceSnapshot: Codable {
    struct Tab: Codable {
        var host: String?
        var path: String?
        var selection: [String]? = nil
        var filter: String? = nil
        var showHidden: Bool? = nil
        var sortKey: FileSortKey? = nil
        var ascending: Bool? = nil
        var previewPath: String? = nil
        var readingEncoding: TextFile.Encoding? = nil
        var backStack: [String]? = nil
        var forwardStack: [String]? = nil
        var scrollAnchor: String? = nil
    }

    struct SavedGroup: Codable {
        var id: UUID
        var tabs: [Tab]
        var active: Int
    }

    var layout: PaneNode?
    var groups: [SavedGroup] = []
    var focused: UUID?
    var localGroupID: UUID?
    var remoteGroupID: UUID?
    var version: Int = 3
    /// Separate from layout migrations: adopt type/name ordering once for existing tabs.
    var sortVersion: Int = 1

    private enum CodingKeys: String, CodingKey {
        case layout, groups, focused, version, sortVersion, localGroupID, remoteGroupID
        case left, right, activeLeft, activeRight
        case local, remote, activeLocal, activeRemote
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sortVersion = try values.decodeIfPresent(Int.self, forKey: .sortVersion) ?? 0
        defer {
            if sortVersion < 1 {
                for group in groups.indices {
                    for tab in groups[group].tabs.indices {
                        groups[group].tabs[tab].sortKey = .kind
                        groups[group].tabs[tab].ascending = true
                    }
                }
                sortVersion = 1
            }
        }
        if let groups = try values.decodeIfPresent([SavedGroup].self, forKey: .groups) {
            self.groups = groups
            layout = try values.decodeIfPresent(PaneNode.self, forKey: .layout)
            focused = try values.decodeIfPresent(UUID.self, forKey: .focused)
            localGroupID = try values.decodeIfPresent(UUID.self, forKey: .localGroupID)
            remoteGroupID = try values.decodeIfPresent(UUID.self, forKey: .remoteGroupID)
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
        try values.encode(version, forKey: .version)
        try values.encode(sortVersion, forKey: .sortVersion)
        try values.encodeIfPresent(layout, forKey: .layout)
        try values.encode(groups, forKey: .groups)
        try values.encodeIfPresent(focused, forKey: .focused)
        try values.encodeIfPresent(localGroupID, forKey: .localGroupID)
        try values.encodeIfPresent(remoteGroupID, forKey: .remoteGroupID)
    }

    /// New snapshots keep the local pane and the complete remote split tree.
    /// Older or malformed snapshots use the lossless two-column migration below.
    var hasRestorableLayout: Bool {
        guard version >= 3, let localGroupID, let remoteGroupID, localGroupID != remoteGroupID,
              case .split(let root)? = layout, root.axis == .vertical,
              root.leading == .leaf(localGroupID),
              groups.contains(where: { $0.id == remoteGroupID }),
              let local = groups.first(where: { $0.id == localGroupID }), !local.tabs.isEmpty,
              local.tabs.allSatisfy({ $0.host?.isEmpty != false }),
              groups.filter({ $0.id != localGroupID }).allSatisfy({ $0.tabs.allSatisfy { $0.host?.isEmpty == false } })
        else { return false }
        let ids = WorkspaceBoard.leafIDs(.split(root))
        return Set(ids).count == ids.count && Set(groups.map(\.id)).count == groups.count
            && Set(ids) == Set(groups.map(\.id))
    }


    struct Columns {
        var local: [Tab] = []
        var remote: [Tab] = []
        var activeLocal = 0
        var activeRemote = 0
        var focusRemote = false
    }

    /// Flatten the old grid in reading order without dropping inactive or orphaned tabs.
    func fixedColumns() -> Columns {
        let ids = layout.map(WorkspaceBoard.leafIDs) ?? []
        let ordered = ids.compactMap { id in groups.first { $0.id == id } }
            + groups.filter { !ids.contains($0.id) }
        var result = Columns()
        var localChosen = false, remoteChosen = false
        for group in ordered {
            for (index, original) in group.tabs.enumerated() {
                var tab = original
                tab.host = tab.host.flatMap { $0.isEmpty ? nil : $0 }
                let remote = tab.host != nil
                if index == min(max(0, group.active), max(0, group.tabs.count - 1)) {
                    if remote, !remoteChosen || group.id == focused {
                        result.activeRemote = result.remote.count
                        remoteChosen = true
                    } else if !remote, !localChosen || group.id == focused {
                        result.activeLocal = result.local.count
                        localChosen = true
                    }
                    if group.id == focused { result.focusRemote = remote }
                }
                if remote { result.remote.append(tab) } else { result.local.append(tab) }
            }
        }
        return result
    }
}
