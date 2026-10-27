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
                guard await FileTransfer.confirmDrop(items, from: LocalFileSystem(), to: target,
                                                     into: directory, window: window) else { return }
                let paths = try await FileTransferQueue.shared.transfer(
                    items, from: LocalFileSystem(), to: target, into: directory, window: window
                )
                FileBrowserStore.shared.refresh(host: remote)
                if remote != nil {
                    SSHTerminalRegistry.paste(ShellEscape.dropText(paths: paths), into: sessionID)
                }
            } catch {
                TransferToast.shared.fail(nil, error.localizedDescription, in: window)
            }
        }
    }
}

extension FileTransfer {
    /// Compatibility entry point; queue ownership and its terminal progress toast are shared.
    @MainActor
    static func run(
        _ items: [Item], from source: any FileSystem, to target: any FileSystem, into directory: String,
        choice: ConflictChoice, window: NSWindow?, started: (Int) -> Void = { _ in }
    ) async throws -> [String] {
        try await FileTransferQueue.shared.transfer(
            items, from: source, to: target, into: directory, window: window,
            choice: choice, prepare: false
        )
    }
}
