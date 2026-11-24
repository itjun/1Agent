import AppKit

enum TerminalCommandLine {
    static var destination: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/natty")
    }

    /// Upgrade only a launcher previously installed by this app.
    static func migrateInstalledLauncher() {
        let manager = FileManager.default
        let old = destination.deletingLastPathComponent().appendingPathComponent("1agent")
        guard Bundle.main.bundleURL.path == "/Applications/Natty.app",
              (try? manager.destinationOfSymbolicLink(atPath: old.path)) == "/Applications/1Agent.app/Contents/Resources/1agent"
        else { return }
        do {
            try install()
            let replacement = old.deletingLastPathComponent().appendingPathComponent(".natty-" + UUID().uuidString)
            try manager.createSymbolicLink(at: replacement, withDestinationURL: destination)
            defer { try? manager.removeItem(at: replacement) }
            guard rename(replacement.path, old.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            NSLog("Natty could not migrate the command-line launcher: %@", error.localizedDescription)
        }
    }

    static func install() throws {
        guard let source = Bundle.main.url(forResource: "natty", withExtension: nil) else { throw AutomationFailure.unavailable }
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) || (try? manager.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            let sameLink = (try? manager.destinationOfSymbolicLink(atPath: destination.path)) == source.path
            if sameLink { return }
            guard let text = try? String(contentsOf: destination, encoding: .utf8), text.contains("# Natty managed command-line launcher") else {
                throw TerminalCommandLineError.existingFile
            }
            try manager.removeItem(at: destination)
        }
        try manager.createSymbolicLink(at: destination, withDestinationURL: source)
    }
}

enum TerminalCommandLineError: LocalizedError {
    case existingFile
    var errorDescription: String? { String(localized: "A different natty command already exists. It was left unchanged.") }
}
