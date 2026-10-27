import AppKit
import Combine
import SwiftUI

/// One open terminal panel or current file endpoint, captured without changing its live state.
struct SwitcherItem: Identifiable, Equatable {
    enum Kind { case terminals, files }
    let id: UUID
    let targetID: UUID
    let title: String
    let subtitle: String
    let layout: PaneNode
    let panes: [SwitcherPane]
    var kind: Kind = .terminals
    var connectionGroup: SidebarConnectionGroup = .local
    var searchText: String = ""
    var fileRows: [SwitcherFileRow] = []
    var filePreview: String? = nil
    var fileStatus: String? = nil
    var isRemoteFile = false
    var filePreviewPath: String? = nil
    var fileSymbol: String { filePreviewPath == nil ? "folder.fill" : "doc" }
    var typeTitle: String {
        if kind == .terminals { return String(localized: "Terminal") }
        return filePreviewPath == nil ? String(localized: "Folder") : String(localized: "File")
    }
}

struct SwitcherFileRow: Identifiable, Equatable {
    let id: String
    let name: String
    let isDirectory: Bool
}

enum SwitcherScope: String, CaseIterable {
    case all, local, remote, files
    var title: String {
        switch self {
        case .all: return String(localized: "All Open Items")
        case .local: return String(localized: "This Mac")
        case .remote: return String(localized: "Remote")
        case .files: return String(localized: "Files")
        }
    }

    func contains(_ item: SwitcherItem) -> Bool {
        switch self {
        case .all: return true
        // 混合分屏在两类中都可找到，仍以完整面板预览和切换。
        case .local: return item.kind == .terminals && item.connectionGroup != .remote
        case .remote: return item.kind == .terminals && item.connectionGroup != .local
        case .files: return item.kind == .files
        }
    }
}

struct SwitcherPane: Identifiable, Equatable {
    let id: UUID
    let lines: [String]?
    let sessionID: String
}

/// Where the window was when the switcher opened; cancelling returns here.
private struct SwitcherOrigin {
    let section: AppSection
    let selectedTabID: UUID?
    let sidebarSelection: Set<UUID>
    let sidebarAnchor: UUID?
    let fileColumnID: UUID?
}

/// 切换面板默认固定；松开快捷键、切换选择或失焦都不会自动关闭。
/// Escape 退出并回到打开时或最近一次明确确认的位置。
/// The main terminal receives no key-down events while the picker is visible.
@MainActor
final class TerminalSwitcher: ObservableObject {
    static let shared = TerminalSwitcher()
    /// Rapid ⌃⇥ presses only load the item the highlight rests on.
    private static let previewDelay: TimeInterval = 0.12

    @Published private(set) var items: [SwitcherItem] = []
    @Published private(set) var highlighted: UUID? {
        didSet {
            if highlighted != oldValue && highlighted != nil && isOpen { schedulePreview() }
        }
    }
    @Published private(set) var originID: UUID?
    @Published var query = "" { didSet { reconcileHighlight() } }
    @Published var scope: SwitcherScope = .all { didSet { reconcileHighlight() } }
    @Published private(set) var isSearching = false
    @Published private(set) var isPresented = false
    weak var searchField: NSSearchField?

    var filteredItems: [SwitcherItem] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return items.filter { item in
            scope.contains(item) && words.allSatisfy {
                (item.title + " " + item.subtitle + " " + item.searchText).localizedStandardContains($0)
            }
        }
    }

    private func reconcileHighlight() {
        if !filteredItems.contains(where: { $0.id == highlighted }) { highlighted = filteredItems.first?.id }
    }

    func beginSearch() {
        guard isOpen else { return }
        isSearching = true
        panel?.makeKey()
        if let searchField, searchField.window != nil {
            panel?.makeFirstResponder(searchField)
            searchField.selectText(nil)
        }
    }

    /// Row and panel frames in `TerminalSwitcherView.space`. Clicks are hit-tested against them because
    /// a click with Control still held after ⌃⇥ never reaches a SwiftUI tap gesture.
    var cardFrames: [UUID: CGRect] = [:]
    var scopeFrames: [SwitcherScope: CGRect] = [:]
    var boxFrame: CGRect = .zero
    var resultsFrame: CGRect = .zero

    private weak var model: AppModel?
    private weak var windowState: WindowState?
    private weak var hostWindow: NSWindow?
    private var panel: NSPanel?
    private var dismissingPanel: NSPanel?
    private var pendingDismissal: DispatchWorkItem?
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var origin: SwitcherOrigin?
    private var previewedID: UUID?
    private var pendingPreview: DispatchWorkItem?

    var isOpen: Bool { panel != nil }

    /// 固定的面板只接收所属窗口的输入，不影响其他窗口。
    func handlesEvents(in window: NSWindow?) -> Bool {
        guard isOpen, let window else { return false }
        return window === panel || window === hostWindow
    }

    /// Shows every open sidebar panel. The optional host supports isolated native-window tests.
    @discardableResult
    func open(model: AppModel, window: WindowState, chord: KeyChord, host: NSWindow? = nil, searching: Bool = false) -> Bool {
        if isOpen {
            if windowState === window {
                if searching { beginSearch(); return true }
                move(by: chord.modifiers.contains(.shift) ? -1 : 1)
                return true
            }
            cancel()
        }
        finishDismissal()
        let rows = model.panelRows(in: window)
        guard let host = host ?? MainWindowManager.shared.window(for: window), host.isVisible else {
            return false
        }
        self.model = model
        windowState = window
        hostWindow = host
        query = ""
        scope = .all
        isSearching = false
        items = rows.compactMap { Self.item(for: $0, model: model) } + Self.fileItems(model: model, window: window)
        guard !items.isEmpty else { return false }
        let fileID = FileBrowserStore.shared.existingWorkspace(for: window)?.focusedColumn?.id
        let current = items.firstIndex { item in
            window.section == .files ? item.kind == .files && item.id == fileID :
                item.kind == .terminals && window.selectedTabID.map { PaneLayout.contains($0, in: item.layout) } == true
        } ?? -1
        origin = SwitcherOrigin(section: window.section, selectedTabID: window.selectedTabID,
                                sidebarSelection: window.sidebarSelection, sidebarAnchor: window.sidebarAnchor,
                                fileColumnID: fileID)
        if current >= 0 {
            originID = items[current].id
        }
        previewedID = originID
        let step = chord.modifiers.contains(.shift) ? -1 : 1
        highlighted = items[searching ? max(0, current) : Self.wrapped(current + step, count: items.count)].id
        showPanel(over: host)
        watch(model: model, window: window, host: host)
        schedulePreview()
        if searching { beginSearch() }
        return true
    }

    /// Keys while the switcher is open. True when the event is used up.
    func handle(_ event: NSEvent) -> Bool {
        guard handlesEvents(in: event.window), event.type == .keyDown else { return false }
        if isSearching, (searchField?.currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 53: cancel()
        case 36, 76: commit()
        case 48: move(by: shift ? -1 : 1)
        case 123: if isSearching { return false }; move(by: -1)
        case 124: if isSearching { return false }; move(by: 1)
        case 125: move(by: 1)
        case 126: move(by: -1)
        default:
            if isSearching { return false }
            if !event.modifierFlags.intersection([.control, .command]).isEmpty { return true }
            if let text = event.characters, !text.isEmpty {
                beginSearch()
                searchField?.currentEditor()?.interpretKeyEvents([event])
            }
        }
        return true
    }

    func move(by delta: Int) {
        let visible = filteredItems
        guard !visible.isEmpty else { return }
        let index = highlighted.flatMap { id in visible.firstIndex { $0.id == id } } ?? 0
        highlighted = visible[Self.wrapped(index + delta, count: visible.count)].id
    }

    func commit(_ id: UUID? = nil) {
        guard isOpen, let item = filteredItems.first(where: { $0.id == (id ?? highlighted) }) else { return }
        let target = item.targetID
        guard let model, let window = windowState else { return }
        if item.kind == .files {
            guard let workspace = FileBrowserStore.shared.existingWorkspace(for: window),
                  let column = workspace.openColumns.first(where: { $0.id == target }) else { return }
            model.showSection(.files, in: window)
            workspace.activate(column)
        } else if model.sidebarOrder(in: window).contains(target) {
            model.selectOnly(target, in: window, focusTerminal: false)
            if window.section != .terminals {
                model.showSection(.terminals, in: window)
            }
        } else {
            return
        }
        pendingPreview?.cancel()
        pendingPreview = nil
        highlighted = item.id
        previewedID = item.id
        originID = item.id
        origin = SwitcherOrigin(section: window.section, selectedTabID: window.selectedTabID,
                                sidebarSelection: window.sidebarSelection, sidebarAnchor: window.sidebarAnchor,
                                fileColumnID: FileBrowserStore.shared.existingWorkspace(for: window)?.focusedColumn?.id)
    }

    /// 退出面板并恢复打开时的位置；明确确认过选择时，以最近确认的位置为准。
    func cancel() {
        guard isOpen else { return }
        let model = self.model
        let window = windowState
        let origin = self.origin
        let isMoved = previewedID != originID
        close()
        guard isMoved, let model, let window, let origin else { return }
        if let id = origin.selectedTabID, model.tabs.contains(where: { $0.id == id }) {
            model.selectTab(id, in: window, focusTerminal: false)
        }
        window.sidebarSelection = origin.sidebarSelection
        window.sidebarAnchor = origin.sidebarAnchor
        if let workspace = FileBrowserStore.shared.existingWorkspace(for: window),
           let column = workspace.openColumns.first(where: { $0.id == origin.fileColumnID }) {
            workspace.activate(column)
        }
        model.showSection(origin.section, in: window)
    }

    /// Shows the highlighted item in the window behind immediately, dropping any pending preview.
    func previewNow() {
        pendingPreview?.cancel()
        pendingPreview = nil
        guard isOpen, let model, let window = windowState,
              let item = items.first(where: { $0.id == highlighted }), item.id != previewedID else { return }
        previewedID = item.id
        if item.kind == .files {
            guard let workspace = FileBrowserStore.shared.existingWorkspace(for: window),
                  let column = workspace.openColumns.first(where: { $0.id == item.targetID }) else { return }
            if window.section != .files {
                model.showSection(.files, in: window)
            }
            workspace.activate(column)
        } else if model.sidebarOrder(in: window).contains(item.targetID) {
            model.selectOnly(item.targetID, in: window, focusTerminal: false)
            if window.section != .terminals {
                model.showSection(.terminals, in: window)
            }
        }
    }

    private func schedulePreview() {
        pendingPreview?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.previewNow() }
        }
        pendingPreview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewDelay, execute: work)
    }

    // MARK: - Panel

    private func showPanel(over host: NSWindow) {
        let panel = SwitcherPanel(
            contentRect: Self.panelFrame(over: host),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = host.appearance
        let chrome = WindowChrome.resolve(isDark: AppearanceDriver.shared.isDark)
        var cornerRadius = SwitcherLayout.windowCornerRadius
        if host.styleMask.contains(.fullScreen) {
            cornerRadius = 0
        }
        let root = TerminalSwitcherView(switcher: self, chrome: chrome, windowCornerRadius: cornerRadius)
            .environment(\.windowChrome, chrome)
            .preferredColorScheme(AppearanceDriver.shared.interfaceColorScheme)
        panel.contentView = FirstMouseHostingView(rootView: root)
        self.panel = panel
        host.addChildWindow(panel, ordered: .above)
        panel.contentView?.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            self.isPresented = true
        }
    }

    /// The dimming covers the whole window, title bar included.
    private static func panelFrame(over host: NSWindow) -> NSRect {
        host.frame
    }

    private func watch(model: AppModel, window: WindowState, host: NSWindow) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: host, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: host, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, let host = self.hostWindow else { return }
                    panel.setFrame(Self.panelFrame(over: host), display: true)
                }
            },
        ]
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return event }
                return self.click(event, in: panel) ? nil : event
            }
        }
        // Published values fire before they change; the check runs once the new terminals are in place.
        model.$tabs.combineLatest(window.$blocks, model.$workspaces)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                MainActor.assumeIsolated { self?.refreshOpenItems() }
            }
            .store(in: &subscriptions)
        if let files = FileBrowserStore.shared.existingWorkspace(for: window) {
            files.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.refreshOpenItems()
            }.store(in: &subscriptions)
        }
    }

    /// 单击预览、双击确认；点击遮罩不关闭，也不穿透到后面的终端。
    private func click(_ event: NSEvent, in panel: NSPanel) -> Bool {
        guard event.window === panel, let view = panel.contentView else {
            return event.window === hostWindow
        }
        var point = view.convert(event.locationInWindow, from: nil)
        if !view.isFlipped { point.y = view.bounds.height - point.y }
        guard boxFrame.contains(point) else { return true }
        // 筛选按钮整块区域都可点击；首次点击或按住 Ctrl 时不交给搜索框抢焦点。
        if let hit = scopeFrames.first(where: { $0.value.contains(point) }) {
            if event.type == .leftMouseDown || event.modifierFlags.contains(.control) {
                scope = hit.key
            }
            return true
        }
        if resultsFrame.contains(point), let hit = cardFrames.first(where: { $0.value.contains(point) }) {
            if event.type == .leftMouseDown && event.clickCount >= 2 {
                commit(hit.key)
            } else {
                highlighted = hit.key
                previewNow()
            }
            return true
        }
        // Native search/picker controls must receive their mouse event and can take keyboard focus.
        if !isSearching { beginSearch() }
        return false
    }

    private func refreshOpenItems() {
        guard isOpen, let model, let windowState else { return }
        let rows = model.panelRows(in: windowState)
        let terminals = rows.compactMap { Self.item(for: $0, model: model) }
        let updated = Dictionary(uniqueKeysWithValues: terminals.map { ($0.id, $0) })
        // Keep terminal order stable while cycling; file endpoints track the current two columns.
        items = items.filter { $0.kind == .terminals }.compactMap { updated[$0.id] }
            + Self.fileItems(model: model, window: windowState)
        if items.isEmpty {
            cancel()
            return
        }
        reconcileHighlight()
    }

    private func close() {
        guard let panel else { return }
        let restoreKey = panel.isKeyWindow && NSApp.isActive
        self.panel = nil
        dismissingPanel = panel
        isPresented = false
        // 选择立即生效，退场中的面板不再接收输入。
        panel.ignoresMouseEvents = true
        panel.contentView?.setAccessibilityHidden(true)
        if restoreKey { hostWindow?.makeKey() }
        searchField = nil
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        subscriptions = []
        pendingPreview?.cancel()
        pendingPreview = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finishDismissal()
        } else {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.finishDismissal() }
            }
            pendingDismissal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.overviewOutDuration, execute: work)
        }
    }

    /// 重开时先移除旧面板，旧退场回调不能清空新一轮预览。
    private func finishDismissal() {
        pendingDismissal?.cancel()
        pendingDismissal = nil
        if let dismissingPanel {
            dismissingPanel.parent?.removeChildWindow(dismissingPanel)
            dismissingPanel.orderOut(nil)
            dismissingPanel.contentView = nil
        }
        dismissingPanel = nil
        isPresented = false
        isSearching = false
        query = ""
        scope = .all
        items = []
        highlighted = nil
        origin = nil
        originID = nil
        previewedID = nil
        cardFrames = [:]
        scopeFrames = [:]
        boxFrame = .zero
        resultsFrame = .zero
    }

    // MARK: - Items

    private static func item(for row: TerminalPanelRow, model: AppModel) -> SwitcherItem? {
        guard let tab = model.tabs.first(where: { $0.id == row.focusedTabID }) else { return nil }
        let layout = model.workspaces.compactMap { $0.panel(containing: row.focusedTabID) }.first?.layout
            ?? .leaf(row.focusedTabID)
        let panes = row.leafIDs.compactMap { id -> SwitcherPane? in
            guard let leaf = model.tabs.first(where: { $0.id == id }) else { return nil }
            let text = SSHTerminalRegistry.viewportText(for: leaf.sessionID)
            var lines = text?.components(separatedBy: "\n")
            while let last = lines?.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines?.removeLast()
            }
            return SwitcherPane(id: id, lines: lines, sessionID: leaf.sessionID)
        }
        let path = tab.isLocal ? tab.directory.map(LocalTerminal.displayPath) : tab.remoteDirectory
        let subtitle = [tab.isLocal ? String(localized: "This Mac") : tab.alias, path]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let title = tab.isLocal && row.name == path && path != "~" && path != "/"
            ? (row.name as NSString).lastPathComponent : row.name
        return SwitcherItem(id: row.id, targetID: row.focusedTabID, title: title,
                            subtitle: subtitle, layout: layout, panes: panes,
                            connectionGroup: model.connectionGroup(for: row.leafIDs), searchText: row.leafIDs.compactMap { id in
                                model.tabs.first { $0.id == id }.map { leaf in
                                    [leaf.alias, leaf.directory, leaf.remoteDirectory,
                                     model.hosts.first { $0.alias == leaf.alias }?.hostName,
                                     model.hosts.first { $0.alias == leaf.alias }?.source].compactMap { $0 }.joined(separator: " ")
                                }
                            }.joined(separator: " "))
    }

    private static func fileItems(model: AppModel, window: WindowState) -> [SwitcherItem] {
        guard let workspace = FileBrowserStore.shared.previewWorkspace(for: window, model: model) else { return [] }
        return workspace.openColumns.map { column in
            let path = column.savedPath ?? "~"
            let preview = column.savedPreviewPath
            let host = model.hosts.first { $0.alias == column.fileSystem.host }
            let displayPath = column.isRemote ? path : LocalTerminal.displayPath(path)
            let title = preview.map { ($0 as NSString).lastPathComponent }
                ?? (displayPath == "~" || displayPath == "/" ? column.title : (displayPath as NSString).lastPathComponent)
            return SwitcherItem(id: column.id, targetID: column.id, title: title,
                subtitle: column.title + " · " + displayPath, layout: .leaf(column.id), panes: [], kind: .files,
                searchText: [host?.hostName, host?.source, preview, path].compactMap { $0 }.joined(separator: " "),
                fileRows: column.shown.prefix(16).map { SwitcherFileRow(id: $0.path, name: $0.name, isDirectory: $0.isDirectory) },
                filePreview: column.preview?.decoded.map { String($0.text.prefix(16000)) },
                fileStatus: column.preview?.error ?? column.error ?? (column.loading ? String(localized: "Loading…") : nil),
                isRemoteFile: column.isRemote, filePreviewPath: preview)
        }
    }

    private static func wrapped(_ index: Int, count: Int) -> Int {
        ((index % count) + count) % count
    }
}

/// Browsing leaves the host key; searching gives the native search field its own field editor.
private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 非搜索状态下，首次点击也应直接选中列表项。
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct SwitcherCardFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct SwitcherScopeFramesKey: PreferenceKey {
    static let defaultValue: [SwitcherScope: CGRect] = [:]
    static func reduce(value: inout [SwitcherScope: CGRect], nextValue: () -> [SwitcherScope: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct SwitcherBoxFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    /// Views that never report keep the default; they must not wipe the panel's frame.
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private struct SwitcherResultsFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    /// Views that never report keep the default; they must not wipe the results frame.
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

struct TerminalSwitcherView: View {
    static let space = "terminalSwitcher"
    @Environment(\.accessibilityReduceMotion) private var isMotionReduced
    @ObservedObject var switcher: TerminalSwitcher
    let chrome: WindowChrome
    var windowCornerRadius: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, min(SwitcherLayout.maxWidth, proxy.size.width - 2 * SwitcherLayout.windowInset))
            let contentWidth = max(1, width - 2 * SwitcherLayout.panelPadding)
            let height = max(1, min(SwitcherLayout.contentHeight,
                proxy.size.height - 2 * SwitcherLayout.windowInset - SwitcherLayout.chromeHeight))
            ZStack {
                RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous)
                    .fill(Color.black.opacity(SwitcherLayout.maskOpacity))
                    .opacity(switcher.isPresented ? 1 : 0)
                VStack(spacing: SwitcherLayout.spacing) {
                    HStack(spacing: 8) {
                        Text("Open Items Overview").font(.system(size: 15, weight: .semibold))
                        Text(verbatim: "\(switcher.filteredItems.count)").foregroundStyle(chrome.secondary)
                        Spacer()
                        Button { switcher.cancel() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).foregroundStyle(chrome.secondary)
                            .accessibilityLabel(Text("Close"))
                    }.frame(height: SwitcherLayout.headerHeight)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(chrome.secondary)
                        SwitcherSearchField(switcher: switcher, chrome: chrome)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: SwitcherLayout.searchHeight)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(chrome.background.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .stroke(switcher.isSearching ? chrome.accent.opacity(0.6) : chrome.hairline, lineWidth: 1))
                    scopes
                    if contentWidth >= SwitcherLayout.sideBySideWidth {
                        HStack(spacing: SwitcherLayout.detailGap) {
                            results.frame(width: min(SwitcherLayout.listWidth, contentWidth * SwitcherLayout.listShare))
                            Rectangle().fill(chrome.hairline).frame(width: 1)
                            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }.frame(height: height)
                    } else {
                        VStack(spacing: SwitcherLayout.spacing) {
                            results.frame(height: max(1, (height - SwitcherLayout.spacing) * 0.45))
                            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }.frame(height: height)
                    }
                    HStack(spacing: 16) {
                        Text("↑↓ Select")
                        Text("↵ Switch")
                        Text("Esc Go Back")
                        Spacer(minLength: 0)
                    }
                    .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(height: SwitcherLayout.footerHeight)
                    .overlay(alignment: .top) { Rectangle().fill(chrome.hairline).frame(height: 1) }
                }
                .foregroundStyle(chrome.text)
                .frame(width: contentWidth).padding(SwitcherLayout.panelPadding)
                .background(RoundedRectangle(cornerRadius: SwitcherLayout.panelCornerRadius).fill(chrome.elevated))
                .overlay(RoundedRectangle(cornerRadius: SwitcherLayout.panelCornerRadius).stroke(chrome.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(chrome.isDark ? 0.2 : 0.1), radius: 20, y: 8)
                .background(GeometryReader { box in
                    Color.clear.preference(key: SwitcherBoxFrameKey.self, value: box.frame(in: .named(Self.space)))
                })
                .scaleEffect(switcher.isPresented || isMotionReduced ? 1 : Theme.Motion.overviewInitialScale)
                .offset(y: switcher.isPresented || isMotionReduced ? 0 : Theme.Motion.overviewOffset)
                .opacity(switcher.isPresented ? 1 : 0)
            }
            .animation(isMotionReduced ? nil : .easeOut(duration: switcher.isPresented
                ? Theme.Motion.overviewInDuration : Theme.Motion.overviewOutDuration), value: switcher.isPresented)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(SwitcherCardFramesKey.self) { switcher.cardFrames = $0 }
            .onPreferenceChange(SwitcherScopeFramesKey.self) { switcher.scopeFrames = $0 }
            .onPreferenceChange(SwitcherBoxFrameKey.self) { switcher.boxFrame = $0 }
            .onPreferenceChange(SwitcherResultsFrameKey.self) { switcher.resultsFrame = $0 }
        }
    }

    private var scopes: some View {
        HStack(spacing: 4) {
            ForEach(SwitcherScope.allCases, id: \.self) { scope in
                let isSelected = switcher.scope == scope
                let count = switcher.items.filter { scope.contains($0) }.count
                Button { switcher.scope = scope } label: {
                    HStack(spacing: 7) {
                        Text(verbatim: scope.title)
                        Text(verbatim: "\(count)").foregroundStyle(isSelected ? chrome.accent : chrome.secondary)
                    }
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .padding(.horizontal, 14).frame(height: SwitcherLayout.scopeHeight)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(isSelected ? chrome.accentFill : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(GeometryReader { button in
                    Color.clear.preference(key: SwitcherScopeFramesKey.self,
                        value: [scope: button.frame(in: .named(Self.space))])
                })
                .foregroundStyle(isSelected ? chrome.accent : chrome.secondary)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("switcher.scope.\(scope.rawValue)")
            }
            Spacer(minLength: 0)
        }.frame(height: SwitcherLayout.scopeHeight)
    }

    private var results: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(switcher.filteredItems) { item in
                        SwitcherRow(item: item, isHighlighted: item.id == switcher.highlighted, chrome: chrome)
                            .id(item.id)
                            .accessibilityAction { switcher.commit(item.id) }
                            .background(GeometryReader { row in
                                Color.clear.preference(key: SwitcherCardFramesKey.self,
                                    value: [item.id: row.frame(in: .named(Self.space))])
                            })
                    }
                }.padding(.trailing, 6)
            }
            .background(GeometryReader { area in
                Color.clear.preference(key: SwitcherResultsFrameKey.self, value: area.frame(in: .named(Self.space)))
            })
            .onAppear { if let id = switcher.highlighted { reader.scrollTo(id) } }
            .onChange(of: switcher.highlighted) { _, id in
                if let id { reader.scrollTo(id) }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let item = switcher.filteredItems.first(where: { $0.id == switcher.highlighted }) {
            SwitcherDetail(item: item, isOrigin: item.id == switcher.originID, chrome: chrome)
                .id(item.id)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 28))
                Text("No Matching Open Items").font(Theme.Font.body)
            }.foregroundStyle(chrome.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A real field editor provides selection, clipboard shortcuts and Chinese input composition.
/// The native bezel and focus ring stay off so the surrounding view can draw the window chrome colors.
private struct SwitcherSearchField: NSViewRepresentable {
    @ObservedObject var switcher: TerminalSwitcher
    let chrome: WindowChrome
    func makeCoordinator() -> Coordinator { Coordinator(switcher) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        field.font = .systemFont(ofSize: 13)
        field.textColor = NSColor(chrome.text)
        let placeholder = String(localized: "Search name, host, IP or path")
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor(chrome.secondary),
            .font: NSFont.systemFont(ofSize: 13),
        ])
        field.setAccessibilityLabel(placeholder)
        field.setAccessibilityIdentifier("switcher.search")
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        switcher.searchField = field
        DispatchQueue.main.async {
            if switcher.isSearching { switcher.beginSearch() }
        }
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != switcher.query { field.stringValue = switcher.query }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let switcher: TerminalSwitcher
        init(_ switcher: TerminalSwitcher) { self.switcher = switcher }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            switcher.query = field.stringValue
        }
    }
}

private struct SwitcherRow: View {
    let item: SwitcherItem
    let isHighlighted: Bool
    let chrome: WindowChrome
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            SwitcherItemIcon(item: item, isHighlighted: isHighlighted, chrome: chrome)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: item.title).font(.system(size: 14, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if item.panes.count > 1 {
                        Text("\(item.panes.count) panes").font(Theme.Font.rowMeta)
                            .foregroundStyle(chrome.secondary).fixedSize()
                    }
                }
                Text(verbatim: item.subtitle).font(.system(size: 11))
                    .foregroundStyle(chrome.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12).frame(height: SwitcherLayout.rowHeight)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
            .fill(isHighlighted ? chrome.accentFill : (isHovered ? chrome.hairline.opacity(0.6) : Color.clear)))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(item.title + " · " + item.subtitle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: item.typeTitle + " · " + item.title + " · " + item.subtitle))
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier("terminal.switcher.row.\(item.id)")
    }
}

private struct SwitcherItemIcon: View {
    let item: SwitcherItem
    var isHighlighted = false
    let chrome: WindowChrome

    var body: some View {
        Group {
            if item.kind == .terminals {
                Image(systemName: "terminal").font(.system(size: 21))
                    .foregroundStyle(isHighlighted ? chrome.accent : chrome.secondary)
            } else if let path = item.filePreviewPath {
                FileTypeIcon(name: (path as NSString).lastPathComponent)
            } else {
                Image(systemName: "folder.fill").font(.system(size: 21))
                    .foregroundStyle(FileBrowserLayout.folderColor)
            }
        }.accessibilityHidden(true)
    }
}

private struct SwitcherDetail: View {
    let item: SwitcherItem
    let isOrigin: Bool
    let chrome: WindowChrome

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: item.title).font(.system(size: 20, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text(verbatim: item.subtitle).font(.system(size: 12))
                        .foregroundStyle(chrome.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if isOrigin {
                    Text("Original Location").font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                        .fixedSize().padding(.top, 5)
                }
            }
            Group {
                if item.kind == .terminals { terminalPreview } else { filePreview }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: SwitcherLayout.previewCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: SwitcherLayout.previewCornerRadius)
                .stroke(chrome.hairline, lineWidth: 1))
            HStack(spacing: 6) {
                Image(systemName: item.kind == .terminals ? "terminal" : item.fileSymbol)
                Text(verbatim: item.typeTitle)
                if item.panes.count > 1 {
                    Text(verbatim: "·")
                    Text("\(item.panes.count) panes")
                }
            }.font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
        }
        .accessibilityIdentifier("switcher.detail")
    }

    private var terminalPreview: some View {
        GeometryReader { proxy in
            let frames = PaneLayout.frames(of: item.layout, in: CGRect(origin: .zero, size: proxy.size))
            let theme = AppearanceDriver.shared.terminalIsDark
                ? ThemePreview.shared.effectiveDark().definition : ThemePreview.shared.effectiveLight().definition
            let background = RGBColor(ghosttyHex: theme.background)!.color
            let foreground = RGBColor(ghosttyHex: theme.foreground)!.color
            ZStack(alignment: .topLeading) {
                background
                ForEach(item.panes) { pane in
                    if let frame = frames[pane.id] {
                        Group {
                            if let lines = pane.lines {
                                TerminalPreview(sessionID: pane.sessionID, fallback: lines.joined(separator: "\n"))
                            } else {
                                Text("Not started").font(Theme.Font.body).foregroundStyle(foreground.opacity(0.7))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .frame(width: frame.width, height: frame.height).clipped()
                        .overlay(Rectangle().stroke(chrome.hairline, lineWidth: item.panes.count > 1 ? 0.5 : 0))
                        .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
        }
    }

    private var filePreview: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 10) {
                if let status = item.fileStatus {
                    Text(verbatim: status).foregroundStyle(chrome.secondary)
                } else if let preview = item.filePreview {
                    Text(verbatim: preview).font(.system(size: 12, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: true)
                } else if item.filePreviewPath != nil {
                    SwitcherItemIcon(item: item, chrome: chrome)
                    Text(verbatim: item.title).fontWeight(.medium)
                    Text("Switch to view this file").foregroundStyle(chrome.secondary)
                } else if item.fileRows.isEmpty {
                    Image(systemName: "folder").font(.system(size: 28)).foregroundStyle(FileBrowserLayout.folderColor)
                    Text("No Items").foregroundStyle(chrome.secondary)
                } else {
                    ForEach(item.fileRows) { row in
                        HStack(spacing: 10) {
                            Group {
                                if row.isDirectory {
                                    Image(systemName: "folder.fill").foregroundStyle(FileBrowserLayout.folderColor)
                                } else {
                                    FileTypeIcon(name: row.name)
                                }
                            }.frame(width: 20, height: 20)
                            Text(verbatim: row.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }.frame(height: 24)
                    }
                }
            }
            .font(.system(size: 13)).padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }.background(chrome.background)
    }

}
