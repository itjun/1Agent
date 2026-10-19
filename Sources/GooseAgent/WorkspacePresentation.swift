import Foundation
import CoreGraphics

/// Fixed connection categories; classification never follows the focused split pane.
enum SidebarConnectionGroup: String, Codable, CaseIterable {
    case local, remote, mixed

    var title: String {
        switch self {
        case .local: String(localized: "This Mac")
        case .remote: String(localized: "Remote")
        case .mixed: String(localized: "Mixed")
        }
    }

    var symbol: String {
        switch self {
        case .local: "desktopcomputer"
        case .remote: "cloud"
        case .mixed: "square.grid.2x2"
        }
    }
}

enum FileWorkspaceLayout: String, Codable, CaseIterable {
    case sideBySide
    case belowTerminal
}

/// Window chrome only. Session identities, sidebar ordering and pane trees stay in their
/// existing models. Files can occupy the full workspace or a resizable dock below the terminal.
struct WorkspacePresentation: Codable, Equatable {
    private static let currentVersion = 6
    private var presentationVersion = currentVersion
    var filesVisible = false
    var filesExpanded = false
    /// A single choice keeps the two file presentations mutually exclusive.
    var filesLayout: FileWorkspaceLayout = .sideBySide
    var filesHeightRatio: Double = WorkspaceChromeLayout.defaultFilesHeightRatio
    // Retained so older saved layouts and width-based callers can still round-trip.
    var filesWidth: Double = WorkspaceChromeLayout.defaultFilesWidth
    var sidebarCollapsed = true
    var toolSidebarOpen = false
    var toolSidebarWidth: Double = 350
    var toolSidebarTab = "commands"
    var commandPreviewExpanded = true
    var commandPreviewHeight: Double = CommandPreviewLayout.defaultHeight
    var collapsedWorkspaces: Set<UUID> = []
    var collapsedConnectionGroups: Set<SidebarConnectionGroup> = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case presentationVersion, filesVisible, filesExpanded, filesLayout, filesWorkspace, filesWidth, filesHeightRatio
        case sidebarCollapsed, collapsedWorkspaces, toolSidebarOpen, toolSidebarWidth, toolSidebarTab
        case commandPreviewExpanded, commandPreviewHeight, collapsedConnectionGroups
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
        toolSidebarOpen = try values.decodeIfPresent(Bool.self, forKey: .toolSidebarOpen) ?? false
        toolSidebarWidth = ToolSidebarLayout.storedWidth(try values.decodeIfPresent(Double.self, forKey: .toolSidebarWidth) ?? 350)
        let toolTab = try values.decodeIfPresent(String.self, forKey: .toolSidebarTab) ?? "commands"
        toolSidebarTab = ["commands", "info", "files"].contains(toolTab) ? toolTab : "commands"
        commandPreviewExpanded = try values.decodeIfPresent(Bool.self, forKey: .commandPreviewExpanded) ?? true
        commandPreviewHeight = CommandPreviewLayout.storedHeight(
            try values.decodeIfPresent(Double.self, forKey: .commandPreviewHeight) ?? CommandPreviewLayout.defaultHeight)
        collapsedWorkspaces = try values.decodeIfPresent(Set<UUID>.self, forKey: .collapsedWorkspaces) ?? []
        collapsedConnectionGroups = try values.decodeIfPresent(Set<SidebarConnectionGroup>.self, forKey: .collapsedConnectionGroups) ?? []
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
        try values.encode(toolSidebarOpen, forKey: .toolSidebarOpen)
        try values.encode(toolSidebarWidth, forKey: .toolSidebarWidth)
        try values.encode(toolSidebarTab, forKey: .toolSidebarTab)
        try values.encode(commandPreviewExpanded, forKey: .commandPreviewExpanded)
        try values.encode(CommandPreviewLayout.storedHeight(commandPreviewHeight), forKey: .commandPreviewHeight)
        try values.encode(collapsedWorkspaces, forKey: .collapsedWorkspaces)
        try values.encode(collapsedConnectionGroups, forKey: .collapsedConnectionGroups)
    }

    static func restored(_ saved: Self?, legacyFiles: Bool) -> Self {
        var result = saved ?? Self()
        if saved == nil { result.filesVisible = legacyFiles }
        result.filesWidth = WorkspaceChromeLayout.storedFilesWidth(result.filesWidth)
        result.filesHeightRatio = WorkspaceChromeLayout.storedFilesHeightRatio(result.filesHeightRatio)
        result.commandPreviewHeight = CommandPreviewLayout.storedHeight(result.commandPreviewHeight)
        return result
    }

    var filesWorkspace: Bool { filesLayout == .sideBySide }
    var fullFilesWorkspace: Bool { filesVisible && filesLayout == .sideBySide }
    var filesDockVisible: Bool { filesVisible && filesLayout == .belowTerminal }
}

enum CommandPreviewLayout {
    static let defaultHeight: Double = 320
    static let minimumHeight: Double = 160
    static let maximumHeight: Double = 1200
    static let collapsedHeight: CGFloat = 32
    static let dividerHeight: CGFloat = 9
    static let minimumListHeight: CGFloat = 120

    static func storedHeight(_ height: Double) -> Double {
        height.isFinite ? min(maximumHeight, max(minimumHeight, height)) : defaultHeight
    }

    /// Fitting a short window never changes the user's stored height.
    static func visibleHeight(available: CGFloat, expanded: Bool, preferred: Double) -> CGFloat {
        if !expanded { return min(collapsedHeight, max(0, available - dividerHeight)) }
        let maximum = max(0, available - minimumListHeight - dividerHeight)
        return min(CGFloat(storedHeight(preferred)), maximum)
    }
}

enum ToolSidebarLayout {
    static func storedWidth(_ width: Double) -> Double { width.isFinite ? min(480, max(300, width)) : 350 }
    static func visibleWidth(detailWidth: CGFloat, open: Bool, filesMode: Bool, preferred: Double) -> CGFloat {
        guard open, !filesMode, detailWidth >= 701 else { return 0 }
        return min(CGFloat(storedWidth(preferred)), detailWidth - 401)
    }
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
