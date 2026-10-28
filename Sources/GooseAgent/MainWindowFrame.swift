import CoreGraphics

/// Where the main window opens: 80% of the screen, centered where possible.
/// A saved frame is not restored. Shift it inside the visible area when it fits.
enum MainWindowFrame {
    static let scale: CGFloat = 0.8
    static let minimumSize = CGSize(width: 880, height: 520)

    static func frame(screen: CGRect, visible: CGRect) -> CGRect {
        let width = (screen.width * scale).rounded(.down)
        let height = (screen.height * scale).rounded(.down)
        let x = centered(screen.minX, screen.width, width, visible.minX, visible.width)
        let y = centered(screen.minY, screen.height, height, visible.minY, visible.height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Split the spare space on both sides. Clamp only when the menu bar or Dock would be covered.
    private static func centered(_ screenStart: CGFloat, _ screenLength: CGFloat, _ length: CGFloat, _ visibleStart: CGFloat, _ visibleLength: CGFloat) -> CGFloat {
        var origin = screenStart + ((screenLength - length) / 2).rounded(.down)
        guard length <= visibleLength else { return origin }
        if origin < visibleStart { origin = visibleStart }
        let visibleEnd = visibleStart + visibleLength
        if origin + length > visibleEnd { origin = visibleEnd - length }
        return origin
    }
}
