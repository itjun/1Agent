import CoreGraphics
import CryptoKit
import Foundation

enum SplitEdge: Equatable {
    case left, right, top, bottom, center

    /// The side the pointer is on. Left and right win when it is equally far from both midlines.
    static func at(_ point: CGPoint, in size: CGSize) -> SplitEdge? {
        guard size.width > 48, size.height > 48 else { return nil }
        guard point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return nil }
        let dx = point.x / size.width - 0.5
        let dy = point.y / size.height - 0.5
        if abs(dx) >= abs(dy) {
            return dx < 0 ? .left : .right
        }
        return dy < 0 ? .top : .bottom
    }
}

enum PaneDirection: Equatable {
    case left, right, up, down
}

enum SplitAxis: Equatable, Codable {
    /// Left and right.
    case vertical
    /// Top and bottom.
    case horizontal
}

struct SplitNode: Equatable, Identifiable, Codable {
    var id: UUID
    var axis: SplitAxis
    var ratio: CGFloat
    var leading: PaneNode
    var trailing: PaneNode
}

indirect enum PaneNode: Equatable, Codable {
    case leaf(UUID)
    case split(SplitNode)
}

struct PaneDivider: Equatable, Identifiable {
    var id: UUID
    /// The split this divider resizes. Same as `id` unless the divider is one segment of a longer line.
    var splitID: UUID
    /// Set when both sides of the split line up across it: the line is cut into one segment per cell,
    /// and dragging a segment moves only that cell's column (or row).
    var segment: Int?
    var axis: SplitAxis
    var frame: CGRect
    /// Min X or Y of the whole split, used while dragging the divider.
    var origin: CGFloat
    var span: CGFloat
}

enum PaneLayout {
    static func contains(_ id: UUID, in node: PaneNode) -> Bool {
        switch node {
        case .leaf(let leaf):
            return leaf == id
        case .split(let split):
            return contains(id, in: split.leading) || contains(id, in: split.trailing)
        }
    }

    /// Ratio for split `id` that gives every pane along its axis the same size, e.g. 1/3 when one
    /// pane sits beside a column of two stacked left-right. Nil when no such split exists.
    static func evenRatio(for id: UUID, in node: PaneNode) -> CGFloat? {
        guard case .split(let split) = node else { return nil }
        if split.id == id {
            let leading = PaneLayout.cellCount(split.leading, along: split.axis)
            let trailing = PaneLayout.cellCount(split.trailing, along: split.axis)
            return CGFloat(leading) / CGFloat(leading + trailing)
        }
        if let ratio = PaneLayout.evenRatio(for: id, in: split.leading) {
            return ratio
        }
        return PaneLayout.evenRatio(for: id, in: split.trailing)
    }

    /// Panes side by side along `axis`. A split across the other axis counts its fuller side.
    static func cellCount(_ node: PaneNode, along axis: SplitAxis) -> Int {
        switch node {
        case .leaf:
            return 1
        case .split(let split):
            let leading = PaneLayout.cellCount(split.leading, along: axis)
            let trailing = PaneLayout.cellCount(split.trailing, along: axis)
            if split.axis == axis {
                return leading + trailing
            }
            return max(leading, trailing)
        }
    }

    static func remove(_ id: UUID, from node: PaneNode) -> PaneNode? {
        switch node {
        case .leaf(let leaf):
            return leaf == id ? nil : node
        case .split(var split):
            let leading = remove(id, from: split.leading)
            let trailing = remove(id, from: split.trailing)
            switch (leading, trailing) {
            case (nil, nil):
                return nil
            case (let only?, nil), (nil, let only?):
                return only
            case (let leading?, let trailing?):
                split.leading = leading
                split.trailing = trailing
                return .split(split)
            }
        }
    }

    /// A lone leaf is not a split, so callers can drop it.
    static func splitRoot(_ node: PaneNode?) -> PaneNode? {
        guard let node else { return nil }
        if case .leaf = node { return nil }
        return node
    }

    static func split(_ node: PaneNode, target: UUID, with incoming: UUID, edge: SplitEdge) -> PaneNode {
        guard incoming != target else { return node }
        if edge == .center {
            return replace(node, target: target, with: incoming)
        }
        switch node {
        case .leaf(let id):
            guard id == target else { return node }
            return makeSplit(target: target, incoming: incoming, edge: edge)
        case .split(var split):
            split.leading = self.split(split.leading, target: target, with: incoming, edge: edge)
            split.trailing = self.split(split.trailing, target: target, with: incoming, edge: edge)
            return .split(split)
        }
    }

    /// The dragged tab takes the target pane. The previous tab leaves the split.
    static func replace(_ node: PaneNode, target: UUID, with incoming: UUID) -> PaneNode {
        switch node {
        case .leaf(let id):
            return id == target ? .leaf(incoming) : node
        case .split(var split):
            split.leading = replace(split.leading, target: target, with: incoming)
            split.trailing = replace(split.trailing, target: target, with: incoming)
            return .split(split)
        }
    }

    /// Keeps every split in place and writes `ids` into the leaves in sidebar order.
    static func replacingLeaves(_ node: PaneNode, with ids: [UUID]) -> PaneNode {
        var remaining = ids
        return PaneLayout.replacingLeaves(node, remaining: &remaining)
    }

    private static func replacingLeaves(_ node: PaneNode, remaining: inout [UUID]) -> PaneNode {
        switch node {
        case .leaf:
            guard let next = remaining.first else { return node }
            remaining.removeFirst()
            return .leaf(next)
        case .split(var split):
            split.leading = PaneLayout.replacingLeaves(split.leading, remaining: &remaining)
            split.trailing = PaneLayout.replacingLeaves(split.trailing, remaining: &remaining)
            return .split(split)
        }
    }

    static func setRatio(_ id: UUID, to ratio: CGFloat, in node: PaneNode) -> PaneNode {
        switch node {
        case .leaf:
            return node
        case .split(var split):
            if split.id == id {
                split.ratio = clamp(ratio)
                return .split(split)
            }
            split.leading = setRatio(id, to: ratio, in: split.leading)
            split.trailing = setRatio(id, to: ratio, in: split.trailing)
            return .split(split)
        }
    }

    /// The pane under `local`, and the side that pane would split toward. A pane cannot split onto itself.
    static func dropTarget(at local: CGPoint, frames: [UUID: CGRect], dragged: UUID) -> (UUID, SplitEdge)? {
        PaneLayout.dropTarget(at: local, frames: frames, excluding: [dragged])
    }

    /// Same, for a drag that carries several panes: none of them can be the landing pane.
    static func dropTarget(at local: CGPoint, frames: [UUID: CGRect], excluding: Set<UUID>) -> (UUID, SplitEdge)? {
        for (id, frame) in frames where !excluding.contains(id) && frame.contains(local) {
            let point = CGPoint(x: local.x - frame.minX, y: local.y - frame.minY)
            if let edge = SplitEdge.at(point, in: frame.size) {
                return (id, edge)
            }
        }
        return nil
    }

    /// The closest pane on that side that shares some of the current pane's height (left/right) or width (up/down).
    /// Ties go to the pane that overlaps the most, then to the one further left or further up.
    /// Nil at the edge of the layout; there is no wrap-around.
    static func neighbor(of id: UUID, toward direction: PaneDirection, frames: [UUID: CGRect]) -> UUID? {
        guard let current = frames[id] else { return nil }
        let tolerance: CGFloat = 2
        var best: (id: UUID, distance: CGFloat, overlap: CGFloat, leading: CGFloat)?
        for (candidateID, frame) in frames where candidateID != id {
            let distance: CGFloat
            let overlap: CGFloat
            let leading: CGFloat
            switch direction {
            case .left:
                distance = current.minX - frame.maxX
                overlap = min(current.maxY, frame.maxY) - max(current.minY, frame.minY)
                leading = frame.minY
            case .right:
                distance = frame.minX - current.maxX
                overlap = min(current.maxY, frame.maxY) - max(current.minY, frame.minY)
                leading = frame.minY
            case .up:
                distance = current.minY - frame.maxY
                overlap = min(current.maxX, frame.maxX) - max(current.minX, frame.minX)
                leading = frame.minX
            case .down:
                distance = frame.minY - current.maxY
                overlap = min(current.maxX, frame.maxX) - max(current.minX, frame.minX)
                leading = frame.minX
            }
            guard distance >= -tolerance, overlap > tolerance else { continue }
            guard let chosen = best else {
                best = (candidateID, distance, overlap, leading)
                continue
            }
            if distance < chosen.distance - tolerance {
                best = (candidateID, distance, overlap, leading)
                continue
            }
            if distance > chosen.distance + tolerance {
                continue
            }
            if overlap > chosen.overlap + tolerance {
                best = (candidateID, distance, overlap, leading)
                continue
            }
            if overlap < chosen.overlap - tolerance {
                continue
            }
            if leading < chosen.leading {
                best = (candidateID, distance, overlap, leading)
            }
        }
        return best?.id
    }

    static func frames(of node: PaneNode, in rect: CGRect) -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        collectFrames(node, in: rect, into: &result)
        return result
    }

    static func dividers(of node: PaneNode, in rect: CGRect) -> [PaneDivider] {
        var result: [PaneDivider] = []
        collectDividers(node, in: rect, into: &result)
        return result
    }

    static func highlight(for edge: SplitEdge, in rect: CGRect) -> CGRect {
        switch edge {
        case .left:
            return CGRect(x: rect.minX, y: rect.minY, width: rect.width * 0.5, height: rect.height)
        case .right:
            return CGRect(x: rect.midX, y: rect.minY, width: rect.width * 0.5, height: rect.height)
        case .top:
            return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.5)
        case .bottom:
            return CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height * 0.5)
        case .center:
            return rect
        }
    }

    /// The rounded reminder sits inside the landing area, with a margin like Otty.
    static func reminder(for edge: SplitEdge, in rect: CGRect) -> CGRect {
        let raw = highlight(for: edge, in: rect)
        let inset = min(10, min(raw.width, raw.height) / 4)
        let padded = raw.insetBy(dx: inset, dy: inset)
        guard padded.width >= 24, padded.height >= 24 else { return raw }
        return padded
    }

    private static func makeSplit(target: UUID, incoming: UUID, edge: SplitEdge) -> PaneNode {
        let incomingLeaf = PaneNode.leaf(incoming)
        let targetLeaf = PaneNode.leaf(target)
        let axis: SplitAxis
        let leading: PaneNode
        let trailing: PaneNode
        switch edge {
        case .center:
            return .leaf(incoming)
        case .left:
            axis = .vertical
            leading = incomingLeaf
            trailing = targetLeaf
        case .right:
            axis = .vertical
            leading = targetLeaf
            trailing = incomingLeaf
        case .top:
            axis = .horizontal
            leading = incomingLeaf
            trailing = targetLeaf
        case .bottom:
            axis = .horizontal
            leading = targetLeaf
            trailing = incomingLeaf
        }
        return .split(SplitNode(id: UUID(), axis: axis, ratio: 0.5, leading: leading, trailing: trailing))
    }

    private static func clamp(_ ratio: CGFloat) -> CGFloat {
        min(0.8, max(0.2, ratio))
    }

    private static func collectFrames(_ node: PaneNode, in rect: CGRect, into result: inout [UUID: CGRect]) {
        switch node {
        case .leaf(let id):
            result[id] = rect
        case .split(let split):
            let pair = childRects(split, in: rect)
            collectFrames(split.leading, in: pair.0, into: &result)
            collectFrames(split.trailing, in: pair.1, into: &result)
        }
    }

    private static func collectDividers(_ node: PaneNode, in rect: CGRect, into result: inout [PaneDivider]) {
        guard case .split(let split) = node else { return }
        let pair = childRects(split, in: rect)
        let hit: CGFloat = 8
        let aligned = PaneLayout.alignedCells(split, in: rect)
        switch split.axis {
        case .vertical:
            let x = pair.0.maxX - (hit - 1) / 2
            guard let aligned else {
                result.append(PaneDivider(
                    id: split.id,
                    splitID: split.id,
                    axis: .vertical,
                    frame: CGRect(x: x, y: rect.minY, width: hit, height: rect.height),
                    origin: rect.minX,
                    span: rect.width
                ))
                break
            }
            let cells = aligned.leading
            for index in cells.indices {
                let start = cells[index].rect.minY
                var end = rect.maxY
                if index + 1 < cells.count {
                    end = cells[index + 1].rect.minY
                }
                result.append(PaneDivider(
                    id: PaneLayout.segmentID(split.id, index),
                    splitID: split.id,
                    segment: index,
                    axis: .vertical,
                    frame: CGRect(x: x, y: start, width: hit, height: end - start),
                    origin: rect.minX,
                    span: rect.width
                ))
            }
        case .horizontal:
            let y = pair.0.maxY - (hit - 1) / 2
            guard let aligned else {
                result.append(PaneDivider(
                    id: split.id,
                    splitID: split.id,
                    axis: .horizontal,
                    frame: CGRect(x: rect.minX, y: y, width: rect.width, height: hit),
                    origin: rect.minY,
                    span: rect.height
                ))
                break
            }
            let cells = aligned.leading
            for index in cells.indices {
                let start = cells[index].rect.minX
                var end = rect.maxX
                if index + 1 < cells.count {
                    end = cells[index + 1].rect.minX
                }
                result.append(PaneDivider(
                    id: PaneLayout.segmentID(split.id, index),
                    splitID: split.id,
                    segment: index,
                    axis: .horizontal,
                    frame: CGRect(x: start, y: y, width: end - start, height: hit),
                    origin: rect.minY,
                    span: rect.height
                ))
            }
        }
        collectDividers(split.leading, in: pair.0, into: &result)
        collectDividers(split.trailing, in: pair.1, into: &result)
    }

    /// Dragging one segment of a divider. The split is turned the other way round, rows of columns into
    /// columns of rows (or back), so that segment's cell gets a split of its own; every pane keeps its frame.
    /// Returns the new tree and the split under that segment, whose id is the segment's divider id.
    /// Nil when the split is not in `node` or its sides do not line up in `rect`.
    /// Pane order follows the new tree: a grid of rows reads column by column afterwards, and back.
    static func detachSegment(_ segment: Int, of splitID: UUID, in node: PaneNode, rect: CGRect) -> (PaneNode, UUID)? {
        guard case .split(var split) = node else { return nil }
        let pair = childRects(split, in: rect)
        if split.id != splitID {
            if let found = PaneLayout.detachSegment(segment, of: splitID, in: split.leading, rect: pair.0) {
                split.leading = found.0
                return (.split(split), found.1)
            }
            if let found = PaneLayout.detachSegment(segment, of: splitID, in: split.trailing, rect: pair.1) {
                split.trailing = found.0
                return (.split(split), found.1)
            }
            return nil
        }
        guard let aligned = PaneLayout.alignedCells(split, in: rect) else { return nil }
        guard segment >= 0, segment < aligned.leading.count else { return nil }
        var cells: [PaneNode] = []
        for index in aligned.leading.indices {
            cells.append(.split(SplitNode(
                id: PaneLayout.segmentID(split.id, index),
                axis: split.axis,
                ratio: split.ratio,
                leading: aligned.leading[index].node,
                trailing: aligned.trailing[index].node
            )))
        }
        let rebuilt = PaneLayout.replacingChainCells(split.leading, axis: PaneLayout.crossAxis(split.axis), cells: &cells)
        return (rebuilt, PaneLayout.segmentID(split.id, segment))
    }

    /// Divider id of one segment. It is also the id of the split that segment gets once detached, so the
    /// divider view under the pointer survives the rebuild and the drag goes on.
    static func segmentID(_ splitID: UUID, _ index: Int) -> UUID {
        let digest = Array(Insecure.MD5.hash(data: Data("\(splitID.uuidString)/\(index)".utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }

    private static func crossAxis(_ axis: SplitAxis) -> SplitAxis {
        if axis == .vertical {
            return .horizontal
        }
        return .vertical
    }

    /// Both sides of the split cut the other way into the same number of cells at the same positions
    /// (within a point). Nil otherwise, or when neither side is cut.
    private static func alignedCells(
        _ split: SplitNode,
        in rect: CGRect
    ) -> (leading: [(node: PaneNode, rect: CGRect)], trailing: [(node: PaneNode, rect: CGRect)])? {
        let pair = childRects(split, in: rect)
        let cross = PaneLayout.crossAxis(split.axis)
        let leading = PaneLayout.chainCells(split.leading, axis: cross, in: pair.0)
        let trailing = PaneLayout.chainCells(split.trailing, axis: cross, in: pair.1)
        guard leading.count >= 2, leading.count == trailing.count else { return nil }
        let tolerance: CGFloat = 1
        for index in leading.indices {
            let a = leading[index].rect
            let b = trailing[index].rect
            if cross == .vertical {
                if abs(a.minX - b.minX) > tolerance || abs(a.maxX - b.maxX) > tolerance {
                    return nil
                }
            } else {
                if abs(a.minY - b.minY) > tolerance || abs(a.maxY - b.maxY) > tolerance {
                    return nil
                }
            }
        }
        return (leading, trailing)
    }

    /// Cells of the run of `axis` splits that starts at `node`, in tree order. Anything else is one cell.
    private static func chainCells(_ node: PaneNode, axis: SplitAxis, in rect: CGRect) -> [(node: PaneNode, rect: CGRect)] {
        guard case .split(let split) = node, split.axis == axis else { return [(node, rect)] }
        let pair = childRects(split, in: rect)
        return PaneLayout.chainCells(split.leading, axis: axis, in: pair.0)
            + PaneLayout.chainCells(split.trailing, axis: axis, in: pair.1)
    }

    /// Same walk as `chainCells`, putting `cells` in place of the cells in order. The run's splits keep their ratios.
    private static func replacingChainCells(_ node: PaneNode, axis: SplitAxis, cells: inout [PaneNode]) -> PaneNode {
        guard case .split(var split) = node, split.axis == axis else {
            if cells.isEmpty {
                return node
            }
            return cells.removeFirst()
        }
        split.leading = PaneLayout.replacingChainCells(split.leading, axis: axis, cells: &cells)
        split.trailing = PaneLayout.replacingChainCells(split.trailing, axis: axis, cells: &cells)
        return .split(split)
    }

    private static func childRects(_ split: SplitNode, in rect: CGRect) -> (CGRect, CGRect) {
        let ratio = clamp(split.ratio)
        let gap: CGFloat = 1
        switch split.axis {
        case .vertical:
            let lead = (rect.width - gap) * ratio
            return (
                CGRect(x: rect.minX, y: rect.minY, width: lead, height: rect.height),
                CGRect(x: rect.minX + lead + gap, y: rect.minY, width: rect.width - lead - gap, height: rect.height)
            )
        case .horizontal:
            let lead = (rect.height - gap) * ratio
            return (
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: lead),
                CGRect(x: rect.minX, y: rect.minY + lead + gap, width: rect.width, height: rect.height - lead - gap)
            )
        }
    }
}
