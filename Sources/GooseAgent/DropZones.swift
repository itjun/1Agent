import AppKit
import QuartzCore

/// The drop circles drawn over a terminal while Finder files hover it. A subview of the terminal,
/// because the terminal's metal layer covers any SwiftUI view placed above it.
final class DropZoneOverlay: NSView {
    private var shapes: [DropZone: CAShapeLayer] = [:]
    private var labels: [DropZone: CATextLayer] = [:]
    private var transfer = true
    private var remote = false
    private(set) var active: DropZone?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `remote` names the transfer zone Upload; `transfer` false leaves that zone out.
    func configure(transfer: Bool, remote: Bool) {
        guard transfer != self.transfer || remote != self.remote || shapes.isEmpty else { return }
        self.transfer = transfer
        self.remote = remote
        rebuild()
    }

    func zone(at point: NSPoint) -> DropZone {
        let local = convert(point, from: nil)
        return DropZoneLayout.zone(at: local, in: bounds.size, transfer: transfer)
    }

    func highlight(_ zone: DropZone?) {
        guard zone != active else { return }
        active = zone
        restyle()
    }

    override func layout() {
        super.layout()
        rebuild()
    }

    private func rebuild() {
        shapes.values.forEach { $0.removeFromSuperlayer() }
        labels.values.forEach { $0.removeFromSuperlayer() }
        shapes = [:]
        labels = [:]
        guard let root = layer, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        for zone in DropZoneLayout.zones(transfer: transfer) {
            let shape = CAShapeLayer()
            let path = CGMutablePath()
            path.addLines(between: DropZoneLayout.outline(of: zone, in: bounds.size))
            path.closeSubpath()
            shape.path = path
            shape.lineWidth = 1
            root.addSublayer(shape)
            shapes[zone] = shape

            let label = CATextLayer()
            label.contentsScale = scale
            label.alignmentMode = .center
            label.fontSize = DropZoneLayout.labelFontSize
            label.font = NSFont.systemFont(ofSize: DropZoneLayout.labelFontSize, weight: .semibold)
            label.cornerRadius = Theme.Radius.row
            let title = zone.title(remote: remote)
            let textSize = (title as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: DropZoneLayout.labelFontSize, weight: .semibold),
            ])
            let width = ceil(textSize.width) + DropZoneLayout.labelPaddingX * 2
            let height = ceil(textSize.height) + DropZoneLayout.labelPaddingY * 2
            let center = DropZoneLayout.labelCenter(of: zone, in: bounds.size)
            label.frame = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
            label.string = title
            root.addSublayer(label)
            labels[zone] = label
        }
        restyle()
    }

    private func restyle() {
        let chrome = WindowChrome.resolve(isDark: AppearanceDriver.shared.isDark)
        let accent = NSColor(chrome.accent)
        let background = NSColor(chrome.background)
        let text = NSColor(chrome.text)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (zone, shape) in shapes {
            let on = zone == active
            shape.fillColor = accent.withAlphaComponent(on ? DropZoneLayout.activeFillAlpha : DropZoneLayout.restingFillAlpha).cgColor
            shape.strokeColor = accent.withAlphaComponent(DropZoneLayout.strokeAlpha).cgColor
        }
        for (zone, label) in labels {
            let on = zone == active
            label.backgroundColor = (on ? accent : background).cgColor
            label.foregroundColor = (on ? background : text).cgColor
            label.borderColor = accent.withAlphaComponent(DropZoneLayout.strokeAlpha).cgColor
            label.borderWidth = on ? 0 : 1
        }
        CATransaction.commit()
    }
}
