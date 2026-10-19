import Foundation

@MainActor
private final class AssociationSystemDouble: TerminalAssociationSystem {
    var applications: [TerminalEntryKind: TerminalEntryApplication] = [:]
    var roles: [TerminalEntryKind: [String: String]] = [:]
    var rejected: Set<TerminalEntryKind> = []
    var ignored: Set<TerminalEntryKind> = []
    var missingApplications: Set<String> = []
    var requests: [(TerminalEntryKind, String)] = []
    var errors: [TerminalEntryKind: NSError] = [:]
    var recoveryRequests: [(TerminalEntryKind, String)] = []
    var restoredRoles: [TerminalEntryKind: [String: String]] = [:]
    var ignoredRoleRestorations: Set<TerminalEntryKind> = []
    var recoveryErrors: [TerminalEntryKind: NSError] = [:]
    var onSet: (() async -> Void)?

    func application(for kind: TerminalEntryKind) -> TerminalEntryApplication? { applications[kind] }
    func installedApplication(_ saved: TerminalEntryApplication) -> TerminalEntryApplication? {
        missingApplications.contains(saved.bundleID) ? nil : saved
    }
    func roleHandlers(for kind: TerminalEntryKind) -> [String: String] { roles[kind] ?? [:] }
    func setApplication(_ application: TerminalEntryApplication, for kind: TerminalEntryKind) async throws {
        requests.append((kind, application.bundleID))
        await onSet?()
        if let error = errors[kind] { throw error }
        if rejected.contains(kind) { throw TerminalAssociationError.systemFailure(-1) }
        if !ignored.contains(kind) { applications[kind] = application }
    }
    func restoreApplication(_ application: TerminalEntryApplication, roles handlers: [String: String], for kind: TerminalEntryKind) async throws {
        recoveryRequests.append((kind, application.bundleID))
        if let error = recoveryErrors[kind] { throw error }
        applications[kind] = application
        if !ignoredRoleRestorations.contains(kind) {
            restoredRoles[kind] = handlers
            roles[kind] = handlers
        }
    }
}

@main
enum TerminalAssociationsTests {
    static let target = app("com.itjun.1agent", "1Agent")
    static let ghostty = app("com.mitchellh.ghostty", "Ghostty")
    static let terminal = app("com.apple.Terminal", "Terminal")

    @MainActor
    static func main() async throws {
        try await withStore { store, system, defaults in
            await store.setAsDefaultTerminal()
            expect(system.requests.map(\.0) == [.executable], "default button changes only executables")
            expect(system.applications[.command] == terminal, "command scripts are opt-in")
            expect(store.isDefaultTerminal && store.hasBackup, "verified default and saved original")
            let backup = try saved(defaults)
            expect(backup[TerminalEntryKind.executable.rawValue]?.application == ghostty, "original application saved before replacement")
            let reloaded = TerminalAssociationStore(system: system, target: target, defaults: defaults, verificationDelay: 0)
            expect(reloaded.hasBackup && reloaded.isDefaultTerminal, "recovery survives store recreation")
            await reloaded.restore()
            expect(system.applications[.executable] == ghostty, "restores original application")
            expect(system.requests.count == 1 && system.recoveryRequests.count == 1, "recovery uses the recorded-role path, not a new association request")
            expect(!reloaded.hasBackup && defaults.object(forKey: TerminalAssociationStore.backupKey) == nil, "successful restore consumes backup")
        }

        try await withStore { store, system, defaults in
            await store.apply([.executable])
            system.applications[.executable] = terminal
            store.refresh()
            await store.apply([.executable])
            expect(try saved(defaults)[TerminalEntryKind.executable.rawValue]?.application == ghostty, "repeat apply preserves the first original")
            await store.restore()
            expect(system.applications[.executable] == ghostty, "repeat apply does not replace recovery point")
        }

        try await withStore { store, system, defaults in
            system.rejected = [.command]
            store.selected = [.executable, .command]
            await store.applySelection()
            expect(store.isDefaultTerminal && !store.isOwned(.command), "partial failure retains verified successes")
            expect(store.feedback?.isFailure == true, "partial failure does not report full success")
            expect(store.selected == [.command], "failed selection remains available to retry")
            expect(try saved(defaults).count == 2, "failed requests keep their recovery records")
            system.rejected = []
            await store.applySelection()
            await store.restore()
            expect(system.applications[.executable] == ghostty && system.applications[.command] == terminal, "each type restores its own original application")
        }

        try await withStore { store, system, _ in
            system.ignored = [.executable]
            await store.setAsDefaultTerminal()
            expect(!store.isDefaultTerminal && store.feedback?.isFailure == true, "successful API callback without readback is a failure")
            expect(store.hasBackup, "verification failure keeps the backup")
        }

        try await withStore { store, system, _ in
            system.roles[.command] = ["viewer": "com.apple.Pages", "editor": ghostty.bundleID, "shell": terminal.bundleID]
            await store.apply([.command])
            system.missingApplications = [terminal.bundleID]
            await store.restore()
            expect(store.hasBackup && store.isOwned(.command), "missing original does not restore to a guessed app")
            expect(store.feedback?.isFailure == true, "missing original is visible")
            system.missingApplications = []
            await store.restore()
            expect(system.restoredRoles[.command] == system.roles[.command], "restore preserves a distinct editor, viewer and shell")
        }

        try await withStore { store, system, defaults in
            defaults.set(Data("unreadable".utf8), forKey: TerminalAssociationStore.backupKey)
            let guarded = TerminalAssociationStore(system: system, target: target, defaults: defaults, verificationDelay: 0)
            await guarded.apply([.executable])
            expect(!guarded.backupIsReadable && system.requests.isEmpty, "unreadable recovery data blocks mutations")
            expect(defaults.data(forKey: TerminalAssociationStore.backupKey) == Data("unreadable".utf8), "unreadable backup is preserved")
            expect(!store.isDefaultTerminal, "the test never alters system associations")
        }

        try await withStore { store, system, _ in
            system.applications[.shell] = nil
            await store.apply([.shell])
            expect(system.requests.isEmpty && store.feedback?.isFailure == true, "an unknown original is not overwritten")
            system.applications[.executable] = target
            store.refresh()
            await store.setAsDefaultTerminal()
            expect(!store.hasBackup && system.requests.isEmpty, "already-owned entries do not create a bogus backup")
        }

        try await withStore { store, system, _ in
            system.onSet = { await store.apply([.command]) }
            await store.setAsDefaultTerminal()
            expect(system.requests.count == 1, "an operation already in progress cannot be reentered")
        }

        try await withStore { store, system, _ in
            system.errors[.executable] = NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -128),
            ])
            await store.apply([.executable, .command])
            expect(system.requests.map(\.0) == [.executable], "canceling macOS confirmation stops the batch")
            expect(store.feedback?.message.contains(String(localized: "The change was canceled.")) == true, "nested cancellation is not shown as a file-read error")
            expect(store.hasBackup, "canceling leaves recovery available")
        }

        try await withStore { store, system, _ in
            await store.setAsDefaultTerminal()
            expect(store.feedback != nil, "a completed operation has feedback")
            system.onSet = { expect(store.feedback == nil, "starting another operation clears stale success feedback") }
            await store.apply([.command])
        }

        try await withStore { store, system, defaults in
            system.roles[.command] = ["viewer": "com.apple.Pages", "editor": ghostty.bundleID, "shell": terminal.bundleID]
            await store.apply([.command])
            system.roles[.command] = ["viewer": target.bundleID, "editor": target.bundleID, "shell": target.bundleID]
            system.ignoredRoleRestorations = [.command]
            await store.restore()
            expect(system.applications[.command] == terminal, "the opener can recover before its distinct roles")
            expect(store.hasBackup && store.feedback?.isFailure == true, "a missing role readback must keep the recovery record")
            expect(try saved(defaults)[TerminalEntryKind.command.rawValue]?.roleHandlers["viewer"] == "com.apple.Pages", "the original roles survive a partial restore")
            system.ignoredRoleRestorations = []
            await store.restore()
            expect(!store.hasBackup && store.feedback?.isFailure == false, "retrying completes role recovery")
        }

        try await withStore { store, system, _ in
            await store.apply([.executable, .command])
            system.recoveryErrors[.executable] = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
            await store.restore()
            expect(system.recoveryRequests.map(\.0) == [.executable], "canceling recovery stops further system confirmations")
            expect(store.hasBackup && store.feedback?.isFailure == true, "canceling recovery keeps both originals")
        }
        print("Terminal associations: 12 recovery and transaction scenarios passed; no system preferences changed")
    }

    @MainActor
    private static func withStore(_ body: (TerminalAssociationStore, AssociationSystemDouble, UserDefaults) async throws -> Void) async throws {
        let suite = "oneagent-terminal-associations-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let system = AssociationSystemDouble()
        system.applications = [.executable: ghostty, .command: terminal, .shell: ghostty, .zsh: terminal]
        let store = TerminalAssociationStore(system: system, target: target, defaults: defaults, verificationDelay: 0)
        try await body(store, system, defaults)
    }

    @MainActor
    private static func saved(_ defaults: UserDefaults) throws -> [String: TerminalAssociationBackup] {
        try JSONDecoder().decode([String: TerminalAssociationBackup].self, from: defaults.data(forKey: TerminalAssociationStore.backupKey)!)
    }

    private static func app(_ id: String, _ name: String) -> TerminalEntryApplication {
        TerminalEntryApplication(bundleID: id, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"))
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
}
