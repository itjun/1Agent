import Foundation

/// In-app language override. `AppleLanguages` is read at process start, so a
/// change here only takes effect after the user quits and reopens the app.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let defaultsKey = "app.language"

    var id: String { rawValue }

    static func current(defaults: UserDefaults = .standard) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .system
    }

    static func apply(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: defaultsKey)
        switch language {
        case .system:
            defaults.removeObject(forKey: "AppleLanguages")
        case .english:
            defaults.set(["en"], forKey: "AppleLanguages")
        case .simplifiedChinese:
            defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        }
    }

    static func synchronize(defaults: UserDefaults = .standard) {
        apply(current(defaults: defaults), defaults: defaults)
    }
}
