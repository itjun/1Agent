import Foundation

/// Moves this app's settings into the `com.itjun.1agent` defaults domain.
///
/// While the app was installed as Ghostty, new values were written into `com.mitchellh.ghostty`,
/// mixed with the official app's own keys. On launch as 1Agent, our keys are copied back once.
/// The Ghostty domain is only read, so the official app's settings stay where they are.
/// Must run before anything reads `UserDefaults`.
enum LegacyDefaultsMigration {
    static let ownDomain = "com.itjun.1agent"
    /// Domain used while this app replaced official Ghostty.
    static let ghosttyDomain = "com.mitchellh.ghostty"
    /// Written into the Ghostty domain by the old copy-forward migration.
    static let ghosttyDoneKey = "migration.from1Agent.done"
    /// Written into our domain after the copy back, so a later launch does not overwrite settings.
    static let broughtBackKey = "migration.fromGhosttyBundle.done"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        if bundleID != LegacyDefaultsMigration.ownDomain {
            LegacyDefaultsMigration.copyMissing(
                from: LegacyDefaultsMigration.ownDomain,
                into: defaults,
                doneKey: LegacyDefaultsMigration.ghosttyDoneKey
            )
            return
        }
        if defaults.bool(forKey: LegacyDefaultsMigration.broughtBackKey) {
            return
        }
        let ghosttyValues = defaults.persistentDomain(forName: LegacyDefaultsMigration.ghosttyDomain) ?? [:]
        let usedByThisApp = LegacyDefaultsMigration.isTruthy(ghosttyValues[LegacyDefaultsMigration.ghosttyDoneKey])
        if usedByThisApp {
            for (key, value) in ghosttyValues where LegacyDefaultsMigration.isAppKey(key) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: LegacyDefaultsMigration.broughtBackKey)
    }

    /// Keys this app writes. Official Ghostty keys (Sparkle `SU*`, its window frames) are left out.
    static func isAppKey(_ key: String) -> Bool {
        switch key {
        case "sidebar.width", "AppleLanguages":
            return true
        default:
            break
        }
        for prefix in ["appearance.", "terminal.", "sidebar.", "app.", "session.", "files.", "ghostty.import"] {
            if key.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }

    /// Plist bools come back as `Bool` or `NSNumber`.
    private static func isTruthy(_ value: Any?) -> Bool {
        if let flag = value as? Bool {
            return flag
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return false
    }

    /// Copies keys the destination does not have yet. The source domain is not modified.
    private static func copyMissing(from domain: String, into defaults: UserDefaults, doneKey: String) {
        if defaults.bool(forKey: doneKey) {
            return
        }
        guard let bundleID = Bundle.main.bundleIdentifier, bundleID != domain else { return }
        let source = defaults.persistentDomain(forName: domain) ?? [:]
        let current = defaults.persistentDomain(forName: bundleID) ?? [:]
        for (key, value) in source where current[key] == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: doneKey)
    }
}
