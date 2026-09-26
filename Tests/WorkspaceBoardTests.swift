import CoreGraphics
import Foundation

@main
enum WorkspaceBoardTests {
    static func main() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()

        let merged = WorkspaceBoard.drop(dragged: second, onto: first, edge: .right, in: [])
        expect(merged.count == 1, "two hosts become one workspace")
        expect(merged[0].number == 1, "the first merge is workspace 1")
        expect(WorkspaceBoard.leafIDs(merged[0].layout) == [first, second], "the incoming pane sits on the right")
        let swapped = WorkspaceBoard.drop(dragged: second, onto: first, edge: .left, in: merged)
        expect(swapped.count == 1 && swapped[0].id == merged[0].id && swapped[0].number == 1, "rearranging a pair keeps that workspace")
        expect(WorkspaceBoard.leafIDs(swapped[0].layout) == [second, first], "the incoming pane sits on the left")

        let secondGroup = WorkspaceBoard.drop(dragged: fourth, onto: third, edge: .bottom, in: merged)
        expect(secondGroup.count == 2, "a second pair is its own workspace")
        expect(secondGroup.map(\.number).sorted() == [1, 2], "the second merge is workspace 2")
        expect(WorkspaceBoard.index(containing: first, in: secondGroup) != WorkspaceBoard.index(containing: third, in: secondGroup), "the two groups do not share a tree")

        let emptied = WorkspaceBoard.extract(second, from: merged)
        expect(emptied.isEmpty, "extracting one host of a pair dissolves the workspace")

        let moved = WorkspaceBoard.drop(dragged: fourth, onto: first, edge: .left, in: secondGroup)
        expect(moved.count == 1, "leaving a pair dissolves that workspace")
        let movedLeaves = WorkspaceBoard.leafIDs(moved[0].layout)
        expect(movedLeaves.contains(first) && movedLeaves.contains(second) && movedLeaves.contains(fourth), "the dragged host joins the other workspace")
        expect(!movedLeaves.contains(third), "the host left behind is no longer in a workspace")
        expect(moved[0].id == merged[0].id, "joining an existing workspace keeps that workspace")

        var triple = WorkspaceBoard.drop(dragged: second, onto: first, edge: .right, in: [])
        triple = WorkspaceBoard.drop(dragged: third, onto: second, edge: .bottom, in: triple)
        let keptID = triple[0].id
        let rearranged = WorkspaceBoard.drop(dragged: third, onto: first, edge: .left, in: triple)
        expect(rearranged.count == 1 && rearranged[0].id == keptID, "rearranging inside a workspace does not open a new one")
        expect(WorkspaceBoard.leafIDs(rearranged[0].layout).count == 3, "all three panes stay in the workspace")

        let dissolvedFirst = WorkspaceBoard.extract(second, from: secondGroup)
        expect(dissolvedFirst.map(\.number) == [2], "workspace 2 remains after workspace 1 dissolves")
        let fifth = UUID()
        let sixth = UUID()
        let reused = WorkspaceBoard.drop(dragged: sixth, onto: fifth, edge: .top, in: dissolvedFirst)
        expect(reused.map(\.number).sorted() == [1, 2], "the next merge reuses the smallest free number")

        expect(WorkspaceBoard.drop(dragged: first, onto: first, edge: .left, in: []) == [], "a pane does not merge with itself")
        let untouched = WorkspaceBoard.extract(first, from: [])
        expect(untouched.isEmpty, "extracting a standalone host does nothing")

        do {
            let encoded = try JSONEncoder().encode(merged)
            let decoded = try JSONDecoder().decode([Workspace].self, from: encoded)
            expect(decoded == merged, "a workspace survives a relaunch")
        } catch {
            fail("workspace did not encode")
        }
        let layoutsForTwo = WorkspaceBoard.availableLayouts(paneCount: 2).map(\.rawValue)
        expect(layoutsForTwo == ["columns", "rows"], "two panes only offer a row and a column")
        let layoutsForThree = WorkspaceBoard.availableLayouts(paneCount: 3).map(\.rawValue)
        expect(layoutsForThree == ["columns", "rows", "leadingSide", "leadingTop"], "three panes add the two featured layouts")
        expect(!WorkspaceBoard.availableLayouts(paneCount: 3).contains(.grid), "three panes have no separate grid")
        expect(WorkspaceBoard.availableLayouts(paneCount: 4).contains(.grid), "four panes can form a grid")
        expect(WorkspaceBoard.availableLayouts(paneCount: 1).isEmpty, "one pane has no layout menu")

        let panes = [UUID(), UUID(), UUID(), UUID(), UUID(), UUID()]
        let a = panes[0], b = panes[1], c = panes[2], d = panes[3], e = panes[4]
        let wide = CGRect(x: 0, y: 0, width: 900, height: 300)
        let square = CGRect(x: 0, y: 0, width: 600, height: 600)

        let threeColumns = WorkspaceBoard.arrange([a, b, c], as: .columns)!
        expect(WorkspaceBoard.leafIDs(threeColumns) == [a, b, c], "columns keep sidebar order")
        let columnFrames = PaneLayout.frames(of: threeColumns, in: wide)
        expect(columnFrames[a]!.maxX <= columnFrames[b]!.minX, "the second pane is to the right of the first")
        expect(columnFrames[b]!.maxX <= columnFrames[c]!.minX, "the third pane is to the right of the second")
        expect(abs(columnFrames[a]!.minY - columnFrames[c]!.minY) < 1, "columns share the top edge")
        expect(nearlyEqual(columnFrames[a]!.width, columnFrames[b]!.width), "the first two columns have the same width")
        expect(nearlyEqual(columnFrames[b]!.width, columnFrames[c]!.width), "the last two columns have the same width")

        let threeRows = WorkspaceBoard.arrange([a, b, c], as: .rows)!
        let rowFrames = PaneLayout.frames(of: threeRows, in: wide)
        expect(rowFrames[a]!.maxY <= rowFrames[b]!.minY, "the second pane is below the first")
        expect(rowFrames[b]!.maxY <= rowFrames[c]!.minY, "the third pane is below the second")
        expect(nearlyEqual(rowFrames[a]!.height, rowFrames[c]!.height), "rows have the same height")

        let grid = WorkspaceBoard.arrange([a, b, c, d], as: .grid)!
        let gridFrames = PaneLayout.frames(of: grid, in: square)
        expect(gridFrames[a]!.maxX <= gridFrames[b]!.minX, "the second pane sits to the right in the grid")
        expect(abs(gridFrames[a]!.minY - gridFrames[b]!.minY) < 1, "the first two panes share a row")
        expect(gridFrames[a]!.maxY <= gridFrames[c]!.minY, "the third pane starts the next row")
        expect(gridFrames[c]!.maxX <= gridFrames[d]!.minX, "the fourth pane sits to the right of the third")
        expect(nearlyEqual(gridFrames[a]!.width, gridFrames[d]!.width), "grid cells have the same width")
        expect(nearlyEqual(gridFrames[a]!.height, gridFrames[d]!.height), "grid cells have the same height")

        let five = WorkspaceBoard.arrange([a, b, c, d, e], as: .grid)!
        let fiveFrames = PaneLayout.frames(of: five, in: square)
        expect(fiveFrames[a]!.maxX <= fiveFrames[b]!.minX && fiveFrames[b]!.maxX <= fiveFrames[c]!.minX, "the top row has three panes")
        expect(abs(fiveFrames[a]!.minY - fiveFrames[c]!.minY) < 1, "the first three panes share the top row")
        expect(fiveFrames[c]!.maxY <= fiveFrames[d]!.minY, "the fourth pane is on the bottom row")
        expect(fiveFrames[d]!.maxX <= fiveFrames[e]!.minX, "the bottom row has two panes")
        expect(nearlyEqual(fiveFrames[a]!.height, fiveFrames[e]!.height), "the two grid rows have the same height")

        let side = WorkspaceBoard.arrange([a, b, c], as: .leadingSide)!
        let sideFrames = PaneLayout.frames(of: side, in: square)
        expect(sideFrames[a]!.maxX <= sideFrames[b]!.minX, "the first pane is the left half")
        expect(sideFrames[b]!.minX == sideFrames[c]!.minX, "the other two panes share the right side")
        expect(sideFrames[b]!.maxY <= sideFrames[c]!.minY, "the right side stacks downward")
        expect(nearlyEqual(sideFrames[a]!.width, sideFrames[b]!.width), "the leading pane takes half the width")

        let top = WorkspaceBoard.arrange([a, b, c], as: .leadingTop)!
        let topFrames = PaneLayout.frames(of: top, in: square)
        expect(topFrames[a]!.maxY <= topFrames[b]!.minY, "the first pane is the top half")
        expect(topFrames[b]!.maxX <= topFrames[c]!.minX, "the bottom row runs left to right")
        expect(nearlyEqual(topFrames[a]!.height, topFrames[b]!.height), "the leading pane takes half the height")

        let six = WorkspaceBoard.arrange(panes, as: .columns)!
        let sixFrames = PaneLayout.frames(of: six, in: wide)
        let sixWidths = panes.compactMap { sixFrames[$0]?.width }
        expect(sixWidths.count == 6, "six columns all have a frame")
        expect(nearlyEqual(sixWidths.min()!, sixWidths.max()!), "six columns stay equal inside the ratio limit")

        let workspace = Workspace(id: UUID(), number: 4, layout: threeColumns)
        let applied = WorkspaceBoard.apply(.rows, to: workspace)
        expect(applied.id == workspace.id && applied.number == 4, "arranging keeps the workspace")
        expect(WorkspaceBoard.leafIDs(applied.layout) == [a, b, c], "arranging keeps every pane")
        expect(WorkspaceBoard.arrange([a], as: .columns) == nil, "one pane is not arranged")

        let outsider = UUID()
        let joined = WorkspaceBoard.join(outsider, to: applied.id, in: [applied])
        expect(joined.count == 1 && joined[0].id == applied.id, "a standalone host joins the workspace it is dropped on")
        expect(WorkspaceBoard.leafIDs(joined[0].layout) == [a, b, c, outsider], "the new host is last in the sidebar order")
        let stayed = WorkspaceBoard.join(a, to: applied.id, in: [applied])
        expect(stayed == [applied], "dropping a member on its own workspace leaves the tree alone")
        let atFront = WorkspaceBoard.join(outsider, beside: a, after: false, to: applied.id, in: [applied])
        expect(WorkspaceBoard.leafIDs(atFront[0].layout) == [outsider, a, b, c], "a host can join before the first member")
        let afterFirst = WorkspaceBoard.join(outsider, beside: a, after: true, to: applied.id, in: [applied])
        expect(WorkspaceBoard.leafIDs(afterFirst[0].layout) == [a, outsider, b, c], "a host can join after a chosen member")

        let quad = WorkspaceBoard.arrange([a, b, c, d], as: .grid)!
        let quadWorkspace = Workspace(id: UUID(), number: 1, layout: quad)
        let broughtForward = WorkspaceBoard.moveLeaf(d, beside: a, after: false, in: [quadWorkspace])
        expect(WorkspaceBoard.leafIDs(broughtForward[0].layout) == [d, a, b, c], "moving to the top of the list puts that pane first")
        expect(splitIDs(broughtForward[0].layout) == splitIDs(quad), "reordering keeps the same splits")
        let beforeFrames = PaneLayout.frames(of: quad, in: square)
        let afterFrames = PaneLayout.frames(of: broughtForward[0].layout, in: square)
        expect(samePlace(afterFrames[d], beforeFrames[a]), "the first sidebar row takes the first window")
        expect(samePlace(afterFrames[c], beforeFrames[d]), "the last sidebar row takes the last window")
        let sentBack = WorkspaceBoard.moveLeaf(a, beside: d, after: true, in: [quadWorkspace])
        expect(WorkspaceBoard.leafIDs(sentBack[0].layout) == [b, c, d, a], "dropping below the last row puts that pane last")
        let untouchedOrder = WorkspaceBoard.moveLeaf(b, beside: a, after: true, in: [quadWorkspace])
        expect(untouchedOrder == [quadWorkspace], "dropping a pane where it already sits changes nothing")
        expect(WorkspaceBoard.moveLeaf(a, beside: outsider, after: false, in: [quadWorkspace]) == [quadWorkspace], "a host outside the workspace is not a reorder target")

        expect(WorkspaceBoard.merge([a], in: [workspace]) == [workspace], "one host is not merged")
        expect(WorkspaceBoard.merge([a, b, c], in: [workspace]) == [workspace], "selecting every member of a workspace changes nothing")
        let four = Workspace(id: UUID(), number: 3, layout: WorkspaceBoard.arrange([a, b, c, d], as: .columns)!)
        let partial = WorkspaceBoard.merge([b, d], in: [four])
        expect(partial.count == 2, "unselected hosts stay when at least two remain")
        let kept = partial.first { $0.id == four.id }!
        let created = partial.first { $0.id != four.id }!
        expect(kept.number == 3, "the old workspace keeps its number")
        expect(WorkspaceBoard.leafIDs(kept.layout) == [a, c], "hosts that were not selected stay in order")
        expect(created.number == 1, "the new workspace takes the smallest free number")
        expect(WorkspaceBoard.leafIDs(created.layout) == [b, d], "the new workspace follows the given order")
        let mergedFrames = PaneLayout.frames(of: created.layout, in: wide)
        expect(mergedFrames[b]!.maxX <= mergedFrames[d]!.minX, "merged panes sit side by side")
        expect(nearlyEqual(mergedFrames[b]!.width, mergedFrames[d]!.width), "merged panes share the width")
        let picked = WorkspaceBoard.merge([c, a], in: [workspace])
        expect(picked.count == 1 && picked[0].id != workspace.id, "extracting a pair dissolves the leftover host and opens a new workspace")
        expect(WorkspaceBoard.leafIDs(picked[0].layout) == [c, a], "the extracted hosts keep the given order")
        expect(!WorkspaceBoard.leafIDs(picked[0].layout).contains(b), "the host left behind is no longer in a workspace")

        print("ok")
    }

    static func nearlyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 2
    }

    static func samePlace(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        guard let lhs, let rhs else { return false }
        return nearlyEqual(lhs.minX, rhs.minX)
            && nearlyEqual(lhs.minY, rhs.minY)
            && nearlyEqual(lhs.width, rhs.width)
            && nearlyEqual(lhs.height, rhs.height)
    }

    static func splitIDs(_ node: PaneNode) -> [UUID] {
        switch node {
        case .leaf:
            return []
        case .split(let split):
            return [split.id] + splitIDs(split.leading) + splitIDs(split.trailing)
        }
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    static func fail(_ message: String) {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}
