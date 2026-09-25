import CoreGraphics
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

enum SplitAxis: Equatable {
    /// Left and right.
    case vertical
    /// Top and bottom.
    case horizontal
}

struct SplitNode: Equatable, Identifiable {
    var id: UUID
    var axis: SplitAxis
    var ratio: CGFloat
    var leading: PaneNode
    var trailing: PaneNode
}

indirect enum PaneNode: Equatable {
    case leaf(UUID)
    case split(SplitNode)
}

struct PaneDivider: Equatable, Identifiable {
    var id: UUID
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
        switch split.axis {
        case .vertical:
            let x = pair.0.maxX - (hit - 1) / 2
            result.append(PaneDivider(
                id: split.id,
                axis: .vertical,
                frame: CGRect(x: x, y: rect.minY, width: hit, height: rect.height),
                origin: rect.minX,
                span: rect.width
            ))
        case .horizontal:
            let y = pair.0.maxY - (hit - 1) / 2
            result.append(PaneDivider(
                id: split.id,
                axis: .horizontal,
                frame: CGRect(x: rect.minX, y: y, width: rect.width, height: hit),
                origin: rect.minY,
                span: rect.height
            ))
        }
        collectDividers(split.leading, in: pair.0, into: &result)
        collectDividers(split.trailing, in: pair.1, into: &result)
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
