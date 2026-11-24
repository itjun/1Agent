import AppKit

enum TerminalCommandLine {
    static var destination: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/1agent")
    }

    static func install() throws {
        guard let source = Bundle.main.url(forResource: "1agent", withExtension: nil) else { throw AutomationFailure.unavailable }
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) || (try? manager.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            let sameLink = (try? manager.destinationOfSymbolicLink(atPath: destination.path)) == source.path
            if sameLink { return }
            guard let text = try? String(contentsOf: destination, encoding: .utf8), text.contains("# 1Agent managed command-line launcher") else {
                throw TerminalCommandLineError.existingFile
            }
            try manager.removeItem(at: destination)
        }
        try manager.createSymbolicLink(at: destination, withDestinationURL: source)
    }
}

enum TerminalCommandLineError: LocalizedError {
    case existingFile
    var errorDescription: String? { String(localized: "A different 1agent command already exists. It was left unchanged.") }
}
