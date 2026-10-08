import AppKit
import SwiftUI

/// AppKit owns the sidebar glass and its geometry. Hosting controllers stay alive when the
/// material changes; in particular, the detail controller and its terminal surfaces never leave
/// the hierarchy. Pass environments explicitly: these hosts are independent SwiftUI roots.
struct NativeSidebarSplit<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    var glass: Bool
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
        controller.configure(glass: glass, width: width, minimum: minimumWidth,
                             maximum: maximumWidth, defaultWidth: defaultWidth,
                             onWidthChange: onWidthChange)
    }
}

final class NativeSidebarSplitController<Sidebar: View, Detail: View>: NSSplitViewController {
    let sidebarHost: NSHostingController<Sidebar>
    let detailHost: NSHostingController<Detail>
    private var usesGlass: Bool?
    private var applying = false
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

    func configure(glass: Bool, width: CGFloat, minimum: CGFloat, maximum: CGFloat,
                   defaultWidth: CGFloat, onWidthChange: @escaping (CGFloat) -> Void) {
        applying = true
        defer { applying = false }
        widthChanged = onWidthChange
        self.defaultWidth = defaultWidth
        let desired = min(max(width, minimum), maximum)
        let changedMaterial = usesGlass != glass
        if changedMaterial {
            let window = view.window
            let responder = window?.firstResponder
            // A field editor is shared by the window and is detached when its sidebar
            // control temporarily leaves the split. Restore its owning control first.
            let editor = responder as? NSTextView
            let editingControl = editor?.isFieldEditor == true ? editor?.delegate as? NSView : nil
            let selection = editor?.selectedRange()
            let old = splitViewItems[0]
            removeSplitViewItem(old)
            let item = glass ? NSSplitViewItem(sidebarWithViewController: sidebarHost)
                             : NSSplitViewItem(viewController: sidebarHost)
            item.canCollapse = false
            item.canCollapseFromWindowResize = false
            item.allowsFullHeightLayout = true
            // Hold width ahead of the detail, but below AppKit's divider drag constraints.
            item.holdingPriority = NSLayoutConstraint.Priority(260)
            insertSplitViewItem(item, at: 0)
            usesGlass = glass
            // Removing only the sidebar item leaves the detail hosting controller untouched.
            if let editingControl, editingControl.window === window {
                window?.makeFirstResponder(editingControl)
                if let selection, let restoredEditor = window?.firstResponder as? NSTextView {
                    restoredEditor.setSelectedRange(selection)
                }
            } else if let responder {
                window?.makeFirstResponder(responder)
            }
        }
        let item = splitViewItems[0]
        item.minimumThickness = minimum
        item.maximumThickness = maximum
        if changedMaterial || abs(requestedWidth - desired) > 0.5 {
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
        guard let width = pendingWidth, view.window != nil, splitView.bounds.width > width else { return }
        pendingWidth = nil
        let wasApplying = applying
        applying = true
        splitView.setPosition(width, ofDividerAt: 0)
        applying = wasApplying
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard !applying, pendingWidth == nil, usesGlass != nil, splitView.bounds.width > 0 else { return }
        let width = sidebarHost.view.frame.width
        guard width > 0, abs(width - lastReportedWidth) > 0.5 else { return }
        requestedWidth = width
        lastReportedWidth = width
        // Never publish SwiftUI state in an AppKit layout/update callback. Report only the
        // latest width, including when a drag ends over the terminal rather than the divider.
        DispatchQueue.main.async { [weak self] in
            guard let self, abs(self.lastReportedWidth - width) < 0.5 else { return }
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
