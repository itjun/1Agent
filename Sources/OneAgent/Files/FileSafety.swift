import Darwin
import Foundation

struct FileRevision: Codable, Equatable, Sendable {
    let token: String
}

struct FileReadSnapshot: Sendable {
    let data: Data
    let revision: FileRevision
}

/// Cancellation belongs to an operation, not to a file view or a window.
final class FileOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var committing = false
    private var processes: [ObjectIdentifier: Process] = [:]

    var isCancelled: Bool { lock.withLock { requested } }
    var shouldAbort: Bool { lock.withLock { requested && !committing } }

    func check() throws {
        if shouldAbort { throw CancellationError() }
    }

    func register(_ process: Process) throws {
        try lock.withLock {
            if requested && !committing { throw CancellationError() }
            processes[ObjectIdentifier(process)] = process
        }
    }

    func unregister(_ process: Process) {
        _ = lock.withLock { processes.removeValue(forKey: ObjectIdentifier(process)) }
    }

    func processStarted(_ process: Process) {
        if lock.withLock({ requested && !committing }), process.isRunning { process.terminate() }
    }

    func cancel() {
        let running: [Process] = lock.withLock {
            requested = true
            return committing ? [] : Array(processes.values)
        }
        for process in running where process.isRunning {
            process.terminate()
            // A child that ignores TERM must not hold a cancelled transfer indefinitely.
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning, process.processIdentifier == pid { kill(pid, SIGKILL) }
            }
        }
    }

    /// Replacing an existing destination is a short, non-cancellable transaction.
    func beginCommit() throws {
        try lock.withLock {
            if requested { throw CancellationError() }
            committing = true
        }
    }

    func endCommit() { lock.withLock { committing = false } }
}

enum FileOperationContext {
    @TaskLocal static var cancellation: FileOperationCancellation?
}

extension FileSystem {
    func revision(_ path: String) async throws -> FileRevision {
        if let host {
            let data = try await RemoteShell.run(alias: host,
                command: "stat -c '%d:%i:%s:%f:%y:%z' -- \(FileRules.shellQuote(path))")
            return FileRevision(token: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
        }
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return FileRevision(token: "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mode):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)")
    }

    func readComplete(_ path: String, maximumBytes: Int) async throws -> FileReadSnapshot {
        try await requireRegularFile(path)
        let before = try await revision(path)
        let data = try await read(path, limit: maximumBytes + 1)
        guard data.count <= maximumBytes else {
            throw FileError.message(String(localized: "The file is too large to convert safely"))
        }
        guard try await revision(path) == before else { throw FileSafety.changed() }
        return FileReadSnapshot(data: data, revision: before)
    }

    func rename(_ path: String, to target: String) async throws {
        let name = (target as NSString).lastPathComponent
        guard try await existingNames(in: FileRules.parent(of: target), among: [name]).isEmpty else {
            throw FileError.message(String(format: String(localized: "“%@” already exists"), name))
        }
        if let host {
            let from = FileRules.shellQuote(path), to = FileRules.shellQuote(target)
            _ = try await RemoteShell.run(alias: host,
                command: "mv -T -n -- \(from) \(to) && if [ -e \(from) ] || [ -L \(from) ]; then exit 1; fi")
        } else {
            try FileManager.default.moveItem(atPath: path, toPath: target)
        }
    }

    /// Refuse links, FIFOs and devices before attempting a complete read or a rewrite.
    func requireRegularFile(_ path: String) async throws {
        let message = String(localized: "Only regular files can be converted")
        if let host {
            let quoted = FileRules.shellQuote(path)
            _ = try await RemoteShell.run(alias: host,
                command: "if [ -f \(quoted) ] && [ ! -L \(quoted) ]; then :; else printf '%s\\n' \(FileRules.shellQuote(message)) >&2; exit 1; fi")
        } else {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw FileError.message(message)
            }
        }
    }

    /// Copies mode/ownership metadata before writing new bytes, then commits only if unchanged.
    /// Existing .bak files are never removed or reused.
    func replaceFile(_ data: Data, at path: String, expected: FileRevision,
                     keepBackup: Bool = true) async throws -> String? {
        guard try await revision(path) == expected else { throw FileSafety.changed() }
        try await requireRegularFile(path)
        let staging = FileRules.join(FileRules.parent(of: path), ".oneagent-format-\(UUID().uuidString)")
        var backup: String?
        do {
            try await copy(path, to: staging)
            try await write(data, to: staging)
            guard try await revision(path) == expected else { throw FileSafety.changed() }
            if keepBackup {
                let chosen = path + ".bak." + UUID().uuidString
                try await copy(path, to: chosen)
                backup = chosen
            }
            try await commitStaged(staging, to: path, expected: expected)
            return backup
        } catch {
            try? await delete([staging])
            throw error
        }
    }

    /// Move a completed sibling temporary item into place. Expected nil means no destination
    /// was present. Never delete the original before a complete replacement exists.
    func commitStaged(_ staging: String, to path: String, expected: FileRevision?) async throws {
        let rollback = FileRules.join(FileRules.parent(of: path), ".oneagent-rollback-\(UUID().uuidString)")
        if let host {
            let target = FileRules.shellQuote(path), temporary = FileRules.shellQuote(staging)
            let saved = FileRules.shellQuote(rollback)
            let changed = FileRules.shellQuote(String(localized: "The file changed. Refresh it and try again."))
            let check: String
            if let expected {
                check = "[ \"$(stat -c '%d:%i:%s:%f:%y:%z' -- \(target))\" = \(FileRules.shellQuote(expected.token)) ]"
            } else {
                check = "[ ! -e \(target) ] && [ ! -L \(target) ]"
            }
            // A remote directory cannot replace a non-empty directory with one POSIX rename.
            // Keep the old tree under a unique rollback name and restore it on shell interruption.
            let directoryCommit = "restore_original() { if { [ -e \(saved) ] || [ -L \(saved) ]; } && [ ! -e \(target) ] && [ ! -L \(target) ]; then mv -T -n -- \(saved) \(target); fi; }; trap restore_original EXIT; trap 'exit 1' HUP INT TERM; mv -T -- \(target) \(saved) && mv -T -n -- \(temporary) \(target) && [ ! -e \(temporary) ] && [ ! -L \(temporary) ] || exit 1; trap - EXIT HUP INT TERM; rm -rf -- \(saved)"
            let commit = expected == nil
                ? "mv -T -n -- \(temporary) \(target); [ ! -e \(temporary) ] && [ ! -L \(temporary) ]"
                : "if [ -d \(target) ] && [ ! -L \(target) ]; then \(directoryCommit); else mv -T -- \(temporary) \(target); fi"
            _ = try await RemoteShell.run(alias: host, command: "if \(check); then \(commit); else printf '%s\\n' \(changed) >&2; exit 1; fi")
            return
        }
        if let expected {
            guard try await revision(path) == expected else { throw FileSafety.changed() }
        } else {
            var info = stat()
            guard lstat(path, &info) != 0, errno == ENOENT else { throw FileSafety.changed() }
        }
        // macOS can atomically exchange even non-empty directories. The old target becomes the
        // staging item, which is removed only after the exchange has succeeded.
        let flags = expected == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
        guard renamex_np(staging, path, flags) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if expected != nil { try? FileManager.default.removeItem(atPath: staging) }
    }
}

enum FileSafety {
    static func changed() -> FileError {
        .message(String(localized: "The file changed. Refresh it and try again."))
    }
}
