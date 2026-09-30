import Foundation

/// One-time copy of settings from the old `com.itjun.1agent` defaults domain into this app's
/// domain (`com.mitchellh.ghostty`). Must run before anything reads `UserDefaults`.
///
/// A key is copied only when this domain does not have it yet, so values left behind by the
/// official Ghostty app (Sparkle `SU*`, window position, icon) stay untouched.
/// The old domain is never modified or removed.
enum LegacyDefaultsMigration {
    static let legacyDomain = "com.itjun.1agent"
    static let doneKey = "migration.from1Agent.done"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: LegacyDefaultsMigration.doneKey) {
            return
        }
        guard let bundleID = Bundle.main.bundleIdentifier, bundleID != LegacyDefaultsMigration.legacyDomain else {
            return
        }

        let legacyValues = defaults.persistentDomain(forName: LegacyDefaultsMigration.legacyDomain) ?? [:]
        let currentValues = defaults.persistentDomain(forName: bundleID) ?? [:]
        for (key, value) in legacyValues {
            if currentValues[key] != nil {
                continue
            }
            defaults.set(value, forKey: key)
        }

        defaults.set(true, forKey: LegacyDefaultsMigration.doneKey)
    }
}
