import Foundation

/// Copies settings and the session snapshot into the current app domain before the model loads.
enum LegacyDefaultsMigration {
    static let ownDomain = "com.itjun.agent"
    private static let previousDomain = "com.itjun.1agent"
    private static let ghosttyDomain = "com.mitchellh.ghostty"
    /// Written into the Ghostty domain by the old copy-forward migration.
    private static let ghosttyDoneKey = "migration.from1Agent.done"
    private static let broughtBackKey = "migration.fromGhosttyBundle.done"
    private static let previousDomainDoneKey = "migration.fromPreviousBundle.done"

    static func runIfNeeded() {
        guard Bundle.main.bundleIdentifier == ownDomain else { return }
        let defaults = UserDefaults.standard
        let current = defaults.persistentDomain(forName: ownDomain) ?? [:]
        guard let migrated = migratedDefaults(
            current: current,
            previous: defaults.persistentDomain(forName: previousDomain) ?? [:],
            ghostty: defaults.persistentDomain(forName: ghosttyDomain) ?? [:]
        ) else { return }
        defaults.setPersistentDomain(migrated, forName: ownDomain)
    }

    static func migratedDefaults(current: [String: Any], previous: [String: Any],
                                 ghostty: [String: Any]) -> [String: Any]? {
        guard !isTruthy(current[previousDomainDoneKey]) else { return nil }
        var migrated = previous.merging(current) { _, currentValue in currentValue }
        // Some versions ran under Ghostty's domain. Recover only our keys if that copy was used.
        if !isTruthy(migrated[broughtBackKey]), isTruthy(ghostty[ghosttyDoneKey]) {
            for (key, value) in ghostty where isAppKey(key) && migrated[key] == nil {
                migrated[key] = value
            }
        }
        migrated[broughtBackKey] = true
        migrated[previousDomainDoneKey] = true
        return migrated
    }

    /// Keys this app writes. Official Ghostty keys (Sparkle `SU*`, its window frames) are left out.
    private static func isAppKey(_ key: String) -> Bool {
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
}
