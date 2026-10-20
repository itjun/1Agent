import CoreGraphics

/// Where the Settings window opens: 50% of the window it was opened from (or of the screen when
/// there is none), centered on it, never smaller than the minimum and never off the visible screen.
enum SettingsWindowFrame {
    static let scale: CGFloat = 0.5

    static func frame(anchor: CGRect, visible: CGRect, minSize: CGSize) -> CGRect {
        var width = max(anchor.width * scale, minSize.width)
        var height = max(anchor.height * scale, minSize.height)
        width = min(width, visible.width)
        height = min(height, visible.height)

        var x = anchor.midX - width / 2
        var y = anchor.midY - height / 2
        x = min(max(x, visible.minX), visible.maxX - width)
        y = min(max(y, visible.minY), visible.maxY - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(.down), height: height.rounded(.down))
    }
}
