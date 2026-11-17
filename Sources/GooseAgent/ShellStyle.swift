import AppKit
import QuartzCore
import SwiftUI

enum ShellStyle {
    // 系统透明度偏好仅影响次级控件；主工作区始终使用不透明的主题底板。
    // 系统“减少透明度”仍提供实色回退。
    static var isTransparent: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}

/// 只用于操作区；正文保持不透明，系统减少透明度时也使用同一主题实色。
struct ThemeGlassSurface: ViewModifier {
    @Environment(\.windowChrome) private var chrome
    @Environment(\.accessibilityReduceTransparency) private var isTransparencyReduced
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if isTransparencyReduced || contrast == .increased {
            content.background(chrome.sidebarBackground)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(chrome.sidebarBackground.opacity(0.55)),
                                in: .rect(cornerRadius: 0))
        } else {
            content.background(chrome.sidebarBackground.opacity(0.65))
                .background(.regularMaterial)
        }
    }
}

/// 导航与工具箱标题共用原生材质，正文始终由各自的不透明底板承载。
struct SidebarMaterial: NSViewRepresentable {
    var isDark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.identifier = NSUserInterfaceItemIdentifier("workspace.sidebarMaterial")
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        view.wantsLayer = true
        let isReduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        view.layer?.backgroundColor = isReduced
            ? NSColor(WindowChrome.resolve(isDark: isDark).sidebarBackground).cgColor : nil
        view.state = isReduced ? .inactive : .followsWindowActiveState
    }
}

enum ShellLayout {
    static let contentRadius: CGFloat = 10
    /// 仅在内部卡片之间留出间距，窗口四边不留外框。
    static let workspaceInset: CGFloat = 5
    static let inactivePaneDimming: Double = 0.08
    static let paneInset: CGFloat = 0
    static let paneVerticalInset: CGFloat = 0
    static let compactTitlebarHeight: CGFloat = 32
    static let compactHeaderHeight: CGFloat = 32
    static let titlebarActionWidth: CGFloat = 48
    static let fileOpacity: Double = 0
    /// 输入框与次级按钮保留主题底色，同时透出窗口渐变。
    static let controlOpacity: Double = 0.45
    static let lightBackdropOpacity: CGFloat = 0.68
    static let darkBackdropOpacity: CGFloat = 0.64
    static let systemLightBackdropOpacity: CGFloat = 0.60
    static let systemDarkBackdropOpacity: CGFloat = 0.58
    static let lightGlowOpacity: CGFloat = 0.10
    static let darkGlowOpacity: CGFloat = 0.04
    // 整窗共用渐变色标，分屏不会重新起色。
    static let backdropLocations: [CGFloat] = [0, 0.55, 1]
    static let glowEndY: CGFloat = 0.55
    static let shadowRadius: CGFloat = 4
    static let shadowOffset: CGFloat = 2
    static let shadowOpacity: Double = 0.14

    static func backdropColors(isDark: Bool, preset: AppThemePreset = AppTheme.stored()) -> [Color] {
        let colors = AppTheme.colors(isDark: isDark, preset: preset)
        let base = RGBColor(ghosttyHex: colors.background)!
        return colors.gradient.map {
            RGBColor(ghosttyHex: $0)!.mixed(with: base, amount: isDark ? 0.25 : 0.45).color
        }
    }

    static func paneFrames(of node: PaneNode, in bounds: CGRect, isFloating: Bool) -> [UUID: CGRect] {
        // 保留布局树的分隔中心和拖动比例，只在内部边缘各退半个间隙。
        // 外沿不内缩，内容直接贴齐窗口边缘。
        let inset = (workspaceInset - 1) / 2
        return PaneLayout.frames(of: node, in: bounds).mapValues { frame in
            let left = frame.minX > bounds.minX ? inset : 0
            let top = frame.minY > bounds.minY ? inset : 0
            let right = frame.maxX < bounds.maxX ? inset : 0
            let bottom = frame.maxY < bounds.maxY ? inset : 0
            return CGRect(x: frame.minX + left, y: frame.minY + top,
                          width: max(1, frame.width - left - right),
                          height: max(1, frame.height - top - bottom))
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

/// 整窗共用主题渐变，不对窗口内容或文字设置 alpha。
struct ShellBackdrop: NSViewRepresentable {
    var isTransparent: Bool
    var isDark: Bool
    var usesTerminalBackground = false
    var preset: AppThemePreset = AppTheme.stored()
    var chrome: WindowChrome?

    func makeNSView(context: Context) -> ShellBackdropView {
        ShellBackdropView()
    }

    func updateNSView(_ view: ShellBackdropView, context: Context) {
        view.isTransparent = isTransparent
        view.isDark = isDark
        view.usesTerminalBackground = usesTerminalBackground
        view.preset = preset
        view.chrome = chrome
        view.applyStyle()
    }
}

final class ShellBackdropView: NSView {
    var isTransparent = false
    var isDark = false
    var usesTerminalBackground = false
    var preset = AppTheme.stored()
    var chrome: WindowChrome?
    private let washView = NSView()
    private let gradientLayer = CAGradientLayer()
    private let tealLayer = CAGradientLayer()
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        washView.wantsLayer = true
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.locations = ShellLayout.backdropLocations.map { NSNumber(value: Double($0)) }
        washView.layer?.addSublayer(gradientLayer)
        tealLayer.type = .radial
        tealLayer.startPoint = CGPoint(x: 0, y: 0)
        tealLayer.endPoint = CGPoint(x: 0.85, y: 0.85)
        washView.layer?.addSublayer(tealLayer)
        washView.frame = bounds
        washView.autoresizingMask = [.width, .height]
        addSubview(washView)
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
        tealLayer.frame = washView.bounds
        CATransaction.commit()
    }

    func applyStyle() {
        wantsLayer = true
        let chrome = chrome ?? WindowChrome.resolve(isDark: isDark)
        appearance = SystemTheme.appearance(isDark: chrome.isDark)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 不透明渐变承载所有岛，面板之间的间隙露出同一张底板。
        // 不采样壁纸，主题配色不会随窗口位置或其他应用变化。
        layer?.backgroundColor = NSColor(chrome.background).cgColor
        if let colors = chrome.gradientColors {
            gradientLayer.isHidden = false
            gradientLayer.startPoint = CGPoint(x: 0, y: 1)
            gradientLayer.endPoint = CGPoint(x: 1, y: 0)
            gradientLayer.colors = colors.prefix(3).map { NSColor($0).cgColor }
            let teal = NSColor(colors[3])
            tealLayer.colors = [teal.cgColor, teal.withAlphaComponent(0).cgColor]
            tealLayer.isHidden = false
        } else {
            gradientLayer.isHidden = usesTerminalBackground
            gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
            gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
            gradientLayer.colors = [chrome.sidebarBackground, chrome.background, chrome.background].map { NSColor($0).cgColor }
            tealLayer.isHidden = true
        }
        gradientLayer.frame = washView.bounds
        tealLayer.frame = washView.bounds
        CATransaction.commit()
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
        clipsToBounds = true
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

/// 工作区连续铺满；边界由分栏容器负责，不再叠加卡片外框。
struct FloatingContentSurface: ViewModifier {
    var showsShadow = true
    @Environment(\.isShellTransparent) private var isTransparent
    @Environment(\.windowChrome) private var chrome

    func body(content: Content) -> some View {
        content.clipped()
    }
}
