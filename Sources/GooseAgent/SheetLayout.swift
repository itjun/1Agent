import Foundation

enum SheetLayout {
    static let hostInformation: CGFloat = 520
    static let hostInformationHeight: CGFloat = 640
    static let quickCommand: CGFloat = 880
    static let quickCommandHeight: CGFloat = 760
    static let quickCommandPreviewHeight: CGFloat = 280
    static let commandEditor: CGFloat = 760
    static let commandEditorHeight: CGFloat = 620
    static let commandLibrary: CGFloat = 1040
    static let commandLibraryHeight: CGFloat = 760
    static let commandLibraryNavigation: CGFloat = 180
    static let commandLibraryPaneMinWidth: CGFloat = 320
    static let commandLibraryNameColumn: CGFloat = 240
    static let commandLibraryPreviewHeight: CGFloat = 76
    static let commandEditorHostWidth: CGFloat = 320
    static let commandEditorGroupWidth: CGFloat = 220
    static let commandCardTextHeight: CGFloat = 200
    static let commandSidebarPreviewHeight: CGFloat = 180
    static let commandSidebarPreviewWidth: CGFloat = 420
    static let commandSidebarPreviewMaxWidth: CGFloat = 900
    static let commandSidebarRowHeight: CGFloat = 40
    static let commandPreviewInset: CGFloat = 16
    static let commandPreviewCodeInset: CGFloat = 10
    static let commandPreviewCodeSpacing: CGFloat = 8
    static let confirmation: CGFloat = 420
    static let dialogInset: CGFloat = 32
    static let search: CGFloat = 520
    static let sessionBodyHeight: CGFloat = 580
    static let settings: CGFloat = 880
    static let settingsBodyHeight: CGFloat = 720
    /// Preview of what "Import from Ghostty" would change, shown over Settings.
    static let importPreview: CGFloat = 680
    static let importPreviewBodyHeight: CGFloat = 600
    /// Search field at the top of the host picker.
    static let searchFieldHeight: CGFloat = 32
    /// One host (or the local terminal) row in the host picker.
    static let pickerRowHeight: CGFloat = 36
    /// File list in the "convert to UTF-8 + LF before upload" alert.
    static let uploadCheckListWidth: CGFloat = 460
    static let uploadCheckListMaxHeight: CGFloat = 240
    /// Update notes dialog. The short height is only used before any release notes are known.
    static let appUpdate: CGFloat = 480
    static let appUpdateHeight: CGFloat = 420
    static let appUpdateCompactHeight: CGFloat = 220
}
