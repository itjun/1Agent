import AppKit
import SwiftUI

enum ShellStyle: String, CaseIterable, Identifiable {
    case automatic
    case classic
    case transparent

    static let storageKey = "appearance.shellStyle"
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .classic: "Classic"
        case .transparent: "Transparent"
        }
    }

    static func stored(defaults: UserDefaults = .standard) -> ShellStyle {
        ShellStyle(rawValue: defaults.string(forKey: ShellStyle.storageKey) ?? "") ?? .automatic
    }

    func usesTransparency(isTransparencyReduced: Bool) -> Bool {
        // 显式透明同样尊重系统辅助功能，避免降低文字的可读性。
        self != .classic && !isTransparencyReduced
    }

    static var isTransparent: Bool {
        ShellStyle.stored().usesTransparency(
            isTransparencyReduced: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
    }
}

enum ShellLayout {
    static let contentRadius: CGFloat = 14
    static let paneInset: CGFloat = 6
    static let terminalOpacity: Double = 0.82
    static let fileOpacity: Double = 0.90

    static func contentFrame(_ frame: CGRect, isFloating: Bool) -> CGRect {
        guard isFloating else { return frame }
        let inset = min(ShellLayout.paneInset, max(0, (min(frame.width, frame.height) - 1) / 2))
        return frame.insetBy(dx: inset, dy: inset)
    }
}

private struct TransparentShellKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isShellTransparent: Bool {
        get { self[TransparentShellKey.self] }
        set { self[TransparentShellKey.self] = newValue }
    }
}

/// 只给背景加材质，不对整窗或文字设置 alpha。
struct ShellBackdrop: NSViewRepresentable {
    var isTransparent: Bool
    var color: NSColor

    func makeNSView(context: Context) -> ShellBackdropView {
        ShellBackdropView()
    }

    func updateNSView(_ view: ShellBackdropView, context: Context) {
        view.isTransparent = isTransparent
        view.tintColor = color
        view.applyStyle()
    }
}

final class ShellBackdropView: NSVisualEffectView {
    var isTransparent = false
    var tintColor = NSColor.windowBackgroundColor

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyStyle()
    }

    func applyStyle() {
        material = .sidebar
        blendingMode = .behindWindow
        state = .active
        isEmphasized = false
        wantsLayer = true
        // 材质层由系统绘制；配色叠层交给 SwiftUI，避免被材质重新覆盖。
        layer?.backgroundColor = (isTransparent ? NSColor.clear : tintColor).cgColor
        window?.isOpaque = !isTransparent
        window?.backgroundColor = isTransparent ? .clear : tintColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 共享文件面板与终端的圆角、边界；经典模式仍铺满原有矩形。
struct FloatingContentSurface: ViewModifier {
    @Environment(\.isShellTransparent) private var isTransparent
    @Environment(\.windowChrome) private var chrome

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: isTransparent ? ShellLayout.contentRadius : 0, style: .continuous)
        content
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(chrome.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08), lineWidth: isTransparent ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(isTransparent ? (chrome.isDark ? 0.16 : 0.07) : 0), radius: 3, y: 2)
    }
}
