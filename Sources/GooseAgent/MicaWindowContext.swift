import AppKit
import SwiftUI

@MainActor
private final class MicaWallpaperCache {
    static let shared = MicaWallpaperCache()
    private struct Entry {
        var modified: Date?
        var color: MicaColor?
    }
    private var entries: [URL: Entry] = [:]

    func color(for screen: NSScreen) async -> MicaColor? {
        let fallback = (NSWorkspace.shared.desktopImageOptions(for: screen)?[.fillColor] as? NSColor)?.usingColorSpace(.sRGB)
        let fill = fallback.map { MicaColor(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent) }
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen), url.isFileURL else { return fill }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached = entries[url], cached.modified == modified { return cached.color ?? fill }
        let color = await Task.detached(priority: .utility) { MicaWallpaper.sample(url) }.value
        entries[url] = Entry(modified: modified, color: color)
        return color ?? fill
    }
}

/// Focus and wallpaper are scoped to each window, including Settings. Moving a window to a
/// different monitor picks up that monitor's wallpaper rather than always using the main screen.
@MainActor
final class MicaWindowContext: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var wallpaper: MicaColor?
    private weak var window: NSWindow?
    private var enabled = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var sampleTask: Task<Void, Never>?

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
        timer?.invalidate()
        sampleTask?.cancel()
    }

    func attach(to window: NSWindow?, enabled: Bool) {
        guard self.window !== window || self.enabled != enabled else { return }
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        timer?.invalidate()
        timer = nil
        sampleTask?.cancel()
        self.window = window
        self.enabled = enabled
        guard enabled, let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification] {
            observe(center, name: name, object: window)
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSApplication.didChangeScreenParametersNotification] {
            observe(center, name: name, object: nil)
        }
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // AppKit has no public wallpaper-change notification. Check the URL/file date infrequently;
        // unchanged wallpaper is served from cache and does not require another image decode.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func observe(_ center: NotificationCenter, name: Notification.Name, object: Any?) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observers.append((center, token))
    }

    private func refresh() {
        guard enabled, let window else { return }
        let active = window.isKeyWindow && NSApp.isActive
        if isActive != active { isActive = active }
        guard let screen = window.screen ?? NSScreen.main else { return }
        sampleTask?.cancel()
        sampleTask = Task { [weak self] in
            let color = await MicaWallpaperCache.shared.color(for: screen)
            guard !Task.isCancelled, let self else { return }
            if wallpaper != color { wallpaper = color }
        }
    }
}

struct MicaWindowReader: NSViewRepresentable {
    let context: MicaWindowContext
    let enabled: Bool

    func makeNSView(context: Context) -> NSView {
        MicaWindowProbe()
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let probe = view as? MicaWindowProbe else { return }
        probe.materialContext = self.context
        probe.enabled = enabled
        probe.bindLater()
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? MicaWindowProbe)?.materialContext?.attach(to: nil, enabled: false)
    }
}

private final class MicaWindowProbe: NSView {
    weak var materialContext: MicaWindowContext?
    var enabled = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bindLater()
    }

    func bindLater() {
        // Avoid publishing window state during a SwiftUI view update.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            materialContext?.attach(to: window, enabled: enabled)
        }
    }
}
