import AppKit
import Foundation

// Only queue persistence and real local copies run in this isolated executable.
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
        let old = [FileTransferQueue.Job(id: UUID(), item: item, sourceHost: nil, targetHost: nil,
                                        directory: target.path, created: Date(), phase: .running),
                   FileTransferQueue.Job(id: UUID(), item: item, sourceHost: nil, targetHost: nil,
                                         directory: target.path, created: Date(), phase: .queued)]
        defaults.set(try JSONEncoder().encode(old), forKey: FileTransferQueue.storageKey)
        let restored = FileTransferQueue(defaults: defaults)
        require(restored.jobs.allSatisfy { $0.phase == .interrupted }, "active work restores interrupted")
        try await Task.sleep(nanoseconds: 50_000_000)
        require(!restored.hasActiveTransfers, "restoration never restarts work")
        require(!manager.fileExists(atPath: target.appendingPathComponent("file.txt").path), "restoration never touches destinations")

        defaults.removeObject(forKey: FileTransferQueue.storageKey)
        let queue = FileTransferQueue(defaults: defaults)
        let cancelledID = queue.enqueue([item], from: LocalFileSystem(), to: LocalFileSystem(), into: target.path, window: nil)[0]
        queue.cancel(cancelledID)
        try await waitUntilIdle(queue)
        require(queue.jobs[0].phase == .cancelled, "queued work can be cancelled")

        let failedID = queue.enqueue([item], from: LocalFileSystem(), to: LocalFileSystem(), into: target.path, window: nil)[0]
        try await waitUntilIdle(queue)
        require(queue.jobs.first { $0.id == failedID }?.phase == .failed, "missing source reports failure")
        try Data("payload".utf8).write(to: URL(fileURLWithPath: item.path))
        queue.retry(failedID)
        try await waitUntilIdle(queue)
        require(queue.jobs.first { $0.id == failedID }?.phase == .completed, "manual retry completes")
        require(try String(contentsOf: target.appendingPathComponent("file.txt"), encoding: .utf8) == "payload", "retry uses original source and target")
        let again = FileTransferQueue(defaults: defaults)
        require(again.jobs.first { $0.id == failedID }?.phase == .completed, "completed history persists")
        require(again.jobs.first { $0.id == failedID }?.directory == target.path, "destination snapshot persists")
        print("File transfer queue tests passed")
    }
}
