import CoreGraphics
import Foundation

@main
enum WorkspaceBoardTests {
    static func main() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()

        let sidebar = [first, second, third]
        expect(WorkspaceBoard.terminal(number: 1, in: sidebar) == first, "⌘1 is the first sidebar terminal")
        expect(WorkspaceBoard.terminal(number: 3, in: sidebar) == third, "⌘3 is the third")
        expect(WorkspaceBoard.terminal(number: 4, in: sidebar) == nil, "past the end there is nothing")
        expect(WorkspaceBoard.terminal(number: 0, in: sidebar) == nil, "0 is not a position")
        expect(WorkspaceBoard.adjacentTerminal(to: second, forward: true, in: sidebar) == third, "next follows sidebar order")
        expect(WorkspaceBoard.adjacentTerminal(to: third, forward: true, in: sidebar) == first, "next wraps to the top")
        expect(WorkspaceBoard.adjacentTerminal(to: first, forward: false, in: sidebar) == third, "previous wraps to the bottom")
        expect(WorkspaceBoard.adjacentTerminal(to: nil, forward: false, in: sidebar) == third, "no selection: previous is the last")
        expect(WorkspaceBoard.adjacentTerminal(to: first, forward: true, in: [first]) == nil, "a lone terminal has nothing to switch to")
        expect(WorkspaceBoard.adjacentTerminal(to: nil, forward: true, in: []) == nil, "an empty sidebar has nothing")

        expect(WorkspaceBoard.selectionAfterClosing(second, workspaceMembers: [], sidebarOrder: sidebar) == third, "closing a row selects the next row")
        expect(WorkspaceBoard.selectionAfterClosing(third, workspaceMembers: [], sidebarOrder: sidebar) == second, "closing the last row selects the one above, not the first")
        expect(WorkspaceBoard.selectionAfterClosing(first, workspaceMembers: [], sidebarOrder: sidebar) == second, "closing the first row selects the next row")
        expect(WorkspaceBoard.selectionAfterClosing(first, workspaceMembers: [], sidebarOrder: [first]) == nil, "closing the only terminal leaves nothing")
        let splitSidebar = [first, second, third, fourth]
        expect(WorkspaceBoard.selectionAfterClosing(third, workspaceMembers: [second, third], sidebarOrder: splitSidebar) == second, "a pane of the same workspace comes before the next sidebar row")
        expect(WorkspaceBoard.selectionAfterClosing(second, workspaceMembers: [second, third], sidebarOrder: splitSidebar) == third, "the next pane of the workspace comes first")
        expect(WorkspaceBoard.selectionAfterClosing(fourth, workspaceMembers: [], sidebarOrder: [first, fourth, second]) == second, "sidebar order decides the neighbor, not creation order")

        let group = WorkspaceBoard.create([first, second, third, fourth, second], in: [])
        expect(group.count == 1 && group[0].members == [first, second, third, fourth], "creation makes unique ordered membership")
        expect(group[0].panels.count == 4, "grouping never combines display panels")
        for id in group[0].members {
            expect(WorkspaceBoard.leafIDs(group[0].panel(containing: id)!.layout) == [id], "every new member starts alone")
        }
        expect(WorkspaceBoard.create(group[0].members, in: group) == group, "creating the exact group preserves its identity and panels")
        let combined = WorkspaceBoard.drop(dragged: third, onto: second, edge: .right, in: group)
        expect(combined[0].id == group[0].id && combined[0].members == group[0].members, "combining inside a group preserves membership and order")
        expect(combined[0].panels.count == 3, "A, B+C and D coexist")
        expect(WorkspaceBoard.leafIDs(combined[0].panel(containing: second)!.layout) == [second, third], "B and C share one display tree")
        expect(combined[0].panel(containing: first) == group[0].panel(containing: first), "A stays independent with a stable panel identity")
        expect(combined[0].panel(containing: fourth) == group[0].panel(containing: fourth), "D is untouched")
        let reordered = WorkspaceBoard.moveLeaf(fourth, beside: first, after: false, in: combined)
        expect(reordered[0].members == [fourth, first, second, third], "sidebar drag changes member order")
        expect(reordered[0].panels == combined[0].panels, "sidebar drag never changes panel geometry or occupants")
        let detached = WorkspaceBoard.detach([second], in: combined)
        expect(detached[0].members == group[0].members && detached[0].panels.count == 4, "detaching retains membership")
        expect(WorkspaceBoard.detach([first], in: detached) == detached, "detaching an independent panel keeps its identity")

        let otherPair = WorkspaceBoard.drop(dragged: fourth, onto: first, edge: .bottom, in: combined)
        expect(otherPair[0].panels.count == 2, "two independent split combinations coexist")
        let remaining = WorkspaceBoard.extract(first, from: WorkspaceBoard.extract(second, from: WorkspaceBoard.extract(third, from: otherPair)))
        expect(remaining.count == 1 && remaining[0].members == [fourth], "a single-member workspace survives")
        expect(remaining[0].id == group[0].id, "single member keeps its workspace identity")
        expect(WorkspaceBoard.extract(fourth, from: remaining).isEmpty, "only empty workspaces are removed")
        let dissolved = WorkspaceBoard.dissolve(otherPair[0].id, in: otherPair)
        expect(!dissolved[0].isGrouped && dissolved[0].panels == otherPair[0].panels, "dissolving removes grouping while preserving both complete split panels")
        let restoredGroup = WorkspaceBoard.create(dissolved[0].members, in: dissolved)
        expect(restoredGroup[0].isGrouped && restoredGroup[0].panels == otherPair[0].panels, "regrouping preserves the existing display trees")

        for edge in [SplitEdge.left, .right, .top, .bottom] {
            let dropped = WorkspaceBoard.drop(dragged: third, onto: second, edge: edge, in: group)
            let tree = dropped[0].panel(containing: second)!.layout
            let frames = PaneLayout.frames(of: tree, in: CGRect(x: 0, y: 0, width: 800, height: 600))
            let source = frames[third]!, target = frames[second]!
            switch edge {
            case .left: expect(source.maxX <= target.minX, "left edge drop")
            case .right: expect(source.minX >= target.maxX, "right edge drop")
            case .top: expect(source.maxY <= target.minY, "top edge drop")
            case .bottom: expect(source.minY >= target.maxY, "bottom edge drop")
            case .center: break
            }
            let rearranged = WorkspaceBoard.drop(dragged: third, onto: second, edge: .left, in: dropped)
            expect(rearranged[0].members == group[0].members, "rearranging keeps sidebar order")
            expect(rearranged[0].panel(containing: second)!.id == dropped[0].panel(containing: second)!.id, "rearranging keeps display identity")
        }
        expect(WorkspaceBoard.drop(dragged: first, onto: first, edge: .left, in: group) == group, "self drop has no effect")
        let outsider = UUID(), companion = UUID()
        let cross = WorkspaceBoard.create([outsider, companion], in: combined)
        let destination = cross.last!.id
        let joined = WorkspaceBoard.join(second, to: destination, in: cross)
        expect(joined.first!.members == [first, third, fourth], "cross-group move removes just the moved membership")
        expect(WorkspaceBoard.leafIDs(joined.last!.panel(containing: second)!.layout) == [second], "sidebar cross-group move makes an independent panel")
        expect(WorkspaceBoard.leafIDs(joined.first!.panel(containing: third)!.layout) == [third], "source split folds around its survivor")
        let crossDrop = WorkspaceBoard.drop(dragged: second, onto: outsider, edge: .top, in: cross)
        expect(crossDrop.last!.members.contains(second) && !crossDrop.first!.members.contains(second), "edge drop adopts target workspace")
        expect(WorkspaceBoard.leafIDs(crossDrop.last!.panel(containing: outsider)!.layout) == [second, outsider], "cross-group edge drop combines only target panel")
        let whole = WorkspaceBoard.joinWorkspace(cross[0].id, to: destination, in: cross)
        expect(whole.count == 1 && whole[0].panels == cross[1].panels + cross[0].panels, "whole-workspace move preserves all display trees and IDs")
        let movingPanel = cross[0].panel(containing: second)!
        let panelMove = WorkspaceBoard.movePanel(movingPanel.id, to: destination, beside: cross[1].panels[0].id, after: false, in: cross)
        expect(panelMove.last!.panels.first == movingPanel, "sidebar panel move preserves its whole split and inserts before the target row")
        expect(!panelMove[0].members.contains(second) && !panelMove[0].members.contains(third), "moving one split row moves all its member sessions")
        let ungroupedPanel = WorkspaceBoard.movePanel(movingPanel.id, to: nil, in: panelMove)
        expect(ungroupedPanel.last!.panels == [movingPanel] && !ungroupedPanel.last!.isGrouped, "moving a split out of a group never extracts leaves")
        let reorderedPanels = WorkspaceBoard.movePanel(cross[0].panels.last!.id, to: cross[0].id, beside: movingPanel.id, after: false, in: cross)
        expect(reorderedPanels[0].panels.first!.id == cross[0].panels.first!.id && reorderedPanels[0].panels[1].id == cross[0].panels.last!.id, "reordering whole panels leaves other geometry intact")

        let subset = WorkspaceBoard.combine([third, second], onto: second, as: .rows, in: group)
        expect(subset[0].members == group[0].members, "menu combine keeps member order")
        expect(WorkspaceBoard.leafIDs(subset[0].panel(containing: second)!.layout) == [third, second], "menu combine uses explicit selection order")
        let across = WorkspaceBoard.combine([second, outsider], onto: outsider, as: .columns, in: cross)
        expect(across.last!.members.contains(second), "menu combine uses right-click target's workspace")
        let looseTarget = WorkspaceBoard.combine([first, outsider], onto: outsider, as: .rows, in: group)
        expect(looseTarget.count == 2 && looseTarget.last!.members == [outsider, first], "combining onto an ungrouped target creates a workspace")
        let independentSubset = WorkspaceBoard.create([second, third], in: combined)
        expect(independentSubset.count == 2 && independentSubset.last!.panels == [combined[0].panel(containing: second)!], "a new group from a complete split preserves that panel")
        let all = WorkspaceBoard.apply(.grid, to: group[0])
        expect(all.members == group[0].members && all.panels.count == 1, "merge-all is explicit")
        expect(WorkspaceBoard.detach(all.members, in: [all])[0].panels.count == 4, "separate-all restores independent panels without removing membership")
        let panelMembers = WorkspaceBoard.leafIDs(combined[0].panel(containing: second)!.layout)
        expect(WorkspaceBoard.selectionAfterClosing(second, workspaceMembers: panelMembers, sidebarOrder: group[0].members) == third, "closing prefers another member of the same panel")

        do {
            let data = try JSONEncoder().encode(otherPair)
            let decoded = try JSONDecoder().decode([Workspace].self, from: data)
            expect(decoded == otherPair, "multiple panels and stable IDs survive snapshot round-trip")
            let encodedObject = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
            expect(encodedObject[0]["layout"] == nil && encodedObject[0]["members"] != nil, "new snapshots write the decoupled schema")
            struct Legacy: Encodable { var id: UUID; var number: Int; var layout: PaneNode; var name: String }
            let legacyTree = WorkspaceBoard.arrange(group[0].members, as: .grid)!
            let legacy = Legacy(id: group[0].id, number: 7, layout: legacyTree, name: "Saved workspace")
            let migrated = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(legacy))
            expect(migrated.id == legacy.id && migrated.number == 7 && migrated.name == legacy.name, "legacy workspace metadata survives")
            expect(migrated.isGrouped, "legacy workspaces remain visible groups after migration")
            let ungroupedRoundTrip = try JSONDecoder().decode([Workspace].self, from: JSONEncoder().encode(dissolved))
            expect(ungroupedRoundTrip == dissolved, "ungrouped split identity and optional grouping survive restart")
            expect(migrated.members == group[0].members && migrated.panels.count == 1 && migrated.panels[0].layout == legacyTree, "legacy four-way split migrates intact")
            let single = WorkspaceBoard.keeping([first], in: [migrated])
            expect(single[0].members == [first] && single[0].panels[0].id == migrated.panels[0].id, "restore keeps single survivors and stable panel ID")
            let repaired = WorkspaceBoard.keeping([first, third, fourth], in: otherPair)
            expect(repaired[0].members == [first, third, fourth] && repaired[0].panels.count == 2, "restore prunes a missing session and folds its panel")
            var corrupt = group[0]
            corrupt.members += [first, outsider]
            corrupt.panels = [TerminalPanel(layout: .split(SplitNode(id: UUID(), axis: .vertical, ratio: 0.5, leading: .leaf(first), trailing: .leaf(first))))]
            let cleaned = WorkspaceBoard.keeping(Set(group[0].members), in: [corrupt, group[0]])
            expect(cleaned.count == 1 && cleaned[0].members == group[0].members && cleaned[0].panels.count == 4, "restore repairs duplicate membership/leaves and missing panel references")
            let doubleMembership = Workspace(id: UUID(), number: 9, members: [first, outsider])
            let unique = WorkspaceBoard.keeping(Set(group[0].members + [outsider]), in: group + [doubleMembership])
            expect(unique.last!.members == [outsider], "restore never places one session in two workspaces")
            expect(WorkspaceBoard.keeping([], in: otherPair).isEmpty, "empty restored workspaces disappear")
        } catch { fail("snapshot migration failed: \(error)") }

        // Exercise transitions rather than testing each method only on fresh independent panels.
        var evolving = group
        var seed: UInt64 = 42
        let pool = [first, second, third, fourth, outsider, companion]
        func random(_ count: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(count))
        }
        for _ in 0..<600 {
            let source = pool[random(pool.count)], target = pool[random(pool.count)]
            switch random(8) {
            case 0: evolving = WorkspaceBoard.create([source, target], in: evolving)
            case 1: evolving = WorkspaceBoard.drop(dragged: source, onto: target, edge: [.left, .right, .top, .bottom][random(4)], in: evolving)
            case 2: evolving = WorkspaceBoard.detach([source, target], in: evolving)
            case 3: evolving = WorkspaceBoard.extract(source, from: evolving)
            case 4: evolving = WorkspaceBoard.combine([source, target], onto: target, as: .rows, in: evolving)
            case 5:
                if let destination = evolving.last?.id { evolving = WorkspaceBoard.join(source, to: destination, in: evolving) }
            case 6:
                if evolving.count > 1 { evolving = WorkspaceBoard.joinWorkspace(evolving[0].id, to: evolving[1].id, in: evolving) }
            default: evolving = WorkspaceBoard.moveLeaf(source, beside: target, after: true, in: evolving)
            }
            let members = evolving.flatMap(\.members)
            expect(Set(members).count == members.count, "sequences never duplicate workspace membership")
            let panelIDs = evolving.flatMap(\.panels).map(\.id)
            expect(Set(panelIDs).count == panelIDs.count, "panel identities remain unique after transitions")
            for workspace in evolving {
                let leaves = workspace.panels.flatMap { WorkspaceBoard.leafIDs($0.layout) }
                expect(!workspace.members.isEmpty && Set(leaves) == Set(workspace.members) && leaves.count == workspace.members.count, "every member appears exactly once across its display panels")
            }
            expect(WorkspaceBoard.keeping(Set(pool), in: evolving) == evolving, "valid transition results require no snapshot repair")
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

        expect(DuplicateHostColor.index(for: "nginx", among: ["raven", "main", "nginx", "nginx"]) == 0, "one repeated host takes the first color")
        expect(DuplicateHostColor.index(for: "raven", among: ["raven", "main", "nginx", "nginx"]) == nil, "a host that appears once stays unmarked")
        expect(DuplicateHostColor.index(for: "nginx", among: ["nginx", "raven", "nginx", "raven"]) == 0, "the first repeated host keeps the first color")
        expect(DuplicateHostColor.index(for: "raven", among: ["nginx", "raven", "nginx", "raven"]) == 1, "the next repeated host takes the next color")
        expect(DuplicateHostColor.index(for: "main", among: ["main"]) == nil, "a single host has no duplicate color")

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
