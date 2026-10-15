import Foundation

// This executable never connects to a host; satisfy RemoteShell's environment dependency.
actor SSHLaunchEnvironment {
    static let shared = SSHLaunchEnvironment()
    func get() -> [String] { [] }
}

@main
struct FileSafetyTests {
    static func require(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
    }

    static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("oneagent-file-safety-tests-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let fs = LocalFileSystem()
        let file = root.appendingPathComponent("config.txt").path
        try await fs.write(Data("original\r\n".utf8), to: file)
        try await fs.write(Data("older backup".utf8), to: file + ".bak")
        do { try await fs.createFile(file); fatalError("create must not truncate an existing file") } catch {}
        require(try String(contentsOfFile: file, encoding: .utf8) == "original\r\n", "create refuses existing bytes")
        let snapshot = try await fs.readComplete(file, maximumBytes: 1024)
        let backup = try await fs.replaceFile(Data("corrected\n".utf8), at: file, expected: snapshot.revision)!
        require(try String(contentsOfFile: file, encoding: .utf8) == "corrected\n", "replacement bytes")
        require(try String(contentsOfFile: backup, encoding: .utf8) == "original\r\n", "backup is original bytes")
        require(try String(contentsOfFile: file + ".bak", encoding: .utf8) == "older backup", "old backup survives")
        require(backup != file + ".bak", "backup uses an independent name")

        do {
            _ = try await fs.replaceFile(Data("stale".utf8), at: file, expected: snapshot.revision)
            fatalError("stale revisions must not replace newer files")
        } catch {}
        require(try String(contentsOfFile: file, encoding: .utf8) == "corrected\n", "stale replacement leaves current file")

        do {
            _ = try await fs.readComplete(file, maximumBytes: 2)
            fatalError("large conversion must be rejected")
        } catch {}

        let link = root.appendingPathComponent("linked.txt").path
        try manager.createSymbolicLink(atPath: link, withDestinationPath: file)
        do {
            _ = try await fs.replaceFile(Data("bad".utf8), at: link, expected: fs.revision(link))
            fatalError("conversion must not follow a symlink and mutate its target")
        } catch {}
        require(try String(contentsOfFile: file, encoding: .utf8) == "corrected\n", "symlink target survives")

        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("config.txt"))
        try Data("existing".utf8).write(to: target.appendingPathComponent("config.txt"))
        let item = FileTransfer.Item(path: source.appendingPathComponent("config.txt").path, isDirectory: false)
        let cancel = FileOperationCancellation()
        cancel.cancel()
        do {
            _ = try await FileOperationContext.$cancellation.withValue(cancel) {
                try await FileTransfer.copy([item], from: fs, to: fs, into: target.path, choice: .overwrite, progress: { _ in })
            }
            fatalError("cancelled transfer must stop")
        } catch {}
        require(try String(contentsOf: target.appendingPathComponent("config.txt"), encoding: .utf8) == "existing", "cancel leaves destination")
        _ = try await FileTransfer.copy([item], from: fs, to: fs, into: target.path, choice: .overwrite, progress: { _ in })
        require(try String(contentsOf: target.appendingPathComponent("config.txt"), encoding: .utf8) == "new", "completed staged transfer replaces destination")
        require(try manager.contentsOfDirectory(atPath: target.path).allSatisfy { !$0.hasPrefix(".oneagent-") }, "successful transfer cleans staging")

        let stagedFolder = root.appendingPathComponent("staged-folder"), existingFolder = root.appendingPathComponent("existing-folder")
        try manager.createDirectory(at: stagedFolder, withIntermediateDirectories: true)
        try manager.createDirectory(at: existingFolder, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: stagedFolder.appendingPathComponent("new.txt"))
        try Data("old".utf8).write(to: existingFolder.appendingPathComponent("old.txt"))
        let folderRevision = try await fs.revision(existingFolder.path)
        try await fs.commitStaged(stagedFolder.path, to: existingFolder.path, expected: folderRevision)
        require(manager.fileExists(atPath: existingFolder.appendingPathComponent("new.txt").path), "directory exchange installs new tree")
        require(!manager.fileExists(atPath: existingFolder.appendingPathComponent("old.txt").path), "directory exchange removes old tree after commit")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        let runningCancellation = FileOperationCancellation()
        let began = Date()
        let run = Task {
            try await FileOperationContext.$cancellation.withValue(runningCancellation) {
                try await ProcessRunner.run(process)
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        runningCancellation.cancel()
        do { _ = try await run.value; fatalError("running process must cancel") } catch {}
        require(Date().timeIntervalSince(began) < 3, "cancel terminates the actual process")
        print("File safety tests passed")
    }
}
