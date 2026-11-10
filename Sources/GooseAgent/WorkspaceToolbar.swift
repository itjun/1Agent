import AppKit
import SwiftUI

/// 退出顶部后短暂保留入口，避免鼠标在通栏边缘移动时闪烁。
@MainActor
final class WorkspaceToolbarVisibility: ObservableObject {
    @Published private(set) var isRevealed = false
    private var pendingHide: DispatchWorkItem?
    private var isHovered = false

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        pendingHide?.cancel()
        pendingHide = nil
        if hovered {
            isRevealed = true
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isHovered else { return }
                self.isRevealed = false
                self.pendingHide = nil
            }
            pendingHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    deinit { pendingHide?.cancel() }
}

/// 窗口只有一个原生工具栏，信息始终来自当前输入焦点。
struct WorkspaceToolbar: NSViewRepresentable {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WindowState
    var visibility: WorkspaceToolbarVisibility
    @ObservedObject private var appearance = AppearanceDriver.shared

    func makeCoordinator() -> Coordinator { Coordinator(model: model, state: state, visibility: visibility) }

    func makeNSView(context: Context) -> ToolbarAttachmentView {
        let view = ToolbarAttachmentView()
        view.onWindow = { [weak coordinator = context.coordinator] in coordinator?.attach(to: $0) }
        return view
    }

    func updateNSView(_ view: ToolbarAttachmentView, context: Context) {
        context.coordinator.update()
    }

    @MainActor
    final class Coordinator: NSObject, NSToolbarDelegate {
        let model: AppModel
        let state: WindowState
        let visibility: WorkspaceToolbarVisibility
        private weak var window: NSWindow?
        private var toolbar: NSToolbar?
        private var toolsItem: NSToolbarItem?
        private var toolsWidth: NSLayoutConstraint?
        private var toolsView: NSHostingView<WorkspaceToolbarTools>?
        private var informationItem: NSToolbarItem?
        private var informationView: NSHostingView<AnyView>?
        private var informationWidth: NSLayoutConstraint?
        private var isPageToolbar = false
        private let navigationSeparator = NSToolbarItem.Identifier("workspace.navigationSeparator")
        private let information = NSToolbarItem.Identifier("workspace.focusedInformation")
        private let branch = NSToolbarItem.Identifier("workspace.branch")
        private let sidebar = NSToolbarItem.Identifier("workspace.sidebar")
        private let tools = NSToolbarItem.Identifier("workspace.tools")

        init(model: AppModel, state: WindowState, visibility: WorkspaceToolbarVisibility) {
            self.model = model
            self.state = state
            self.visibility = visibility
        }

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            let toolbar = NSToolbar(identifier: "1Agent.workspace")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            self.toolbar = toolbar
            window.toolbarStyle = .unifiedCompact
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar = toolbar
            window.titlebarSeparatorStyle = .none
            NotificationCenter.default.addObserver(self, selector: #selector(splitDidResize(_:)),
                name: NSSplitView.didResizeSubviewsNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize(_:)),
                name: NSWindow.didResizeNotification, object: window)
            update()
        }

        func update() {
            window?.backgroundColor = NSColor(WindowChrome.resolve(isDark: AppearanceDriver.shared.isDark).panelHeader)
            let isTerminal = state.section == .terminals && !state.presentation.fullFilesWorkspace
            let tab = model.selectedTab(in: state)
            window?.title = state.section == .commands ? String(localized: "Command Library")
                : state.presentation.fullFilesWorkspace ? String(localized: "Files")
                : tab.map { model.sessionTitle($0) } ?? String(localized: "1Agent")
            isPageToolbar = !isTerminal
            if let window {
                let height = max(0, window.frame.height - window.contentLayoutRect.maxY)
                if abs(state.workspaceToolbarHeight - height) > 0.5 {
                    DispatchQueue.main.async { [weak self] in self?.state.workspaceToolbarHeight = height }
                }
            }
            if let toolbar {
                let leadingItems = [sidebar, navigationSeparator, information]
                for (position, id) in leadingItems.enumerated() {
                    if state.isToolReadingExpanded {
                        if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == id }) {
                            toolbar.removeItem(at: index)
                        }
                    } else if !toolbar.items.contains(where: { $0.itemIdentifier == id }) {
                        toolbar.insertItem(withItemIdentifier: id, at: min(position, toolbar.items.count))
                    }
                }
                for id in [NSToolbarItem.Identifier.flexibleSpace] {
                    if isPageToolbar || state.isToolReadingExpanded, let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == id }) {
                        toolbar.removeItem(at: index)
                    } else if !isPageToolbar && !state.isToolReadingExpanded && !toolbar.items.contains(where: { $0.itemIdentifier == id }) {
                        toolbar.insertItem(withItemIdentifier: id, at: toolbar.items.firstIndex(where: { $0.itemIdentifier == tools }) ?? toolbar.items.count)
                    }
                }
                let index = toolbar.items.firstIndex { $0.itemIdentifier == tools }
                if isTerminal {
                    if index == nil { toolbar.insertItem(withItemIdentifier: tools, at: toolbar.items.count) }
                    updateToolWidth()
                } else if let index {
                    toolbar.removeItem(at: index)
                    toolsItem = nil
                    toolsWidth = nil
                }
                if isTerminal && !state.isToolReadingExpanded && tab != nil {
                    if !toolbar.items.contains(where: { $0.itemIdentifier == branch }) {
                        toolbar.insertItem(withItemIdentifier: branch,
                            at: toolbar.items.firstIndex(where: { $0.itemIdentifier == tools }) ?? toolbar.items.count)
                    }
                } else if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == branch }) {
                    toolbar.removeItem(at: index)
                }
            }
            updateInformation()
            FocusedTerminal.shared.refreshSoon()
        }

        private func updateInformation() {
            guard let informationView, let informationItem else { return }
            let width: CGFloat
            var contentWidth: CGFloat = 0
            var contentLeadingInset: CGFloat = 0
            if isPageToolbar, let content = window?.contentView,
               let split = findSplitView(in: content, identifier: "workspace.navigationSplit"),
               let detail = split.arrangedSubviews.last {
                // 收起侧栏后，红绿灯与侧栏按钮仍占用原生通栏左侧空间。
                let isSidebarCollapsed = split.arrangedSubviews.first.map { split.isSubviewCollapsed($0) } ?? false
                contentWidth = detail.frame.width
                contentLeadingInset = max(0, informationView.convert(.zero, to: nil).x - detail.convert(.zero, to: nil).x)
                width = max(120, detail.frame.width - (isSidebarCollapsed ? 160 : 32))
            } else {
                width = 0
            }
            if isPageToolbar {
                informationView.sizingOptions = []
                if informationWidth == nil {
                    informationWidth = informationView.widthAnchor.constraint(equalToConstant: width)
                }
                informationWidth?.constant = width
                informationWidth?.isActive = true
                informationItem.minSize = NSSize(width: width, height: Theme.Toolbar.height)
                informationItem.maxSize = NSSize(width: width, height: Theme.Toolbar.height)
            } else {
                informationWidth?.isActive = false
                informationView.sizingOptions = [.intrinsicContentSize]
                informationItem.minSize = NSSize(width: 120, height: Theme.Toolbar.height)
                informationItem.maxSize = NSSize(width: 720, height: Theme.Toolbar.height)
            }
            informationView.rootView = AnyView(WorkspaceToolbarInformation(model: model, state: state,
                contentWidth: contentWidth, contentLeadingInset: contentLeadingInset)
                .frame(width: isPageToolbar ? width : nil, height: Theme.Toolbar.height))
        }

        @objc private func windowDidResize(_ notification: Notification) { update() }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [sidebar, navigationSeparator, information, .flexibleSpace, branch, tools]
        }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            if id == navigationSeparator {
                guard let content = window?.contentView,
                      let splitView = findSplitView(in: content, identifier: "workspace.navigationSplit") else { return nil }
                return NSTrackingSeparatorToolbarItem(identifier: id, splitView: splitView, dividerIndex: 0)
            }
            if id == tools {
                let control = NSHostingView(rootView: WorkspaceToolbarTools(model: model, state: state, visibility: visibility, tabsWidth: toolTabsWidth))
                control.sizingOptions = []
                let width = control.widthAnchor.constraint(equalToConstant: toolGroupWidth)
                width.priority = .defaultLow
                width.isActive = true
                control.heightAnchor.constraint(equalToConstant: WorkspaceToolbarTools.height).isActive = true
                let item = NSToolbarItem(itemIdentifier: id)
                item.label = String(localized: "Workspace Tools")
                item.view = control
                item.autovalidates = false
                item.visibilityPriority = .high
                if #available(macOS 26.0, *) { item.isBordered = false }
                toolsItem = item
                toolsView = control
                toolsWidth = width
                return item
            }
            if id == information {
                let item = NSToolbarItem(itemIdentifier: id)
                let view = NSHostingView(rootView: AnyView(WorkspaceToolbarInformation(model: model, state: state)))
                view.sizingOptions = [.intrinsicContentSize]
                item.view = view
                informationItem = item
                informationView = view
                item.minSize = NSSize(width: 120, height: Theme.Toolbar.height)
                item.maxSize = NSSize(width: 720, height: Theme.Toolbar.height)
                item.visibilityPriority = .high
                if #available(macOS 26.0, *) { item.isBordered = false }
                return item
            }
            if id == branch {
                let item = NSToolbarItem(itemIdentifier: id)
                let view = NSHostingView(rootView: WorkspaceToolbarBranch(model: model, state: state))
                view.sizingOptions = [.intrinsicContentSize]
                item.view = view
                item.minSize = NSSize(width: 1, height: Theme.Toolbar.height)
                item.maxSize = NSSize(width: 240, height: Theme.Toolbar.height)
                item.visibilityPriority = .high
                item.isBordered = false
                return item
            }
            let item = NSToolbarItem(itemIdentifier: id)
            let title = AppShortcutID.toggleSidebar.title
            let control = NSHostingView(rootView: WorkspaceSidebarToggle(shortcut: .toggleSidebar,
                systemImage: "sidebar.left", identifier: "workspace.sidebar") { [weak self] in
                    guard let self else { return }
                    model.toggleSidebar(in: state)
                })
            control.sizingOptions = [.intrinsicContentSize]
            item.view = control
            item.autovalidates = false
            item.label = title
            item.toolTip = title + " (" + AppShortcuts.display(for: .toggleSidebar) + ")"
            item.isBordered = false
            return item
        }
        private func findSplitView(in view: NSView, identifier: String) -> NSSplitView? {
            if let split = view as? NSSplitView, split.identifier?.rawValue == identifier { return split }
            for child in view.subviews {
                if let split = findSplitView(in: child, identifier: identifier) { return split }
            }
            return nil
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func splitDidResize(_ notification: Notification) {
            guard let split = notification.object as? NSSplitView, split.window === window else { return }
            DispatchQueue.main.async { [weak self] in
                self?.updateToolWidth()
                self?.updateInformation()
            }
        }

        private var toolTabsWidth: CGFloat {
            let sidebarWidth: CGFloat
            if let content = window?.contentView,
               let split = findSplitView(in: content, identifier: "workspace.inspectorSplit"),
               let inspector = split.arrangedSubviews.last, !split.isSubviewCollapsed(inspector) {
                sidebarWidth = inspector.frame.width
            } else {
                sidebarWidth = CGFloat(state.presentation.toolSidebarWidth)
            }
            // 标签与开关共用右栏宽度，开关始终在最右端预留位置。
            return max(WorkspaceToolbarTools.height * 3,
                       sidebarWidth - WorkspaceToolbarTools.height - 4 * Theme.Space.s)
        }

        private var toolGroupWidth: CGFloat {
            guard state.presentation.toolSidebarOpen else { return WorkspaceToolbarTools.height }
            let tabsWidth = toolTabsWidth
            if state.isToolReadingExpanded {
                return window?.frame.width ?? state.toolPreviewFrame.width + tabsWidth
            }
            let previewWidth = state.toolPreviewFrame.width
            return tabsWidth + WorkspaceToolbarTools.height + 2 * Theme.Space.s
                + (previewWidth > 0 ? previewWidth + 2 * Theme.Space.s : 0)
        }

        private func updateToolWidth() {
            guard let toolsWidth else { return }
            let width = toolGroupWidth
            if abs(toolsWidth.constant - width) > 0.5 { toolsWidth.constant = width }
            toolsView?.rootView = WorkspaceToolbarTools(model: model, state: state, visibility: visibility, tabsWidth: toolTabsWidth)
            toolsItem?.minSize = NSSize(width: state.isToolReadingExpanded ? toolTabsWidth + 220 : width, height: WorkspaceToolbarTools.height)
            toolsItem?.maxSize = NSSize(width: width, height: WorkspaceToolbarTools.height)
        }
    }
}

/// 三个文字选项等宽排列，右端开关在侧栏展开或通栏悬停时显示。
private struct WorkspaceToolbarTools: View {
    static let height: CGFloat = Theme.Toolbar.height
    @ObservedObject var model: AppModel
    @ObservedObject var state: WindowState
    @ObservedObject var visibility: WorkspaceToolbarVisibility
    var tabsWidth: CGFloat
    @ObservedObject private var appearance = AppearanceDriver.shared
    @FocusState private var isControlFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var isMotionReduced
    @State private var hoveredTab: WorkspaceToolTab?

    private var chrome: WindowChrome { WindowChrome.resolve(isDark: appearance.isDark) }
    private var isToggleVisible: Bool {
        state.presentation.toolSidebarOpen || visibility.isRevealed
            || isControlFocused || NSWorkspace.shared.isVoiceOverEnabled
    }

    var body: some View {
        HStack(spacing: 2 * Theme.Space.s) {
            if state.toolPreviewFrame.width > 0 {
                WorkspacePreviewToolbar(model: model, state: state)
                    .frame(width: state.isToolReadingExpanded ? nil : state.toolPreviewFrame.width)
                    .frame(maxWidth: state.isToolReadingExpanded ? .infinity : nil)
            }
            if state.presentation.toolSidebarOpen {
                HStack(spacing: 0) {
                    ForEach(WorkspaceToolTab.allCases, id: \.self) { tab in
                        let isSelected = state.toolSidebarTab == tab
                        Button {
                            state.toolSidebarTab = tab
                        } label: {
                            Text(verbatim: tab.title)
                                .font(.system(size: Theme.Toolbar.textSize, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? chrome.selectionText : chrome.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .frame(height: Self.height)
                                .background(isSelected ? chrome.accentFill : hoveredTab == tab ? chrome.hoverFill : .clear,
                                            in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                                .padding(.horizontal, 2)
                                .contentShape(Rectangle())
                        }
                        .onHover { hoveredTab = $0 ? tab : nil }
                        .help(tab.title)
                        .accessibilityLabel(tab.title)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityIdentifier("workspace.tools.\(tab.rawValue)")
                    }
                }
                .frame(width: tabsWidth)
            }
            WorkspaceSidebarToggle(shortcut: .toggleToolSidebar,
                systemImage: "sidebar.right", identifier: "workspace.inspector") {
                model.toggleToolSidebar(in: state)
            }
            .focused($isControlFocused)
            .opacity(isToggleVisible ? 1 : 0)
            .allowsHitTesting(isToggleVisible)
            .animation(isMotionReduced ? nil : .easeOut(duration: 0.15), value: isToggleVisible)
        }
        .buttonStyle(FamilyPlainButtonStyle())
        .frame(height: Self.height)
        .preferredColorScheme(appearance.interfaceColorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Workspace Tools"))
        .accessibilityIdentifier("workspace.tools")
    }
}

/// 左右侧栏共用扁平按钮，只在悬停和按下时显示底色。
private struct WorkspaceSidebarToggle: View {
    let shortcut: AppShortcutID
    let systemImage: String
    let identifier: String
    let action: () -> Void
    @ObservedObject private var appearance = AppearanceDriver.shared

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Theme.Toolbar.iconFont)
                .frame(width: Theme.Toolbar.height, height: Theme.Toolbar.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(WorkspaceSidebarButtonStyle(chrome: WindowChrome.resolve(isDark: appearance.isDark)))
        .help(shortcut.title + " (" + AppShortcuts.display(for: shortcut) + ")")
        .accessibilityLabel(shortcut.title)
        .accessibilityIdentifier(identifier)
        .preferredColorScheme(appearance.interfaceColorScheme)
    }
}

private struct WorkspaceSidebarButtonStyle: ButtonStyle {
    let chrome: WindowChrome
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(chrome.text)
            .background(configuration.isPressed ? chrome.accentFill : isHovered ? chrome.hoverFill : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .onHover { isHovered = $0 }
            .clickableCursor()
    }
}

/// 文件和改动预览共用通栏标题及阅读操作。
private struct WorkspacePreviewToolbar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WindowState
    var body: some View {
        HStack(spacing: 8) {
            if let request = state.toolGitPreview {
                FileTypeIcon(name: (request.change.path as NSString).lastPathComponent)
                Text(verbatim: (request.change.path as NSString).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle).help(request.change.path)
                if let stats = request.change.lineStats { GitLineStatsLabel(stats: stats).fixedSize() }
            } else if let column = state.toolPreviewColumn {
                WorkspacePreviewFileTitle(column: column)
            }
            Spacer(minLength: 4)
            Button {
                NSApp.keyWindow?.makeFirstResponder(nil)
                state.isToolPreviewExpanded.toggle()
            } label: {
                Image(systemName: state.isToolReadingExpanded
                    ? "arrow.down.left.and.arrow.up.right" : "arrow.up.right.and.arrow.down.left")
                    .font(Theme.Toolbar.iconFont)
                    .frame(width: Theme.Toolbar.height, height: Theme.Toolbar.height).contentShape(Rectangle())
            }
            .help(state.isToolReadingExpanded ? String(localized: "Collapse Reading") : String(localized: "Expand Reading"))
            .accessibilityLabel(state.isToolReadingExpanded ? String(localized: "Collapse Reading") : String(localized: "Expand Reading"))
            .accessibilityIdentifier("workspace.preview.expand")
            Button { state.toolPreviewFindRequest += 1 } label: {
                Image(systemName: "magnifyingglass")
                    .font(Theme.Toolbar.iconFont)
                    .frame(width: Theme.Toolbar.height, height: Theme.Toolbar.height).contentShape(Rectangle())
            }
            .help(String(localized: "Find in Preview") + " (" + AppShortcuts.display(for: .find) + ")").accessibilityLabel(Text("Find in Preview"))
            .accessibilityIdentifier("workspace.preview.find")
            Button {
                state.closeToolPreview()
                if let tab = model.selectedTab(in: state) { SSHTerminalRegistry.focus(tab.sessionID) }
            } label: {
                Image(systemName: "xmark")
                    .font(Theme.Toolbar.iconFont)
                    .frame(width: Theme.Toolbar.height, height: Theme.Toolbar.height).contentShape(Rectangle())
            }
            .help("Close Preview").accessibilityLabel(Text("Close Preview"))
            .accessibilityIdentifier("workspace.preview.close")
        }
        .font(Theme.Font.paneTitle)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.preview.toolbar")
    }
}

private struct WorkspacePreviewFileTitle: View {
    @ObservedObject var column: FileColumn
    var body: some View {
        if let preview = column.preview {
            FileTypeIcon(name: preview.entry.name)
            Text(verbatim: preview.entry.name).lineLimit(1).truncationMode(.middle).help(preview.entry.path)
        }
    }
}

final class ToolbarAttachmentView: NSView {
    var onWindow: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.onWindow?(window)
            }
        }
    }
}

/// 跟踪整条通栏的悬停状态，供右侧展开按钮使用；点击继续交给原有控件。
struct ToolbarHoverTracking: NSViewRepresentable {
    var onHover: (Bool) -> Void = { _ in }
    func makeNSView(context: Context) -> ToolbarHoverTrackingView {
        let view = ToolbarHoverTrackingView()
        view.onHover = onHover
        return view
    }
    func updateNSView(_ view: ToolbarHoverTrackingView, context: Context) { view.onHover = onHover }
}

final class ToolbarHoverTrackingView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    private var isHovered = false
    private var mouseMonitor: Any?
    private weak var trackingView: NSView?
    private var toolbarTrackingArea: NSTrackingArea?

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let toolbarTrackingArea { trackingView?.removeTrackingArea(toolbarTrackingArea) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var toolbarRect: NSRect {
        guard let window, window.toolbar?.isVisible == true else { return .zero }
        let bottom = window.contentLayoutRect.maxY
        return NSRect(x: 0, y: bottom, width: window.frame.width,
                      height: max(0, window.frame.height - bottom))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard let host = window?.contentView?.superview else { return }
        // 跟踪区域放到窗口视图，覆盖原生标题栏及两侧按钮。
        let rect = host.convert(toolbarRect, from: nil)
        if trackingView === host, toolbarTrackingArea?.rect == rect { return }
        if let toolbarTrackingArea { trackingView?.removeTrackingArea(toolbarTrackingArea) }
        let area = NSTrackingArea(rect: rect,
            options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        trackingView = host
        toolbarTrackingArea = area
        host.addTrackingArea(area)
        setHovered(toolbarRect.contains(window!.mouseLocationOutsideOfEventStream))
    }
    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        // 跟踪区域可能在布局过程中刷新，延后发布，避免在 SwiftUI 更新中修改状态。
        DispatchQueue.main.async { [weak self] in self?.onHover(hovered) }
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        if let toolbarTrackingArea { trackingView?.removeTrackingArea(toolbarTrackingArea) }
        toolbarTrackingArea = nil
        trackingView = nil
        setHovered(false)
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        updateTrackingAreas()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged]) { [weak self] event in
            guard let self else { return event }
            setHovered(event.window === self.window && toolbarRect.contains(event.locationInWindow))
            return event
        }
    }
}

private struct WorkspaceToolbarInformation: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WindowState
    var contentWidth: CGFloat = 0
    var contentLeadingInset: CGFloat = 0
    @ObservedObject private var appearance = AppearanceDriver.shared

    var body: some View {
        Group {
            if state.section == .commands {
                QuickCommandLibraryHeader(model: model, window: state)
            } else if state.presentation.fullFilesWorkspace {
                FilesWorkspaceToolbar(workspace: model.fileWorkspace(for: state),
                    contentWidth: contentWidth, contentLeadingInset: contentLeadingInset)
            } else {
                FocusedWorkspaceInformation(model: model, state: state)
            }
        }
        .environment(\.windowChrome, WindowChrome.resolve(isDark: appearance.isDark))
        .preferredColorScheme(appearance.interfaceColorScheme)
        .font(Theme.Font.body)
        .foregroundStyle(WindowChrome.resolve(isDark: appearance.isDark).text)
    }
}

/// 分支放在弹性空白之后，紧靠终端右边界；打开预览时随右侧工具区一起左移。
private struct WorkspaceToolbarBranch: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WindowState
    @ObservedObject private var appearance = AppearanceDriver.shared

    var body: some View {
        Group {
            if let tab = model.selectedTab(in: state) {
                TerminalGitBadge(tab: tab, model: model, window: state).id(tab.id)
                    .frame(maxWidth: 240, alignment: .trailing)
            }
        }
        .environment(\.windowChrome, WindowChrome.resolve(isDark: appearance.isDark))
        .preferredColorScheme(appearance.interfaceColorScheme)
        .foregroundStyle(WindowChrome.resolve(isDark: appearance.isDark).text)
    }
}

private struct FocusedWorkspaceInformation: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WindowState
    @ObservedObject private var appearance = AppearanceDriver.shared

    private var chrome: WindowChrome { WindowChrome.resolve(isDark: appearance.isDark) }

    private func title(_ tab: TerminalTab) -> String {
        let name: String
        if let custom = tab.contentTitle { name = custom }
        else if tab.isLocal, let directory = tab.directory {
            let last = (directory as NSString).lastPathComponent
            name = last.isEmpty ? String(localized: "This Mac") : last
        } else { name = tab.alias ?? String(localized: "Terminal") }
        return model.paneNumber(for: tab.id, in: state).map { "\($0)-\(name)" } ?? name
    }

    var body: some View {
        HStack(spacing: 12) {
            if state.section == .commands {
                Text("Command Library").font(.headline)
            } else if state.presentation.fullFilesWorkspace {
                Text("Files").font(.headline)
            } else if let tab = model.selectedTab(in: state) {
                Text(tab.isLocal ? String(localized: "This Mac") : String(localized: "Remote"))
                    .font(.system(size: Theme.Toolbar.textSize, weight: .medium))
                    .foregroundStyle(chrome.secondary)
                    .padding(.horizontal, Theme.Space.s)
                    .frame(height: Theme.Toolbar.height)
                    .background(chrome.hoverFill,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .fixedSize()
                Text(verbatim: title(tab)).font(.headline)
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("workspace.focusedTerminalTitle")
                if let path = TerminalPaneActions.workingDirectory(of: tab) {
                    Text(verbatim: tab.isLocal ? LocalTerminal.displayPath(path) : path)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(path)
                }
                RemoteTitleStatus(tab: tab)
            } else {
                Text("1Agent").font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.windowChrome, chrome)
        .accessibilityIdentifier("workspace.focusedInformation")
    }
}
