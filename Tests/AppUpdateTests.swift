import Foundation

@main
enum AppUpdateTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "oneagent-update-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        try Data(#"{"autoCheck":false,"remindVersion":"v9"}"#.utf8).write(to: root.appendingPathComponent("prefs.json"))
        try Data("keep".utf8).write(to: root.appendingPathComponent("unrelated.txt"))
        AppUpdatePreferences.migrate(defaults: defaults, directory: root)
        precondition(!defaults.bool(forKey: "SUEnableAutomaticChecks"))
        precondition(!defaults.bool(forKey: "SUAutomaticallyUpdate"))
        precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent("unrelated.txt").path))
        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        AppUpdatePreferences.migrate(defaults: defaults, directory: root)
        precondition(defaults.bool(forKey: "SUEnableAutomaticChecks"), "Migration must not overwrite new preferences")
        let preparation = ApplicationExitPreparation()
        var saves = 0
        let first = Task { try await preparation.prepare { saves += 1; try await Task.sleep(for: .milliseconds(30)) } }
        let second = Task { try await preparation.prepare { saves += 1 } }
        try await first.value; try await second.value
        precondition(saves == 1, "Update and termination must share one save")
        preparation.reset()
        try await preparation.prepare { saves += 1 }
        precondition(saves == 2, "An aborted installation must save fresh output on the next quit")
        let retry = ApplicationExitPreparation()
        do { try await retry.prepare { throw CocoaError(.fileWriteNoPermission) }; fatalError("Failure swallowed") }
        catch {}
        try await retry.prepare { saves += 1 }
        precondition(saves == 3, "Failed preparation must allow retry")
        print("PASS: updater preference migration, scoped cleanup, single exit save and retry")
    }
}
