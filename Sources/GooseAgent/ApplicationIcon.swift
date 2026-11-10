import AppKit

enum ApplicationIcon: String, CaseIterable, Identifiable {
    case original = "Original"
    static let storageKey = "appearance.applicationIcon"
    static let defaultIcon: Self = .original
    var id: String { rawValue }

    static func stored(defaults: UserDefaults = .standard) -> Self { .original }

    func image(in bundle: Bundle = .main) -> NSImage? {
        guard let url = bundle.url(forResource: rawValue, withExtension: "icns", subdirectory: "ApplicationIcons") else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// 清除旧版的彩色自定义图标，Dock、Finder 和系统图标样式统一交给应用包。
@MainActor
final class ApplicationIconManager {
    static let shared = ApplicationIconManager()
    private let defaults: UserDefaults
    private let applicationURL: URL

    init(defaults: UserDefaults = .standard, applicationURL: URL = Bundle.main.bundleURL) {
        self.defaults = defaults
        self.applicationURL = applicationURL
    }

    @discardableResult
    func restoreSystemIcon() -> Bool {
        NSApp.applicationIconImage = nil
        guard NSWorkspace.shared.setIcon(nil, forFile: applicationURL.path, options: []) else {
            NSLog("1Agent: could not clear the legacy custom icon at %@", applicationURL.path)
            return false
        }
        defaults.set(ApplicationIcon.original.rawValue, forKey: ApplicationIcon.storageKey)
        return true
    }
}
