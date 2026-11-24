import CoreGraphics
import Foundation

/// A display surface, independent of workspace membership and sidebar ordering.
struct TerminalPanel: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var layout: PaneNode
}

struct Workspace: Identifiable, Equatable, Codable {
    var id: UUID
    var number: Int
    var members: [UUID]
    var panels: [TerminalPanel]
    /// Empty means the generated name, such as Workspace 1.
    var name: String?
    /// A group is optional. Ungrouped split panels still need a durable tree owner.
    var isGrouped: Bool

    init(id: UUID, number: Int, members: [UUID], panels: [TerminalPanel]? = nil, name: String? = nil, isGrouped: Bool = true) {
        self.id = id
        self.number = number
        self.members = members
        self.panels = panels ?? members.map { TerminalPanel(id: $0, layout: .leaf($0)) }
        self.name = name
        self.isGrouped = isGrouped
    }

    /// Legacy split workspaces keep their entire tree as one panel.
    init(id: UUID, number: Int, layout: PaneNode, name: String? = nil) {
        self.init(id: id, number: number, members: WorkspaceBoard.leafIDs(layout),
                  panels: [TerminalPanel(id: id, layout: layout)], name: name)
    }

    func panel(containing id: UUID) -> TerminalPanel? {
        panels.first { PaneLayout.contains(id, in: $0.layout) }
    }

    private enum CodingKeys: String, CodingKey { case id, number, members, panels, name, layout, isGrouped }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(UUID.self, forKey: .id)
        let number = try values.decode(Int.self, forKey: .number)
        let name = try values.decodeIfPresent(String.self, forKey: .name)
        if let members = try values.decodeIfPresent([UUID].self, forKey: .members) {
            self.init(id: id, number: number, members: members,
                      panels: try values.decodeIfPresent([TerminalPanel].self, forKey: .panels), name: name)
        } else {
            self.init(id: id, number: number, layout: try values.decode(PaneNode.self, forKey: .layout), name: name)
        }
        isGrouped = try values.decodeIfPresent(Bool.self, forKey: .isGrouped) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(number, forKey: .number)
        try values.encode(members, forKey: .members)
        try values.encode(panels, forKey: .panels)
        try values.encodeIfPresent(name, forKey: .name)
        try values.encode(isGrouped, forKey: .isGrouped)
    }
}

/// How a workspace's panes are arranged. Order follows the sidebar, left to right then top to bottom.
enum WorkspaceLayout: String, Equatable, CaseIterable {
    /// One row, equal widths.
    case columns
    /// One column, equal heights.
    case rows
    /// As close to a square as the pane count allows. The last row can be shorter.
    case grid
    /// The first pane takes the left half. The rest stack on the right.
    case leadingSide
    /// The first pane takes the top half. The rest sit in a row underneath.
    case leadingTop
}

enum WorkspaceBoard {
    /// Derived chrome only; member reorder does not mutate panels or these identifiers.
    static func splitNumber(for session: UUID, in workspace: Workspace) -> Int? {
        let splitPanels = workspace.panels.filter { leafIDs($0.layout).count > 1 }
        return splitPanels.firstIndex { PaneLayout.contains(session, in: $0.layout) }.map { $0 + 1 }
    }

    /// Smallest positive integer that is not already a workspace title.
    static func nextNumber(_ workspaces: [Workspace]) -> Int {
        let used = Set(workspaces.filter(\.isGrouped).map(\.number))
        var number = 1
        while used.contains(number) {
            number += 1
        }
        return number
    }

    static func index(containing tab: UUID, in workspaces: [Workspace]) -> Int? {
        workspaces.firstIndex { workspace in
            workspace.members.contains(tab)
        }
    }

    /// Menu entries that would not repeat another entry for this count.
    static func availableLayouts(paneCount: Int) -> [WorkspaceLayout] {
        guard paneCount >= 2 else { return [] }
        var layouts: [WorkspaceLayout] = [.columns, .rows]
        if paneCount >= 4 {
            layouts.append(.grid)
        }
        if paneCount >= 3 {
            layouts.append(.leadingSide)
            layouts.append(.leadingTop)
        }
        return layouts
    }

    /// Edge for the second and later terminals of a multi-drop, so they line up after the first
    /// one on the same axis instead of nesting inside it.
    static func continuation(of edge: SplitEdge) -> SplitEdge {
        switch edge {
        case .left, .right, .center:
            return .right
        case .top, .bottom:
            return .bottom
        }
    }

    /// Builds only the explicitly requested display arrangement. Single sessions stay leaves.
    static func arrange(_ ids: [UUID], as layout: WorkspaceLayout) -> PaneNode? {
        guard ids.count >= 2 else { return nil }
        switch layout {
        case .columns:
            return WorkspaceBoard.splitEven(ids, axis: .vertical)
        case .rows:
            return WorkspaceBoard.splitEven(ids, axis: .horizontal)
        case .grid:
            return WorkspaceBoard.stackRows(WorkspaceBoard.rowGroups(ids))
        case .leadingSide:
            return WorkspaceBoard.featureFirst(ids, axis: .vertical, restAxis: .horizontal)
        case .leadingTop:
            return WorkspaceBoard.featureFirst(ids, axis: .horizontal, restAxis: .vertical)
        }
    }

    /// Explicitly combines every workspace member; grouping alone never calls this.
    static func apply(_ layout: WorkspaceLayout, to workspace: Workspace) -> Workspace {
        guard let arranged = arrange(workspace.members, as: layout) else { return workspace }
        var workspace = workspace
        let id = workspace.panels.first?.id ?? UUID()
        workspace.panels = [TerminalPanel(id: id, layout: arranged)]
        return workspace
    }

    static func leafIDs(_ node: PaneNode) -> [UUID] {
        switch node {
        case .leaf(let id): return [id]
        case .split(let split): return leafIDs(split.leading) + leafIDs(split.trailing)
        }
    }

    /// Sidebar ordering must never change the occupants or geometry of a panel.
    static func moveLeaf(_ dragged: UUID, beside target: UUID, after: Bool, in workspaces: [Workspace]) -> [Workspace] {
        guard dragged != target,
              let index = index(containing: dragged, in: workspaces),
              workspaces[index].members.contains(target) else { return workspaces }
        var result = workspaces
        result[index].members.removeAll { $0 == dragged }
        let slot = result[index].members.firstIndex(of: target)! + (after ? 1 : 0)
        result[index].members.insert(dragged, at: slot)
        return result
    }

    /// Reorder sessions inside one split while retaining its geometry, dividers and panel identity.
    static func reorderTerminals(_ ids: [UUID], beside target: UUID, after: Bool, in workspaces: [Workspace]) -> [Workspace] {
        guard let index = index(containing: target, in: workspaces),
              let panel = workspaces[index].panels.firstIndex(where: { PaneLayout.contains(target, in: $0.layout) }) else { return workspaces }
        let leaves = leafIDs(workspaces[index].panels[panel].layout)
        let dragged = unique(ids).filter { $0 != target }
        guard !dragged.isEmpty, Set(dragged).isSubset(of: Set(leaves)) else { return workspaces }
        var ordered = leaves.filter { !dragged.contains($0) }
        let slot = ordered.firstIndex(of: target)! + (after ? 1 : 0)
        ordered.insert(contentsOf: dragged, at: slot)
        guard ordered != leaves else { return workspaces }
        var remaining = ordered.makeIterator()
        func reorder(_ node: PaneNode) -> PaneNode {
            switch node {
            case .leaf: return .leaf(remaining.next()!)
            case .split(var split):
                split.leading = reorder(split.leading)
                split.trailing = reorder(split.trailing)
                return .split(split)
            }
        }
        var result = workspaces
        result[index].panels[panel].layout = reorder(result[index].panels[panel].layout)
        var members = ordered.makeIterator()
        result[index].members = result[index].members.map { leaves.contains($0) ? members.next()! : $0 }
        return result
    }

    static func join(_ dragged: UUID, to workspaceID: UUID, in workspaces: [Workspace]) -> [Workspace] {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              !workspace.members.contains(dragged) else { return workspaces }
        var result = extract(dragged, from: workspaces)
        guard let index = result.firstIndex(where: { $0.id == workspaceID }) else { return workspaces }
        result[index].members.append(dragged)
        let panelID = result.flatMap(\.panels).contains { $0.id == dragged } ? UUID() : dragged
        result[index].panels.append(TerminalPanel(id: panelID, layout: .leaf(dragged)))
        return result
    }

    static func join(_ dragged: UUID, beside target: UUID, after: Bool, to workspaceID: UUID,
                     in workspaces: [Workspace]) -> [Workspace] {
        guard dragged != target,
              workspaces.first(where: { $0.id == workspaceID })?.members.contains(target) == true else { return workspaces }
        let joined = join(dragged, to: workspaceID, in: workspaces)
        return moveLeaf(dragged, beside: target, after: after, in: joined)
    }

    /// Grouping preserves every fully selected panel, including its split geometry and identity.
    static func create(_ ids: [UUID], in workspaces: [Workspace]) -> [Workspace] {
        let ordered = unique(ids)
        guard !ordered.isEmpty else { return workspaces }
        if let existing = workspaces.firstIndex(where: { Set($0.members) == Set(ordered) }) {
            var result = workspaces
            result[existing].isGrouped = true
            return result
        }
        let wanted = Set(ordered)
        var panels: [TerminalPanel] = []
        var handled = Set<UUID>()
        for id in ordered where !handled.contains(id) {
            if let source = index(containing: id, in: workspaces),
               let panel = workspaces[source].panel(containing: id),
               Set(leafIDs(panel.layout)).isSubset(of: wanted) {
                panels.append(panel)
                handled.formUnion(leafIDs(panel.layout))
            } else {
                let panelID = workspaces.flatMap(\.panels).contains { $0.id == id } ? UUID() : id
                panels.append(TerminalPanel(id: panelID, layout: .leaf(id)))
                handled.insert(id)
            }
        }
        var result = workspaces
        for id in ordered { result = extract(id, from: result) }
        result.append(Workspace(id: UUID(), number: nextNumber(result), members: ordered, panels: panels))
        return result
    }

    /// Explicit edge drop: only the target panel changes, even inside the same workspace.
    static func drop(dragged: UUID, onto target: UUID, edge: SplitEdge, in workspaces: [Workspace]) -> [Workspace] {
        guard dragged != target, edge != .center else { return workspaces }
        var result = workspaces
        if index(containing: target, in: result) == nil {
            let panelID = result.flatMap(\.panels).contains { $0.id == target } ? UUID() : target
            result.append(Workspace(id: UUID(), number: nextNumber(result), members: [target],
                                    panels: [TerminalPanel(id: panelID, layout: .leaf(target))], isGrouped: false))
        }
        let destination = result[index(containing: target, in: result)!].id
        if let source = index(containing: dragged, in: result), result[source].id == destination {
            result[source] = removingFromPanels([dragged], in: result[source])
        } else {
            result = extract(dragged, from: result)
            let i = result.firstIndex { $0.id == destination }!
            result[i].members.append(dragged)
        }
        let i = result.firstIndex { $0.id == destination }!
        let panel = result[i].panels.firstIndex { PaneLayout.contains(target, in: $0.layout) }!
        result[i].panels[panel].layout = PaneLayout.split(result[i].panels[panel].layout, target: target, with: dragged, edge: edge)
        return result
    }

    /// Selected sessions combine in the target's workspace, leaving other panels untouched.
    static func combine(_ ids: [UUID], onto target: UUID, as layout: WorkspaceLayout,
                        in workspaces: [Workspace]) -> [Workspace] {
        let ordered = unique(ids)
        guard ordered.count >= 2, ordered.contains(target), let tree = arrange(ordered, as: layout) else { return workspaces }
        var result = workspaces
        if index(containing: target, in: result) == nil {
            let panelID = result.flatMap(\.panels).contains { $0.id == target } ? UUID() : target
            result.append(Workspace(id: UUID(), number: nextNumber(result), members: [target],
                                    panels: [TerminalPanel(id: panelID, layout: .leaf(target))], isGrouped: false))
        }
        let destination = result[index(containing: target, in: result)!].id
        for id in ordered { result = join(id, to: destination, in: result) }
        let i = result.firstIndex { $0.id == destination }!
        let old = result[i].panel(containing: target)!
        let reuse = Set(leafIDs(old.layout)).isSubset(of: Set(ordered))
        result[i] = removingFromPanels(Set(ordered), in: result[i])
        result[i].panels.append(TerminalPanel(id: reuse ? old.id : UUID(), layout: tree))
        return result
    }

    /// Separate display only, keeping workspace membership and sidebar position.
    static func detach(_ ids: [UUID], in workspaces: [Workspace]) -> [Workspace] {
        let wanted = Set(ids)
        return workspaces.map { workspace in
            let split = workspace.members.filter { id in
                wanted.contains(id) && (workspace.panel(containing: id).map { leafIDs($0.layout).count > 1 } ?? false)
            }
            guard !split.isEmpty else { return workspace }
            var result = removingFromPanels(Set(split), in: workspace)
            result.panels += split.map { TerminalPanel(layout: .leaf($0)) }
            return result
        }
    }

    /// Whole workspace moves preserve panel identities, shapes and ratios.
    static func joinWorkspace(_ source: UUID, to destination: UUID, in workspaces: [Workspace]) -> [Workspace] {
        guard source != destination, let moving = workspaces.first(where: { $0.id == source }),
              workspaces.contains(where: { $0.id == destination }) else { return workspaces }
        var result = workspaces.filter { $0.id != source }
        let i = result.firstIndex { $0.id == destination }!
        result[i].members += moving.members
        result[i].panels += moving.panels
        return result
    }

    static func dissolve(_ workspaceID: UUID, in workspaces: [Workspace]) -> [Workspace] {
        workspaces.map { workspace in
            var result = workspace
            if result.id == workspaceID { result.isGrouped = false }
            return result
        }
    }

    /// Move one complete panel. A nil destination removes grouping without breaking its tree.
    static func movePanel(_ panelID: UUID, to workspaceID: UUID?, beside targetPanelID: UUID? = nil,
                          after: Bool = true, in workspaces: [Workspace]) -> [Workspace] {
        guard let source = workspaces.firstIndex(where: { $0.panels.contains { $0.id == panelID } }),
              let panel = workspaces[source].panels.first(where: { $0.id == panelID }),
              panelID != targetPanelID else { return workspaces }
        if let workspaceID, !workspaces.contains(where: { $0.id == workspaceID }) { return workspaces }
        let leaves = leafIDs(panel.layout)
        var result = workspaces
        result[source].panels.removeAll { $0.id == panelID }
        result[source].members.removeAll { leaves.contains($0) }
        if let workspaceID, let destination = result.firstIndex(where: { $0.id == workspaceID }) {
            var panelSlot = result[destination].panels.count
            if let targetPanelID, let slot = result[destination].panels.firstIndex(where: { $0.id == targetPanelID }) {
                panelSlot = slot + (after ? 1 : 0)
            }
            result[destination].panels.insert(panel, at: panelSlot)
            result[destination].members = result[destination].panels.flatMap { leafIDs($0.layout) }
        } else {
            result.append(Workspace(id: UUID(), number: 0, members: leaves, panels: [panel], isGrouped: false))
        }
        return result.filter { !$0.members.isEmpty }
    }

    /// Membership removal, also used when a session closes. Single-member groups survive.
    static func extract(_ id: UUID, from workspaces: [Workspace]) -> [Workspace] {
        guard let i = index(containing: id, in: workspaces) else { return workspaces }
        var result = workspaces
        result[i] = removingFromPanels([id], in: result[i])
        result[i].members.removeAll { $0 == id }
        return result.filter { !$0.members.isEmpty }
    }

    static func setRatio(_ id: UUID, to ratio: CGFloat, in workspaces: [Workspace]) -> [Workspace] {
        workspaces.map { workspace in
            var result = workspace
            for i in result.panels.indices {
                result.panels[i].layout = PaneLayout.setRatio(id, to: ratio, in: result.panels[i].layout)
            }
            return result
        }
    }

    /// Snapshot repair: unique membership, no missing sessions or duplicate leaves, and stable surviving panel IDs.
    static func keeping(_ known: Set<UUID>, in workspaces: [Workspace]) -> [Workspace] {
        var used = Set<UUID>()
        var panelIDs = Set<UUID>()
        var workspaceIDs = Set<UUID>()
        return workspaces.compactMap { workspace in
            guard workspaceIDs.insert(workspace.id).inserted else { return nil }
            var result = workspace
            result.members = workspace.members.filter { known.contains($0) && used.insert($0).inserted }
            guard !result.members.isEmpty else { return nil }
            var remaining = Set(result.members)
            func prune(_ node: PaneNode) -> PaneNode? {
                switch node {
                case .leaf(let id): return remaining.remove(id) != nil ? node : nil
                case .split(var split):
                    let a = prune(split.leading), b = prune(split.trailing)
                    if let a, let b { split.leading = a; split.trailing = b; return .split(split) }
                    return a ?? b
                }
            }
            result.panels = workspace.panels.compactMap { panel in
                guard let layout = prune(panel.layout) else { return nil }
                let id = panelIDs.insert(panel.id).inserted ? panel.id : UUID()
                panelIDs.insert(id)
                return TerminalPanel(id: id, layout: layout)
            }
            result.panels += result.members.filter { remaining.contains($0) }.map { TerminalPanel(layout: .leaf($0)) }
            return result
        }
    }

    private static func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static func removingFromPanels(_ ids: Set<UUID>, in workspace: Workspace) -> Workspace {
        var result = workspace
        result.panels = workspace.panels.compactMap { panel in
            var layout: PaneNode? = panel.layout
            for id in ids {
                if let node = layout { layout = PaneLayout.remove(id, from: node) }
            }
            guard let layout else { return nil }
            return TerminalPanel(id: panel.id, layout: layout)
        }
        return result
    }

    /// Splits as evenly as possible so each ratio stays inside the 0.2...0.8 limit.
    private static func splitEven(_ ids: [UUID], axis: SplitAxis) -> PaneNode {
        if ids.count == 1 {
            return .leaf(ids[0])
        }
        let leftCount = ids.count / 2
        let left = Array(ids.prefix(leftCount))
        let right = Array(ids.suffix(ids.count - leftCount))
        let ratio = CGFloat(leftCount) / CGFloat(ids.count)
        return .split(SplitNode(
            id: UUID(),
            axis: axis,
            ratio: ratio,
            leading: WorkspaceBoard.splitEven(left, axis: axis),
            trailing: WorkspaceBoard.splitEven(right, axis: axis)
        ))
    }

    /// First pane takes half. The remaining panes share the other half equally.
    private static func featureFirst(_ ids: [UUID], axis: SplitAxis, restAxis: SplitAxis) -> PaneNode {
        let rest = Array(ids.dropFirst())
        return .split(SplitNode(
            id: UUID(),
            axis: axis,
            ratio: 0.5,
            leading: .leaf(ids[0]),
            trailing: WorkspaceBoard.splitEven(rest, axis: restAxis)
        ))
    }

    /// Rows differ by at most one pane. Earlier rows take the extra pane.
    private static func rowGroups(_ ids: [UUID]) -> [[UUID]] {
        let count = ids.count
        let columnCount = Int(ceil(sqrt(Double(count))))
        let rowCount = Int(ceil(Double(count) / Double(columnCount)))
        let base = count / rowCount
        let extra = count % rowCount
        var groups: [[UUID]] = []
        var index = 0
        for row in 0..<rowCount {
            let size = base + (row < extra ? 1 : 0)
            let end = index + size
            groups.append(Array(ids[index..<end]))
            index = end
        }
        return groups
    }

    /// Each row is the same height. Panes inside a row share that row's width.
    private static func stackRows(_ rows: [[UUID]]) -> PaneNode {
        if rows.count == 1 {
            return WorkspaceBoard.splitEven(rows[0], axis: .vertical)
        }
        let topCount = rows.count / 2
        let top = Array(rows.prefix(topCount))
        let bottom = Array(rows.suffix(rows.count - topCount))
        let ratio = CGFloat(topCount) / CGFloat(rows.count)
        return .split(SplitNode(
            id: UUID(),
            axis: .horizontal,
            ratio: ratio,
            leading: WorkspaceBoard.stackRows(top),
            trailing: WorkspaceBoard.stackRows(bottom)
        ))
    }

    /// ⌘1…⌘8: the terminal at that 1-based position of the sidebar order, nil past the end.
    static func terminal(number: Int, in order: [UUID]) -> UUID? {
        if number < 1 || number > order.count {
            return nil
        }
        return order[number - 1]
    }

    /// ⇧⌘[ / ⇧⌘]: the terminal before or after `current` in sidebar order, wrapping at the ends.
    /// With nothing selected, the first (forward) or last terminal. Nil when there is nothing to switch to.
    static func adjacentTerminal(to current: UUID?, forward: Bool, in order: [UUID]) -> UUID? {
        guard let current, let index = order.firstIndex(of: current) else {
            if forward {
                return order.first
            }
            return order.last
        }
        if order.count < 2 {
            return nil
        }
        var next = index + (forward ? 1 : -1)
        if next < 0 {
            next = order.count - 1
        } else if next >= order.count {
            next = 0
        }
        return order[next]
    }

    /// The terminal to select after the selected `closed` one closes. Both lists are taken before it closes.
    /// Another session of the same display panel comes first (next, else previous), so the keyboard stays
    /// in the split; otherwise the sidebar neighbor (the next row, else the previous one). Never the first
    /// row just because it is first, which is often an SSH session. Nil when nothing else is left.
    static func selectionAfterClosing(_ closed: UUID, workspaceMembers: [UUID], sidebarOrder: [UUID]) -> UUID? {
        if let index = workspaceMembers.firstIndex(of: closed) {
            if index + 1 < workspaceMembers.count {
                return workspaceMembers[index + 1]
            }
            if index > 0 {
                return workspaceMembers[index - 1]
            }
        }
        guard let index = sidebarOrder.firstIndex(of: closed) else {
            return sidebarOrder.first { $0 != closed }
        }
        if index + 1 < sidebarOrder.count {
            return sidebarOrder[index + 1]
        }
        if index > 0 {
            return sidebarOrder[index - 1]
        }
        return nil
    }


}

/// Color slot for a host that appears more than once.
/// Each repeated alias keeps one slot, in the order that alias first appears.
enum DuplicateHostColor {
    static func index(for alias: String, among aliases: [String]) -> Int? {
        var counts: [String: Int] = [:]
        for name in aliases {
            counts[name, default: 0] += 1
        }
        guard let count = counts[alias], count > 1 else { return nil }
        var order: [String] = []
        for name in aliases {
            guard let nameCount = counts[name], nameCount > 1 else { continue }
            if order.contains(name) {
                continue
            }
            order.append(name)
        }
        return order.firstIndex(of: alias)
    }
}
