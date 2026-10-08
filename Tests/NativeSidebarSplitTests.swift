import AppKit
import SwiftUI

private final class Probe {
    var created = 0
    weak var field: NSTextField?
}

private struct InputProbe: NSViewRepresentable {
    let probe: Probe
    var output: String
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: output)
        probe.created += 1
        probe.field = field
        return field
    }
    func updateNSView(_ view: NSTextField, context: Context) { view.stringValue = output }
}

private final class CanvasGeometryProbe: ObservableObject {
    @Published var glass = true
    var headers: [Int: NSView] = [:]
}

private struct HeaderProbe: NSViewRepresentable {
    let probe: CanvasGeometryProbe
    let index: Int
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        probe.headers[index] = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Match RootView's nested hosting and full-size content layout, including the four pane headers.
/// Testing the split controller directly misses the representable's intermediate container.
private struct EmbeddedSplitFixture: View {
    @ObservedObject var probe: CanvasGeometryProbe
    var body: some View {
        NativeSidebarSplit(glass: probe.glass, width: 260, minimumWidth: 200,
                           maximumWidth: 420, defaultWidth: 260) {
            Color.clear.ignoresSafeArea(edges: .top)
        } detail: {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(0..<4) { index in
                        HeaderProbe(probe: probe, index: index)
                            .frame(width: geo.size.width / 2, height: 22)
                            .position(x: geo.size.width * (index % 2 == 0 ? 0.25 : 0.75),
                                      y: (index < 2 ? 0 : geo.size.height / 2) + 11)
                    }
                }
            }
            .ignoresSafeArea(edges: .top)
        }
        .frame(minWidth: 880, minHeight: 520)
        .ignoresSafeArea(edges: .top)
    }
}

/// Settings lets AppKit extend both columns into the titlebar while their controls respect it.
private struct EmbeddedSettingsFixture: View {
    @ObservedObject var probe: CanvasGeometryProbe
    var body: some View {
        NativeSidebarSplit(glass: probe.glass, width: 180, minimumWidth: 180,
                           maximumWidth: 180, defaultWidth: 180) {
            VStack(spacing: 0) {
                HeaderProbe(probe: probe, index: 0).frame(height: 24)
                Spacer(minLength: 0)
            }
        } detail: {
            VStack(spacing: 0) {
                HeaderProbe(probe: probe, index: 1).frame(height: 24)
                Spacer(minLength: 0)
            }
            .background(Color.white.ignoresSafeArea())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
    }
}

@main
struct NativeSidebarSplitTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let probe = Probe()
        let sidebarProbe = Probe()
        let controller = NativeSidebarSplitController(
            sidebar: InputProbe(probe: sidebarProbe, output: "Workspace"),
            detail: InputProbe(probe: probe, output: "output 0")
        )
        // Representables configure before receiving a window/frame.
        controller.configure(glass: true, width: 310, minimum: 200, maximum: 420,
                             defaultWidth: 260, onWidthChange: { _ in })
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        precondition(abs(controller.sidebarHost.view.frame.width - 310) < 1, "initial saved width before window attachment")
        let originalDetail = controller.detailHost
        let originalSidebar = controller.sidebarHost
        let originalDetailItem = controller.splitViewItems[1]
        var reports: [CGFloat] = []
        func configure(_ glass: Bool, _ width: CGFloat = 260, _ fixed: Bool = false) {
            controller.configure(glass: glass, width: width, minimum: fixed ? 180 : 200,
                                 maximum: fixed ? 180 : 420, defaultWidth: fixed ? 180 : 260,
                                 onWidthChange: { reports.append($0) })
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        configure(false)
        let field = probe.field!
        precondition(window.makeFirstResponder(field), "probe must accept keyboard focus")
        let responder = window.firstResponder
        for (index, glass) in [true, false, true, false].enumerated() {
            // This is what updateNSViewController does when a stored setting changes.
            controller.detailHost.rootView = InputProbe(probe: probe, output: "output \(index + 1)")
            configure(glass)
            precondition(probe.created == 1, "SwiftUI must reuse the native input surface")
            precondition(sidebarProbe.created == 1, "sidebar content must also survive changing split items")
            precondition(field.stringValue == "output \(index + 1)", "output continues during material changes")
            precondition(controller.detailHost === originalDetail)
            precondition(controller.sidebarHost === originalSidebar)
            precondition(controller.splitViewItems[1] === originalDetailItem)
            precondition(field.window === window, "detail view must remain attached")
            precondition(window.firstResponder === responder, "input focus must survive material changes")
            precondition(controller.splitViewItems[0].behavior == (glass ? .sidebar : .default))
        }
        let sidebarField = sidebarProbe.field!
        precondition(window.makeFirstResponder(sidebarField))
        let sidebarResponder = window.firstResponder
        configure(true)
        precondition(window.firstResponder === sidebarResponder, "sidebar editing focus survives switching")
        configure(true, 340)
        precondition(controller.splitView.isVertical, "sidebar must sit beside the content")
        precondition(abs(controller.sidebarHost.view.frame.width - 340) < 1, "restored width")
        controller.splitView.setPosition(300, ofDividerAt: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        precondition(abs((reports.last ?? 0) - 300) < 1, "native divider must publish width")
        configure(false, 300)
        precondition(abs(controller.sidebarHost.view.frame.width - 300) < 1, "switch preserves dragged width")
        window.setContentSize(NSSize(width: 1400, height: 800))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        precondition(abs(controller.sidebarHost.view.frame.width - 300) < 1, "window resize preserves sidebar width")
        controller.restoreDefaultWidth()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        precondition(abs(controller.sidebarHost.view.frame.width - 260) < 1, "divider reset restores default width")
        configure(false, 100)
        precondition(abs(controller.sidebarHost.view.frame.width - 200) < 1, "minimum sidebar width")
        configure(true, 900)
        precondition(abs(controller.sidebarHost.view.frame.width - 420) < 1, "maximum sidebar width")
        configure(true, 180, true)
        precondition(abs(controller.sidebarHost.view.frame.width - 180) < 1, "fixed settings width")
        precondition(controller.splitViewItems[0].minimumThickness == controller.splitViewItems[0].maximumThickness)
        print("ok: native sidebar behaviors, stable hosts/detail item/input view/focus, width restoration and drag reporting")
        window.close()
        verifyEmbeddedCanvasGeometry()
        verifySettingsTitlebarGeometry()
    }

    @MainActor private static func verifyEmbeddedCanvasGeometry() {
        let probe = CanvasGeometryProbe()
        let host = NSHostingController(rootView: EmbeddedSplitFixture(probe: probe))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for glass in [true, false, true] {
            probe.glass = glass
            for size in [NSSize(width: 1100, height: 720), NSSize(width: 1500, height: 900),
                         NSSize(width: 880, height: 520)] {
                window.setContentSize(size)
                window.contentView?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                let content = window.contentView!
                precondition(probe.headers.count == 4)
                for index in 0..<4 {
                    let header = probe.headers[index]!
                    let rect = header.convert(header.bounds, to: content)
                    precondition(rect.minY >= -0.5, "top pane title must not extend above the window")
                    precondition(rect.maxY <= content.bounds.maxY + 0.5, "pane title stays within the window")
                    precondition(rect.minX >= 259.5, "pane title stays to the right of the sidebar")
                    precondition(rect.maxX <= content.bounds.maxX + 0.5, "pane title must not extend past the right edge")
                    if index < 2 {
                        precondition(abs(rect.minY) < 0.5, "top headers align with the full-size content top")
                    }
                    if index % 2 == 1 {
                        precondition(abs(rect.maxX - content.bounds.maxX) < 0.5, "right headers align with the content edge")
                    }
                }
            }
        }
        print("ok: embedded SwiftUI split keeps all four pane titles visible across resize and material changes")
        window.close()
    }

    @MainActor private static func verifySettingsTitlebarGeometry() {
        let probe = CanvasGeometryProbe()
        let host = NSHostingController(rootView: EmbeddedSettingsFixture(probe: probe))
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for glass in [true, false, true] {
            probe.glass = glass
            window.setContentSize(NSSize(width: 900, height: 600))
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            let content = window.contentView!
            let navigation = probe.headers[0]!
            var ancestor: NSView? = navigation
            while ancestor != nil, !(ancestor is NSSplitView) { ancestor = ancestor?.superview }
            let split = ancestor as! NSSplitView
            let splitRect = split.convert(split.bounds, to: content)
            precondition(abs(splitRect.minY) < 0.5, "settings split must include the titlebar, not only its background")
            precondition(abs(splitRect.height - content.bounds.height) < 0.5, "both settings columns span the full window height")
            let sidebar = navigation.convert(navigation.bounds, to: content)
            let detail = probe.headers[1]!.convert(probe.headers[1]!.bounds, to: content)
            let safeTop = content.safeAreaInsets.top
            precondition(sidebar.minY >= safeTop - 0.5, "navigation controls stay below the traffic lights")
            precondition(detail.minY >= safeTop - 0.5, "settings controls respect the titlebar safe area")
            precondition(abs(sidebar.maxX - 180) < 0.5, "settings sidebar keeps its fixed width")
            precondition(detail.minX >= sidebar.maxX - 0.5, "settings content stays in the right column")
        }
        print("ok: settings split extends through titlebar with safe controls and fixed sidebar in both materials")
        window.close()
    }
}
