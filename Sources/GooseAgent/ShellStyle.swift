import AppKit
import QuartzCore
import SwiftUI

enum ShellStyle {
    // 窗口统一使用原生材质，旧的外壳选项不再影响显示。
    // 系统“减少透明度”仍提供实色回退。
    static var isTransparent: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}

enum ShellLayout {
    static let contentRadius: CGFloat = 14
    /// 工作区外缘与相邻悬浮面板共用同一间距。
    static let workspaceInset: CGFloat = Theme.Space.s
    static let paneInset: CGFloat = 0
    static let paneVerticalInset: CGFloat = 0
    static let compactTitlebarHeight: CGFloat = 32
    static let compactHeaderHeight: CGFloat = 32
    static let titlebarActionWidth: CGFloat = 48
    static let terminalOpacity: Double = 0.96
    static let fileOpacity: Double = 0.98
    static let lightBackdropOpacity: CGFloat = 0.90
    static let darkBackdropOpacity: CGFloat = 0.88
    static let lightGlowOpacity: CGFloat = 0.10
    static let darkGlowOpacity: CGFloat = 0.04
    // 整窗共用垂直渐变；同一高度的左右侧栏不因各自宽高或光晕产生色差。
    static let backdropLocations: [CGFloat] = [0, 0.55, 1]
    static let glowEndY: CGFloat = 0.55
    static let shadowRadius: CGFloat = 4
    static let shadowOffset: CGFloat = 2
    static let shadowOpacity: Double = 0.14

    static func paneFrames(of node: PaneNode, in bounds: CGRect, isFloating: Bool) -> [UUID: CGRect] {
        let frames = PaneLayout.frames(of: node, in: bounds)
        guard isFloating else { return frames }
        // 原生分隔占 1 pt，两侧各退半步，保留拖动中心和原有分屏比例。
        let inset = max(0, (ShellLayout.workspaceInset - 1) / 2)
        return frames.mapValues { frame in
            let horizontal = min(inset, max(0, (frame.width - 1) / 2))
            let vertical = min(inset, max(0, (frame.height - 1) / 2))
            let left = frame.minX > bounds.minX + 0.5 ? horizontal : 0
            let right = frame.maxX < bounds.maxX - 0.5 ? horizontal : 0
            let top = frame.minY > bounds.minY + 0.5 ? vertical : 0
            let bottom = frame.maxY < bounds.maxY - 0.5 ? vertical : 0
            return CGRect(x: frame.minX + left, y: frame.minY + top,
                          width: frame.width - left - right, height: frame.height - top - bottom)
        }
    }

    static func contentFrame(_ frame: CGRect, isFloating: Bool) -> CGRect {
        guard isFloating else { return frame }
        let horizontal = min(ShellLayout.paneInset, max(0, (frame.width - 1) / 2))
        let vertical = min(ShellLayout.paneVerticalInset, max(0, (frame.height - 1) / 2))
        return frame.insetBy(dx: horizontal, dy: vertical)
    }
}

private struct TransparentShellKey: EnvironmentKey {
    static let defaultValue = false
}

private struct WorkspaceTitlebarLeadingInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// 收起左栏后，首个面板标题为红绿灯和悬停按钮保留横向空间。
    var workspaceTitlebarLeadingInset: CGFloat {
        get { self[WorkspaceTitlebarLeadingInsetKey.self] }
        set { self[WorkspaceTitlebarLeadingInsetKey.self] = newValue }
    }

    var isShellTransparent: Bool {
        get { self[TransparentShellKey.self] }
        set { self[TransparentShellKey.self] = newValue }
    }
}

/// 只给背景加材质，不对整窗或文字设置 alpha。
struct ShellBackdrop: NSViewRepresentable {
    var isTransparent: Bool
    var isDark: Bool
    var preset: AppThemePreset = AppTheme.stored()

    func makeNSView(context: Context) -> ShellBackdropView {
        ShellBackdropView()
    }

    func updateNSView(_ view: ShellBackdropView, context: Context) {
        view.isTransparent = isTransparent
        view.isDark = isDark
        view.preset = preset
        view.applyStyle()
    }
}

final class ShellBackdropView: NSView {
    var isTransparent = false
    var isDark = false
    var preset = AppTheme.stored()
    private let wallpaperView = DesktopWallpaperView()
    private let materialView = NSVisualEffectView()
    private let washView = NSView()
    private let gradientLayer = CAGradientLayer()
    private let glowLayer = CAGradientLayer()
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 先铺壁纸，再在窗内模糊；不采样窗口后面的其他应用。
        materialView.material = .sidebar
        materialView.blendingMode = .withinWindow
        materialView.state = .active
        washView.wantsLayer = true
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.locations = ShellLayout.backdropLocations.map { NSNumber(value: Double($0)) }
        glowLayer.startPoint = CGPoint(x: 0.5, y: 1)
        glowLayer.endPoint = CGPoint(x: 0.5, y: 1 - ShellLayout.glowEndY)
        washView.layer?.addSublayer(gradientLayer)
        washView.layer?.addSublayer(glowLayer)
        for view in [wallpaperView, materialView, washView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyStyle()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = washView.bounds
        glowLayer.frame = washView.bounds
        CATransaction.commit()
    }

    func applyStyle() {
        wantsLayer = true
        appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        let colors = AppTheme.colors(isDark: isDark, preset: preset)
        let fallback = NSColor(colors.color(colors.gradient[1]))
        let opacity = isTransparent ? (isDark ? ShellLayout.darkBackdropOpacity : ShellLayout.lightBackdropOpacity) : 1
        let glow = NSColor(colors.color(colors.glow))
            .withAlphaComponent(isDark ? ShellLayout.darkGlowOpacity : ShellLayout.lightGlowOpacity)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 实色底板阻止其他窗口内容穿透；只在材质下采样桌面壁纸。
        layer?.backgroundColor = fallback.cgColor
        gradientLayer.colors = colors.gradient.map { NSColor(colors.color($0)).withAlphaComponent(opacity).cgColor }
        glowLayer.colors = [glow.cgColor, glow.withAlphaComponent(0).cgColor]
        gradientLayer.frame = washView.bounds
        glowLayer.frame = washView.bounds
        CATransaction.commit()
        let wasHidden = wallpaperView.isHidden
        wallpaperView.isHidden = !isTransparent
        materialView.isHidden = !isTransparent
        if wasHidden && isTransparent { wallpaperView.refresh() }
        window?.isOpaque = !isTransparent
        window?.backgroundColor = isTransparent ? .clear : fallback
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum DesktopWallpaperLayout {
    static func imageFrame(imageSize: CGSize, screenFrame: CGRect, scaling: NSImageScaling,
                           allowsClipping: Bool) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return screenFrame }
        if scaling == .scaleAxesIndependently { return screenFrame }
        var scale: CGFloat = 1
        if scaling != .scaleNone {
            let ratios = (screenFrame.width / imageSize.width, screenFrame.height / imageSize.height)
            scale = allowsClipping ? max(ratios.0, ratios.1) : min(ratios.0, ratios.1)
            if scaling == .scaleProportionallyDown { scale = min(1, scale) }
        }
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

/// 只读取系统配置的壁纸，不截屏。按屏幕坐标绘制，移动窗口时壁纸保持与桌面对齐。
private final class DesktopWallpaperView: NSView {
    private struct Wallpaper {
        var screenFrame: CGRect
        var image: NSImage?
        var scaling: NSImageScaling
        var allowsClipping: Bool
        var fill: NSColor
    }
    private var wallpapers: [Wallpaper] = []
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 8
        return cache
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let notifications = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            notifications.addObserver(self, selector: #selector(windowGeometryChanged(_:)), name: name, object: nil)
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didChangeScreenParametersNotification] {
            notifications.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh() }
    }

    @objc private func windowGeometryChanged(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow, changedWindow === window else { return }
        needsDisplay = true
    }

    @objc func refresh() {
        guard window != nil, !isHidden else { return }
        let workspace = NSWorkspace.shared
        wallpapers = NSScreen.screens.map { screen in
            let options = workspace.desktopImageOptions(for: screen) ?? [:]
            var image: NSImage?
            if let url = workspace.desktopImageURL(for: screen) {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let key = "\(url.absoluteString):\(modified?.timeIntervalSince1970 ?? 0)" as NSString
                image = Self.images.object(forKey: key)
                if image == nil, let loaded = NSImage(contentsOf: url) {
                    Self.images.setObject(loaded, forKey: key)
                    image = loaded
                }
            }
            return Wallpaper(screenFrame: screen.frame, image: image,
                scaling: (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) } ?? .scaleProportionallyUpOrDown,
                allowsClipping: (options[.allowClipping] as? NSNumber)?.boolValue ?? true,
                fill: (options[.fillColor] as? NSColor)?.withAlphaComponent(1) ?? .windowBackgroundColor)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        guard let window else { return }
        for wallpaper in wallpapers {
            let screenFrame = convert(window.convertFromScreen(wallpaper.screenFrame), from: nil)
            guard screenFrame.intersects(dirtyRect) else { continue }
            NSGraphicsContext.saveGraphicsState()
            screenFrame.clip()
            wallpaper.fill.setFill()
            screenFrame.fill()
            if let image = wallpaper.image {
                let frame = DesktopWallpaperLayout.imageFrame(imageSize: image.size, screenFrame: screenFrame,
                    scaling: wallpaper.scaling, allowsClipping: wallpaper.allowsClipping)
                image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// 共享文件面板与终端的圆角、边界；减少透明度时使用实色回退。
struct FloatingContentSurface: ViewModifier {
    @Environment(\.isShellTransparent) private var isTransparent
    @Environment(\.windowChrome) private var chrome

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: isTransparent ? ShellLayout.contentRadius : 0, style: .continuous)
        content
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(chrome.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.045), lineWidth: isTransparent ? 0.5 : 0)
                    .allowsHitTesting(false)
            }
            .shadow(color: isTransparent ? Color(nsColor: .shadowColor).opacity(ShellLayout.shadowOpacity) : .clear,
                    radius: ShellLayout.shadowRadius, y: ShellLayout.shadowOffset)
    }
}
