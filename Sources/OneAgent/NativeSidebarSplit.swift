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
    var isDividerHidden: Bool = false
    var dividerWidth: CGFloat = 1
    var sidebarCornerRadius: CGFloat = 0
    var usesSystemSidebarMaterial = true
    var isTrailing: Bool = false
    var toolbarIdentifier: String?
    var extendsSidebarIntoTitlebar = true
    var width: CGFloat
    var minimumWidth: CGFloat
    var maximumWidth: CGFloat
    var defaultWidth: CGFloat
    var onWidthChange: (CGFloat) -> Void = { _ in }
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    func makeNSViewController(context: Context) -> NativeSidebarSplitController<Sidebar, Detail> {
        let controller = NativeSidebarSplitController(sidebar: sidebar(), detail: detail(), isTrailing: isTrailing,
                                                     usesSystemSidebarMaterial: usesSystemSidebarMaterial)
        configure(controller)
        return controller
    }

    func updateNSViewController(_ controller: NativeSidebarSplitController<Sidebar, Detail>, context: Context) {
        controller.sidebarHost.rootView = sidebar()
        controller.detailHost.rootView = detail()
        configure(controller)
    }

    private func configure(_ controller: NativeSidebarSplitController<Sidebar, Detail>) {
        controller.splitView.identifier = toolbarIdentifier.map { NSUserInterfaceItemIdentifier($0) }
        controller.configure(width: width, minimum: minimumWidth,
                             maximum: maximumWidth, defaultWidth: defaultWidth, collapsed: collapsed,
                             isDividerHidden: isDividerHidden, dividerWidth: dividerWidth,
                             sidebarCornerRadius: sidebarCornerRadius,
                             extendsSidebarIntoTitlebar: extendsSidebarIntoTitlebar,
                             onWidthChange: onWidthChange)
    }
}

final class NativeSidebarSplitController<Sidebar: View, Detail: View>: NSSplitViewController {
    let sidebarHost: NSHostingController<Sidebar>
    let detailHost: NSHostingController<Detail>
    private let isTrailing: Bool
    private var sidebarItem: NSSplitViewItem { splitViewItems[isTrailing ? 1 : 0] }
    private var configured = false
    private var applying = false
    private var collapsed = false
    private var requestedWidth: CGFloat = 0
    private var lastReportedWidth: CGFloat = 0
    private var pendingWidth: CGFloat?
    private var widthChanged: (CGFloat) -> Void = { _ in }
    private var defaultWidth: CGFloat = 0

    init(sidebar: Sidebar, detail: Detail, isTrailing: Bool = false, usesSystemSidebarMaterial: Bool = true) {
        self.isTrailing = isTrailing
        sidebarHost = NSHostingController(rootView: sidebar)
        detailHost = NSHostingController(rootView: detail)
        super.init(nibName: nil, bundle: nil)
        // Content changes must not resize the window or fight the native divider.
        sidebarHost.sizingOptions = []
        detailHost.sizingOptions = []
        let nativeSplit = SidebarSplitView()
        nativeSplit.isVertical = true
        nativeSplit.dividerStyle = .thin
        nativeSplit.drawsDividerBelowTitlebar = isTrailing
        nativeSplit.onResetWidth = { [weak self] in self?.restoreDefaultWidth() }
        splitView = nativeSplit
        // 原生 sidebar 项会在内容下面另铺系统材质；工作区导航需要直接透出窗口渐变。
        let sidebarItem = usesSystemSidebarMaterial && !isTrailing
            ? NSSplitViewItem(sidebarWithViewController: sidebarHost) : NSSplitViewItem(viewController: sidebarHost)
        if !isTrailing { addSplitViewItem(sidebarItem) }
        let content = NSSplitViewItem(viewController: detailHost)
        sidebarItem.titlebarSeparatorStyle = .none
        content.titlebarSeparatorStyle = .none
        content.holdingPriority = .defaultLow
        // Keep terminal glyphs and mouse coordinates outside the sidebar. Only the opaque
        // background extends beneath the floating pane; no live terminal mirroring is needed.
        if #available(macOS 26.0, *) { content.automaticallyAdjustsSafeAreaInsets = false }
        addSplitViewItem(content)
        if isTrailing { addSplitViewItem(sidebarItem) }
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
                   defaultWidth: CGFloat, collapsed: Bool = false, isDividerHidden: Bool = false,
                   dividerWidth: CGFloat = 1,
                   sidebarCornerRadius: CGFloat = 0,
                   extendsSidebarIntoTitlebar: Bool = true,
                   onWidthChange: @escaping (CGFloat) -> Void) {
        applying = true
        defer { applying = false }
        (splitView as? SidebarSplitView)?.isDividerHidden = isDividerHidden
        // The invisible gap belongs between visible panes. AppKit can still reserve its
        // thickness for a collapsed sidebar, which doubles the window's outer inset.
        let effectiveDividerWidth = collapsed && isDividerHidden ? 0 : dividerWidth
        if let split = splitView as? SidebarSplitView, split.customDividerWidth != effectiveDividerWidth {
            split.customDividerWidth = effectiveDividerWidth
            split.needsLayout = true
        }
        if #available(macOS 26.0, *) {
            sidebarItem.automaticallyAdjustsSafeAreaInsets = dividerWidth == 1
        }
        (sidebarHost.view as? NSHostingView<Sidebar>)?.safeAreaRegions = dividerWidth > 1 ? [] : .all
        // AppKit 在 hosting view 外另包了一层侧栏材质，也需裁切，避免圆角外露出方形底板。
        if let sidebar = (isTrailing ? splitView.arrangedSubviews.last : splitView.arrangedSubviews.first) {
            sidebar.wantsLayer = true
            sidebar.layer?.cornerRadius = sidebarCornerRadius
            sidebar.layer?.cornerCurve = .continuous
            sidebar.layer?.masksToBounds = sidebarCornerRadius > 0
        }
        widthChanged = onWidthChange
        self.defaultWidth = defaultWidth
        let desired = min(max(width, minimum), maximum)
        let initialConfiguration = !configured
        let changedCollapse = self.collapsed != collapsed
        self.collapsed = collapsed
        if initialConfiguration {
            let item = sidebarItem
            item.canCollapse = true
            item.canCollapseFromWindowResize = false
            // 左侧自标题栏贯穿到底部；右侧工具面板从通栏下方开始。
            item.holdingPriority = NSLayoutConstraint.Priority(260)
            configured = true
        }
        let item = sidebarItem
        // 阅读覆盖导航时释放其标题栏占位，内容与终端仍保留在原分栏中。
        item.allowsFullHeightLayout = !isTrailing && extendsSidebarIntoTitlebar
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
        splitView.setPosition(isTrailing ? splitView.bounds.width - width - splitView.dividerThickness : width, ofDividerAt: 0)
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
        splitView.setPosition(isTrailing ? splitView.bounds.width - defaultWidth - splitView.dividerThickness : defaultWidth, ofDividerAt: 0)
    }
}

private final class SidebarSplitView: NSSplitView {
    var customDividerWidth: CGFloat = 1
    override var dividerThickness: CGFloat { customDividerWidth }
    var onResetWidth: () -> Void = {}
    var drawsDividerBelowTitlebar = false
    var isDividerHidden = false {
        didSet {
            if isDividerHidden != oldValue { needsDisplay = true }
        }
    }

    override var dividerColor: NSColor { isDividerHidden ? .clear : super.dividerColor }

    override func drawDivider(in rect: NSRect) {
        // 隐藏边界只影响绘制，保留原生拖动、光标及双击调宽的命中区域。
        guard !isDividerHidden else { return }
        let visibleRect = drawsDividerBelowTitlebar && window != nil
            ? rect.intersection(convert(window!.contentLayoutRect, from: nil)) : rect
        if !visibleRect.isEmpty { super.drawDivider(in: visibleRect) }
    }

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
