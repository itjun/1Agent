import Foundation

@main
enum LegacyDefaultsMigrationTests {
    static func main() {
        let snapshot = Data("saved session".utf8)
        let previous: [String: Any] = [
            "session.openTabs": snapshot,
            "appearance.mode": "dark",
            "SUEnableAutomaticChecks": false,
        ]
        let ghostty: [String: Any] = [
            "migration.from1Agent.done": true,
            "appearance.mode": "light",
            "terminal.fontSize": 16,
            "SUFeedURL": "https://example.invalid/ghostty.xml",
            "NSWindow Frame Main": "ghostty window",
        ]
        let migrated = LegacyDefaultsMigration.migratedDefaults(
            current: ["appearance.mode": "system"], previous: previous, ghostty: ghostty
        )!
        precondition(migrated["session.openTabs"] as? Data == snapshot)
        precondition(migrated["appearance.mode"] as? String == "system")
        precondition(migrated["terminal.fontSize"] as? Int == 16)
        precondition(migrated["SUEnableAutomaticChecks"] as? Bool == false)
        precondition(migrated["SUFeedURL"] == nil && migrated["NSWindow Frame Main"] == nil)
        precondition(LegacyDefaultsMigration.migratedDefaults(
            current: migrated, previous: ["session.openTabs": Data()], ghostty: ghostty
        ) == nil, "Later launches must keep the current domain")

        let alreadyRecovered = LegacyDefaultsMigration.migratedDefaults(
            current: [:], previous: ["migration.fromGhosttyBundle.done": true, "session.openTabs": snapshot],
            ghostty: ghostty
        )!
        precondition(alreadyRecovered["session.openTabs"] as? Data == snapshot)
        precondition(alreadyRecovered["terminal.fontSize"] == nil, "Do not restore obsolete Ghostty settings twice")

        let fresh = LegacyDefaultsMigration.migratedDefaults(
            current: [:], previous: [:], ghostty: ["terminal.fontSize": 20]
        )!
        precondition(fresh["terminal.fontSize"] == nil, "Official Ghostty settings belong to Ghostty")
        print("LegacyDefaultsMigrationTests passed: session snapshot, explicit preferences, and one-time scoped recovery")
    }
}
