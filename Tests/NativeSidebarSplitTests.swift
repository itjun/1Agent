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
            precondition(controller.splitViewItems[0].behavior == .sidebar)
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
        verifyThreeColumns()
        verifyHiddenDivider()
        verifyEmbeddedCanvasGeometry()
        verifySettingsTitlebarGeometry()
        verifyDockGeometry()
        verifyMenuDisplayCycleOpensSplit()
    }

    @MainActor private static func verifyThreeColumns() {
        let probe = Probe()
        let inspectorProbe = Probe()
        var widths: [CGFloat] = []
        var collapses: [Bool] = []
        func inspector(_ collapsed: Bool = false, width: CGFloat = 350) -> NativeInspectorConfiguration {
            NativeInspectorConfiguration(isCollapsed: collapsed, width: width,
                onWidthChange: { widths.append($0) }, onCollapseChange: { collapses.append($0) },
                content: AnyView(InputProbe(probe: inspectorProbe, output: "search")))
        }
        let controller = NativeSidebarSplitController(sidebar: Color.clear,
            detail: InputProbe(probe: probe, output: "terminal"), inspector: inspector())
        controller.configure(width: 260, minimum: 200, maximum: 420, defaultWidth: 260,
                             onWidthChange: { _ in }, inspector: inspector())
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 880, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        precondition(widths.isEmpty, "provisional small window must not overwrite saved inspector width")
        window.setContentSize(NSSize(width: 1400, height: 800))
        func settle() {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        func configure(left: Bool = false, right: Bool = false, width: CGFloat = 350) {
            controller.configure(width: 260, minimum: 200, maximum: 420, defaultWidth: 260,
                collapsed: left, onWidthChange: { _ in }, inspector: inspector(right, width: width))
            settle()
        }
        configure()
        for index in 0..<2 {
            let columns = controller.splitView
            precondition(columns.acceptsFirstMouse(for: nil), "column dividers must accept a drag from an inactive window")
            let x = columns.arrangedSubviews[index].frame.maxX + columns.dividerThickness / 2
            for offset: CGFloat in [-2, 0, 2] {
                let point = columns.convert(NSPoint(x: x + offset, y: columns.bounds.midY), to: columns.superview)
                let hit = columns.hitTest(point)
                precondition(hit === columns, "native divider \(index) must receive mouse events within its drag tolerance, offset=\(offset), got \(String(describing: hit))")
            }
        }
        let originalField = probe.field!
        let originalInspector = controller.inspectorHost!
        precondition(controller.splitViewItems[2].behavior == .inspector)
        precondition(window.makeFirstResponder(originalField))
        let responder = window.firstResponder
        for (left, right) in [(true, false), (true, true), (false, true), (false, false)] {
            configure(left: left, right: right)
            precondition(controller.splitViewItems[0].isCollapsed == left)
            precondition(controller.splitViewItems[2].isCollapsed == right)
            precondition(controller.inspectorHost === originalInspector)
            precondition(probe.created == 1 && inspectorProbe.created == 1,
                         "column toggles must retain terminal and inspector inputs")
            precondition(originalField.window === window && window.firstResponder === responder,
                         "column toggles preserve terminal attachment and focus")
            if !right { precondition(abs(originalInspector.view.frame.width - 350) < 1) }
        }
        controller.splitView.setPosition(controller.splitView.bounds.width - 410 - controller.splitView.dividerThickness,
                                         ofDividerAt: 1)
        settle()
        precondition(abs((widths.last ?? 0) - 410) < 1, "inspector drag publishes its actual width")
        configure(width: 410)
        window.setContentSize(NSSize(width: 1200, height: 680))
        settle()
        precondition(abs(originalInspector.view.frame.width - 410) < 1, "window resize retains inspector width")
        precondition(controller.detailHost.view.frame.width >= WorkspaceChromeLayout.minimumTerminalWidth)
        controller.splitViewItems[2].isCollapsed = true
        settle()
        precondition(collapses.last == true, "native inspector collapse updates application state")
        configure()
        precondition(abs(originalInspector.view.frame.width - 350) < 1)
        precondition(probe.created == 1 && inspectorProbe.created == 1)
        window.close()
        print("ok: three columns preserve hosts/focus across four toggle states, inspector drag/resize/collapse restore")
    }

    @MainActor private static func verifyHiddenDivider() {
        let probe = Probe()
        let controller = NativeSidebarSplitController(sidebar: Color.clear,
            detail: InputProbe(probe: probe, output: "live terminal"))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1100, height: 720))
        var reportedWidth: CGFloat = 0
        func configure(isHidden: Bool, isCollapsed: Bool = false) {
            controller.configure(width: 260, minimum: 200, maximum: 420, defaultWidth: 260,
                                 collapsed: isCollapsed, isDividerHidden: isHidden,
                                 onWidthChange: { reportedWidth = $0 })
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        func hasVisibleDividerPixels() -> Bool {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 32,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            controller.splitView.effectiveAppearance.performAsCurrentDrawingAppearance {
                controller.splitView.drawDivider(in: NSRect(x: 8, y: 0,
                    width: controller.splitView.dividerThickness, height: 32))
            }
            NSGraphicsContext.restoreGraphicsState()
            return (0..<32).contains { y in
                (0..<16).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 }
            }
        }
        configure(isHidden: false)
        precondition(window.makeFirstResponder(probe.field!))
        let responder = window.firstResponder
        let thickness = controller.splitView.dividerThickness
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for isHidden in [true, false, true] {
                configure(isHidden: isHidden)
                precondition(hasVisibleDividerPixels() == !isHidden,
                             "transparent divider draws no pixels; classic drawing is restored")
                precondition(controller.splitView.dividerThickness == thickness && thickness > 0,
                             "hiding the line preserves native resizing geometry")
                precondition(probe.created == 1 && window.firstResponder === responder,
                             "shell switching preserves the terminal and its input focus")
                controller.splitView.setPosition(320, ofDividerAt: 0)
                window.contentView?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
                precondition(abs(reportedWidth - 320) < 1, "invisible divider still publishes resized width")
                precondition(hasVisibleDividerPixels() == !isHidden, "resizing never restores a hidden line")
                configure(isHidden: isHidden, isCollapsed: true)
                configure(isHidden: isHidden)
                precondition(hasVisibleDividerPixels() == !isHidden, "reopening sidebar retains divider style")
            }
        }
        window.close()
        print("ok: hidden divider draws no pixels in light/dark, resizes, collapses, restores classic and preserves terminal focus")
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

    /// Opening settings from its shortcut lays the new split out inside the menu display cycle.
    /// Geometry feedback used to re-enter divider placement until AppKit aborted the process.
    @MainActor private static func verifyMenuDisplayCycleOpensSplit() {
        let opener = MenuDisplayCycleOpener()
        let menu = NSMenu(title: "App")
        let item = NSMenuItem(title: "Settings", action: #selector(MenuDisplayCycleOpener.open), keyEquivalent: ",")
        item.keyEquivalentModifierMask = .command
        item.target = opener
        menu.addItem(item)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                      context: nil, characters: ",", charactersIgnoringModifiers: ",",
                                      isARepeat: false, keyCode: 43)!
        precondition(menu.performKeyEquivalent(with: event), "settings shortcut must run")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        precondition(opener.window?.isVisible == true, "settings-style split must stay open through the menu display cycle")
        opener.window?.close()
        print("ok: menu display cycle opens a settings-style split without exhausting layout")
    }
}

private struct MenuDisplayCycleFixture: View {
    @State private var bounds: [Int: CGRect] = [:]
    @State private var selected = 0
    @State private var sidebarWidth: CGFloat = 220

    var body: some View {
        NativeSidebarSplit(width: sidebarWidth, minimumWidth: 180, maximumWidth: 420, defaultWidth: 220,
                           onWidthChange: { sidebarWidth = $0 }) {
            List(selection: $selected) {
                ForEach(0..<8, id: \.self) { page in
                    Text("Page \(page)").tag(page)
                }
            }
            .listStyle(.sidebar)
        } detail: {
            VStack(spacing: 0) {
                Text("Title")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, bounds[selected]?.minX ?? 24)
                    .frame(height: 76)
                ZStack {
                    ForEach(0..<8, id: \.self) { page in
                        ScrollView {
                            Text("form \(page) \(Int(bounds[page]?.width ?? 0))")
                                .frame(maxWidth: 960, alignment: .leading)
                                .onGeometryChange(for: CGRect.self) { geometry in
                                    let frame = geometry.frame(in: .named("settings.detail"))
                                    return CGRect(x: frame.minX, y: 0, width: frame.width, height: 0)
                                } action: { bounds[page] = $0 }
                                .padding(24)
                                .frame(maxWidth: .infinity)
                        }
                        .opacity(selected == page ? 1 : 0)
                    }
                }
            }
            .coordinateSpace(name: "settings.detail")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .top)
    }
}

private final class MenuDisplayCycleOpener: NSObject {
    var window: NSWindow?
    @objc func open() {
        let host = NSHostingController(rootView: MenuDisplayCycleFixture())
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
