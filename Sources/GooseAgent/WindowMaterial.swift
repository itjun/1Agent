import AppKit
import SwiftUI

/// One source of truth for all windows and the embedded terminal renderer.
@MainActor
final class WindowMaterial: ObservableObject {
    static let shared = WindowMaterial()
    @Published private(set) var settings = WindowMaterialSettings.load()
    @Published private(set) var reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    private var observers: [NSObjectProtocol] = []

    var opacity: Double { settings.effectiveOpacity(reduceTransparency: reduceTransparency) }
    var terminalOpacity: Double { settings.terminalOpacity(reduceTransparency: reduceTransparency) }
    var isAcrylic: Bool { opacity < 1 }
    var isMica: Bool { settings.style == .mica && !reduceTransparency }

    func chrome(isDark: Bool, context: MicaWindowContext) -> WindowChrome {
        let choice = isDark ? ThemePreview.shared.effectiveDark() : ThemePreview.shared.effectiveLight()
        guard isMica, let wallpaper = context.wallpaper,
              let base = RGBColor(ghosttyHex: choice.definition.background) else { return choice.chrome() }
        let tinted = MicaColor.background(base: MicaColor(red: base.red, green: base.green, blue: base.blue), wallpaper: wallpaper, active: context.isActive)
        return WindowChrome(theme: choice.definition, backgroundOverride: RGBColor(red: tinted.red, green: tinted.green, blue: tinted.blue))
    }

    private init() {
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    func refresh() {
        let previousOpacity = opacity
        let previousTerminalOpacity = terminalOpacity
        let next = WindowMaterialSettings.load()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if settings != next { settings = next }
        if reduceTransparency != reduced { reduceTransparency = reduced }
        if previousOpacity != opacity || previousTerminalOpacity != terminalOpacity {
            for window in NSApp.windows where window.identifier == MainWindowManager.windowID || window.identifier == SettingsWindowController.windowID {
                configure(window)
            }
            GhosttyRuntime.applyTerminalSettings()
        }
    }

    func configure(_ window: NSWindow) {
        window.isOpaque = !isAcrylic
        window.backgroundColor = isAcrylic ? .clear : .windowBackgroundColor
    }
}

/// A single native backdrop per window. Theme tint is drawn by the foreground surfaces, so the
/// terminal can keep its text fully opaque while only its background blends with this material.
struct AcrylicBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = AcrylicEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        let grain = AcrylicGrainView(frame: view.bounds)
        grain.autoresizingMask = [.width, .height]
        view.addSubview(grain)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private final class AcrylicEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A cached, tiled texture; no animation or per-frame random generation.
private final class AcrylicGrainView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static let texture: NSImage = {
        let size = 128
        let image = NSImage(size: NSSize(width: size, height: size))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32),
              let bytes = bitmap.bitmapData else { return image }
        var seed: UInt32 = 0x1A6E17
        for pixel in 0 ..< size * size {
            seed = seed &* 1664525 &+ 1013904223
            let channel: UInt8 = seed & 0x80000000 == 0 ? 0 : 6
            let offset = pixel * 4
            // Premultiplied black/white at very low alpha.
            bytes[offset] = channel
            bytes[offset + 1] = channel
            bytes[offset + 2] = channel
            bytes[offset + 3] = 6
        }
        image.addRepresentation(bitmap)
        return image
    }()

    override func draw(_ dirtyRect: NSRect) {
        NSColor(patternImage: Self.texture).setFill()
        dirtyRect.fill()
    }
}
