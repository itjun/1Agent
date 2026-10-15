import AppKit
import SwiftUI

/// The production terminal/file hierarchy is also exercised by native geometry tests. The
/// terminal stays at the same structural position while files expand, collapse and resize.
struct WorkspaceContentSplit<Terminal: View, Files: View>: View {
    var presentation: WorkspacePresentation
    var onRatioChange: (Double) -> Void
    @ViewBuilder var terminal: () -> Terminal
    @ViewBuilder var files: () -> Files

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let dockHeight = WorkspaceChromeLayout.filesHeight(in: size.height, ratio: presentation.filesHeightRatio)
            let terminalHeight = presentation.filesDockVisible
                ? max(0, size.height - dockHeight - WorkspaceChromeLayout.dividerWidth) : size.height
            ZStack(alignment: .topLeading) {
                terminal()
                    .frame(width: size.width, height: terminalHeight)
                    .opacity(presentation.fullFilesWorkspace ? 0 : 1)
                    .allowsHitTesting(!presentation.fullFilesWorkspace)
                    .accessibilityHidden(presentation.fullFilesWorkspace)
                if presentation.filesVisible {
                    files()
                        .frame(width: size.width, height: presentation.fullFilesWorkspace ? size.height : dockHeight)
                        .offset(y: presentation.fullFilesWorkspace ? 0 : terminalHeight + WorkspaceChromeLayout.dividerWidth)
                }
                if presentation.filesDockVisible {
                    WorkspaceDockDivider { delta in
                        guard size.height > 0 else { return }
                        onRatioChange(Double((dockHeight - delta) / size.height))
                    }
                    .frame(height: WorkspaceChromeLayout.dividerWidth)
                    .offset(y: terminalHeight)
                    .accessibilityLabel(Text("Resize Files Panel"))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }
}

private struct WorkspaceDockDivider: NSViewRepresentable {
    var onDrag: (CGFloat) -> Void
    func makeNSView(context: Context) -> WorkspaceDockDividerView { WorkspaceDockDividerView() }
    func updateNSView(_ view: WorkspaceDockDividerView, context: Context) { view.onDrag = onDrag }
}

private final class WorkspaceDockDividerView: NSView {
    var onDrag: (CGFloat) -> Void = { _ in }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.midY, width: bounds.width, height: 1).fill()
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 14, y: bounds.midY - 1, width: 28, height: 2),
                     xRadius: 1, yRadius: 1).fill()
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let wasMovable = window.isMovable
        window.isMovable = false
        defer { window.isMovable = wasMovable }
        let start = event.locationInWindow.y
        let drag = onDrag
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { next, stop in
            guard let next else { stop.pointee = true; return }
            if next.type == .leftMouseUp { stop.pointee = true; return }
            drag(start - next.locationInWindow.y)
        }
    }
}

/// AppKit owns solid sidebar geometry. Both hosting controllers and terminal surfaces stay
/// attached across appearance and layout updates. Pass environments to these independent roots.
struct NativeSidebarSplit<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    var collapsed: Bool = false
    var width: CGFloat
    var minimumWidth: CGFloat
    var maximumWidth: CGFloat
    var defaultWidth: CGFloat
    var onWidthChange: (CGFloat) -> Void = { _ in }
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    func makeNSViewController(context: Context) -> NativeSidebarSplitController<Sidebar, Detail> {
        let controller = NativeSidebarSplitController(sidebar: sidebar(), detail: detail())
        configure(controller)
        return controller
    }

    func updateNSViewController(_ controller: NativeSidebarSplitController<Sidebar, Detail>, context: Context) {
        controller.sidebarHost.rootView = sidebar()
        controller.detailHost.rootView = detail()
        configure(controller)
    }

    private func configure(_ controller: NativeSidebarSplitController<Sidebar, Detail>) {
        controller.configure(width: width, minimum: minimumWidth,
                             maximum: maximumWidth, defaultWidth: defaultWidth, collapsed: collapsed,
                             onWidthChange: onWidthChange)
    }
}

final class NativeSidebarSplitController<Sidebar: View, Detail: View>: NSSplitViewController {
    let sidebarHost: NSHostingController<Sidebar>
    let detailHost: NSHostingController<Detail>
    private var configured = false
    private var applying = false
    private var collapsed = false
    private var requestedWidth: CGFloat = 0
    private var lastReportedWidth: CGFloat = 0
    private var pendingWidth: CGFloat?
    private var widthChanged: (CGFloat) -> Void = { _ in }
    private var defaultWidth: CGFloat = 0

    init(sidebar: Sidebar, detail: Detail) {
        sidebarHost = NSHostingController(rootView: sidebar)
        detailHost = NSHostingController(rootView: detail)
        super.init(nibName: nil, bundle: nil)
        // Content changes must not resize the window or fight the native divider.
        sidebarHost.sizingOptions = []
        detailHost.sizingOptions = []
        let nativeSplit = SidebarSplitView()
        nativeSplit.isVertical = true
        nativeSplit.dividerStyle = .thin
        nativeSplit.onResetWidth = { [weak self] in self?.restoreDefaultWidth() }
        splitView = nativeSplit
        addSplitViewItem(NSSplitViewItem(viewController: sidebarHost))
        let content = NSSplitViewItem(viewController: detailHost)
        content.holdingPriority = .defaultLow
        // Keep terminal glyphs and mouse coordinates outside the sidebar. Only the opaque
        // background extends beneath the floating pane; no live terminal mirroring is needed.
        if #available(macOS 26.0, *) { content.automaticallyAdjustsSafeAreaInsets = false }
        addSplitViewItem(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // A representable embeds the controller in an intermediate view. Autoresizing can
        // retain the split's initial margins there, leaving its top and right edges outside
        // the visible window. Pin the split to that container before SwiftUI resizes it.
        guard splitView !== view else { return }
        splitView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func configure(width: CGFloat, minimum: CGFloat, maximum: CGFloat,
                   defaultWidth: CGFloat, collapsed: Bool = false, onWidthChange: @escaping (CGFloat) -> Void) {
        applying = true
        defer { applying = false }
        widthChanged = onWidthChange
        self.defaultWidth = defaultWidth
        let desired = min(max(width, minimum), maximum)
        let initialConfiguration = !configured
        let changedCollapse = self.collapsed != collapsed
        self.collapsed = collapsed
        if initialConfiguration {
            let item = splitViewItems[0]
            item.canCollapse = true
            item.canCollapseFromWindowResize = false
            item.allowsFullHeightLayout = true
            item.holdingPriority = NSLayoutConstraint.Priority(260)
            configured = true
        }
        let item = splitViewItems[0]
        item.minimumThickness = minimum
        item.maximumThickness = maximum
        item.isCollapsed = collapsed
        if initialConfiguration || changedCollapse || abs(requestedWidth - desired) > 0.5 {
            requestedWidth = desired
            lastReportedWidth = desired
            pendingWidth = desired
            splitView.layoutSubtreeIfNeeded()
            applyPendingWidth()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyPendingWidth()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyPendingWidth()
    }

    private func applyPendingWidth() {
        // makeNSViewController runs before the representable receives a window or frame.
        // Ignore provisional native widths until the saved width can actually be restored.
        guard !collapsed, let width = pendingWidth, view.window != nil, splitView.bounds.width > width else { return }
        pendingWidth = nil
        let wasApplying = applying
        applying = true
        splitView.setPosition(width, ofDividerAt: 0)
        applying = wasApplying
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard !collapsed, !applying, pendingWidth == nil, configured, splitView.bounds.width > 0 else { return }
        let width = sidebarHost.view.frame.width
        guard width > 0, abs(width - lastReportedWidth) > 0.5 else { return }
        requestedWidth = width
        lastReportedWidth = width
        // Never publish SwiftUI state in an AppKit layout/update callback. Report only the
        // latest width, including when a drag ends over the terminal rather than the divider.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.collapsed, abs(self.lastReportedWidth - width) < 0.5 else { return }
            self.widthChanged(width)
        }
    }

    func restoreDefaultWidth() {
        splitView.setPosition(defaultWidth, ofDividerAt: 0)
    }
}

private final class SidebarSplitView: NSSplitView {
    var onResetWidth: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, let first = arrangedSubviews.first,
           abs(point.x - first.frame.maxX) <= max(5, dividerThickness) {
            onResetWidth()
            return
        }
        super.mouseDown(with: event)
    }
}
