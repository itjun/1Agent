import AppKit
import Combine

enum ApplicationIcon: String, CaseIterable, Identifiable {
    case original = "Original"
    case strawberryCream = "M01"
    case lavenderMilkshake = "M02"
    case mintCandy = "M03"
    case cloudSoda = "M04"
    case peachSorbet = "M05"
    case lemonPudding = "M06"
    case blueberryYogurt = "M07"
    case pistachioMousse = "M08"
    case strawberrySeaSalt = "M09"
    case taroPeach = "M10"

    static let storageKey = "appearance.applicationIcon"
    static let defaultIcon: Self = .original
    static let macaronIcons = allCases.filter { $0 != .original }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: String(localized: "Original Blue")
        case .strawberryCream: String(localized: "Strawberry Cream")
        case .lavenderMilkshake: String(localized: "Lavender Milkshake")
        case .mintCandy: String(localized: "Mint Candy")
        case .cloudSoda: String(localized: "Cloud Soda")
        case .peachSorbet: String(localized: "Peach Sorbet")
        case .lemonPudding: String(localized: "Lemon Pudding")
        case .blueberryYogurt: String(localized: "Blueberry Yogurt")
        case .pistachioMousse: String(localized: "Pistachio Mousse")
        case .strawberrySeaSalt: String(localized: "Strawberry Sea Salt")
        case .taroPeach: String(localized: "Taro Peach")
        }
    }

    struct Palette: Equatable {
        let fill: String
        let ring: String
        let ink: String
    }

    /// Same colors as `Resources/AppIcon/macaron-palettes.json`; the window chrome accent follows them.
    /// Nil keeps the original blue chrome.
    var palette: Palette? {
        switch self {
        case .original: nil
        case .strawberryCream: Palette(fill: "F6C3D1", ring: "E7A7BC", ink: "A26D86")
        case .lavenderMilkshake: Palette(fill: "D9CCF3", ring: "BCA9DD", ink: "82719F")
        case .mintCandy: Palette(fill: "C6E8D5", ring: "A1CCB8", ink: "678F83")
        case .cloudSoda: Palette(fill: "BEDDF3", ring: "9FC2DD", ink: "688BA8")
        case .peachSorbet: Palette(fill: "F7CDB9", ring: "E6AE99", ink: "A9796F")
        case .lemonPudding: Palette(fill: "F4E3AA", ring: "DDC989", ink: "A28F5E")
        case .blueberryYogurt: Palette(fill: "C5CFEE", ring: "ACB6DB", ink: "7982A7")
        case .pistachioMousse: Palette(fill: "DCE7B4", ring: "BFCF96", ink: "889A69")
        case .strawberrySeaSalt: Palette(fill: "F1C8D2", ring: "D7AABA", ink: "968099")
        case .taroPeach: Palette(fill: "DACBF2", ring: "BFA9D9", ink: "9077A4")
        }
    }

    static func stored(defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: storageKey) ?? "") ?? defaultIcon
    }

    func image(in bundle: Bundle = .main) -> NSImage? {
        guard let url = bundle.url(forResource: rawValue, withExtension: "icns", subdirectory: "ApplicationIcons") else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// Keep the running icon and Finder's persistent custom icon on the same saved palette.
/// NSWorkspace writes Finder metadata at the bundle root; signed Contents and its resources stay intact.
@MainActor
final class ApplicationIconManager: ObservableObject {
    static let shared = ApplicationIconManager()

    @Published private(set) var selected: ApplicationIcon
    @Published private(set) var loadFailed = false
    @Published private(set) var finderUpdateFailed = false
    private let defaults: UserDefaults
    private let bundle: Bundle
    private let applicationURL: URL
    private var images: [ApplicationIcon: NSImage] = [:]

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main, applicationURL: URL? = nil) {
        self.defaults = defaults
        self.bundle = bundle
        self.applicationURL = applicationURL ?? bundle.bundleURL
        selected = ApplicationIcon.stored(defaults: defaults)
    }

    func image(for icon: ApplicationIcon) -> NSImage? {
        if let image = images[icon] { return image }
        guard let image = icon.image(in: bundle) else { return nil }
        images[icon] = image
        return image
    }

    func applyStoredIcon() {
        let icon = ApplicationIcon.stored(defaults: defaults)
        guard apply(icon) else {
            // Keep the saved running icon usable if the app was moved to a read-only volume.
            // The settings page reports the Finder failure and lets the user retry.
            if finderUpdateFailed, let image = image(for: icon) {
                NSApp.applicationIconImage = image
            }
            return
        }
        selected = icon
    }

    @discardableResult
    func select(_ icon: ApplicationIcon) -> Bool {
        guard apply(icon) else { return false }
        defaults.set(icon.rawValue, forKey: ApplicationIcon.storageKey)
        selected = icon
        return true
    }

    private func apply(_ icon: ApplicationIcon) -> Bool {
        guard let image = image(for: icon) else {
            loadFailed = true
            finderUpdateFailed = false
            return false
        }
        loadFailed = false
        // Use the same rendered asset for every icon, including the original, on all surfaces.
        guard NSWorkspace.shared.setIcon(image, forFile: applicationURL.path, options: []) else {
            finderUpdateFailed = true
            return false
        }
        finderUpdateFailed = false
        NSApp.applicationIconImage = image
        return true
    }
}
