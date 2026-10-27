import AppKit
import Foundation

// Only transient queue behavior and real local copies run in this isolated executable.
actor SSHLaunchEnvironment {
    static let shared = SSHLaunchEnvironment()
    func get() -> [String] { [] }
}
enum UploadCheck {
    struct Prepared { var items: [FileTransfer.Item]; func cleanUp() {} }
    @MainActor static func prepare(_ items: [FileTransfer.Item], from: any FileSystem,
                                   to: any FileSystem, window: NSWindow?) async throws -> Prepared? {
        Prepared(items: items)
    }
}
@MainActor final class FileBrowserStore {
    static let shared = FileBrowserStore()
    func refresh(host: String?) {}
}

@MainActor final class TransferToast {
    static let shared = TransferToast()
    func begin(_ text: String, in window: NSWindow?) -> Int { 0 }
    func progress(_ id: Int, _ text: String, fraction: Double) {}
    func finish(_ id: Int, _ text: String) {}
    func fail(_ id: Int?, _ text: String, in window: NSWindow?) {}
}

@main
struct FileTransferQueueTests {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }

    @MainActor static func waitUntilIdle(_ queue: FileTransferQueue) async throws {
        for _ in 0..<100 {
            if !queue.hasActiveTransfers { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        fatalError("queue did not settle")
    }

    @MainActor static func main() async throws {
        let suite = "oneagent-file-queue-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(suite)
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let item = FileTransfer.Item(path: source.appendingPathComponent("file.txt").path, isDirectory: false)
        defaults.set(Data("legacy history".utf8), forKey: FileTransferQueue.storageKey)
        let queue = FileTransferQueue(defaults: defaults)
        require(defaults.data(forKey: FileTransferQueue.storageKey) == nil, "legacy history is removed")
        require(queue.jobs.isEmpty, "old transfers do not restart")
        require(!manager.fileExists(atPath: target.appendingPathComponent("file.txt").path), "initialization never touches destinations")

        let cancelledID = queue.enqueue([item], from: LocalFileSystem(), to: LocalFileSystem(), into: target.path, window: nil)[0]
        queue.cancel(cancelledID)
        try await waitUntilIdle(queue)
        require(queue.jobs.isEmpty, "cancelled work leaves no history")
        do {
            _ = try await queue.transfer([item], from: LocalFileSystem(), to: LocalFileSystem(), into: target.path,
                                         window: nil, choice: .rename, prepare: false)
            fatalError("missing source must fail")
        } catch {}
        require(queue.jobs.isEmpty, "failed work leaves no history")
        try Data("payload".utf8).write(to: URL(fileURLWithPath: item.path))
        let paths = try await queue.transfer([item], from: LocalFileSystem(), to: LocalFileSystem(), into: target.path,
                                             window: nil, choice: .rename, prepare: false)
        require(paths == [target.appendingPathComponent("file.txt").path], "completed transfer returns its destination")
        require(try String(contentsOf: target.appendingPathComponent("file.txt"), encoding: .utf8) == "payload", "transfer copies the source")
        require(queue.jobs.isEmpty, "completed work leaves no history")
        require(defaults.data(forKey: FileTransferQueue.storageKey) == nil, "transfers never persist history")
        print("File transfer queue tests passed")
    }
}
