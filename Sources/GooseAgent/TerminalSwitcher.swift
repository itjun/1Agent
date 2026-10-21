import AppKit
import Combine
import SwiftUI

/// One open terminal panel or current file endpoint, captured without changing its live state.
struct SwitcherItem: Identifiable, Equatable {
    let id: UUID
    let targetID: UUID
    let title: String
    let subtitle: String
    let layout: PaneNode
    let panes: [SwitcherPane]
    var kind: SwitcherScope = .terminals
    var searchText: String = ""
    var fileRows: [SwitcherFileRow] = []
    var filePreview: String? = nil
    var fileStatus: String? = nil
    var isRemoteFile = false
    var fileSymbol: String { isRemoteFile ? SidebarConnectionGroup.remote.symbol : "desktopcomputer" }
}

struct SwitcherFileRow: Identifiable, Equatable {
    let id: String
    let name: String
    let isDirectory: Bool
}

enum SwitcherScope: String, CaseIterable {
    case all, terminals, files
    var title: String {
        switch self {
        case .all: return String(localized: "All Open Items")
        case .terminals: return String(localized: "Terminals")
        case .files: return String(localized: "Files")
        }
    }
}

struct SwitcherPane: Identifiable, Equatable {
    let id: UUID
    let lines: [String]?
    let textColumns: Int
}

/// Where the window was when the switcher opened; cancelling returns here.
private struct SwitcherOrigin {
    let section: AppSection
    let selectedTabID: UUID?
    let sidebarSelection: Set<UUID>
    let sidebarAnchor: UUID?
    let fileColumnID: UUID?
}

/// Hold the switcher's modifiers to cycle panels; the window behind follows the highlight.
/// Release to keep it, Escape to return to where the switcher opened.
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
    weak var searchField: NSSearchField?

    var filteredItems: [SwitcherItem] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return items.filter { item in
            (scope == .all || item.kind == scope) && words.allSatisfy {
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

    /// Columns of the grid on screen, so ↑ and ↓ move by a row.
    var columns = 1
    /// Card and panel frames in `TerminalSwitcherView.space`. Clicks are hit-tested against them because
    /// a click with Control still held after ⌃⇥ never reaches a SwiftUI tap gesture.
    var cardFrames: [UUID: CGRect] = [:]
    var boxFrame: CGRect = .zero
    var resultsFrame: CGRect = .zero

    private weak var model: AppModel?
    private weak var windowState: WindowState?
    private weak var hostWindow: NSWindow?
    private var panel: NSPanel?
    private var mouseMonitor: Any?
    private var releaseModifiers: NSEvent.ModifierFlags = []
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var origin: SwitcherOrigin?
    private var previewedID: UUID?
    private var pendingPreview: DispatchWorkItem?

    var isOpen: Bool { panel != nil }

    /// Shows every open sidebar panel. The optional host supports isolated native-window tests.
    @discardableResult
    func open(model: AppModel, window: WindowState, chord: KeyChord, host: NSWindow? = nil, searching: Bool = false) -> Bool {
        if isOpen {
            if searching { beginSearch(); return true }
            move(by: chord.modifiers.contains(.shift) ? -1 : 1)
            return true
        }
        let rows = model.panelRows(in: window)
        guard let host = host ?? MainWindowManager.shared.window(for: window), host.isVisible else {
            return false
        }
        self.model = model
        windowState = window
        hostWindow = host
        releaseModifiers = chord.menuModifierMask.intersection([.control, .command, .option])
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
        guard isOpen else { return false }
        if event.type == .flagsChanged {
            if !isSearching && !releaseModifiers.isEmpty && event.modifierFlags.intersection(releaseModifiers).isEmpty {
                commit()
            }
            return false
        }
        guard event.type == .keyDown else { return false }
        if isSearching, (searchField?.currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 53: cancel()
        case 36, 76: commit()
        case 48: move(by: shift ? -1 : 1)
        case 123: if isSearching { return false }; move(by: -1)
        case 124: if isSearching { return false }; move(by: 1)
        case 125: move(by: columns)
        case 126: move(by: -columns)
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
        guard let item = filteredItems.first(where: { $0.id == (id ?? highlighted) }) else { return }
        let target = item.targetID
        let model = self.model
        let window = windowState
        close()
        guard let model, let window else { return }
        if item.kind == .files {
            guard let workspace = FileBrowserStore.shared.existingWorkspace(for: window),
                  let column = workspace.openColumns.first(where: { $0.id == target }) else { return }
            model.showSection(.files, in: window)
            workspace.activate(column)
        } else if model.sidebarOrder(in: window).contains(target) {
            model.selectOnly(target, in: window)
        }
    }

    /// Closes the switcher and puts the window back where it was when the switcher opened.
    func cancel() {
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
        host.addChildWindow(panel, ordered: .above)
        self.panel = panel
    }

    /// The dimming covers the whole window, title bar included.
    private static func panelFrame(over host: NSWindow) -> NSRect {
        host.frame
    }

    private func watch(model: AppModel, window: WindowState, host: NSWindow) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: host, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.isSearching != true { self?.cancel() } }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: host, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, let host = self.hostWindow else { return }
                    panel.setFrame(Self.panelFrame(over: host), display: true)
                }
            },
        ]
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return event }
                if event.type == .flagsChanged {
                    _ = self.handle(event)
                    return event
                }
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

    /// A click on a card shows it behind the panel, a double-click switches to it, the rest of the panel
    /// does nothing, anywhere else cancels.
    private func click(_ event: NSEvent, in panel: NSPanel) -> Bool {
        guard event.window === panel, let view = panel.contentView else {
            cancel()
            return true
        }
        var point = view.convert(event.locationInWindow, from: nil)
        if !view.isFlipped { point.y = view.bounds.height - point.y }
        guard boxFrame.contains(point) else { cancel(); return true }
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
        let restoreKey = panel?.isKeyWindow == true && NSApp.isActive
        if let panel {
            hostWindow?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        if restoreKey { hostWindow?.makeKey() }
        isSearching = false
        query = ""
        scope = .all
        searchField = nil
        releaseModifiers = []
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        subscriptions = []
        items = []
        highlighted = nil
        pendingPreview?.cancel()
        pendingPreview = nil
        origin = nil
        originID = nil
        previewedID = nil
        cardFrames = [:]
        boxFrame = .zero
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
            return SwitcherPane(id: id, lines: lines, textColumns: lines?.map(\.count).max() ?? 0)
        }
        let path = tab.isLocal ? tab.directory.map(LocalTerminal.displayPath) : tab.remoteDirectory
        let subtitle = [tab.alias, path].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return SwitcherItem(id: row.id, targetID: row.focusedTabID, title: row.name,
                            subtitle: subtitle, layout: layout, panes: panes, searchText: row.leafIDs.compactMap { id in
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
            let title = preview.map { ($0 as NSString).lastPathComponent } ?? column.title
            return SwitcherItem(id: column.id, targetID: column.id, title: title,
                subtitle: column.title + " · " + path, layout: .leaf(column.id), panes: [], kind: .files,
                searchText: [host?.hostName, host?.source, preview, path].compactMap { $0 }.joined(separator: " "),
                fileRows: column.shown.prefix(8).map { SwitcherFileRow(id: $0.path, name: $0.name, isDirectory: $0.isDirectory) },
                filePreview: column.preview?.decoded.map { String($0.text.prefix(1600)) },
                fileStatus: column.error ?? (column.loading ? String(localized: "Loading…") : nil),
                isRemoteFile: column.isRemote)
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

/// The panel is never key, so the first click must reach the cards instead of only activating the window.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct SwitcherCardFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
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
    @ObservedObject var switcher: TerminalSwitcher
    let chrome: WindowChrome
    var windowCornerRadius: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, min(1080, proxy.size.width - 2 * (SwitcherLayout.panelPadding + SwitcherLayout.windowInset)))
            let count = max(1, min(5, Int((width + 14) / 204)))
            let grid = SwitcherLayout.Grid(columns: count, cardWidth: (width - CGFloat(count - 1) * 14) / CGFloat(count), scrolls: true)
            let sections = [SwitcherScope.terminals, .files].filter { kind in switcher.filteredItems.contains { $0.kind == kind } }
            let rows = sections.reduce(0) { total, kind in
                total + (switcher.filteredItems.filter { $0.kind == kind }.count + count - 1) / count
            }
            let height = min(max(100, proxy.size.height - 176 - 2 * SwitcherLayout.windowInset), max(130, CGFloat(rows) * (grid.cardHeight + 14) + CGFloat(sections.count) * 34))
            ZStack {
                RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous)
                    .fill(Color.black.opacity(SwitcherLayout.maskOpacity))
                VStack(spacing: 12) {
                    HStack {
                        Text("Open Items Overview").font(Theme.Font.body.weight(.semibold))
                        Text(verbatim: "\(switcher.filteredItems.count)").foregroundStyle(chrome.secondary)
                        Spacer()
                        Button { switcher.cancel() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel(Text("Close"))
                    }
                    SwitcherSearchField(switcher: switcher).frame(height: 30)
                    FamilySegments(value: $switcher.scope, options: SwitcherScope.allCases.map { ($0, $0.title) })
                        .accessibilityLabel(Text("Content Type")).frame(maxWidth: 300, alignment: .leading)
                    ScrollViewReader { reader in
                        ScrollView {
                            if sections.isEmpty {
                                Text("No Matching Open Items").foregroundStyle(chrome.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 120)
                            }
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(sections, id: \.self) { kind in
                                    let entries = switcher.filteredItems.filter { $0.kind == kind }
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Image(systemName: kind == .files ? "folder" : "terminal")
                                            Text(verbatim: kind.title).fontWeight(.semibold)
                                            Text(verbatim: "\(entries.count)").foregroundStyle(chrome.secondary)
                                        }.font(Theme.Font.rowMeta)
                                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(grid.cardWidth), spacing: 14), count: count), spacing: 14) {
                                            ForEach(entries) { item in
                                                SwitcherCard(item: item, grid: grid, highlighted: item.id == switcher.highlighted,
                                                             isOrigin: item.id == switcher.originID, chrome: chrome)
                                                    .id(item.id)
                                                    .accessibilityAction { switcher.commit(item.id) }
                                                    .background(GeometryReader { card in
                                                        Color.clear.preference(key: SwitcherCardFramesKey.self,
                                                            value: [item.id: card.frame(in: .named(Self.space))])
                                                    })
                                            }
                                        }
                                    }
                                }
                            }
                        }.frame(height: height)
                        .background(GeometryReader { area in
                            Color.clear.preference(key: SwitcherResultsFrameKey.self, value: area.frame(in: .named(Self.space)))
                        })
                        .onAppear { if let id = switcher.highlighted { reader.scrollTo(id) } }
                        .onChange(of: switcher.highlighted) { _, id in
                            if let id { reader.scrollTo(id) }
                        }
                    }
                    Text(LocalizedStringKey(switcher.isSearching ? "Click to preview · Double-click or Return to switch · Esc to go back" : "Release modifiers to switch · Double-click a card to switch · Esc to go back"))
                        .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                }
                .frame(width: width).padding(SwitcherLayout.panelPadding)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(chrome.elevated))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(chrome.hairline, lineWidth: 1))
                .background(GeometryReader { box in
                    Color.clear.preference(key: SwitcherBoxFrameKey.self, value: box.frame(in: .named(Self.space)))
                })
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(SwitcherCardFramesKey.self) { switcher.cardFrames = $0 }
            .onPreferenceChange(SwitcherBoxFrameKey.self) { switcher.boxFrame = $0 }
            .onPreferenceChange(SwitcherResultsFrameKey.self) { switcher.resultsFrame = $0 }
            .onAppear { switcher.columns = count }
            .onChange(of: count) { _, count in switcher.columns = count }
        }
    }
}

/// A real field editor provides selection, clipboard shortcuts and Chinese input composition.
private struct SwitcherSearchField: NSViewRepresentable {
    @ObservedObject var switcher: TerminalSwitcher
    func makeCoordinator() -> Coordinator { Coordinator(switcher) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = String(localized: "Search name, host, IP or path")
        field.setAccessibilityLabel(field.placeholderString)
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

private struct SwitcherCard: View {
    let item: SwitcherItem
    let grid: SwitcherLayout.Grid
    let highlighted: Bool
    let isOrigin: Bool
    let chrome: WindowChrome
    @State private var hovered = false

    private var fill: Color {
        if highlighted {
            return chrome.accentFill
        }
        return hovered ? chrome.hairline.opacity(0.5) : Color.clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SwitcherLayout.titleSpacing) {
            if item.kind == .files { fileThumbnail } else { thumbnail }
            HStack(spacing: 5) {
                if item.kind == .files {
                    Image(systemName: item.fileSymbol)
                } else {
                    TerminalPanelIcon(layout: item.layout)
                }
                Text(verbatim: item.title)
                .font(Theme.Font.rowMeta.weight(highlighted ? .semibold : .regular))
                .foregroundStyle(highlighted ? chrome.text : chrome.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                if item.panes.count > 1 { Text(verbatim: "\(item.panes.count)").foregroundStyle(chrome.secondary) }
                if isOrigin {
                    Text("Original Location").font(.system(size: 10)).foregroundStyle(chrome.secondary)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(chrome.hairline.opacity(0.6)))
                }
            }.frame(width: grid.thumbnailWidth, height: 18)
            Text(verbatim: item.subtitle).font(.system(size: 10)).foregroundStyle(chrome.secondary)
                .lineLimit(1).truncationMode(.middle).frame(width: grid.thumbnailWidth, height: 12, alignment: .leading)
        }
        .padding(SwitcherLayout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: SwitcherLayout.cardCornerRadius, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SwitcherLayout.cardCornerRadius, style: .continuous)
                .stroke(highlighted ? chrome.accent : Color.clear, lineWidth: SwitcherLayout.highlightLineWidth)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: item.title + " · " + item.subtitle))
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier("terminal.switcher.card.\(item.id)")
    }

    /// The terminal's own typeface with the bundled Nerd Font symbols behind it, so prompt icons and
    /// powerline separators draw as they do in the terminal instead of as missing-glyph boxes.
    private static func terminalFont(size: CGFloat) -> Font {
        let symbols = NSFontDescriptor(fontAttributes: [.family: TerminalDefaults.symbolFallbackFamily])
        let base = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: TerminalFontSettings.family]), size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [symbols]])
        let font = NSFont(descriptor: descriptor, size: size) ?? base
        return Font(font as CTFont)
    }

    private var thumbnail: some View {
        let width = grid.thumbnailWidth
        let height = grid.thumbnailHeight
        let frames = PaneLayout.frames(of: item.layout, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ZStack(alignment: .topLeading) {
            chrome.background
            ForEach(item.panes) { pane in
                if let frame = frames[pane.id] {
                    paneThumbnail(pane, size: frame.size)
                        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                        .clipped()
                        .overlay(Rectangle().stroke(chrome.hairline, lineWidth: 0.5))
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: SwitcherLayout.thumbnailCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SwitcherLayout.thumbnailCornerRadius, style: .continuous)
                .stroke(chrome.hairline, lineWidth: 1)
        )
    }
    private var fileThumbnail: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let preview = item.filePreview {
                Text(verbatim: preview).font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(chrome.text).frame(maxWidth: .infinity, alignment: .leading)
            } else if let status = item.fileStatus {
                Text(verbatim: status).font(.system(size: 10)).foregroundStyle(chrome.secondary)
            } else if item.fileRows.isEmpty {
                Image(systemName: item.fileSymbol).font(.system(size: 28)).foregroundStyle(chrome.accent)
                Text(verbatim: item.subtitle).font(.system(size: 10)).foregroundStyle(chrome.secondary)
            } else {
                ForEach(item.fileRows) { row in
                    HStack(spacing: 5) {
                        Image(systemName: row.isDirectory ? "folder.fill" : "doc").foregroundStyle(row.isDirectory ? chrome.accent : chrome.secondary)
                        Text(verbatim: row.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }.font(.system(size: 9))
                }
            }
            Spacer(minLength: 0)
        }.padding(8).frame(width: grid.thumbnailWidth, height: grid.thumbnailHeight, alignment: .topLeading)
            .background(chrome.background).clipped()
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(chrome.hairline, lineWidth: 1))
    }

    private func paneThumbnail(_ pane: SwitcherPane, size: CGSize) -> some View {
        let fontSize = SwitcherLayout.thumbnailFontSize(width: size.width, textColumns: pane.textColumns)
        let visibleRows = max(1, Int(size.height / (fontSize * SwitcherLayout.lineHeightRatio)))
        return ZStack(alignment: .topLeading) {
            chrome.background
            if let lines = pane.lines {
                Text(verbatim: lines.suffix(visibleRows).joined(separator: "\n"))
                    .font(Self.terminalFont(size: fontSize))
                    .foregroundStyle(chrome.text).fixedSize().padding(fontSize * 0.5)
            } else {
                Text("Not started").font(Theme.Font.rowMeta).foregroundStyle(chrome.tertiary)
                    .frame(width: size.width, height: size.height)
            }
        }
    }

}
