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
    static let terminalOpacity: Double = 0.84
    static let fileOpacity: Double = 0.98
    static let backdropTintOpacity: CGFloat = 0.25
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 左右侧栏和窗格间隙共用同一张系统材质底板。
        material = .sidebar
        washView.wantsLayer = true
        washView.frame = bounds
        washView.autoresizingMask = [.width, .height]
        addSubview(washView)
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
        appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        let fallback = NSColor.windowBackgroundColor
        layer?.backgroundColor = nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let wash = NSColor.windowBackgroundColor.withAlphaComponent(ShellLayout.backdropTintOpacity)
            washView.layer?.backgroundColor = (isTransparent ? wash : fallback).cgColor
        }
        window?.isOpaque = !isTransparent
        window?.backgroundColor = isTransparent ? .clear : fallback
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
