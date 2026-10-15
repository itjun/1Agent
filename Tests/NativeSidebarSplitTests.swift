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
    @Published var revision = 0
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
        NativeSidebarSplit(width: 260, minimumWidth: 200,
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
        NativeSidebarSplit(width: 180, minimumWidth: 180,
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

private final class DockGeometryProbe: ObservableObject {
    @Published var presentation = WorkspacePresentation()
    let terminal = Probe()
    let geometry = CanvasGeometryProbe()
}

/// Exercise the same native split, toolbar and dock hierarchy at the smallest supported size.
private struct EmbeddedDockFixture: View {
    @ObservedObject var probe: DockGeometryProbe
    var body: some View {
        GeometryReader { outer in
            NativeSidebarSplit(collapsed: WorkspaceChromeLayout.temporarilyCollapseSidebar(
                totalWidth: outer.size.width, sidebarWidth: 310, filesVisible: probe.presentation.filesVisible,
                filesWorkspace: true),
                width: 310, minimumWidth: 200, maximumWidth: 420, defaultWidth: 260) {
                HeaderProbe(probe: probe.geometry, index: 0)
                    .ignoresSafeArea(edges: .top)
            } detail: {
                VStack(spacing: 0) {
                    HeaderProbe(probe: probe.geometry, index: 1)
                        .frame(height: WorkspaceChromeLayout.toolbarHeight)
                    WorkspaceContentSplit(presentation: probe.presentation, onRatioChange: { ratio in
                        probe.presentation.filesHeightRatio = ratio
                    }) {
                        InputProbe(probe: probe.terminal, output: "live terminal")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(HeaderProbe(probe: probe.geometry, index: 4))
                    } files: {
                        HStack(spacing: WorkspaceChromeLayout.dividerWidth) {
                            HeaderProbe(probe: probe.geometry, index: 2)
                            HeaderProbe(probe: probe.geometry, index: 3)
                        }
                    }
                }
                .ignoresSafeArea(edges: .top)
            }
        }
        .frame(minWidth: 880, minHeight: 520)
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
        controller.configure(width: 310, minimum: 200, maximum: 420,
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
        func configure(_ width: CGFloat = 260, _ fixed: Bool = false) {
            controller.configure(width: width, minimum: fixed ? 180 : 200,
                                 maximum: fixed ? 180 : 420, defaultWidth: fixed ? 180 : 260,
                                 onWidthChange: { reports.append($0) })
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        configure()
        let field = probe.field!
        precondition(window.makeFirstResponder(field), "probe must accept keyboard focus")
        let responder = window.firstResponder
        for index in 0..<4 {
            // This is what updateNSViewController does when a stored setting changes.
            controller.detailHost.rootView = InputProbe(probe: probe, output: "output \(index + 1)")
            configure(260 + CGFloat(index) * 10)
            precondition(probe.created == 1, "SwiftUI must reuse the native input surface")
            precondition(sidebarProbe.created == 1, "sidebar content must also survive layout updates")
            precondition(field.stringValue == "output \(index + 1)", "output continues during content and width updates")
            precondition(controller.detailHost === originalDetail)
            precondition(controller.sidebarHost === originalSidebar)
            precondition(controller.splitViewItems[1] === originalDetailItem)
            precondition(field.window === window, "detail view must remain attached")
            precondition(window.firstResponder === responder, "input focus must survive content and width updates")
            precondition(controller.splitViewItems[0].behavior == .default)
        }
        for _ in 0..<3 {
            controller.configure(width: 310, minimum: 200, maximum: 420,
                                 defaultWidth: 260, collapsed: true, onWidthChange: { reports.append($0) })
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            precondition(controller.splitViewItems[0].isCollapsed)
            precondition(controller.detailHost === originalDetail && field.window === window,
                         "collapsing sidebar must not detach the live terminal surface")
            controller.configure(width: 310, minimum: 200, maximum: 420,
                                 defaultWidth: 260, collapsed: false, onWidthChange: { reports.append($0) })
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            precondition(abs(controller.sidebarHost.view.frame.width - 310) < 1,
                         "temporary collapse restores saved width")
            precondition(probe.created == 1 && sidebarProbe.created == 1)
        }
        let sidebarField = sidebarProbe.field!
        precondition(window.makeFirstResponder(sidebarField))
        let sidebarResponder = window.firstResponder
        configure()
        precondition(window.firstResponder === sidebarResponder, "sidebar editing focus survives updates")
        configure(340)
        precondition(controller.splitView.isVertical, "sidebar must sit beside the content")
        precondition(abs(controller.sidebarHost.view.frame.width - 340) < 1, "restored width")
        controller.splitView.setPosition(300, ofDividerAt: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        precondition(abs((reports.last ?? 0) - 300) < 1, "native divider must publish width")
        configure(300)
        precondition(abs(controller.sidebarHost.view.frame.width - 300) < 1, "update preserves dragged width")
        window.setContentSize(NSSize(width: 1400, height: 800))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        precondition(abs(controller.sidebarHost.view.frame.width - 300) < 1, "window resize preserves sidebar width")
        controller.restoreDefaultWidth()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        precondition(abs(controller.sidebarHost.view.frame.width - 260) < 1, "divider reset restores default width")
        configure(100)
        precondition(abs(controller.sidebarHost.view.frame.width - 200) < 1, "minimum sidebar width")
        configure(900)
        precondition(abs(controller.sidebarHost.view.frame.width - 420) < 1, "maximum sidebar width")
        configure(180, true)
        precondition(abs(controller.sidebarHost.view.frame.width - 180) < 1, "fixed settings width")
        precondition(controller.splitViewItems[0].minimumThickness == controller.splitViewItems[0].maximumThickness)
        print("ok: native sidebar behaviors, stable hosts/detail item/input view/focus, width restoration and drag reporting")
        window.close()
        verifyEmbeddedCanvasGeometry()
        verifySettingsTitlebarGeometry()
        verifyDockGeometry()
    }

    @MainActor private static func verifyDockGeometry() {
        let probe = DockGeometryProbe()
        let host = NSHostingController(rootView: EmbeddedDockFixture(probe: probe))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for width: CGFloat in [880, 1100, 880] {
            window.setContentSize(NSSize(width: width, height: 520))
            for workspaceMode in [false, true] {
                probe.presentation.filesLayout = workspaceMode ? .sideBySide : .belowTerminal
            for visible in [false, true, false] {
                probe.presentation.filesVisible = visible
                for ratio in [0.25, 0.60, 0.75] {
                    probe.presentation.filesHeightRatio = ratio
                    window.contentView?.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
                    let content = window.contentView!
                    let terminal = probe.terminal.field!
                    let terminalRect = terminal.convert(terminal.bounds, to: content)
                    let terminalArea = probe.geometry.headers[4]!
                    let terminalAreaRect = terminalArea.convert(terminalArea.bounds, to: content)
                    precondition(probe.terminal.created == 1, "dock toggling and resizing cannot recreate a terminal")
                    precondition(terminal.window === window)
                    let toolbar = probe.geometry.headers[1]!
                    let toolbarRect = toolbar.convert(toolbar.bounds, to: content)
                    let expectedCollapse = visible && width < 915
                    precondition(abs(toolbarRect.minX - (expectedCollapse ? 0 : 311)) < 2,
                                 "native geometry must collapse and restore the saved sidebar width")
                    precondition(terminalRect.width >= 400, "native terminal minimum survives the open dock")
                    precondition(terminalAreaRect.height >= WorkspaceChromeLayout.minimumTerminalHeight)
                    precondition(terminalRect.maxY <= content.bounds.maxY + 1)
                    if visible {
                        let files = probe.geometry.headers[2]!
                        let fileRect = files.convert(files.bounds, to: content)
                        precondition(fileRect.width >= 300)
                        let remote = probe.geometry.headers[3]!
                        let remoteRect = remote.convert(remote.bounds, to: content)
                        precondition(remoteRect.width >= 300, "both transfer ends stay visible and usable")
                        precondition(abs(remoteRect.maxX - content.bounds.maxX) < 1)
                        if !workspaceMode {
                            precondition(fileRect.minY >= terminalAreaRect.maxY + 4,
                                         "the shared production dock must appear below the terminal, not replace it")
                            precondition(fileRect.height >= WorkspaceChromeLayout.minimumFilesHeight)
                        }
                    }
                }
            }
            }
        }
        print("ok: production bottom dock at 880x520 preserves terminal identity, both file panes and sidebar restoration")
        window.close()
    }

    @MainActor private static func verifyEmbeddedCanvasGeometry() {
        let probe = CanvasGeometryProbe()
        let host = NSHostingController(rootView: EmbeddedSplitFixture(probe: probe))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for revision in 0..<3 {
            probe.revision = revision
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
        print("ok: embedded SwiftUI split keeps all four pane titles visible across resize and content and width updates")
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
        for revision in 0..<3 {
            probe.revision = revision
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
        print("ok: settings split extends through titlebar with safe controls and fixed sidebar in repeated updates")
        window.close()
    }
}
