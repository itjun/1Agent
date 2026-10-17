import Foundation
import CoreGraphics

@main
struct WorkspacePresentationTests {
    static func main() throws {
        let fresh = WorkspacePresentation.restored(nil, legacyFiles: false)
        precondition(!fresh.filesVisible && fresh.filesWidth == 360)
        precondition(fresh.sidebarCollapsed && fresh.filesWorkspace,
                     "new windows start with a hidden sidebar and a full file workspace")
        let legacy = WorkspacePresentation.restored(nil, legacyFiles: true)
        precondition(legacy.filesVisible && legacy.filesWorkspace && !legacy.filesExpanded,
                     "legacy Files becomes a full file workspace")
        var saved = fresh
        saved.sidebarCollapsed = true
        saved.filesVisible = true
        saved.filesExpanded = true
        saved.filesLayout = .sideBySide
        saved.filesWidth = 512
        saved.filesHeightRatio = 0.7
        saved.collapsedWorkspaces = [UUID(), UUID()]
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(WorkspacePresentation.self, from: data)
        precondition(WorkspacePresentation.restored(decoded, legacyFiles: false) == saved)
        var closed = saved
        closed.filesVisible = false
        precondition(!WorkspacePresentation.restored(closed, legacyFiles: true).filesVisible,
                     "explicit new presentation wins over a legacy focused area")
        precondition(WorkspaceChromeLayout.storedFilesWidth(.nan) == 360)
        precondition(WorkspaceChromeLayout.storedFilesWidth(.infinity) == 360)
        precondition(WorkspaceChromeLayout.storedFilesWidth(-10) == 300)
        precondition(WorkspaceChromeLayout.storedFilesWidth(-.infinity) == 360)
        precondition(WorkspaceChromeLayout.storedFilesWidth(100_000) == 1600)
        var invalidDimensions = saved
        invalidDimensions.filesWidth = .nan
        let repairedDimensions = WorkspacePresentation.restored(invalidDimensions, legacyFiles: false)
        precondition(repairedDimensions.filesWidth == 360)
        precondition(WorkspaceChromeLayout.storedFilesHeightRatio(.nan) == 0.6)
        precondition(WorkspaceChromeLayout.storedFilesHeightRatio(.infinity) == 0.6)
        precondition(WorkspaceChromeLayout.storedFilesHeightRatio(-10) == 0.25)
        precondition(WorkspaceChromeLayout.storedFilesHeightRatio(10) == 0.75)
        for height: CGFloat in [420, 472, 720, 900] {
            for ratio in [0.25, 0.6, 0.75] {
                let filesHeight = WorkspaceChromeLayout.filesHeight(in: height, ratio: ratio)
                precondition(filesHeight >= WorkspaceChromeLayout.minimumFilesHeight)
                precondition(height - filesHeight - WorkspaceChromeLayout.dividerWidth >= WorkspaceChromeLayout.minimumTerminalHeight)
            }
        }

        let previousDock = Data(#"{"filesVisible":true,"filesExpanded":false,"filesWidth":360,"sidebarCollapsed":false,"collapsedWorkspaces":[]}"#.utf8)
        let migratedDock = try JSONDecoder().decode(WorkspacePresentation.self, from: previousDock)
        precondition(migratedDock.filesVisible && migratedDock.filesWorkspace && !migratedDock.sidebarCollapsed,
                     "previous narrow-dock snapshots restore into the full file workspace")
        precondition(migratedDock.filesWidth == 360)
        let collapsedGroup = UUID()
        let previousWorkspace = try JSONSerialization.data(withJSONObject: [
            "presentationVersion": 1,
            "filesVisible": true,
            "filesExpanded": true,
            "filesWorkspace": false,
            "filesWidth": 612,
            "sidebarCollapsed": true,
            "collapsedWorkspaces": [collapsedGroup.uuidString]
        ])
        let migratedWorkspace = try JSONDecoder().decode(WorkspacePresentation.self, from: previousWorkspace)
        precondition(migratedWorkspace.filesVisible && migratedWorkspace.filesWorkspace
                        && !migratedWorkspace.filesExpanded && !migratedWorkspace.sidebarCollapsed)
        precondition(migratedWorkspace.filesWidth == 612
                        && migratedWorkspace.collapsedWorkspaces == [collapsedGroup],
                     "the version-two chrome migration keeps saved widths and workspace identities")
        let migratedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(migratedWorkspace)) as! [String: Any]
        precondition(migratedJSON["presentationVersion"] as? Int == 4)
        precondition(migratedJSON["filesWorkspace"] == nil)
        precondition(migratedJSON["filesLayout"] as? String == "sideBySide")
        let minimalSnapshot = try JSONDecoder().decode(WorkspacePresentation.self, from: Data("{}".utf8))
        precondition(minimalSnapshot == fresh, "snapshots missing new fields use safe defaults")
        var alongside = migratedDock
        alongside.filesLayout = .belowTerminal
        alongside.sidebarCollapsed = true
        let alongsideSaved = try JSONEncoder().encode(alongside)
        let alongsideRestored = try JSONDecoder().decode(WorkspacePresentation.self, from: alongsideSaved)
        precondition(alongsideRestored == alongside)
        precondition(alongsideRestored.sidebarCollapsed,
                     "an explicit sidebar choice survives after the one-time migration")
        let previousBottom = Data(#"{"presentationVersion":2,"filesVisible":true,"filesWorkspace":false,"filesHeightRatio":0.65,"sidebarCollapsed":true}"#.utf8)
        let restoredBottom = try JSONDecoder().decode(WorkspacePresentation.self, from: previousBottom)
        precondition(restoredBottom.filesLayout == .sideBySide && restoredBottom.fullFilesWorkspace)
        precondition(restoredBottom.sidebarCollapsed && restoredBottom.filesHeightRatio == 0.65,
                     "old bottom layout becomes independent Files while preserving user sizing")
        for layout in FileWorkspaceLayout.allCases {
            for visible in [false, true] {
                var state = fresh
                state.filesLayout = layout
                state.filesVisible = visible
                precondition(!(state.fullFilesWorkspace && state.filesDockVisible),
                             "file layouts must never appear simultaneously")
                precondition((state.fullFilesWorkspace || state.filesDockVisible) == visible)
            }
        }
        precondition(!WorkspaceChromeLayout.temporarilyCollapseSidebar(totalWidth: 880, sidebarWidth: 260,
                        filesVisible: true, filesWorkspace: true))
        precondition(WorkspaceChromeLayout.temporarilyCollapseSidebar(totalWidth: 880, sidebarWidth: 420,
                        filesVisible: true, filesWorkspace: true))

        for total: CGFloat in [880, 960, 1100, 1440, 1800] {
            for sidebar: CGFloat in [200, 260, 420] {
                let collapse = WorkspaceChromeLayout.temporarilyCollapseSidebar(
                    totalWidth: total, sidebarWidth: sidebar, filesVisible: true)
                let detail = total - (collapse ? 0 : sidebar)
                for expanded in [false, true] {
                    for preferred: Double in [300, 360, 900, 1600] {
                        let files = WorkspaceChromeLayout.filesWidth(in: detail, preferred: preferred, expanded: expanded)
                        precondition(files >= 300, "file browser must remain usable")
                        precondition(detail - files - WorkspaceChromeLayout.dividerWidth >= 400,
                                     "terminal minimum is preserved, even at the smallest window")
                    }
                }
                precondition(!WorkspaceChromeLayout.temporarilyCollapseSidebar(
                    totalWidth: total, sidebarWidth: sidebar, filesVisible: false),
                             "closing files restores the user's sidebar preference")
            }
        }

        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let group = WorkspaceBoard.create([a, b, c, d], in: [])[0]
        precondition(WorkspaceBoard.splitNumber(for: a, in: group) == nil)
        let paired = WorkspaceBoard.drop(dragged: b, onto: a, edge: .right, in: [group])
        let twoPairs = WorkspaceBoard.drop(dragged: d, onto: c, edge: .bottom, in: paired)
        let markers = [a, b, c, d].map { WorkspaceBoard.splitNumber(for: $0, in: twoPairs[0]) }
        precondition(markers == [1, 1, 2, 2])
        let reordered = WorkspaceBoard.moveLeaf(d, beside: a, after: false, in: twoPairs)
        precondition(reordered[0].panels == twoPairs[0].panels)
        precondition([a, b, c, d].map { WorkspaceBoard.splitNumber(for: $0, in: reordered[0]) } == markers,
                     "sidebar reordering cannot change split identities or geometry")
        let detached = WorkspaceBoard.detach([a], in: twoPairs)
        precondition(WorkspaceBoard.splitNumber(for: a, in: detached[0]) == nil)
        precondition(WorkspaceBoard.splitNumber(for: b, in: detached[0]) == nil)
        print("WorkspacePresentationTests passed")
    }
}
