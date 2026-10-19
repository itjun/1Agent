import AppKit

@main
enum ApplicationIconTests {
    struct Failure: Error { let message: String }

    @MainActor
    static func main() {
        do { try run() }
        catch {
            fputs("ApplicationIconTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    static func run() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        let bundle = Bundle(path: args[1])!
        let suite = args[2]
        let phase = args[3]
        let applicationURL = URL(fileURLWithPath: args[4])
        precondition(applicationURL.path.hasPrefix("/private/tmp/oneagent-app-icons."))
        let defaults = UserDefaults(suiteName: suite)!

        if phase == "save" {
            let manager = ApplicationIconManager(defaults: defaults, bundle: bundle, applicationURL: applicationURL)
            try check(manager.select(.mintCandy), "Saved icon must be applied")
            try check(finderMatches(applicationURL, manager.image(for: .mintCandy)!), "Finder must use M03 before the app exits")
            defaults.synchronize()
            print("Saved M03 for a fresh process")
            return
        }
        if phase == "restore" {
            let manager = ApplicationIconManager(defaults: defaults, bundle: bundle, applicationURL: applicationURL)
            try check(manager.selected == .mintCandy, "Fresh process must restore the saved choice instead of the original")
            try check(finderMatches(applicationURL, manager.image(for: .mintCandy)!), "Finder metadata must persist while the app is not running")
            // An installer replaces the application bundle and removes its custom icon metadata.
            try check(NSWorkspace.shared.setIcon(nil, forFile: applicationURL.path), "Simulated bundle replacement must reset Finder metadata")
            manager.applyStoredIcon()
            try check(samePixels(NSApp.applicationIconImage, manager.image(for: .mintCandy)!), "Startup must apply the restored image to AppKit")
            try check(finderMatches(applicationURL, manager.image(for: .mintCandy)!), "Startup must restore Finder after bundle replacement")
            try check(manager.select(.defaultIcon), "Fixture default must be restored after restart verification")
            defaults.removePersistentDomain(forName: suite)
            print("Fresh process verified persistent Finder metadata and restored M03 after simulated reinstall")
            return
        }

        defaults.removePersistentDomain(forName: suite)
        try check(ApplicationIcon.stored(defaults: defaults) == .original, "First launch defaults to the original white and blue icon")
        defaults.set("unknown-palette", forKey: ApplicationIcon.storageKey)
        try check(ApplicationIcon.stored(defaults: defaults) == .original, "Unknown preferences fall back to the original")
        defaults.set("M05", forKey: ApplicationIcon.storageKey)
        try check(ApplicationIcon.stored(defaults: defaults) == .peachSorbet, "Changing the default must preserve an existing M05 selection")
        defaults.removeObject(forKey: ApplicationIcon.storageKey)

        let manager = ApplicationIconManager(defaults: defaults, bundle: bundle, applicationURL: applicationURL)
        try check(ApplicationIcon.allCases.count == 11, "The original and all ten approved palettes must ship")
        try check(ApplicationIcon.macaronIcons.count == 10 && !ApplicationIcon.macaronIcons.contains(.original),
                  "All ten macaron alternatives must remain available separately from the original")
        guard let defaultURL = bundle.url(forResource: "AppIcon", withExtension: "icns"),
              let bundledDefault = NSImage(contentsOf: defaultURL),
              let originalImage = manager.image(for: .original) else {
            throw Failure(message: "The bundled default and original icon must both exist")
        }
        try check(samePixels(bundledDefault, originalImage), "The installed app's default icon must match the original settings option")
        manager.applyStoredIcon()
        try check(finderMatches(applicationURL, manager.image(for: .original)!), "First launch must apply the original icon to Finder")
        for icon in ApplicationIcon.allCases {
            guard let image = manager.image(for: icon) else { throw Failure(message: "Missing bundled asset: \(icon.rawValue)") }
            try check(image.isValid, "Bundled image must decode: \(icon.rawValue)")
            try check(manager.select(icon), "Each bundled palette must be selectable")
            try check(manager.selected == icon, "UI selection must match the applied icon")
            try check(defaults.string(forKey: ApplicationIcon.storageKey) == icon.rawValue, "Selection must persist")
            try check(samePixels(NSApp.applicationIconImage, image), "AppKit must receive \(icon.rawValue), not only a preview")
            try check(finderMatches(applicationURL, image), "Finder must show \(icon.rawValue) too")
        }
        try check(manager.select(.defaultIcon), "Restore default must apply the original")
        try check(manager.selected == .original && ApplicationIcon.stored(defaults: defaults) == .original,
                  "Restore default must save the original")
        try check(finderMatches(applicationURL, manager.image(for: .defaultIcon)!), "Restore default must synchronize Finder back to the original")

        defaults.set(ApplicationIcon.cloudSoda.rawValue, forKey: ApplicationIcon.storageKey)
        let unavailable = ApplicationIconManager(defaults: defaults, bundle: .main, applicationURL: applicationURL)
        let previousImage = NSApp.applicationIconImage
        try check(!unavailable.select(.strawberryCream), "Missing resources must not report success")
        try check(unavailable.loadFailed && unavailable.selected == .cloudSoda, "Failure must retain the previous selection")
        try check(ApplicationIcon.stored(defaults: defaults) == .cloudSoda, "Failure must not overwrite saved preferences")
        try check(samePixels(NSApp.applicationIconImage, previousImage!), "Failure must not clear the running app icon")
        let invalidTarget = applicationURL.appendingPathComponent("Missing.app")
        let rejected = ApplicationIconManager(defaults: defaults, bundle: bundle, applicationURL: invalidTarget)
        try check(!rejected.select(.strawberryCream) && rejected.finderUpdateFailed,
                  "A Finder write failure must be reported instead of claiming a synchronized change")
        try check(rejected.selected == .cloudSoda && ApplicationIcon.stored(defaults: defaults) == .cloudSoda,
                  "Finder failure must preserve the previous selection and preferences")
        try check(samePixels(NSApp.applicationIconImage, previousImage!), "Finder failure must not partially switch only the Dock")
        defaults.removePersistentDomain(forName: suite)
        print("ApplicationIconTests passed: original default, 10 alternatives, 11 Finder/Dock icons, saved M05 preservation, persistence and failure handling")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    @MainActor
    static func finderMatches(_ target: URL, _ expected: NSImage) -> Bool {
        for _ in 0..<40 {
            if samePixels(NSWorkspace.shared.icon(forFile: target.path), expected) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    /// AppKit copies/resamples ICNS representations; compare rendered content, allowing sub-level raster rounding.
    @MainActor
    static func samePixels(_ first: NSImage, _ second: NSImage) -> Bool {
        func pixels(_ image: NSImage) -> Data {
            let rect = NSRect(x: 0, y: 0, width: 256, height: 256)
            let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
                                    bytesPerRow: 256 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.clear(rect)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return Data(bytes: context.data!, count: 256 * 256 * 4)
        }
        let a = pixels(first), b = pixels(second)
        let difference = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(difference) / Double(a.count) < 0.5
    }
}
