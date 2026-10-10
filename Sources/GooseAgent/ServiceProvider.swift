import AppKit

/// Finder's Services menu: "New 1Agent Tab Here" and "New 1Agent Window Here".
/// The selectors are named by `NSMessage` in the Info.plist `NSServices` entries.
@MainActor
final class ServiceProvider: NSObject {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    @objc func openTab(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openTerminals(from: pasteboard, asWorkspace: false, error: error)
    }

    @objc func openWindow(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openTerminals(from: pasteboard, asWorkspace: true, error: error)
    }

    private func openTerminals(
        from pasteboard: NSPasteboard,
        asWorkspace: Bool,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        // A selected file opens its folder. Finder keeps the selection order; keep it too.
        var directories: [String] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            var directory = url.standardizedFileURL.path
            if !isDirectory.boolValue {
                directory = (directory as NSString).deletingLastPathComponent
            }
            if !directories.contains(directory) {
                directories.append(directory)
            }
        }
        if directories.isEmpty {
            error.pointee = String(localized: "No folder to open.") as NSString
            return
        }
        model.openLocalTerminals(at: directories, asWorkspace: asWorkspace)
    }
}
