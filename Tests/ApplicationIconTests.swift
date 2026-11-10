import AppKit

@main
enum ApplicationIconTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        let bundle = Bundle(path: args[1])!
        let suite = args[2], phase = args[3]
        let applicationURL = URL(fileURLWithPath: args[4])
        precondition(applicationURL.path.hasPrefix("/private/tmp/oneagent-app-icons."))
        let defaults = UserDefaults(suiteName: suite)!
        let manager = ApplicationIconManager(defaults: defaults, applicationURL: applicationURL)
        if phase == "save" {
            defaults.set("M05", forKey: ApplicationIcon.storageKey)
            let legacy = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
                NSColor.systemPink.setFill()
                rect.fill()
                return true
            }
            expect(NSWorkspace.shared.setIcon(legacy, forFile: applicationURL.path), "Legacy custom icon can be installed in the fixture")
            defaults.synchronize()
            print("Saved a legacy colored icon for migration in a fresh process")
            return
        }
        if phase == "restore" {
            expect(defaults.string(forKey: ApplicationIcon.storageKey) == "M05", "Fixture starts with a retired icon")
        }
        expect(ApplicationIcon.allCases == [.original], "Only the original application icon remains")
        let names = try FileManager.default.contentsOfDirectory(atPath: bundle.resourceURL!.appendingPathComponent("ApplicationIcons").path)
        expect(names.filter { $0.hasSuffix(".icns") } == ["Original.icns"], "No colored icon assets ship")
        expect(ApplicationIcon.original.image(in: bundle)?.isValid == true, "Original artwork decodes")
        expect(manager.restoreSystemIcon(), "Restore the native bundle icon")
        expect(defaults.string(forKey: ApplicationIcon.storageKey) == "Original", "Retired icon preference migrates to original")
        expect(try applicationURL.resourceValues(forKeys: [.customIconKey]).customIcon == nil, "Finder custom icon has been removed")
        expect(manager.restoreSystemIcon(), "Repeating the migration is safe")
        let invalid = ApplicationIconManager(defaults: defaults, applicationURL: applicationURL.appendingPathComponent("Missing.app"))
        expect(!invalid.restoreSystemIcon(), "An invalid target does not report success")
        defaults.removePersistentDomain(forName: suite)
        print("ApplicationIconTests passed: original asset only, legacy icon removal, native icon restoration")
    }

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
