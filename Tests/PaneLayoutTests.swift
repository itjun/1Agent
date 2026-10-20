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

        let fourth = UUID()
        let threeAcross = PaneLayout.split(splitRight, target: second, with: fourth, edge: .right)
        guard case .split(let rootOfThree) = threeAcross else { fail("expected a split"); return }
        expect(PaneLayout.evenRatio(for: rootOfThree.id, in: threeAcross).map { abs($0 - 1.0 / 3.0) < 0.001 } == true, "one pane beside two across gets a third")
        guard case .split(let rootOfNested) = nested else { fail("expected a split"); return }
        expect(PaneLayout.evenRatio(for: rootOfNested.id, in: nested) == 0.5, "a stacked column counts as one across")
        guard case .split(let column) = rootOfNested.trailing else { fail("expected a column"); return }
        expect(PaneLayout.evenRatio(for: column.id, in: nested) == 0.5, "two stacked panes split evenly")
        expect(PaneLayout.evenRatio(for: UUID(), in: nested) == nil, "unknown split has no ratio")

        let removed = PaneLayout.remove(third, from: nested)
        expect(removed == splitRight, "removing the extra pane collapses back")
        do {
            let encoded = try JSONEncoder().encode(splitRight)
            let decoded = try JSONDecoder().decode(PaneNode.self, from: encoded)
            expect(decoded == splitRight, "split layout survives a relaunch")
        } catch {
            fail("split layout did not encode")
        }
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

        let rightHit = PaneLayout.dropTarget(
            at: CGPoint(x: 160, y: 50),
            frames: [first: CGRect(x: 0, y: 0, width: 200, height: 100)],
            dragged: second
        )
        expect(rightHit?.0 == first && rightHit?.1 == .right, "a point on the right half splits right")
        let selfHit = PaneLayout.dropTarget(
            at: CGPoint(x: 160, y: 50),
            frames: [first: CGRect(x: 0, y: 0, width: 200, height: 100)],
            dragged: first
        )
        expect(selfHit == nil, "a pane does not split onto itself")

        expect(PaneLayout.split(.leaf(first), target: first, with: second, edge: .center) == .leaf(second), "center drop takes the pane")
        expect(PaneLayout.splitRoot(.leaf(second)) == nil, "a single pane is not stored as a split")
        let taken = PaneLayout.split(splitRight, target: first, with: third, edge: .center)
        guard case .split(let takenNode) = taken else { fail("center drop inside a split keeps the split"); return }
        expect(takenNode.leading == .leaf(third) && takenNode.trailing == .leaf(second), "center drop replaces that pane")

        let topLeft = UUID()
        let topMiddle = UUID()
        let topRight = UUID()
        let bottomLeft = UUID()
        let bottomRight = UUID()
        let grid: [UUID: CGRect] = [
            topLeft: CGRect(x: 0, y: 0, width: 100, height: 100),
            topMiddle: CGRect(x: 101, y: 0, width: 99, height: 100),
            topRight: CGRect(x: 201, y: 0, width: 99, height: 100),
            bottomLeft: CGRect(x: 0, y: 101, width: 150, height: 99),
            bottomRight: CGRect(x: 151, y: 101, width: 149, height: 99),
        ]
        expect(PaneLayout.neighbor(of: topLeft, toward: .right, frames: grid) == topMiddle, "right goes to the next pane in the row")
        expect(PaneLayout.neighbor(of: topRight, toward: .right, frames: grid) == nil, "right stops at the edge")
        expect(PaneLayout.neighbor(of: bottomLeft, toward: .up, frames: grid) == topLeft, "up picks the pane with the most overlap")
        expect(PaneLayout.neighbor(of: bottomRight, toward: .up, frames: grid) == topRight, "up from the right half lands on the right column")
        expect(PaneLayout.neighbor(of: topMiddle, toward: .down, frames: grid) == bottomLeft, "an even overlap goes to the pane further left")
        expect(PaneLayout.neighbor(of: topRight, toward: .down, frames: grid) == bottomRight, "down follows the column")
        expect(PaneLayout.neighbor(of: bottomRight, toward: .left, frames: grid) == bottomLeft, "left stays in the row")
        expect(PaneLayout.neighbor(of: topLeft, toward: .up, frames: grid) == nil, "up stops at the top edge")

        PaneLayoutTests.dividerSegments()
        print("ok")
    }

    /// 2×2 grid built as rows: the middle line belongs to the root, so it is cut per column and a
    /// segment drag moves only its own column.
    static func dividerSegments() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()
        let rootID = UUID()
        let topID = UUID()
        let bottomID = UUID()
        let rows = PaneNode.split(SplitNode(
            id: rootID,
            axis: .horizontal,
            ratio: 0.5,
            leading: .split(SplitNode(id: topID, axis: .vertical, ratio: 0.5, leading: .leaf(a), trailing: .leaf(b))),
            trailing: .split(SplitNode(id: bottomID, axis: .vertical, ratio: 0.5, leading: .leaf(c), trailing: .leaf(d)))
        ))
        let rect = CGRect(x: 0, y: 0, width: 401, height: 201)

        let dividers = PaneLayout.dividers(of: rows, in: rect)
        let middle = dividers.filter { $0.splitID == rootID }
        expect(middle.count == 2, "aligned columns cut the middle line in two")
        expect(middle[0].segment == 0 && middle[1].segment == 1, "segments follow the columns left to right")
        expect(middle[0].id != middle[1].id && middle[0].id != rootID, "each segment has its own divider id")
        expect(middle[0].frame.minX == 0 && abs(middle[0].frame.maxX - 201) < 0.01, "left segment covers the left column and the gap")
        expect(abs(middle[1].frame.maxX - 401) < 0.01, "right segment reaches the right edge")
        expect(dividers.filter { $0.splitID == topID }.first?.segment == nil, "a row's own vertical line is not cut")

        let before = PaneLayout.frames(of: rows, in: rect)
        guard let (columns, dragged) = PaneLayout.detachSegment(0, of: rootID, in: rows, rect: rect) else {
            fail("aligned grid did not detach")
            return
        }
        expect(dragged == middle[0].id, "the detached split keeps the segment's divider id")
        expect(PaneLayout.frames(of: columns, in: rect) == before, "detaching moves no pane")
        expect(WorkspaceBoard.leafIDs(columns) == [a, c, b, d], "panes read column by column after the rebuild")
        do {
            let decoded = try JSONDecoder().decode(PaneNode.self, from: JSONEncoder().encode(columns))
            expect(decoded == columns, "the rebuilt layout survives a relaunch")
        } catch {
            fail("rebuilt layout did not encode")
        }

        let resized = PaneLayout.setRatio(dragged, to: 0.3, in: columns)
        let after = PaneLayout.frames(of: resized, in: rect)
        expect(after[a]!.height < before[a]!.height && after[c]!.height > before[c]!.height, "the left column moves")
        expect(after[b] == before[b] && after[d] == before[d], "the right column stays")
        let resizedDividers = PaneLayout.dividers(of: resized, in: rect)
        let horizontal = resizedDividers.filter { $0.axis == .horizontal }
        expect(horizontal.count == 2 && horizontal[0].frame.minY != horizontal[1].frame.minY, "each column draws its line at its own height")
        expect(resizedDividers.filter { $0.axis == .vertical }.count == 1, "columns no longer line up, so the middle vertical line is whole")

        let columnDividers = PaneLayout.dividers(of: columns, in: rect).filter { $0.axis == .vertical }
        expect(columnDividers.count == 2, "columns of aligned rows cut the vertical line per row")
        guard let (back, topSplit) = PaneLayout.detachSegment(0, of: columnDividers[0].splitID, in: columns, rect: rect) else {
            fail("aligned columns did not detach")
            return
        }
        expect(topSplit == columnDividers[0].id, "the row keeps the segment's divider id")
        expect(PaneLayout.frames(of: back, in: rect) == before, "turning back moves no pane")
        expect(WorkspaceBoard.leafIDs(back) == [a, b, c, d], "panes read row by row again")

        let skewed = PaneLayout.setRatio(topID, to: 0.3, in: rows)
        expect(PaneLayout.dividers(of: skewed, in: rect).filter { $0.splitID == rootID }.count == 1, "misaligned columns keep one whole line")
        expect(PaneLayout.detachSegment(0, of: rootID, in: skewed, rect: rect) == nil, "misaligned columns do not detach")
        expect(PaneLayout.detachSegment(2, of: rootID, in: rows, rect: rect) == nil, "a segment past the last column does not detach")

        let threeOverTwo = PaneNode.split(SplitNode(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            leading: .split(SplitNode(id: UUID(), axis: .vertical, ratio: 0.5, leading: .leaf(a), trailing: .leaf(b))),
            trailing: .leaf(c)
        ))
        expect(PaneLayout.dividers(of: threeOverTwo, in: rect).count == 2, "a side without columns keeps the line whole")

        let wide = UUID()
        let e = UUID()
        let f = UUID()
        let threeColumns = PaneNode.split(SplitNode(
            id: wide,
            axis: .horizontal,
            ratio: 0.5,
            leading: .split(SplitNode(id: UUID(), axis: .vertical, ratio: 0.5, leading: .split(SplitNode(id: UUID(), axis: .vertical, ratio: 0.5, leading: .leaf(a), trailing: .leaf(b))), trailing: .leaf(c))),
            trailing: .split(SplitNode(id: UUID(), axis: .vertical, ratio: 0.5, leading: .split(SplitNode(id: UUID(), axis: .vertical, ratio: 0.5, leading: .leaf(d), trailing: .leaf(e))), trailing: .leaf(f)))
        ))
        let wideBefore = PaneLayout.frames(of: threeColumns, in: rect)
        expect(PaneLayout.dividers(of: threeColumns, in: rect).filter { $0.splitID == wide }.count == 3, "three aligned columns give three segments")
        guard let (wideColumns, middleSplit) = PaneLayout.detachSegment(1, of: wide, in: threeColumns, rect: rect) else {
            fail("three columns did not detach")
            return
        }
        expect(PaneLayout.frames(of: wideColumns, in: rect) == wideBefore, "three columns keep their frames")
        let wideResized = PaneLayout.frames(of: PaneLayout.setRatio(middleSplit, to: 0.7, in: wideColumns), in: rect)
        expect(wideResized[b] != wideBefore[b], "the middle column moves")
        expect(wideResized[a] == wideBefore[a] && wideResized[c] == wideBefore[c], "the outer columns stay")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    static func fail(_ message: String) {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}
