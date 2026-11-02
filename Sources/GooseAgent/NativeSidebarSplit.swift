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

/// 工具栏只绑定本窗口的顶层工作区分栏。
func workspaceColumnSplit(in view: NSView) -> NSSplitView? {
    if let split = view as? NSSplitView, split.identifier?.rawValue == "workspace.columns" { return split }
    for child in view.subviews {
        if let split = workspaceColumnSplit(in: child) { return split }
    }
    return nil
}

/// 右侧检查器保持挂载，收起时不销毁搜索、选择和预览状态。
struct NativeInspectorConfiguration {
    var isCollapsed: Bool
    var width: CGFloat
    var onWidthChange: (CGFloat) -> Void
    var onCollapseChange: (Bool) -> Void = { _ in }
    var content: AnyView
}

extension Notification.Name {
    static let workspaceSplitDidAttach = Notification.Name("workspaceSplitDidAttach")
}

/// AppKit owns solid sidebar geometry. Both hosting controllers and terminal surfaces stay
/// attached across appearance and layout updates. Pass environments to these independent roots.
struct NativeSidebarSplit<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    var collapsed: Bool = false
    var isDividerHidden: Bool = false
    var width: CGFloat
    var minimumWidth: CGFloat
    var maximumWidth: CGFloat
    var defaultWidth: CGFloat
    var onWidthChange: (CGFloat) -> Void = { _ in }
    var onCollapseChange: (Bool) -> Void = { _ in }
    var inspector: NativeInspectorConfiguration? = nil
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    func makeNSViewController(context: Context) -> NativeSidebarSplitController<Sidebar, Detail> {
        let controller = NativeSidebarSplitController(sidebar: sidebar(), detail: detail(), inspector: inspector)
        configure(controller)
        return controller
    }

    func updateNSViewController(_ controller: NativeSidebarSplitController<Sidebar, Detail>, context: Context) {
        // 显示周期里同步替换 rootView 会立刻再要一次约束更新。设置从菜单打开时，
        // 这次重入会超过 AppKit 的更新上限并闪退，所以等内容先记下来，布局结束后再换。
        controller.stageHostedContent(sidebar: sidebar(), detail: detail(), inspector: inspector?.content)
        configure(controller)
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsViewController: NativeSidebarSplitController<Sidebar, Detail>, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        // 分栏必须填满工作区；不能把拖动中的临时 fittingSize 当成整个工作区的新尺寸。
        return CGSize(width: width, height: height)
    }

    private func configure(_ controller: NativeSidebarSplitController<Sidebar, Detail>) {
        controller.configure(width: width, minimum: minimumWidth,
                             maximum: maximumWidth, defaultWidth: defaultWidth, collapsed: collapsed,
                             isDividerHidden: isDividerHidden,
                             onWidthChange: onWidthChange, onCollapseChange: onCollapseChange, inspector: inspector)
    }
}

final class NativeSidebarSplitController<Sidebar: View, Detail: View>: NSSplitViewController {
    let sidebarHost: NSHostingController<Sidebar>
    let detailHost: NSHostingController<Detail>
    private(set) var inspectorHost: NSHostingController<AnyView>?
    private var inspectorConfiguration: NativeInspectorConfiguration?
    private var pendingInspectorWidth: CGFloat?
    private var lastInspectorWidth: CGFloat = 0
    private var configured = false
    // 嵌套计数，而不是布尔值。setPosition 会同步进入 SwiftUI 更新并再次 configure；
    // 内层结束时若把标记清掉，这次拖动回调会把临时列宽写回去，打开设置时形成死循环并闪退。
    private var applyingDepth = 0
    private var applying: Bool { applyingDepth > 0 }
    private var positioningDivider = false
    private var collapsed = false
    private var requestedWidth: CGFloat = 0
    private var lastReportedWidth: CGFloat = 0
    private var pendingWidth: CGFloat?
    private var pendingSidebar: Sidebar
    private var pendingDetail: Detail
    private var pendingInspectorContent: AnyView?
    private var hostedContentScheduled = false
    private var widthApplyScheduled = false
    private var widthChanged: (CGFloat) -> Void = { _ in }
    private var collapseChanged: (Bool) -> Void = { _ in }
    private var defaultWidth: CGFloat = 0
    private var isAnimatingCollapse = false
    private var collapseGeneration = 0

    init(sidebar: Sidebar, detail: Detail, inspector: NativeInspectorConfiguration? = nil) {
        sidebarHost = NSHostingController(rootView: sidebar)
        detailHost = NSHostingController(rootView: detail)
        pendingSidebar = sidebar
        pendingDetail = detail
        pendingInspectorContent = inspector?.content
        super.init(nibName: nil, bundle: nil)
        // Content changes must not resize the window or fight the native divider.
        sidebarHost.sizingOptions = []
        detailHost.sizingOptions = []
        let nativeSplit = SidebarSplitView()
        nativeSplit.identifier = NSUserInterfaceItemIdentifier("workspace.columns")
        nativeSplit.isVertical = true
        nativeSplit.dividerStyle = .thin
        nativeSplit.onResetWidth = { [weak self] in self?.restoreDefaultWidth() }
        splitView = nativeSplit
        addSplitViewItem(NSSplitViewItem(sidebarWithViewController: sidebarHost))
        let content = NSSplitViewItem(viewController: detailHost)
        content.holdingPriority = .defaultLow
        // 中央区域始终占用独立的列，避免新系统把侧栏覆盖在终端字形上。
        if #available(macOS 26.0, *) { content.automaticallyAdjustsSafeAreaInsets = false }
        addSplitViewItem(content)
        if let inspector {
            let host = NSHostingController(rootView: inspector.content)
            host.sizingOptions = []
            inspectorHost = host
            let item = NSSplitViewItem(inspectorWithViewController: host)
            item.minimumThickness = 300
            item.maximumThickness = 480
            item.canCollapse = true
            item.canCollapseFromWindowResize = false
            item.holdingPriority = NSLayoutConstraint.Priority(260)
            addSplitViewItem(item)
            content.minimumThickness = WorkspaceChromeLayout.minimumTerminalWidth
        }
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
                   onWidthChange: @escaping (CGFloat) -> Void,
                   onCollapseChange: @escaping (Bool) -> Void = { _ in },
                   inspector: NativeInspectorConfiguration? = nil) {
        applyingDepth += 1
        defer { applyingDepth -= 1 }
        (splitView as? SidebarSplitView)?.isDividerHidden = isDividerHidden
        widthChanged = onWidthChange
        collapseChanged = onCollapseChange
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
        if let inspector, inspectorHost != nil {
            let previous = inspectorConfiguration
            inspectorConfiguration = inspector
            if previous == nil || previous?.isCollapsed != inspector.isCollapsed ||
                abs((previous?.width ?? 0) - inspector.width) > 0.5 {
                pendingInspectorWidth = inspector.width
                lastInspectorWidth = inspector.width
            }
        }
        let item = splitViewItems[0]
        item.minimumThickness = minimum
        item.maximumThickness = maximum
        if initialConfiguration || changedCollapse || abs(requestedWidth - desired) > 0.5 {
            requestedWidth = desired
            lastReportedWidth = desired
            pendingWidth = desired
        }
        var changes: [(NSSplitViewItem, Bool)] = []
        if item.isCollapsed != collapsed { changes.append((item, collapsed)) }
        if let inspector, inspectorHost != nil, splitViewItems[2].isCollapsed != inspector.isCollapsed {
            changes.append((splitViewItems[2], inspector.isCollapsed))
        }
        if !changes.isEmpty {
            collapseGeneration += 1
            let generation = collapseGeneration
            let animate = !initialConfiguration && view.window?.isVisible == true &&
                !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            isAnimatingCollapse = animate
            if animate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = WorkspaceChromeLayout.sidebarTransitionDuration
                    for (column, value) in changes { column.animator().isCollapsed = value }
                } completionHandler: { [weak self] in
                    guard let self, self.collapseGeneration == generation else { return }
                    self.isAnimatingCollapse = false
                    self.applyPendingWidth()
                }
            } else {
                for (column, value) in changes { column.isCollapsed = value }
            }
        }
        // 让 AppKit 在当前帧统一布局；同步递归布局会在 SwiftUI 更新中再次
        // 更新所有终端和侧栏，阻塞收起动画，且开着的隐藏会话越多越明显。
        applyPendingWidth()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyPendingWidth()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyPendingWidth()
        NotificationCenter.default.post(name: .workspaceSplitDidAttach, object: splitView)
    }

    func stageHostedContent(sidebar: Sidebar, detail: Detail, inspector: AnyView?) {
        pendingSidebar = sidebar
        pendingDetail = detail
        pendingInspectorContent = inspector
        guard view.window != nil else {
            applyHostedContent()
            return
        }
        guard !hostedContentScheduled else { return }
        hostedContentScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hostedContentScheduled = false
            self.applyHostedContent()
        }
    }

    private func applyHostedContent() {
        sidebarHost.rootView = pendingSidebar
        detailHost.rootView = pendingDetail
        if let pendingInspectorContent {
            inspectorHost?.rootView = pendingInspectorContent
        }
    }

    private func applyPendingWidth() {
        // 分隔条位置也要等这次显示周期结束。同步 setPosition 会在设置窗口的第一次布局里
        // 再次进入 SwiftUI，把约束更新次数耗尽。
        guard !widthApplyScheduled, !positioningDivider else { return }
        // makeNSViewController runs before the representable receives a window or frame.
        // Ignore provisional native widths until the saved width can actually be restored.
        guard !isAnimatingCollapse, view.window != nil, splitView.bounds.width > 0,
              (!collapsed && pendingWidth != nil) ||
                (inspectorConfiguration?.isCollapsed == false && pendingInspectorWidth != nil) else { return }
        if let configuration = inspectorConfiguration {
            let leftWidth = collapsed ? 0 : requestedWidth + splitView.dividerThickness
            let rightWidth = configuration.isCollapsed ? 0 : configuration.width + splitView.dividerThickness
            // 创建窗口时尺寸尚未恢复，不能把受约束的临时列宽写回用户配置。
            guard splitView.bounds.width >= leftWidth + rightWidth + WorkspaceChromeLayout.minimumTerminalWidth else { return }
        }
        widthApplyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.widthApplyScheduled = false
            self.commitPendingWidth()
        }
    }

    private func commitPendingWidth() {
        guard !positioningDivider else { return }
        guard !isAnimatingCollapse, view.window != nil, splitView.bounds.width > 0 else { return }
        positioningDivider = true
        applyingDepth += 1
        defer {
            applyingDepth -= 1
            positioningDivider = false
        }
        if !collapsed, let width = pendingWidth, splitView.bounds.width > width {
            pendingWidth = nil
            if abs(splitView.arrangedSubviews[0].frame.width - width) > 0.5 {
                splitView.setPosition(width, ofDividerAt: 0)
            }
        }
        if let configuration = inspectorConfiguration, !configuration.isCollapsed,
           let width = pendingInspectorWidth,
           splitView.bounds.width > width + WorkspaceChromeLayout.minimumTerminalWidth {
            pendingInspectorWidth = nil
            if abs(splitView.arrangedSubviews[2].frame.width - width) > 0.5 {
                splitView.setPosition(splitView.bounds.width - width - splitView.dividerThickness, ofDividerAt: 1)
            }
        }
    }

    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        // 保留系统细线，只扩大鼠标命中范围，避免 Retina 下必须对准半个点。
        let nativeRect = super.splitView(splitView, effectiveRect: proposedEffectiveRect,
                                         forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        return nativeRect.isEmpty ? nativeRect : nativeRect.insetBy(dx: -3, dy: 0)
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard !applying, configured, splitView.bounds.width > 0 else { return }
        // 当场记录原生拖动的宽度；延后一轮读取时，inspector 可能已按旧约束回弹。
        // reportLayoutChanges 只同步内部记录，对 SwiftUI 的回写仍异步进行。
        reportLayoutChanges()
    }

    private func reportLayoutChanges() {
        guard !applying, !isAnimatingCollapse, configured, view.window != nil else { return }
        let nativeCollapsed = splitViewItems[0].isCollapsed
        if nativeCollapsed != collapsed {
            collapsed = nativeCollapsed
            DispatchQueue.main.async { [weak self] in
                guard let self, self.collapsed == nativeCollapsed else { return }
                self.collapseChanged(nativeCollapsed)
            }
        }
        if let configuration = inspectorConfiguration,
           splitViewItems[2].isCollapsed != configuration.isCollapsed {
            let value = splitViewItems[2].isCollapsed
            inspectorConfiguration?.isCollapsed = value
            DispatchQueue.main.async { [weak self] in
                guard let self, self.inspectorConfiguration?.isCollapsed == value else { return }
                self.inspectorConfiguration?.onCollapseChange(value)
            }
        }
        if let configuration = inspectorConfiguration, !configuration.isCollapsed,
           pendingInspectorWidth == nil, inspectorHost != nil {
            let width = splitView.arrangedSubviews[2].frame.width
            if width > 0, abs(width - lastInspectorWidth) > 0.5 {
                lastInspectorWidth = width
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.inspectorConfiguration?.isCollapsed == false,
                          abs(self.lastInspectorWidth - width) < 0.5 else { return }
                    self.inspectorConfiguration?.onWidthChange(width)
                }
            }
        }
        guard !collapsed, pendingWidth == nil else { return }
        let width = splitView.arrangedSubviews[0].frame.width
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
    var isDividerHidden = false {
        didSet {
            if isDividerHidden != oldValue { needsDisplay = true }
        }
    }

    override var dividerColor: NSColor { isDividerHidden ? .clear : super.dividerColor }

    override func drawDivider(in rect: NSRect) {
        // 透明外壳始终不画边界，保留原生拖动、光标及双击调宽的命中区域。
        guard !isDividerHidden else { return }
        super.drawDivider(in: rect)
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
