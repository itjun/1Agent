import AppKit
import Quartz
import SwiftUI

/// The body of a pane that is not a terminal.
struct PaneContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    let tab: TerminalTab

    var body: some View {
        switch tab.content {
        case .terminal:
            EmptyView()
        case .preview(let path):
            FilePreviewPane(url: URL(fileURLWithPath: path)) {
                model.notePaneFocused(tab.id, in: window)
            }
        }
    }
}

/// Quick Look of one local file: images, SVG, PDF, text, video. Fills the pane.
struct FilePreviewPane: NSViewRepresentable {
    let url: URL
    var onFocus: () -> Void

    func makeNSView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.onFocus = onFocus
        view.show(url)
        return view
    }

    func updateNSView(_ view: PreviewContainerView, context: Context) {
        view.onFocus = onFocus
        view.show(url)
    }

    static func dismantleNSView(_ view: PreviewContainerView, coordinator: ()) {
        view.close()
    }
}

final class PreviewContainerView: NSView {
    var onFocus: (() -> Void)?
    private var preview: QLPreviewView?
    private var shownURL: URL?

    func show(_ url: URL) {
        guard url != shownURL else { return }
        shownURL = url
        if preview == nil, let created = QLPreviewView(frame: bounds, style: .normal) {
            created.autoresizingMask = [.width, .height]
            created.shouldCloseWithWindow = false
            addSubview(created)
            preview = created
        }
        preview?.previewItem = url as NSURL
    }

    func close() {
        preview?.close()
        preview = nil
    }

    /// Any click inside makes this pane the selected one; Quick Look still gets the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, NSApp.currentEvent?.type == .leftMouseDown {
            onFocus?()
        }
        return hit
    }
}
