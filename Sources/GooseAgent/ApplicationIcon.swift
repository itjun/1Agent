import AppKit
import Combine

enum ApplicationIcon: String, CaseIterable, Identifiable {
    case original = "Original"
    case strawberryCream = "M01"
    case apricotCream = "M02"
    case vanillaCustard = "M03"
    case pistachioGreen = "M04"
    case mintCandy = "M05"
    case cloudSoda = "M06"
    case clearSkyBlue = "M07"
    case taroMilkshake = "M08"
    case coralPeach = "M09"
    case cocoaMilkTea = "M10"

    static let storageKey = "appearance.applicationIcon"
    static let defaultIcon: Self = .original
    static let macaronIcons = allCases.filter { $0 != .original }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: String(localized: "Original Blue")
        case .strawberryCream: String(localized: "Strawberry Cream")
        case .apricotCream: String(localized: "Apricot Cream")
        case .vanillaCustard: String(localized: "Vanilla Custard")
        case .pistachioGreen: String(localized: "Pistachio Green")
        case .mintCandy: String(localized: "Mint Candy")
        case .cloudSoda: String(localized: "Cloud Soda")
        case .clearSkyBlue: String(localized: "Clear Sky Blue")
        case .taroMilkshake: String(localized: "Taro Milkshake")
        case .coralPeach: String(localized: "Coral Peach")
        case .cocoaMilkTea: String(localized: "Cocoa Milk Tea")
        }
    }

    struct Palette: Equatable {
        let fill: String
        let ring: String
        let ink: String
        let terminalBackground: String
        let terminalForeground: String

        var terminalAccent: String { fill }
    }

    /// Shared identity colors for app icons, window chrome, and terminal palettes.
    /// Raw IDs stay stable when an installed palette receives a redesigned appearance.
    var palette: Palette? {
        switch self {
        case .original: nil
        case .strawberryCream: Palette(fill: "EDAFC9", ring: "C389A4", ink: "98627E", terminalBackground: "24151F", terminalForeground: "F8E9F0")
        case .apricotCream: Palette(fill: "F0BD91", ring: "C5976F", ink: "9A704C", terminalBackground: "261C13", terminalForeground: "F8EEDF")
        case .vanillaCustard: Palette(fill: "EEDB8D", ring: "C2B06A", ink: "958447", terminalBackground: "211D10", terminalForeground: "F5F1DF")
        case .pistachioGreen: Palette(fill: "C8D98F", ring: "A1B36F", ink: "7A8D4E", terminalBackground: "1B2112", terminalForeground: "F0F3E1")
        case .mintCandy: Palette(fill: "A5D7B4", ring: "80B18F", ink: "5A8A69", terminalBackground: "13241B", terminalForeground: "E4F3E9")
        case .cloudSoda: Palette(fill: "96D4D8", ring: "74ADB2", ink: "52858B", terminalBackground: "122329", terminalForeground: "E1F1F4")
        case .clearSkyBlue: Palette(fill: "A8C4EB", ring: "85A1C8", ink: "617DA4", terminalBackground: "0D1B2E", terminalForeground: "E6EDF8")
        case .taroMilkshake: Palette(fill: "C6ACE0", ring: "A589BF", ink: "84659E", terminalBackground: "21182C", terminalForeground: "F1E9F8")
        case .coralPeach: Palette(fill: "EDA99A", ring: "C8887A", ink: "A26759", terminalBackground: "281913", terminalForeground: "F9EAE5")
        case .cocoaMilkTea: Palette(fill: "CDB59F", ring: "AD947F", ink: "8C735F", terminalBackground: "231C17", terminalForeground: "F1E9E1")
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

/// Remote terminal identity keeps its existing preference key through the palette redesign.
enum RemotePalette {
    static let storageKey = "appearance.remotePalette"
    static let defaultPalette: ApplicationIcon = .vanillaCustard

    static func stored(defaults: UserDefaults = .standard) -> ApplicationIcon {
        RemotePalette.palette(raw: defaults.string(forKey: storageKey))
    }

    static func palette(raw: String?) -> ApplicationIcon {
        if let icon = ApplicationIcon(rawValue: raw ?? ""), icon.palette != nil {
            return icon
        }
        return defaultPalette
    }
}

/// Settings → Appearance → Icon & widget style.
/// Regular is the Default style. Dark, Clear, and Tinted are drawn by macOS from the layered app icon.
enum SystemIconStyle: Equatable {
    case regular
    case adaptive

    /// Icon tests pin this so palette checks do not follow the machine's icon style.
    static var overrideForTests: SystemIconStyle?

    static func current() -> SystemIconStyle {
        if let overrideForTests { return overrideForTests }
        guard #available(macOS 26.0, *) else { return .regular }
        guard let config = NSWorkspace.shared.perform(Selector(("currentIconAppearanceConfiguration")))?.takeUnretainedValue() as? NSObject else {
            return .regular
        }
        // 1 is Regular Light, the Default style. Dark is 0 or 2, Clear is 3...5, Tinted is 6...8.
        let theme = (config.value(forKey: "iconAppearanceTheme") as? NSNumber)?.intValue ?? 1
        if theme == 1 { return .regular }
        return .adaptive
    }
}

/// Keep the running icon and Finder's persistent custom icon on the same saved palette.
/// NSWorkspace writes Finder metadata at the bundle root; signed Contents and its resources stay intact.
/// A flat custom icon cannot take part in Dark, Clear, or Tinted, so those styles use the layered bundle icon.
@MainActor
final class ApplicationIconManager: ObservableObject {
    static let shared = ApplicationIconManager(observesSystemStyle: true)

    @Published private(set) var selected: ApplicationIcon
    @Published private(set) var loadFailed = false
    @Published private(set) var finderUpdateFailed = false
    private let defaults: UserDefaults
    private let bundle: Bundle
    private let applicationURL: URL
    private var images: [ApplicationIcon: NSImage] = [:]
    private var lastAppliedStyle: SystemIconStyle?
    private var styleWatch: SystemIconStyleWatch?

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main, applicationURL: URL? = nil, observesSystemStyle: Bool = false) {
        self.defaults = defaults
        self.bundle = bundle
        self.applicationURL = applicationURL ?? bundle.bundleURL
        selected = ApplicationIcon.stored(defaults: defaults)
        if observesSystemStyle {
            let watch = SystemIconStyleWatch {
                ApplicationIconManager.shared.applyStoredIcon()
            }
            watch.start()
            styleWatch = watch
        }
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
            if SystemIconStyle.current() == .regular, finderUpdateFailed, let image = image(for: icon) {
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
        let style = SystemIconStyle.current()
        if style == .adaptive {
            loadFailed = false
            // A flat image replaces the layered icon, so Dark, Clear, and Tinted never reach the Dock.
            guard NSWorkspace.shared.setIcon(nil, forFile: applicationURL.path, options: []) else {
                finderUpdateFailed = true
                return false
            }
            finderUpdateFailed = false
            NSApp.applicationIconImage = nil
            if lastAppliedStyle != .adaptive {
                lastAppliedStyle = .adaptive
                refreshDockIconCache()
            }
            return true
        }
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
        lastAppliedStyle = .regular
        return true
    }

    /// The Dock keeps the last flat custom icon until icon appearance is saved again.
    private func refreshDockIconCache() {
        guard applicationURL.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path else { return }
        guard let configurationClass = NSClassFromString("SLSIconAppearanceConfiguration") as? NSObject.Type else { return }
        let fetch = NSSelectorFromString("fetchCurrentIconAppearanceConfiguration")
        guard configurationClass.responds(to: fetch),
              let config = configurationClass.perform(fetch)?.takeUnretainedValue() as? NSObject else { return }
        let save = NSSelectorFromString("save")
        guard config.responds(to: save) else { return }
        config.perform(save)
    }
}

/// Follows System Settings → Appearance → Icon & widget style while the app is running.
private final class SystemIconStyleWatch: NSObject {
    private var token: NSObjectProtocol?
    private var isStarted = false
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        super.init()
    }

    func start() {
        if isStarted { return }
        isStarted = true
        UserDefaults.standard.addObserver(self, forKeyPath: "AppleIconAppearanceTheme", options: [.new], context: nil)
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: Notification.Name("NSWorkspaceIconAppearanceConfigurationDidChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.deliver()
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        deliver()
    }

    private func deliver() {
        DispatchQueue.main.async { [onChange] in
            MainActor.assumeIsolated {
                onChange()
            }
        }
    }

    deinit {
        if isStarted {
            UserDefaults.standard.removeObserver(self, forKeyPath: "AppleIconAppearanceTheme")
        }
        if let token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }
}
