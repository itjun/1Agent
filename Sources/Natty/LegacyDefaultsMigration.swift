import Foundation

/// Copies settings and the session snapshot into the current app domain before the model loads.
enum LegacyDefaultsMigration {
    static let ownDomain = "com.itjun.natty"
    private static let previousDomain = "com.itjun.agent"
    private static let originalDomain = "com.itjun.1agent"
    private static let ghosttyDomain = "com.mitchellh.ghostty"
    /// Written into the Ghostty domain by the old copy-forward migration.
    private static let ghosttyDoneKey = "migration.from1Agent.done"
    private static let broughtBackKey = "migration.fromGhosttyBundle.done"
    private static let renamedDomainDoneKey = "migration.toNatty.done"
    private static let previousDomainDoneKey = "migration.fromPreviousBundle.done"

    static func runIfNeeded() {
        guard Bundle.main.bundleIdentifier == ownDomain else { return }
        let defaults = UserDefaults.standard
        let current = defaults.persistentDomain(forName: ownDomain) ?? [:]
        guard let migrated = migratedDefaults(
            current: current,
            previous: defaults.persistentDomain(forName: previousDomain) ?? [:],
            original: defaults.persistentDomain(forName: originalDomain) ?? [:],
            ghostty: defaults.persistentDomain(forName: ghosttyDomain) ?? [:]
        ) else { return }
        defaults.setPersistentDomain(migrated, forName: ownDomain)
    }

    static func migratedDefaults(current: [String: Any], previous: [String: Any],
                                 original: [String: Any] = [:], ghostty: [String: Any]) -> [String: Any]? {
        guard !isTruthy(current[renamedDomainDoneKey]) else { return nil }
        let history = isTruthy(previous[previousDomainDoneKey]) ? previous
            : original.merging(previous) { _, newer in newer }
        var migrated = history.merging(current) { _, currentValue in currentValue }
        // Some versions ran under Ghostty's domain. Recover only our keys if that copy was used.
        if !isTruthy(migrated[broughtBackKey]), isTruthy(ghostty[ghosttyDoneKey]) {
            for (key, value) in ghostty where isAppKey(key) && migrated[key] == nil {
                migrated[key] = value
            }
        }
        migrated[broughtBackKey] = true
        migrated[previousDomainDoneKey] = true
        migrated[renamedDomainDoneKey] = true
        return migrated
    }

    /// Move the old file or directory once. Keep using the original if a move fails.
    static func supportURL(_ name: String, root: URL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0]) -> URL {
        let manager = FileManager.default
        let parent = root.appendingPathComponent(ownDomain, isDirectory: true)
        let destination = parent.appendingPathComponent(name)
        let source = root.appendingPathComponent(originalDomain).appendingPathComponent(name)
        guard !manager.fileExists(atPath: destination.path), manager.fileExists(atPath: source.path) else {
            return destination
        }
        do {
            try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.moveItem(at: source, to: destination)
            return destination
        } catch {
            return manager.fileExists(atPath: destination.path) ? destination : source
        }
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
