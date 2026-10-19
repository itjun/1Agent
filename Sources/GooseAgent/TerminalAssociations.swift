import AppKit
import Combine
import CoreServices
import UniformTypeIdentifiers

/// Only terminal file types belong here. Directories and URL schemes are deliberately absent.
enum TerminalEntryKind: String, CaseIterable, Codable, Identifiable {
    case executable = "public.unix-executable"
    case command = "com.apple.terminal.shell-script"
    case shell = "public.shell-script"
    case zsh = "public.zsh-script"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .executable: String(localized: "Unix Executables")
        case .command: String(localized: ".command Scripts")
        case .shell: String(localized: ".sh Scripts")
        case .zsh: String(localized: ".zsh Scripts")
        }
    }
}

struct TerminalEntryApplication: Codable, Equatable {
    var bundleID: String
    var name: String
    var url: URL

    func hasSameIdentity(as other: Self) -> Bool {
        bundleID.caseInsensitiveCompare(other.bundleID) == .orderedSame
    }
}

struct TerminalAssociationBackup: Codable {
    var application: TerminalEntryApplication
    /// Preserve differing viewer/editor/shell choices when restoring the default opener.
    var roleHandlers: [String: String]
}

@MainActor
protocol TerminalAssociationSystem {
    func application(for kind: TerminalEntryKind) -> TerminalEntryApplication?
    func installedApplication(_ saved: TerminalEntryApplication) -> TerminalEntryApplication?
    func roleHandlers(for kind: TerminalEntryKind) -> [String: String]
    func setApplication(_ application: TerminalEntryApplication, for kind: TerminalEntryKind) async throws
    func restoreApplication(_ application: TerminalEntryApplication, roles: [String: String], for kind: TerminalEntryKind) async throws
}

enum TerminalAssociationError: LocalizedError {
    case unavailableType
    case unknownOriginalApplication
    case missingOriginalApplication(String)
    case verificationFailed
    case unreadableBackup
    case systemFailure(Int)

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        var current = error as NSError
        for _ in 0..<5 {
            if current.domain == NSCocoaErrorDomain && current.code == NSUserCancelledError { return true }
            if current.domain == NSOSStatusErrorDomain && current.code == Int(userCanceledErr) { return true }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            current = underlying
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .unavailableType: String(localized: "This file type is unavailable on this Mac.")
        case .unknownOriginalApplication: String(localized: "The current application could not be determined, so its association was left unchanged.")
        case .missingOriginalApplication(let name):
            String(format: String(localized: "The original application “%@” is no longer installed. Its backup has been kept."), name)
        case .verificationFailed: String(localized: "macOS did not confirm the new default application. Its backup has been kept.")
        case .unreadableBackup: String(localized: "The saved association backup could not be read. No associations have been changed.")
        case .systemFailure(let code):
            String(format: String(localized: "macOS could not change this association (error %lld)."), Int64(code))
        }
    }
}

@MainActor
final class MacTerminalAssociationSystem: TerminalAssociationSystem {
    private static let roles: [(String, LSRolesMask)] = [
        ("viewer", .viewer), ("editor", .editor), ("shell", .shell),
    ]

    static func application(at url: URL) -> TerminalEntryApplication? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.localizedInfoDictionary?["CFBundleName"] as? String
            ?? (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
        return TerminalEntryApplication(bundleID: id, name: name, url: url)
    }

    func application(for kind: TerminalEntryKind) -> TerminalEntryApplication? {
        // A type can have separate viewer/editor/shell overrides. NSWorkspace's
        // type lookup may choose an editor; read the all-role association first
        // so the displayed default and recovery point refer to the same setting.
        if let handler = LSCopyDefaultRoleHandlerForContentType(kind.rawValue as CFString, .all)?.takeRetainedValue(),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: handler as String) {
            return Self.application(at: url)
        }
        guard let type = UTType(kind.rawValue),
              let url = NSWorkspace.shared.urlForApplication(toOpen: type) else { return nil }
        return Self.application(at: url)
    }

    func installedApplication(_ saved: TerminalEntryApplication) -> TerminalEntryApplication? {
        if let application = Self.application(at: saved.url), application.hasSameIdentity(as: saved) {
            return application
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: saved.bundleID) else { return nil }
        return Self.application(at: url)
    }

    func roleHandlers(for kind: TerminalEntryKind) -> [String: String] {
        var handlers: [String: String] = [:]
        for (name, role) in Self.roles {
            if let value = LSCopyDefaultRoleHandlerForContentType(kind.rawValue as CFString, role)?.takeRetainedValue() {
                handlers[name] = value as String
            }
        }
        return handlers
    }

    func setApplication(_ application: TerminalEntryApplication, for kind: TerminalEntryKind) async throws {
        guard let type = UTType(kind.rawValue) else { throw TerminalAssociationError.unavailableType }
        guard Self.application(at: application.url)?.hasSameIdentity(as: application) == true else {
            throw TerminalAssociationError.missingOriginalApplication(application.name)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.setDefaultApplication(at: application.url, toOpen: type) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func restoreApplication(_ application: TerminalEntryApplication, roles handlers: [String: String], for kind: TerminalEntryKind) async throws {
        // Restoring another opener also goes through macOS consent. Cancellation must leave
        // the recovery record intact; never fall back to another API after a declined request.
        try await setApplication(application, for: kind)
        // The all-role opener may originally have had a different editor/viewer.
        for (name, role) in Self.roles {
            guard let bundleID = handlers[name] else { continue }
            if roleHandlers(for: kind)[name]?.caseInsensitiveCompare(bundleID) == .orderedSame { continue }
            let typeID = kind.rawValue
            // This API can wait for a separate macOS confirmation. Keep the app
            // responsive while it is open, and distrust a noErr without readback.
            let status = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: LSSetDefaultRoleHandlerForContentType(typeID as CFString, role, bundleID as CFString))
                }
            }
            guard status == noErr else { throw TerminalAssociationError.systemFailure(Int(status)) }
            // macOS may return noErr before its confirmation is answered. Do not
            // queue another role change or consume the backup until this one lands.
            var confirmed = false
            for attempt in 0..<120 {
                if roleHandlers(for: kind)[name]?.caseInsensitiveCompare(bundleID) == .orderedSame {
                    confirmed = true
                    break
                }
                if attempt < 119 { try await Task.sleep(nanoseconds: 500_000_000) }
            }
            guard confirmed else { throw TerminalAssociationError.verificationFailed }
        }
    }
}

struct TerminalAssociationFeedback {
    var message: String
    var isFailure: Bool
}

/// Saves the first pre-change application, applies one type at a time, and verifies macOS's result.
/// The injected system keeps transaction/recovery tests away from the real LaunchServices database.
@MainActor
final class TerminalAssociationStore: ObservableObject {
    static let backupKey = "app.systemIntegration.associationBackup.v1"
    static let shared = TerminalAssociationStore(
        system: MacTerminalAssociationSystem(),
        target: TerminalEntryApplication(bundleID: "com.itjun.1agent", name: "1Agent", url: Bundle.main.bundleURL),
        defaults: .standard
    )

    @Published private(set) var applications: [TerminalEntryKind: TerminalEntryApplication] = [:]
    @Published private(set) var isBusy = false
    @Published private(set) var hasBackup = false
    @Published private(set) var backupIsReadable = true
    @Published private(set) var feedback: TerminalAssociationFeedback?
    @Published var selected: Set<TerminalEntryKind> = []
    let target: TerminalEntryApplication

    private let system: any TerminalAssociationSystem
    private let defaults: UserDefaults
    private let verificationDelay: UInt64
    private var backups: [String: TerminalAssociationBackup] = [:]

    init(system: any TerminalAssociationSystem, target: TerminalEntryApplication, defaults: UserDefaults,
         verificationDelay: UInt64 = 150_000_000) {
        self.system = system
        self.target = target
        self.defaults = defaults
        self.verificationDelay = verificationDelay
        if let data = defaults.object(forKey: Self.backupKey) {
            if let data = data as? Data,
               let saved = try? JSONDecoder().decode([String: TerminalAssociationBackup].self, from: data),
               saved.keys.allSatisfy({ TerminalEntryKind(rawValue: $0) != nil }) {
                backups = saved
            } else {
                backupIsReadable = false
                feedback = TerminalAssociationFeedback(message: TerminalAssociationError.unreadableBackup.localizedDescription, isFailure: true)
            }
        }
        refresh()
    }

    var isDefaultTerminal: Bool { isOwned(.executable) }
    var canApplySelection: Bool { backupIsReadable && !isBusy && selected.contains { !isOwned($0) } }

    func isOwned(_ kind: TerminalEntryKind) -> Bool {
        applications[kind]?.hasSameIdentity(as: target) == true
    }

    func refresh() {
        guard !isBusy else { return }
        applications = Dictionary(uniqueKeysWithValues: TerminalEntryKind.allCases.compactMap { kind in
            system.application(for: kind).map { (kind, $0) }
        })
        selected = selected.filter { !isOwned($0) }
        hasBackup = !backups.isEmpty
    }

    func setAsDefaultTerminal() async {
        await apply([.executable])
    }

    func applySelection() async {
        await apply(selected)
    }

    func apply(_ kinds: Set<TerminalEntryKind>) async {
        guard !isBusy, backupIsReadable, !kinds.isEmpty else { return }
        isBusy = true
        feedback = nil
        var failures: [String] = []
        var changed = 0
        for kind in TerminalEntryKind.allCases where kinds.contains(kind) {
            do {
                guard let original = system.application(for: kind) else { throw TerminalAssociationError.unknownOriginalApplication }
                if original.hasSameIdentity(as: target) { continue }
                if backups[kind.rawValue] == nil {
                    backups[kind.rawValue] = TerminalAssociationBackup(application: original, roleHandlers: system.roleHandlers(for: kind))
                    try saveBackups()
                }
                try await system.setApplication(target, for: kind)
                try await verify(target, for: kind)
                changed += 1
            } catch {
                failures.append(failureDescription(error, kind: kind))
                if TerminalAssociationError.isCancellation(error) { break }
            }
        }
        finish(changed: changed, failures: failures, restoring: false)
    }

    func restore() async {
        guard !isBusy, backupIsReadable, !backups.isEmpty else { return }
        isBusy = true
        feedback = nil
        var failures: [String] = []
        var changed = 0
        for kind in TerminalEntryKind.allCases {
            guard let backup = backups[kind.rawValue] else { continue }
            do {
                guard let original = system.installedApplication(backup.application) else {
                    throw TerminalAssociationError.missingOriginalApplication(backup.application.name)
                }
                try await system.restoreApplication(original, roles: backup.roleHandlers, for: kind)
                try await verify(original, for: kind)
                let restoredRoles = system.roleHandlers(for: kind)
                guard backup.roleHandlers.allSatisfy({ name, bundleID in
                    restoredRoles[name]?.caseInsensitiveCompare(bundleID) == .orderedSame
                }) else { throw TerminalAssociationError.verificationFailed }
                backups.removeValue(forKey: kind.rawValue)
                try saveBackups()
                changed += 1
            } catch {
                failures.append(failureDescription(error, kind: kind))
                if TerminalAssociationError.isCancellation(error) { break }
            }
        }
        finish(changed: changed, failures: failures, restoring: true)
    }

    private func verify(_ application: TerminalEntryApplication, for kind: TerminalEntryKind) async throws {
        for attempt in 0..<4 {
            if system.application(for: kind)?.hasSameIdentity(as: application) == true { return }
            if attempt < 3 {
                try await Task.sleep(nanoseconds: verificationDelay)
            }
        }
        throw TerminalAssociationError.verificationFailed
    }

    private func saveBackups() throws {
        if backups.isEmpty { defaults.removeObject(forKey: Self.backupKey) }
        else { defaults.set(try JSONEncoder().encode(backups), forKey: Self.backupKey) }
        hasBackup = !backups.isEmpty
    }

    private func finish(changed: Int, failures: [String], restoring: Bool) {
        isBusy = false
        refresh()
        if failures.isEmpty {
            feedback = TerminalAssociationFeedback(
                message: restoring ? String(localized: "The previous default applications have been restored.")
                    : changed > 0 ? String(localized: "The selected associations have been changed and verified.")
                    : String(localized: "These entries already open with 1Agent."),
                isFailure: false
            )
        } else {
            let summary = changed > 0 ? String(localized: "Some associations were changed. The following entries still need attention:")
                : String(localized: "The operation could not be completed:")
            feedback = TerminalAssociationFeedback(message: summary + "\n" + failures.joined(separator: "\n"), isFailure: true)
        }
    }

    private func failureDescription(_ error: Error, kind: TerminalEntryKind) -> String {
        let detail: String
        if TerminalAssociationError.isCancellation(error) { detail = String(localized: "The change was canceled.") }
        else if let error = error as? TerminalAssociationError { detail = error.localizedDescription }
        else {
            let error = error as NSError
            detail = TerminalAssociationError.systemFailure(error.code).localizedDescription
        }
        return kind.title + ": " + detail
    }
}
