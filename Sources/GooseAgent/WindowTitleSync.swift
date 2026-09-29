import AppKit
import QuartzCore
import SwiftUI

/// Keeps Mission Control title in sync while forcing a transparent, title-less
/// titlebar so SwiftUI can draw one custom title without system duplication.
struct WindowTitleSync: NSViewRepresentable {
    var title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.apply(title: title, to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(title: title, to: view.window) }
    }

    private static func apply(title: String, to window: NSWindow?) {
        guard let window else { return }
        if window.title != title {
            window.title = title
        }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Keep false so SwiftUI controls in the titlebar band (e.g. New Tab) receive clicks.
        // Pane titles still move the window through their own drag handles.
        window.isMovableByWindowBackground = false
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.toolbar = nil
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .none
        }
        // Hide any leftover separator view the system still inserts under the traffic lights.
        Self.hideSeparatorViews(in: window.contentView?.superview)
    }

    private static func hideSeparatorViews(in root: NSView?) {
        guard let root else { return }
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            let name = String(describing: type(of: view))
            if name.contains("Separator") || name.contains("TitlebarSeparator") {
                view.isHidden = true
                view.alphaValue = 0
            }
            stack.append(contentsOf: view.subviews)
        }
    }
}
