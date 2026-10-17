import Foundation
import CoreGraphics

enum FileWorkspaceLayout: String, Codable, CaseIterable {
    case sideBySide
    case belowTerminal
}

/// Window chrome only. Session identities, sidebar ordering and pane trees stay in their
/// existing models. Files can occupy the full workspace or a resizable dock below the terminal.
struct WorkspacePresentation: Codable, Equatable {
    private static let currentVersion = 4
    private var presentationVersion = currentVersion
    var filesVisible = false
    var filesExpanded = false
    /// A single choice keeps the two file presentations mutually exclusive.
    var filesLayout: FileWorkspaceLayout = .sideBySide
    var filesHeightRatio: Double = WorkspaceChromeLayout.defaultFilesHeightRatio
    // Retained so older saved layouts and width-based callers can still round-trip.
    var filesWidth: Double = WorkspaceChromeLayout.defaultFilesWidth
    var sidebarCollapsed = true
    var collapsedWorkspaces: Set<UUID> = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case presentationVersion, filesVisible, filesExpanded, filesLayout, filesWorkspace, filesWidth, filesHeightRatio
        case sidebarCollapsed, collapsedWorkspaces
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        filesVisible = try values.decodeIfPresent(Bool.self, forKey: .filesVisible) ?? false
        filesExpanded = try values.decodeIfPresent(Bool.self, forKey: .filesExpanded) ?? false
        if let layout = try values.decodeIfPresent(FileWorkspaceLayout.self, forKey: .filesLayout) {
            filesLayout = layout
        } else {
            filesLayout = (try values.decodeIfPresent(Bool.self, forKey: .filesWorkspace) ?? true)
                ? .sideBySide : .belowTerminal
        }
        filesHeightRatio = WorkspaceChromeLayout.storedFilesHeightRatio(
            try values.decodeIfPresent(Double.self, forKey: .filesHeightRatio) ?? WorkspaceChromeLayout.defaultFilesHeightRatio)
        filesWidth = WorkspaceChromeLayout.storedFilesWidth(
            try values.decodeIfPresent(Double.self, forKey: .filesWidth) ?? WorkspaceChromeLayout.defaultFilesWidth)
        sidebarCollapsed = try values.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed) ?? true
        collapsedWorkspaces = try values.decodeIfPresent(Set<UUID>.self, forKey: .collapsedWorkspaces) ?? []
        let savedVersion = try values.decodeIfPresent(Int.self, forKey: .presentationVersion) ?? 0
        if savedVersion < 2 {
            filesLayout = .sideBySide
            filesExpanded = false
            if values.contains(.sidebarCollapsed) { sidebarCollapsed = false }
        }
        // The redesigned Files page is independent; old dock placement is migrated, not exposed.
        if savedVersion < 4 { filesLayout = .sideBySide; filesExpanded = false }
        presentationVersion = max(savedVersion, Self.currentVersion)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(presentationVersion, forKey: .presentationVersion)
        try values.encode(filesVisible, forKey: .filesVisible)
        try values.encode(filesLayout, forKey: .filesLayout)
        try values.encode(filesExpanded, forKey: .filesExpanded)
        try values.encode(filesWidth, forKey: .filesWidth)
        try values.encode(filesHeightRatio, forKey: .filesHeightRatio)
        try values.encode(sidebarCollapsed, forKey: .sidebarCollapsed)
        try values.encode(collapsedWorkspaces, forKey: .collapsedWorkspaces)
    }

    static func restored(_ saved: Self?, legacyFiles: Bool) -> Self {
        var result = saved ?? Self()
        if saved == nil { result.filesVisible = legacyFiles }
        result.filesWidth = WorkspaceChromeLayout.storedFilesWidth(result.filesWidth)
        result.filesHeightRatio = WorkspaceChromeLayout.storedFilesHeightRatio(result.filesHeightRatio)
        return result
    }

    var filesWorkspace: Bool { filesLayout == .sideBySide }
    var fullFilesWorkspace: Bool { filesVisible && filesLayout == .sideBySide }
    var filesDockVisible: Bool { filesVisible && filesLayout == .belowTerminal }
}

enum WorkspaceChromeLayout {
    static let toolbarHeight: CGFloat = 48
    static let searchHeight: CGFloat = 34
    static let selectionBarHeight: CGFloat = 32
    static let defaultFilesWidth: Double = 360
    static let minimumFilesWidth: CGFloat = 300
    static let minimumTerminalWidth: CGFloat = 400
    static let dividerWidth: CGFloat = 5
    static let gridMinimumWidth: CGFloat = 640
    static let maximumStoredFilesWidth: Double = 1600
    static let defaultFilesHeightRatio: Double = 0.60
    static let minimumTerminalHeight: CGFloat = 140
    static let minimumFilesHeight: CGFloat = 240

    static func storedFilesHeightRatio(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return defaultFilesHeightRatio }
        return min(max(ratio, 0.25), 0.75)
    }

    static func filesHeight(in contentHeight: CGFloat, ratio: Double) -> CGFloat {
        let maximum = max(0, contentHeight - minimumTerminalHeight - dividerWidth)
        return min(max(minimumFilesHeight, contentHeight * storedFilesHeightRatio(ratio)), maximum)
    }

    static func storedFilesWidth(_ width: Double) -> Double {
        guard width.isFinite else { return defaultFilesWidth }
        return min(max(width, Double(minimumFilesWidth)), maximumStoredFilesWidth)
    }

    static func temporarilyCollapseSidebar(totalWidth: CGFloat, sidebarWidth: CGFloat,
                                           filesVisible: Bool, filesWorkspace: Bool = false) -> Bool {
        let minimum = filesWorkspace ? minimumFilesWidth * 2 + dividerWidth
                                     : minimumTerminalWidth + minimumFilesWidth + dividerWidth
        return filesVisible && totalWidth - sidebarWidth < minimum
    }

    static func filesWidth(in detailWidth: CGFloat, preferred: Double, expanded: Bool) -> CGFloat {
        let maximum = max(minimumFilesWidth, detailWidth - minimumTerminalWidth - dividerWidth)
        let desired = expanded ? max(CGFloat(storedFilesWidth(preferred)), detailWidth * 0.6)
                               : CGFloat(storedFilesWidth(preferred))
        return min(desired, maximum)
    }
}
