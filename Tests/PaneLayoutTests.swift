import CoreGraphics
import Foundation

@main
enum PaneLayoutTests {
    static func main() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let splitRight = PaneLayout.split(.leaf(first), target: first, with: second, edge: .right)
        guard case .split(let node) = splitRight else { fail("expected a split"); return }
        expect(node.axis == .vertical, "right edge splits left/right")
        expect(node.leading == .leaf(first) && node.trailing == .leaf(second), "incoming pane sits on the right")

        let nested = PaneLayout.split(splitRight, target: second, with: third, edge: .bottom)
        expect(PaneLayout.contains(third, in: nested), "third pane is in the tree")
        let frames = PaneLayout.frames(of: nested, in: CGRect(x: 0, y: 0, width: 200, height: 100))
        expect(frames.count == 3, "three frames")
        let left = frames[first]!
        let top = frames[second]!
        let bottom = frames[third]!
        expect(abs((left.width + top.width) - 199) < 1, "left and right fill the width")
        expect(abs(top.width - bottom.width) < 0.1, "stacked panes share a column")
        expect(abs((top.height + bottom.height) - 99) < 1, "stacked panes fill the column")

        let removed = PaneLayout.remove(third, from: nested)
        expect(removed == splitRight, "removing the extra pane collapses back")
        expect(PaneLayout.splitRoot(PaneLayout.remove(second, from: splitRight)) == nil, "one remaining pane is no longer a split")
        expect(PaneLayout.split(.leaf(first), target: first, with: first, edge: .left) == .leaf(first), "a pane does not split with itself")

        let ratio = PaneLayout.setRatio(node.id, to: 0.95, in: splitRight)
        if case .split(let resized) = ratio {
            expect(abs(resized.ratio - 0.8) < 0.001, "ratio clamps to 0.8")
        } else {
            fail("ratio update lost the split")
        }
        let size = CGSize(width: 200, height: 100)
        expect(SplitEdge.at(CGPoint(x: 40, y: 50), in: size) == .left, "left of center")
        expect(SplitEdge.at(CGPoint(x: 160, y: 50), in: size) == .right, "right of center")
        expect(SplitEdge.at(CGPoint(x: 100, y: 20), in: size) == .top, "above center")
        expect(SplitEdge.at(CGPoint(x: 100, y: 80), in: size) == .bottom, "below center")
        expect(SplitEdge.at(CGPoint(x: 100, y: 50), in: size) == .right, "exact center picks a side")
        expect(SplitEdge.at(CGPoint(x: 20, y: 40), in: size) == .left, "a corner follows the stronger axis")
        expect(SplitEdge.at(CGPoint(x: -1, y: 50), in: size) == nil, "outside the pane")
        expect(SplitEdge.at(CGPoint(x: 10, y: 10), in: CGSize(width: 40, height: 40)) == nil, "tiny pane")

        let pane = CGRect(x: 0, y: 0, width: 200, height: 100)
        expect(PaneLayout.highlight(for: .center, in: pane) == pane, "center highlight is the whole pane")
        let rightHalf = PaneLayout.highlight(for: .right, in: pane)
        expect(rightHalf.minX == 100 && rightHalf.width == 100, "right highlight is the right half")
        let reminder = PaneLayout.reminder(for: .center, in: pane)
        expect(reminder == CGRect(x: 10, y: 10, width: 180, height: 80), "reminder sits inside the pane")

        expect(PaneLayout.split(.leaf(first), target: first, with: second, edge: .center) == .leaf(second), "center drop takes the pane")
        expect(PaneLayout.splitRoot(.leaf(second)) == nil, "a single pane is not stored as a split")
        let taken = PaneLayout.split(splitRight, target: first, with: third, edge: .center)
        guard case .split(let takenNode) = taken else { fail("center drop inside a split keeps the split"); return }
        expect(takenNode.leading == .leaf(third) && takenNode.trailing == .leaf(second), "center drop replaces that pane")
        print("ok")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    static func fail(_ message: String) {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}
