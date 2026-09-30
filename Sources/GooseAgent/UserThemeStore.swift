import AppKit
import CoreServices
import GhosttyTheme

enum UserThemeError: LocalizedError {
    case unreadable(String)
    case invalidTheme(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let fileName):
            return String(format: String(localized: "“%@” could not be read as text."), fileName)
        case .invalidTheme(let fileName):
            return String(format: String(localized: "“%@” is not a Ghostty theme file: it needs background and foreground colors."), fileName)
        }
    }
}

/// Themes the user keeps in Ghostty's own folder, `$XDG_CONFIG_HOME/ghostty/themes` (default `~/.config`).
/// Each plain file is one theme; the file name is the theme name. A name here wins over the bundled catalog.
///
/// Not main-actor isolated: `TerminalThemeChoice` reads it from nonisolated code. The list only
/// changes on the main thread (init, FSEvents on the main queue, Settings actions).
final class UserThemeStore: ObservableObject {
    static let shared = UserThemeStore()

    /// Sorted by name.
    @Published private(set) var themes: [GhosttyThemeDefinition] = []
    private var themesByName: [String: GhosttyThemeDefinition] = [:]
    private var eventStream: FSEventStreamRef?

    static var directoryURL: URL {
        let environment = ProcessInfo.processInfo.environment
        var configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            configURL = URL(fileURLWithPath: xdg, isDirectory: true)
        }
        return configURL.appendingPathComponent("ghostty/themes", isDirectory: true)
    }

    /// Loads synchronously, so launch-time migration already sees the user's themes.
    private init() {
        apply(UserThemeStore.scan())
        startWatching()
        // The folder may be created outside the app; coming back to the app picks it up.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                UserThemeStore.shared.reload()
            }
        }
    }

    func theme(named name: String) -> GhosttyThemeDefinition? {
        themesByName[name]
    }

    /// Rescans the folder. When the light or dark theme in use changed, terminals and window chrome follow.
    @MainActor
    func reload() {
        startWatching()
        let scanned = UserThemeStore.scan()
        if scanned == themes {
            return
        }
        let lightBefore = ThemePreview.shared.effectiveLight().definition
        let darkBefore = ThemePreview.shared.effectiveDark().definition
        apply(scanned)
        let lightAfter = ThemePreview.shared.effectiveLight().definition
        let darkAfter = ThemePreview.shared.effectiveDark().definition
        if lightBefore != lightAfter || darkBefore != darkAfter {
            GhosttyRuntime.applySelectedThemes()
            AppearanceDriver.shared.reapply()
        }
    }

    /// Validates first, then copies into the folder (created if missing). An existing name is never
    /// overwritten; the copy gets " 2", " 3", … instead. Returns the saved theme name.
    @MainActor
    @discardableResult
    func importThemeFile(from url: URL) throws -> String {
        let fileName = url.lastPathComponent
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw UserThemeError.unreadable(fileName)
        }
        guard UserThemeParser.parse(name: fileName, contents: contents) != nil else {
            throw UserThemeError.invalidTheme(fileName)
        }
        let directory = try UserThemeStore.ensureDirectory()
        var name = fileName
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(fileName) \(suffix)"
            suffix += 1
        }
        try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(name))
        reload()
        return name
    }

    /// Moves the theme file to the Trash, so it can be put back from there. Callers confirm first.
    @MainActor
    func deleteTheme(named name: String) throws {
        let fileURL = UserThemeStore.directoryURL.appendingPathComponent(name)
        try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
        reload()
    }

    @MainActor
    func openDirectory() throws {
        let directory = try UserThemeStore.ensureDirectory()
        startWatching()
        NSWorkspace.shared.open(directory)
    }

    @discardableResult
    static func ensureDirectory() throws -> URL {
        let directory = UserThemeStore.directoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Every readable regular file that parses as a theme. A missing folder is simply empty.
    static func scan() -> [GhosttyThemeDefinition] {
        let directory = UserThemeStore.directoryURL
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [GhosttyThemeDefinition] = []
        for url in urls {
            // Resolves symlinks, so a linked theme file counts as a regular file.
            let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: Set(keys))
            if values?.isRegularFile != true {
                continue
            }
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let theme = UserThemeParser.parse(name: url.lastPathComponent, contents: contents) {
                result.append(theme)
            }
        }
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }

    private func apply(_ scanned: [GhosttyThemeDefinition]) {
        var byName: [String: GhosttyThemeDefinition] = [:]
        for theme in scanned {
            byName[theme.name] = theme
        }
        themesByName = byName
        themes = scanned
    }

    /// File-level FSEvents catch in-place edits too, not only files added or removed.
    /// Only starts once the folder exists; `reload()` and `openDirectory()` retry.
    private func startWatching() {
        if eventStream != nil {
            return
        }
        let directory = UserThemeStore.directoryURL.resolvingSymlinksInPath()
        if !FileManager.default.fileExists(atPath: directory.path) {
            return
        }
        var context = FSEventStreamContext(
            version: 0,
            info: nil,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, _, _, _, _, _ in
            MainActor.assumeIsolated {
                UserThemeStore.shared.reload()
            }
        }
        // Latency coalesces editors that delete then rewrite a file, so the theme never looks gone.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else {
            return
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        eventStream = stream
    }
}
