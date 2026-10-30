import AppKit
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
    static let lightBackdropLiftOpacity: CGFloat = 0.55
    static let lightAtmosphereOpacity: CGFloat = 0.18
    static let darkAtmosphereOpacity: CGFloat = 0.035

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

    func makeNSView(context: Context) -> ShellBackdropView {
        ShellBackdropView()
    }

    func updateNSView(_ view: ShellBackdropView, context: Context) {
        view.isTransparent = isTransparent
        view.isDark = isDark
        view.applyStyle()
    }
}

final class ShellBackdropView: NSVisualEffectView {
    var isTransparent = false
    var isDark = false
    private let washView = NSView()
    private let atmosphereView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 与 Surge 的底板一致：headerView 材质叠加淡色图片。
        // 使用公开 API，保留系统模糊、外观切换和辅助功能行为。
        material = .headerView
        washView.wantsLayer = true
        washView.frame = bounds
        washView.autoresizingMask = [.width, .height]
        addSubview(washView)
        atmosphereView.image = NSImage(named: "WindowAtmosphere")
        atmosphereView.imageScaling = .scaleAxesIndependently
        atmosphereView.frame = bounds
        atmosphereView.autoresizingMask = [.width, .height]
        atmosphereView.setAccessibilityElement(false)
        atmosphereView.setAccessibilityHidden(true)
        addSubview(atmosphereView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyStyle()
    }

    func applyStyle() {
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        isEmphasized = false
        wantsLayer = true
        let fallback = NSColor.windowBackgroundColor
        layer?.backgroundColor = nil
        // 浅色底板提亮但不盖住系统模糊；深色直接使用原生材质。
        let wash = isDark ? NSColor.clear : NSColor.white.withAlphaComponent(ShellLayout.lightBackdropLiftOpacity)
        washView.layer?.backgroundColor = (isTransparent ? wash : fallback).cgColor
        atmosphereView.isHidden = !isTransparent
        atmosphereView.alphaValue = isDark ? ShellLayout.darkAtmosphereOpacity : ShellLayout.lightAtmosphereOpacity
        window?.isOpaque = !isTransparent
        window?.backgroundColor = isTransparent ? .clear : fallback
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 共享文件面板与终端的圆角、边界；减少透明度时使用实色回退。
struct FloatingContentSurface: ViewModifier {
    @Environment(\.isShellTransparent) private var isTransparent
    @Environment(\.windowChrome) private var chrome
    @Environment(\.accessibilityReduceMotion) private var isMotionReduced
    var isSelected = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: isTransparent ? ShellLayout.contentRadius : 0, style: .continuous)
        let shadow = isSelected
            ? chrome.accent.opacity(chrome.isDark ? 0.20 : 0.16)
            : Color.black.opacity(chrome.isDark ? 0.12 : 0.045)
        content
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(chrome.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.045), lineWidth: isTransparent ? 0.5 : 0)
                    .allowsHitTesting(false)
            }
            .animation(isMotionReduced ? nil : .easeInOut(duration: Theme.Motion.terminalDuration)) { surface in
                surface.shadow(color: isTransparent ? shadow : .clear,
                               radius: isSelected ? 6 : 4, y: 2)
            }
    }
}
