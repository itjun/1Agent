import AppKit
import Foundation

// This executable only stages temporary local files. It never reads SSH configuration or connects.
actor SSHLaunchEnvironment {
    static let shared = SSHLaunchEnvironment()
    func get() -> [String] { [] }
}


@main
struct UploadCheckTests {
    static func require(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }

    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("oneagent-upload-check-tests-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        func write(_ relative: String, _ value: String) throws -> URL {
            let path = root.appendingPathComponent(relative)
            try manager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: path)
            return path
        }

        let first = try write("first/config.txt", "first\r\n")
        let second = try write("second/config.txt", "second\r\n")
        let items = [first, second].map { FileTransfer.Item(path: $0.path, isDirectory: false) }
        let findings = try UploadCheck.scan(items)
        let staged = try UploadCheck.stage(items, converting: Set(findings.map(\.path)), findings: findings)
        defer { staged.cleanUp() }
        require(Set(staged.items.map(\.path)).count == 2, "equal basenames use independent staging locations")
        require(staged.items.allSatisfy { ($0.path as NSString).lastPathComponent == "config.txt" }, "original upload names are retained")
        require(try String(contentsOfFile: staged.items[0].path, encoding: .utf8) == "first\n", "first file keeps its own bytes")
        require(try String(contentsOfFile: staged.items[1].path, encoding: .utf8) == "second\n", "second file does not replace the first staged file")
        require(try Data(contentsOf: first) == Data("first\r\n".utf8), "first source is unchanged")
        require(try Data(contentsOf: second) == Data("second\r\n".utf8), "second source is unchanged")

        let original = try write("tree/sub/config.txt", "same\r\n")
        let outside = try write("outside/config.txt", "same\r\n")
        let directoryItem = FileTransfer.Item(path: root.appendingPathComponent("tree").path, isDirectory: true)
        let prior = try UploadCheck.scan([directoryItem])
        require(prior.count == 1 && prior[0].path == original.path, "directory scan preserves the caller's path spelling")
        let stagedTree = try UploadCheck.stage([directoryItem], converting: Set(prior.map(\.path)), findings: prior)
        defer { stagedTree.cleanUp() }
        require(try String(contentsOfFile: stagedTree.items[0].path + "/sub/config.txt", encoding: .utf8) == "same\n", "regular directory contents convert within staging")
        require(try Data(contentsOf: original) == Data("same\r\n".utf8), "directory conversion preserves the original file")
        let subdirectory = original.deletingLastPathComponent()
        try manager.removeItem(at: subdirectory)
        try manager.createSymbolicLink(at: subdirectory, withDestinationURL: outside.deletingLastPathComponent())
        do {
            let escaped = try UploadCheck.stage([directoryItem], converting: Set(prior.map(\.path)), findings: prior)
            escaped.cleanUp()
            fatalError("a replaced symlink ancestor must be rejected even when its file digest matches")
        } catch {}
        require(try Data(contentsOf: outside) == Data("same\r\n".utf8), "conversion never deletes or modifies the symlink target outside staging")

        try Data("changed\r\n".utf8).write(to: first)
        do {
            let stale = try UploadCheck.stage([items[0]], converting: [first.path], findings: findings)
            stale.cleanUp()
            fatalError("files changed after confirmation must not be converted")
        } catch {}
        require(try Data(contentsOf: first) == Data("changed\r\n".utf8), "digest mismatch preserves new source contents")

        let cancellation = FileOperationCancellation()
        cancellation.cancel()
        do { _ = try UploadCheck.scan(items, cancellation: cancellation); fatalError("cancelled scan must stop") }
        catch is CancellationError {}
        do { _ = try UploadCheck.stage(items, converting: [first.path], cancellation: cancellation); fatalError("cancelled staging must stop") }
        catch is CancellationError {}
        print("Upload staging tests passed")
    }
}
