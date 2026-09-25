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
        expect(SplitEdge.at(CGPoint(x: 10, y: 50), in: CGSize(width: 200, height: 100)) == .left, "left band")
        expect(SplitEdge.at(CGPoint(x: 100, y: 50), in: CGSize(width: 200, height: 100)) == nil, "center is not an edge")
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
