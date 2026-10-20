import AppKit
import Foundation

/// Copies between this Mac and a host, or within one side. Files go through `cat`, folders
/// through `tar`, both over the shared ssh connection; progress counts the bytes passed along.
enum FileTransfer {
    struct Item: Codable, Sendable {
        var path: String
        var isDirectory: Bool
    }

    /// Asks about names already in `directory`. Nil means cancel; no conflict means rename,
    /// which then keeps every name as it is.
    @MainActor
    static func askAboutConflicts(_ names: Set<String>, in window: NSWindow?) async -> ConflictChoice? {
        guard !names.isEmpty else { return .rename }
        let alert = FamilyAlert()
        alert.alertStyle = .warning
        let list = names.sorted().prefix(5).joined(separator: "、")
        alert.messageText = names.count == 1
            ? String(format: String(localized: "“%@” already exists"), list)
            : String(format: String(localized: "%d items already exist"), names.count)
        alert.informativeText = names.count == 1
            ? String(localized: "Keep both copies, or replace the existing item?")
            : String(format: String(localized: "%@. Keep both copies, or replace the existing items?"), list)
        alert.addButton(withTitle: String(localized: "Keep Both"))
        alert.addButton(withTitle: String(localized: "Replace")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        let response = if let window { await alert.beginSheetModal(for: window) } else { alert.runModal() }
        switch response {
        case .alertFirstButtonReturn: return .rename
        case .alertSecondButtonReturn: return .overwrite
        default: return nil
        }
    }

    /// Names already in `directory` the user must decide on. On one side, a name that would replace
    /// a folder holding a source is left out: it always keeps both copies. Throws when the copy
    /// stays in the source's own folder or puts a folder into itself.
    static func conflicts(
        _ items: [Item], from source: any FileSystem, to target: any FileSystem, into directory: String
    ) async throws -> Set<String> {
        let names = items.map { ($0.path as NSString).lastPathComponent }
        let existing = try await target.existingNames(in: directory, among: names)
        return existing.subtracting(try await protectedNames(items, from: source, to: target, into: directory))
    }

    /// Same side only. Folders are resolved first, so two panes reaching one folder through a link
    /// still count as the same place.
    private static func protectedNames(
        _ items: [Item], from source: any FileSystem, to target: any FileSystem, into directory: String
    ) async throws -> Set<String> {
        guard source.host == target.host, !items.isEmpty else { return [] }
        let names = items.map { ($0.path as NSString).lastPathComponent }
        let resolved = await target.resolveFolders(items.map { FileRules.parent(of: $0.path) } + [directory])
        let folder = resolved[items.count]
        let sources = zip(resolved, names).map { FileRules.join($0, $1) }
        let checked = zip(sources, items).map { (path: $0, isDirectory: $1.isDirectory) }
        if let refusal = FileRules.sameSideRefusal(sources: checked, into: folder) {
            throw FileError.message(refusal)
        }
        return FileRules.protectedNames(names, sources: sources, into: folder)
    }

    /// Copies `items` from `source` into `directory` on `target` and returns the new paths.
    /// `progress` gets a fraction from 0 to 1, from any thread.
    static func copy(
        _ items: [Item],
        from source: any FileSystem,
        to target: any FileSystem,
        into directory: String,
        choice: ConflictChoice,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [String] {
        let names = items.map { ($0.path as NSString).lastPathComponent }
        var existing = try await target.existingNames(in: directory, among: names)
        let keep = try await protectedNames(items, from: source, to: target, into: directory)
        var picks = FileRules.targetNames(for: names, existing: existing, choice: choice, keep: keep)
        // A new name such as `a 1.txt` may be taken too; pick again until every new name is free.
        while true {
            let fresh = picks.map(\.name).filter { !existing.contains($0) && !names.contains($0) }
            let taken = try await target.existingNames(in: directory, among: fresh)
            if taken.isEmpty { break }
            existing.formUnion(taken)
            picks = FileRules.targetNames(for: names, existing: existing, choice: choice, keep: keep)
        }
        let total = max(1, try await totalSize(items, on: source))
        let counter = ByteCounter(total: total, report: progress)
        var results: [String] = []
        for (item, pick) in zip(items, picks) {
            let destination = FileRules.join(directory, pick.name)
            let cancellation = FileOperationContext.cancellation
            try cancellation?.check()
            let revision = pick.replace ? try await target.revision(destination) : nil
            let staging = FileRules.join(directory, ".oneagent-transfer-" + UUID().uuidString)
            do {
                try await copyOne(item, from: source, to: target, destination: staging, counter: counter)
                try cancellation?.beginCommit()
                do {
                    try await target.commitStaged(staging, to: destination, expected: revision)
                    cancellation?.endCommit()
                } catch {
                    cancellation?.endCommit()
                    throw error
                }
                results.append(destination)
            } catch {
                // A cancelled SSH must not prevent removing its partial staging item.
                await FileOperationContext.$cancellation.withValue(nil) { try? await target.delete([staging]) }
                throw error
            }
        }
        progress(1)
        return results
    }

    private static func copyOne(
        _ item: Item, from source: any FileSystem, to target: any FileSystem,
        destination: String, counter: ByteCounter
    ) async throws {
        switch (source.host, target.host) {
        case (nil, nil):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/cp")
            process.arguments = ["-pR", item.path, destination]
            let result = try await ProcessRunner.run(process)
            guard result.status == 0 else { throw ProcessRunner.failure(result) }
            counter.add(Int(try await size(of: item, on: source)))
        case (nil, let host?):
            let quoted = FileRules.shellQuote(destination)
            if item.isDirectory {
                let tar = localTar(["-C", item.path, "-cf", "-", "."])
                let ssh = await RemoteShell.process(alias: host, command: "mkdir -p \(quoted) && tar -xf - -C \(quoted)")
                try await pipe(producer: tar, consumer: ssh, counter: counter)
            } else {
                guard let file = FileHandle(forReadingAtPath: item.path) else {
                    throw FileError.message(String(localized: "Could not open the file"))
                }
                let ssh = await RemoteShell.process(alias: host, command: "cat > \(quoted)")
                try await pipe(reading: file, consumer: ssh, counter: counter)
            }
        case (let host?, nil):
            let quoted = FileRules.shellQuote(item.path)
            if item.isDirectory {
                try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
                let ssh = await RemoteShell.process(alias: host, command: "tar -C \(quoted) -cf - .")
                let tar = localTar(["-xf", "-", "-C", destination])
                try await pipe(producer: ssh, consumer: tar, counter: counter)
            } else {
                guard FileManager.default.createFile(atPath: destination, contents: nil),
                      let file = FileHandle(forWritingAtPath: destination) else {
                    throw FileError.message(String(localized: "Could not create the file"))
                }
                let ssh = await RemoteShell.process(alias: host, command: "cat -- \(quoted)")
                try await pipe(producer: ssh, writing: file, counter: counter)
            }
        case (let from?, let to?) where from == to:
            try await source.copy(item.path, to: destination)
            counter.add(Int(try await size(of: item, on: source)))
        case (_?, _?):
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("ghostty-transfer-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let local = LocalFileSystem()
            let half = ByteCounter(total: 1, report: { _ in })
            let staged = staging.appendingPathComponent((item.path as NSString).lastPathComponent).path
            try await copyOne(item, from: source, to: local, destination: staged, counter: half)
            try await copyOne(Item(path: staged, isDirectory: item.isDirectory), from: local, to: target,
                              destination: destination, counter: counter)
        }
    }

    // MARK: Sizes

    private static func totalSize(_ items: [Item], on source: any FileSystem) async throws -> Int64 {
        var total: Int64 = 0
        for item in items {
            total += (try? await size(of: item, on: source)) ?? 0
        }
        return total
    }

    private static func size(of item: Item, on source: any FileSystem) async throws -> Int64 {
        guard let host = source.host else {
            return localSize(item.path)
        }
        let output = try await RemoteShell.run(alias: host, command: "du -sk -- \(FileRules.shellQuote(item.path))")
        let kilobytes = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isWhitespace).first
        return (Int64(kilobytes ?? "") ?? 0) * 1024
    }

    private static func localSize(_ path: String) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: Pipes

    /// `COPYFILE_DISABLE` keeps macOS tar from adding `._` resource files for Linux hosts.
    private static func localTar(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["COPYFILE_DISABLE"] = "1"
        process.environment = environment
        return process
    }

    /// Feeds one process, or a file, into another process, or a file, on a background thread.
    private static func pipe(
        producer: Process? = nil, reading: FileHandle? = nil,
        consumer: Process? = nil, writing: FileHandle? = nil,
        counter: ByteCounter
    ) async throws {
        signal(SIGPIPE, SIG_IGN)
        let cancellation = FileOperationContext.cancellation
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try runPipe(producer: producer, reading: reading, consumer: consumer, writing: writing, counter: counter, cancellation: cancellation)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runPipe(
        producer: Process?, reading: FileHandle?, consumer: Process?, writing: FileHandle?,
        counter: ByteCounter, cancellation: FileOperationCancellation?
    ) throws {
        try cancellation?.check()
        for process in [producer, consumer].compactMap({ $0 }) { try cancellation?.register(process) }
        defer {
            for process in [producer, consumer].compactMap({ $0 }) { cancellation?.unregister(process) }
        }
        var drains: [(Process, Drain)] = []
        var reader = reading
        var writer = writing
        if let producer {
            let out = Pipe()
            let err = Pipe()
            producer.standardOutput = out
            producer.standardError = err
            producer.standardInput = FileHandle.nullDevice
            try producer.run()
            cancellation?.processStarted(producer)
            drains.append((producer, Drain(err.fileHandleForReading)))
            reader = out.fileHandleForReading
        }
        if let consumer {
            let input = Pipe()
            let err = Pipe()
            consumer.standardInput = input
            consumer.standardOutput = FileHandle.nullDevice
            consumer.standardError = err
            do {
                try consumer.run()
                cancellation?.processStarted(consumer)
            } catch {
                producer?.terminate()
                throw error
            }
            drains.append((consumer, Drain(err.fileHandleForReading)))
            writer = input.fileHandleForWriting
        }
        guard let reader, let writer else { return }
        var copyError: Error?
        do {
            try ProcessRunner.copy(reader, to: writer, cancellation: cancellation) { counter.add($0) }
        } catch {
            copyError = error
            producer?.terminate()
        }
        try? writer.close()
        if producer == nil { try? reader.close() }
        for (process, drain) in drains {
            process.waitUntilExit()
            let errors = drain.wait()
            if process.terminationStatus != 0 {
                throw ProcessRunner.failure(ProcessResult(status: process.terminationStatus, stdout: Data(), stderr: errors))
            }
        }
        try cancellation?.check()
        if let copyError { throw copyError }
    }
}

/// Bytes passed so far across one transfer, turned into a fraction for the progress toast.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var done: Int64 = 0
    private let total: Int64
    private let report: @Sendable (Double) -> Void

    init(total: Int64, report: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.report = report
    }

    func add(_ bytes: Int) {
        lock.lock()
        done += Int64(bytes)
        let fraction = min(1, Double(done) / Double(total))
        lock.unlock()
        report(fraction)
    }
}
