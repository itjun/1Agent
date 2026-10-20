import Foundation

@main
struct FileWorkspaceStateTests {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }

    static func main() throws {
        let first = UUID(), second = UUID(), orphan = UUID()
        var saved = FileWorkspaceSnapshot()
        saved.layout = .split(SplitNode(id: UUID(), axis: .vertical, ratio: 0.55,
                                       leading: .leaf(first), trailing: .leaf(second)))
        saved.groups = [
            .init(id: first, tabs: [.init(host: nil, path: "/local/one"), .init(host: "alpha", path: "/alpha/one")], active: 0),
            .init(id: second, tabs: [.init(host: "beta", path: "/beta/one"), .init(host: nil, path: "/local/two"),
                                    .init(host: "alpha", path: "/alpha/two")], active: 2),
            .init(id: orphan, tabs: [.init(host: nil, path: "/local/orphan")], active: 0),
        ]
        saved.focused = second
        let migrated = saved.fixedColumns()
        require(migrated.local.map(\.path) == ["/local/one", "/local/two", "/local/orphan"], "all local tabs survive in reading order")
        require(migrated.remote.map(\.path) == ["/alpha/one", "/beta/one", "/alpha/two"], "all host tabs survive including repeated host")
        require(migrated.activeRemote == 2 && migrated.focusRemote, "focused group's active host wins")
        require(migrated.activeLocal == 0, "other endpoint retains its active local location")

        var tab = FileWorkspaceSnapshot.Tab(host: "alpha", path: "/srv/app")
        tab.selection = ["/srv/app/config.env"]
        tab.filter = "config"
        tab.showHidden = true
        tab.sortKey = .modified
        tab.ascending = false
        tab.previewPath = "/srv/app/config.env"
        tab.readingEncoding = .utf8
        tab.backStack = ["/srv", "/srv/previous"]
        tab.forwardStack = ["/srv/next"]
        tab.scrollAnchor = "/srv/app/config.env"
        saved.groups = [.init(id: first, tabs: [tab], active: 0)]
        let roundtrip = try JSONDecoder().decode(FileWorkspaceSnapshot.self, from: JSONEncoder().encode(saved))
        let restored = roundtrip.groups[0].tabs[0]
        require(restored.path == tab.path && restored.selection == tab.selection && restored.filter == tab.filter,
                "directory, selection and filter roundtrip")
        require(restored.showHidden == true && restored.sortKey == .modified && restored.ascending == false,
                "visibility and sort roundtrip")
        require(restored.previewPath == tab.previewPath && restored.readingEncoding == .utf8, "preview context roundtrip")
        require(restored.backStack == tab.backStack && restored.forwardStack == tab.forwardStack && restored.scrollAnchor == tab.scrollAnchor,
                "navigation history and the visible-row anchor roundtrip")

        // An existing snapshot has no sort migration marker. Only its sorting should change.
        var legacyValues = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        legacyValues.removeValue(forKey: "sortVersion")
        let migratedSort = try JSONDecoder().decode(FileWorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: legacyValues))
        var expected = saved
        expected.groups[0].tabs[0].sortKey = .kind
        expected.groups[0].tabs[0].ascending = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        require(try encoder.encode(migratedSort) == encoder.encode(expected),
                "sort migration preserves every saved field except sort key and direction")
        var manualSort = migratedSort
        manualSort.groups[0].tabs[0].sortKey = .size
        manualSort.groups[0].tabs[0].ascending = false
        let restoredManualSort = try JSONDecoder().decode(FileWorkspaceSnapshot.self, from: encoder.encode(manualSort))
        require(try encoder.encode(restoredManualSort) == encoder.encode(manualSort),
                "later manual sorting survives relaunch without repeating the migration")

        let legacy = Data(#"{"local":[{"path":"/Users/test"}],"remote":[{"host":"old-host","path":"/opt/app"}],"activeLocal":0,"activeRemote":0}"#.utf8)
        let old = try JSONDecoder().decode(FileWorkspaceSnapshot.self, from: legacy).fixedColumns()
        require(old.local.first?.path == "/Users/test" && old.remote.first?.path == "/opt/app", "old local/remote format migrates")
        require(old.local.first?.sortKey == .kind && old.remote.first?.sortKey == .kind
                && old.local.first?.ascending == true && old.remote.first?.ascending == true,
                "legacy local and remote tabs both adopt type/name ordering")
        print("File workspace state tests passed")
    }
}
