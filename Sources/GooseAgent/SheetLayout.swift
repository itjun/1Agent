import Foundation

enum SheetLayout {
    static let hostInformation: CGFloat = 520
    static let hostInformationHeight: CGFloat = 640
    static let quickCommand: CGFloat = 640
    static let quickCommandHeight: CGFloat = 650
    static let commandLibrary: CGFloat = 820
    static let commandLibraryHeight: CGFloat = 680
    static let folderPicker: CGFloat = 600
    static let confirmation: CGFloat = 420
    static let dialogInset: CGFloat = 32
    static let search: CGFloat = 520
    static let sessionBodyHeight: CGFloat = 580
    static let commandPaletteHeight: CGFloat = 440
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
    /// Update notes dialog.
    static let appUpdate: CGFloat = 480
    static let appUpdateHeight: CGFloat = 420
}
