import CoreGraphics
import Foundation

struct Workspace: Identifiable, Equatable, Codable {
    var id: UUID
    var number: Int
    var layout: PaneNode
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
    /// Smallest positive integer that is not already a workspace title.
    static func nextNumber(_ workspaces: [Workspace]) -> Int {
        let used = Set(workspaces.map(\.number))
        var number = 1
        while used.contains(number) {
            number += 1
        }
        return number
    }

    static func index(containing tab: UUID, in workspaces: [Workspace]) -> Int? {
        workspaces.firstIndex { workspace in
            PaneLayout.contains(tab, in: workspace.layout)
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

    /// Rebuilds the split tree. Fewer than two panes cannot be a workspace.
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

    /// Replaces the tree and keeps the workspace identity. The member order stays the sidebar order.
    static func apply(_ layout: WorkspaceLayout, to workspace: Workspace) -> Workspace {
        let ids = WorkspaceBoard.leafIDs(workspace.layout)
        guard let arranged = WorkspaceBoard.arrange(ids, as: layout) else { return workspace }
        var workspace = workspace
        workspace.layout = arranged
        return workspace
    }

    static func leafIDs(_ node: PaneNode) -> [UUID] {
        switch node {
        case .leaf(let id):
            return [id]
        case .split(let split):
            return WorkspaceBoard.leafIDs(split.leading) + WorkspaceBoard.leafIDs(split.trailing)
        }
    }

    /// Moves a member beside another member of the same workspace. The split shape stays; only the occupants move.
    static func moveLeaf(_ dragged: UUID, beside target: UUID, after: Bool, in workspaces: [Workspace]) -> [Workspace] {
        guard dragged != target else { return workspaces }
        guard let index = WorkspaceBoard.index(containing: dragged, in: workspaces),
              WorkspaceBoard.index(containing: target, in: workspaces) == index else {
            return workspaces
        }
        var ids = WorkspaceBoard.leafIDs(workspaces[index].layout)
        guard let from = ids.firstIndex(of: dragged) else { return workspaces }
        ids.remove(at: from)
        guard let targetIndex = ids.firstIndex(of: target) else { return workspaces }
        var destination = targetIndex
        if after {
            destination += 1
        }
        ids.insert(dragged, at: destination)
        var workspaces = workspaces
        workspaces[index].layout = PaneLayout.replacingLeaves(workspaces[index].layout, with: ids)
        return workspaces
    }

    /// Adds `dragged` at the end of an existing workspace. A host already in that group stays put.
    static func join(_ dragged: UUID, to workspaceID: UUID, in workspaces: [Workspace]) -> [Workspace] {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return workspaces }
        if WorkspaceBoard.index(containing: dragged, in: workspaces) == index { return workspaces }
        let leaves = WorkspaceBoard.leafIDs(workspaces[index].layout)
        guard let target = leaves.last, target != dragged else { return workspaces }
        return WorkspaceBoard.join(dragged, beside: target, after: true, to: workspaceID, in: workspaces)
    }

    /// Inserts `dragged` beside `target` in that workspace's sidebar order.
    static func join(
        _ dragged: UUID,
        beside target: UUID,
        after: Bool,
        to workspaceID: UUID,
        in workspaces: [Workspace]
    ) -> [Workspace] {
        guard dragged != target else { return workspaces }
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return workspaces }
        if WorkspaceBoard.index(containing: dragged, in: workspaces) == index {
            return WorkspaceBoard.moveLeaf(dragged, beside: target, after: after, in: workspaces)
        }
        let members = WorkspaceBoard.leafIDs(workspaces[index].layout)
        guard members.contains(target) else { return workspaces }
        let edge: SplitEdge = after ? .right : .left
        var workspaces = WorkspaceBoard.extract(dragged, from: workspaces)
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return workspaces }
        workspaces[index].layout = PaneLayout.split(
            workspaces[index].layout,
            target: target,
            with: dragged,
            edge: edge
        )
        return WorkspaceBoard.withoutSingleLeaves(workspaces)
    }

    /// Selected hosts become one new equal-column workspace, in the given order.
    /// Fewer than two hosts, or a set that is already exactly one workspace, stays as it is.
    static func merge(_ ids: [UUID], in workspaces: [Workspace]) -> [Workspace] {
        var ordered: [UUID] = []
        var seen = Set<UUID>()
        for id in ids where seen.insert(id).inserted {
            ordered.append(id)
        }
        guard ordered.count >= 2 else { return workspaces }
        let wanted = Set(ordered)
        if workspaces.contains(where: { Set(WorkspaceBoard.leafIDs($0.layout)) == wanted }) {
            return workspaces
        }
        var workspaces = workspaces
        for id in ordered {
            workspaces = WorkspaceBoard.extract(id, from: workspaces)
        }
        guard let layout = WorkspaceBoard.arrange(ordered, as: .columns) else { return workspaces }
        workspaces.append(Workspace(
            id: UUID(),
            number: WorkspaceBoard.nextNumber(workspaces),
            layout: layout
        ))
        return workspaces
    }

    /// `dragged` joins `target` on `edge`. A lone host becomes a new workspace.
    /// A group that is no longer a split is removed, and its remaining host stays standalone.
    static func drop(
        dragged: UUID,
        onto target: UUID,
        edge: SplitEdge,
        in workspaces: [Workspace]
    ) -> [Workspace] {
        guard dragged != target else { return workspaces }
        if let draggedIndex = WorkspaceBoard.index(containing: dragged, in: workspaces),
           let targetIndex = WorkspaceBoard.index(containing: target, in: workspaces),
           draggedIndex == targetIndex {
            return WorkspaceBoard.rearrange(
                dragged: dragged,
                onto: target,
                edge: edge,
                at: draggedIndex,
                in: workspaces
            )
        }
        var workspaces = WorkspaceBoard.extract(dragged, from: workspaces)
        if let targetIndex = WorkspaceBoard.index(containing: target, in: workspaces) {
            workspaces[targetIndex].layout = PaneLayout.split(
                workspaces[targetIndex].layout,
                target: target,
                with: dragged,
                edge: edge
            )
            return WorkspaceBoard.withoutSingleLeaves(workspaces)
        }
        let layout = PaneLayout.split(.leaf(target), target: target, with: dragged, edge: edge)
        guard case .split = layout else { return workspaces }
        let created = Workspace(
            id: UUID(),
            number: WorkspaceBoard.nextNumber(workspaces),
            layout: layout
        )
        workspaces.append(created)
        return workspaces
    }

    /// Moves a pane inside the workspace it already belongs to. The group keeps its number.
    private static func rearrange(
        dragged: UUID,
        onto target: UUID,
        edge: SplitEdge,
        at index: Int,
        in workspaces: [Workspace]
    ) -> [Workspace] {
        var workspaces = workspaces
        guard let removed = PaneLayout.remove(dragged, from: workspaces[index].layout) else {
            return workspaces
        }
        let layout = PaneLayout.split(removed, target: target, with: dragged, edge: edge)
        guard case .split = layout else {
            workspaces.remove(at: index)
            return workspaces
        }
        workspaces[index].layout = layout
        return workspaces
    }

    /// Pulls a pane out of its workspace. The group disappears when one host is left.
    static func extract(_ id: UUID, from workspaces: [Workspace]) -> [Workspace] {
        guard let found = WorkspaceBoard.index(containing: id, in: workspaces) else { return workspaces }
        var workspaces = workspaces
        if let removed = PaneLayout.remove(id, from: workspaces[found].layout) {
            workspaces[found].layout = removed
        } else {
            workspaces.remove(at: found)
        }
        return WorkspaceBoard.withoutSingleLeaves(workspaces)
    }

    static func setRatio(_ id: UUID, to ratio: CGFloat, in workspaces: [Workspace]) -> [Workspace] {
        var workspaces = workspaces
        for index in workspaces.indices {
            workspaces[index].layout = PaneLayout.setRatio(id, to: ratio, in: workspaces[index].layout)
        }
        return workspaces
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

    private static func withoutSingleLeaves(_ workspaces: [Workspace]) -> [Workspace] {
        workspaces.filter { workspace in
            if case .split = workspace.layout {
                return true
            }
            return false
        }
    }
}
