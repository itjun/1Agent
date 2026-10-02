import AppKit
import Foundation

/// The transfer circle: Finder files go to the terminal's current folder. Over ssh they are
/// uploaded to the remote shell's folder (home when it never reported one) and the remote paths
/// are typed at the prompt; a local shell gets a copy in its own folder.
@MainActor
enum DropTransfer {
    static func run(_ urls: [URL], for tab: TerminalTab, model: AppModel) {
        let sessionID = tab.sessionID
        let window = SSHTerminalRegistry.window(for: sessionID)
        let remote = tab.alias.flatMap { $0.isEmpty ? nil : $0 }
        let target = fileSystem(for: remote)
        let items = urls.map { url -> FileTransfer.Item in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return FileTransfer.Item(path: url.path, isDirectory: isDirectory.boolValue)
        }
        Task { @MainActor in
            var toast: Int?
            do {
                let directory: String
                if remote != nil {
                    if let known = tab.remoteDirectory {
                        directory = known
                    } else {
                        directory = try await target.home()
                    }
                } else {
                    directory = SSHTerminalRegistry.currentWorkingDirectory(for: sessionID)
                        ?? tab.directory ?? NSHomeDirectory()
                }
                guard let prepared = try await UploadCheck.prepare(
                    items, from: LocalFileSystem(), to: target, window: window
                ) else { return }
                defer { prepared.cleanUp() }
                let existing = try await FileTransfer.conflicts(
                    prepared.items, from: LocalFileSystem(), to: target, into: directory
                )
                guard let choice = await FileTransfer.askAboutConflicts(existing, in: window) else { return }
                let paths = try await FileTransfer.run(
                    prepared.items, from: LocalFileSystem(), to: target, into: directory, choice: choice,
                    window: window, started: { toast = $0 }
                )
                FileBrowserStore.shared.refresh(host: remote)
                if remote != nil {
                    SSHTerminalRegistry.paste(ShellEscape.dropText(paths: paths), into: sessionID)
                }
            } catch {
                TransferToast.shared.fail(toast, error.localizedDescription, in: window)
            }
        }
    }
}

extension FileTransfer {
    /// `copy` with the progress toast: "Uploading 42%", then "Uploaded", or the error in red.
    @MainActor
    static func run(
        _ items: [Item], from source: any FileSystem, to target: any FileSystem, into directory: String,
        choice: ConflictChoice, window: NSWindow?, started: (Int) -> Void = { _ in }
    ) async throws -> [String] {
        let running: String
        let done: String
        switch (source.isRemote, target.isRemote) {
        case (false, true):
            running = String(localized: "Uploading")
            done = String(localized: "Uploaded")
        case (true, false):
            running = String(localized: "Downloading")
            done = String(localized: "Downloaded")
        default:
            running = String(localized: "Copying")
            done = String(localized: "Copied")
        }
        let toast = TransferToast.shared.begin(running, in: window)
        started(toast)
        let paths = try await copy(items, from: source, to: target, into: directory, choice: choice) { fraction in
            Task { @MainActor in
                let percent = Int((fraction * 100).rounded())
                TransferToast.shared.progress(toast, "\(running) \(percent)%", fraction: fraction)
            }
        }
        TransferToast.shared.finish(toast, done)
        return paths
    }
}
