import Foundation

/// Saved independently of the terminal theme and Ghostty's surface configuration.
enum SidebarMaterial: String, CaseIterable {
    case liquidGlass
    case solid

    static let storageKey = "sidebar.material"
    static let defaultValue: Self = .liquidGlass

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: storageKey) ?? "") ?? defaultValue
    }

    func effective(supportsGlass: Bool, reduceTransparency: Bool) -> Self {
        self == .liquidGlass && supportsGlass && !reduceTransparency ? .liquidGlass : .solid
    }

    static var supportsGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}
