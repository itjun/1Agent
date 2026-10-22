import Foundation

@main
enum RemotePaletteTests {
    struct Failure: Error { let message: String }

    static func main() {
        do { try run() }
        catch {
            fputs("RemotePaletteTests failed: \(error)\n", stderr)
            exit(1)
        }
        print("RemotePaletteTests passed")
    }

    static func run() throws {
        let suite = "oneagent.remote-palette.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try check(RemotePalette.stored(defaults: defaults) == .peachSorbet, "Remote must default to M05")

        defaults.set(ApplicationIcon.original.rawValue, forKey: RemotePalette.storageKey)
        try check(RemotePalette.stored(defaults: defaults) == .peachSorbet, "Original has no palette, so remote falls back to M05")

        defaults.set("M99", forKey: RemotePalette.storageKey)
        try check(RemotePalette.stored(defaults: defaults) == .peachSorbet, "An unknown value falls back to M05")

        defaults.set(ApplicationIcon.cloudSoda.rawValue, forKey: RemotePalette.storageKey)
        try check(RemotePalette.stored(defaults: defaults) == .cloudSoda, "A saved macaron palette must be kept")

        for isDark in [false, true] {
            let local = WindowChrome(isDark: isDark, icon: ApplicationIcon.defaultIcon)
            let remote = WindowChrome(isDark: isDark, icon: RemotePalette.defaultPalette)
            try check(local.sidebarBackground != remote.sidebarBackground, "Default icon and remote windows must differ (dark: \(isDark))")
        }
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
}
