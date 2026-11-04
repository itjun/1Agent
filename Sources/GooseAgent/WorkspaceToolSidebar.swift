import AppKit
import SwiftUI

// 右栏只切换内容，不改变终端分屏树。
enum WorkspaceToolTab: String, CaseIterable {
    case commands, changes, files
    var title: String {
        switch self {
        case .commands: String(localized: "Commands")
        case .changes: String(localized: "Changes")
        case .files: String(localized: "Files")
        }
    }
}

struct WorkspaceToolSidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @Environment(\.windowChrome) private var chrome
    @State private var hoveredTab: WorkspaceToolTab?
    private var location: GitLocation? {
        let context = model.quickCommandContext(in: window)
        return context.directory.map { GitLocation(host: context.host, directory: $0) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(WorkspaceToolTab.allCases, id: \.self) { tab in
                    Button {
                        if tab == .changes { window.toolGitBranchComparison = false }
                        window.toolSidebarTab = tab
                    } label: {
                        Text(verbatim: tab.title).font(Theme.Font.row)
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .background(window.toolSidebarTab == tab ? chrome.accentFill :
                                            hoveredTab == tab ? chrome.hairline : .clear)
                            .overlay(alignment: .trailing) {
                                if tab != .files {
                                    Rectangle().fill(chrome.hairline).frame(width: 1, height: 16)
                                        .allowsHitTesting(false)
                                }
                            }
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .onHover { isHovered in
                            if isHovered { hoveredTab = tab }
                            else if hoveredTab == tab { hoveredTab = nil }
                        }
                        .accessibilityAddTraits(window.toolSidebarTab == tab ? .isSelected : [])
                        .accessibilityIdentifier("workspace.tools." + tab.rawValue)
                }
            }
            .background(chrome.elevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(chrome.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 12).frame(height: 42)
            switch window.toolSidebarTab {
            case .commands: QuickCommandSidebar(model: model, window: window, showsHeader: false)
            case .changes:
                if let location { WorkspaceChangesView(location: location, window: window).id(location) }
                else { unavailable }
            case .files:
                if let location { WorkspaceFilesView(location: location, window: window).id(location) }
                else { unavailable }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(chrome.text).background(Color.clear)
        .onChange(of: window.selectedTabID, initial: true) { _, _ in synchronizeContext() }
        .onChange(of: location) { _, _ in synchronizeContext() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.toolSidebar")
    }
    private func synchronizeContext() {
        window.synchronizeToolContext(sessionID: model.selectedTab(in: window)?.sessionID, location: location)
    }
    private var unavailable: some View {
        Text("Directory unknown").foregroundStyle(chrome.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GitRefreshKey: Hashable {
    var isComparison: Bool
    var base: String
    var revision: Int
}

private struct WorkspaceRefreshButton: View {
    let isLoading: Bool
    let isFailed: Bool
    let action: () -> Void
    @State private var isComplete = false

    var body: some View {
        Button {
            guard !isLoading else { return }
            action()
        } label: {
            ZStack {
                if isLoading { ProgressView().controlSize(.small) }
                else { Image(systemName: isComplete ? "checkmark" : "arrow.clockwise") }
            }.frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(FamilyButtonStyle()).help("Refresh").accessibilityLabel("Refresh")
        .disabled(isLoading)
        .onChange(of: isLoading) { _, loading in isComplete = !loading && !isFailed }
        .task(id: isComplete) {
            guard isComplete else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            isComplete = false
        }
    }
}

struct WorkspaceChangesView: View {
    let location: GitLocation
    @ObservedObject var window: WindowState
    @Environment(\.windowChrome) private var chrome
    @State private var snapshot: GitSnapshot?
    @State private var changes: [GitChange] = []
    @State private var treeRows: [GitChangeTree.Row] = []
    @State private var collapsedDirectories: Set<String> = []
    @State private var stats: GitLineStats?
    @State private var selection: String?
    @State private var base = ""
    @State private var error: String?
    @State private var isLoading = true
    @State private var revision = 0
    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    private var selectedChange: GitChange? { changes.first { $0.path == selection } }
    private var comparisonBase: String? {
        window.toolGitBranchComparison ? (base.isEmpty ? snapshot?.defaultBase : base) : nil
    }
    private var refreshKey: GitRefreshKey {
        GitRefreshKey(isComparison: window.toolGitBranchComparison, base: base, revision: revision)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: (location.directory as NSString).lastPathComponent).font(Theme.Font.sectionTitle)
                    if let snapshot {
                        Label { Text(verbatim: snapshot.branch) } icon: { Image(systemName: "arrow.triangle.branch") }
                            .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary).lineLimit(1)
                    }
                }
                Spacer()
                WorkspaceRefreshButton(isLoading: isLoading, isFailed: error != nil) {
                    isLoading = true
                    revision += 1
                }.accessibilityIdentifier("workspace.changes.refresh")
            }
            FamilySegments(value: $window.toolGitBranchComparison, options: [
                (false, String(localized: "Uncommitted")),
                (true, String(localized: "Branch Comparison"))
            ], isFullWidth: true)
            if window.toolGitBranchComparison, let snapshot, !snapshot.branches.isEmpty {
                HStack {
                    Text("Compare with").font(Theme.Font.rowMeta)
                    Picker("Compare with", selection: Binding(get: { comparisonBase ?? "" }, set: { base = $0 })) {
                        if comparisonBase == nil { Text("Select a branch").tag("") }
                        ForEach(snapshot.branches, id: \.self) { Text(verbatim: $0).tag($0) }
                    }.labelsHidden()
                }
            }
            if let error {
                Text(verbatim: error).font(Theme.Font.rowMeta).foregroundStyle(chrome.danger).textSelection(.enabled)
            }
            if isLoading && snapshot == nil { ProgressView().frame(maxWidth: .infinity) }
            else if snapshot == nil && error == nil { Text("This folder is not a Git repository.").foregroundStyle(chrome.secondary) }
            else if window.toolGitBranchComparison && comparisonBase == nil {
                Text("No comparison branch is available.").foregroundStyle(chrome.secondary)
            } else {
                HStack(spacing: 8) {
                    Text(String(format: String(localized: "%lld changed files"), Int64(changes.count)))
                        .foregroundStyle(chrome.secondary)
                    if let stats { GitLineStatsLabel(stats: stats) }
                }.font(Theme.Font.rowMeta)
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(GitChangeTree.visibleRows(treeRows, collapsed: collapsedDirectories)) { row in
                            if let change = row.change {
                                changeRow(change, depth: row.depth)
                            } else {
                                directoryRow(row)
                            }
                        }
                        if changes.isEmpty && !isLoading && error == nil {
                            Text("No changes").foregroundStyle(chrome.secondary).padding(.vertical, 20)
                        }
                    }
                }.frame(maxHeight: .infinity)
            }

        }
        .padding(.horizontal, 12).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: refreshKey) { await refresh() }
        .onReceive(timer) { _ in if !isLoading && NSApp.isActive { revision += 1 } }
    }

    private func directoryRow(_ row: GitChangeTree.Row) -> some View {
        let isCollapsed = row.isCollapsed(in: collapsedDirectories)
        return Button {
            if isCollapsed { collapsedDirectories.subtract(row.directoryPaths) }
            else { collapsedDirectories.insert(row.path) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down").font(.system(size: 10)).frame(width: 10)
                Image(systemName: "folder.fill").frame(width: 20)
                Text(verbatim: row.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }.foregroundStyle(chrome.secondary)
                .padding(.vertical, 6).padding(.horizontal, 6)
                .padding(.leading, CGFloat(min(row.depth, 8)) * 12)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(row.path)
            .accessibilityValue(Text(isCollapsed ? "Collapsed" : "Expanded"))
            .accessibilityIdentifier("workspace.gitDirectory." + row.path)
    }

    private func changeRow(_ change: GitChange, depth: Int) -> some View {
        Button { selection = change.path; openDiff(change) } label: {
            HStack(spacing: 6) {
                FileTypeIcon(name: (change.path as NSString).lastPathComponent)
                Text(verbatim: (change.path as NSString).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                if let stats = change.lineStats { GitLineStatsLabel(stats: stats).font(Theme.Font.rowMeta).fixedSize() }
                Text(verbatim: change.displayStatus).font(Theme.Font.rowMeta).frame(minWidth: 14)
                    .foregroundStyle(change.displayStatus == "A" ? chrome.success :
                        change.displayStatus == "D" ? chrome.danger :
                        change.displayStatus == "M" ? chrome.warning : chrome.secondary)
            }.padding(.vertical, 5).padding(.horizontal, 6)
                .padding(.leading, CGFloat(min(depth, 8)) * 12 + 16)
                .contentShape(Rectangle())
                .background(selection == change.path ? chrome.accentFill : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(change.path)
            .accessibilityIdentifier("workspace.gitFile." + change.path)
    }

    private func refresh() async {
        isLoading = true
        error = nil
        stats = nil
        do {
            let next = try await WorkspaceGit.snapshot(at: location)
            try Task.checkCancellation()
            snapshot = next
            guard let next else { changes = []; treeRows = []; selection = nil; isLoading = false; return }
            let root = GitLocation(host: location.host, directory: next.root)
            let selectedBase = base.isEmpty ? next.defaultBase : base
            if window.toolGitBranchComparison && selectedBase == nil { changes = []; treeRows = []; selection = nil }
            else {
                let rows = try await WorkspaceGit.changes(at: root, base: window.toolGitBranchComparison ? selectedBase : nil)
                try Task.checkCancellation()
                let countedRows = try await WorkspaceGit.changesWithLineStats(at: root, snapshot: next,
                    base: window.toolGitBranchComparison ? selectedBase : nil, changes: rows)
                try Task.checkCancellation()
                changes = countedRows
                treeRows = GitChangeTree.build(countedRows)
                stats = WorkspaceGit.totalLineStats(countedRows)
                if !rows.contains(where: { $0.path == selection }) { selection = nil }
                if window.toolGitPreview?.location == root {
                    if let change = selectedChange { openDiff(change) }
                    else { window.toolGitPreview = nil }
                }
            }
        } catch {
            if Task.isCancelled { return }
            self.error = error.localizedDescription
            changes = []; treeRows = []; selection = nil
        }
        isLoading = false
    }
    private func openDiff(_ change: GitChange) {
        guard let snapshot else { return }
        window.openToolGitPreview(GitPreviewRequest(location: GitLocation(host: location.host, directory: snapshot.root),
            snapshot: snapshot, change: change, base: comparisonBase, revision: revision))
    }
}


struct WorkspaceFilesView: View {
    let location: GitLocation
    @ObservedObject var window: WindowState
    @StateObject private var column: FileColumn
    @Environment(\.windowChrome) private var chrome
    @State private var revision = 0
    init(location: GitLocation, window: WindowState) {
        self.location = location
        self.window = window
        _column = StateObject(wrappedValue: {
            let column = FileColumn(fileSystem: fileSystem(for: location.host))
            column.showHidden = true
            return column
        }())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: (location.directory as NSString).lastPathComponent).font(Theme.Font.sectionTitle)
                Spacer()
                WorkspaceRefreshButton(isLoading: column.loading, isFailed: column.error != nil) {
                    column.refresh()
                    revision += 1
                }.accessibilityIdentifier("workspace.files.refresh")
            }
            Text(verbatim: location.host == nil ? LocalTerminal.displayPath(location.directory) : location.directory)
                .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary).lineLimit(2).truncationMode(.middle)
            CommandTextField(text: $column.filter, placeholder: String(localized: "Search Files"), identifier: "workspace.files.search", symbol: "magnifyingglass")
                .frame(height: 32)
            if let error = column.error { Text(verbatim: error).foregroundStyle(chrome.danger) }
            if column.loading { ProgressView().frame(maxWidth: .infinity) }
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(column.shown) { entry in
                        WorkspaceFileRow(entry: entry, fileSystem: column.fileSystem, showHidden: column.showHidden, depth: 0, selectedPath: column.selection.first, revision: revision) { file in
                            column.selection = [file.path]
                            guard !file.isDirectory, let kind = FilePreviewPolicy.kind(for: file.name) else { return }
                            window.openToolFilePreview(column)
                            if kind == .text { column.showPreview(file) }
                            else { column.showQuickLook(file, window: nil) }
                        }
                    }
                    if column.shown.isEmpty && !column.loading && column.error == nil {
                        Text("No files").foregroundStyle(chrome.secondary).padding(.vertical, 20)
                    }
                }
            }
        }.padding(16).onAppear { column.start(at: location.directory) }
    }
}

private struct WorkspaceFileRow: View {
    let entry: FileEntry
    let fileSystem: any FileSystem
    let showHidden: Bool
    let depth: Int
    let selectedPath: String?
    let revision: Int
    let open: (FileEntry) -> Void
    @State private var isExpanded = false
    @State private var children: [FileEntry] = []
    @State private var error: String?
    @State private var isLoading = false
    @Environment(\.windowChrome) private var chrome
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                open(entry)
                if entry.isDirectory { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if entry.isDirectory {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right").frame(width: 12)
                        Image(systemName: "folder.fill")
                            .foregroundStyle(selectedPath == entry.path ? chrome.accent : chrome.secondary)
                    } else {
                        FileTypeIcon(name: entry.name)
                    }
                    Text(verbatim: entry.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if isLoading { ProgressView().controlSize(.mini) }
                }.padding(.vertical, 7).padding(.horizontal, 6)
                    .padding(.leading, CGFloat(min(depth, 8)) * 12).contentShape(Rectangle())
                    .background(selectedPath == entry.path ? chrome.accentFill : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)
                .accessibilityAddTraits(selectedPath == entry.path ? .isSelected : [])
                .accessibilityIdentifier("workspace.fileRow." + entry.path)
            if isExpanded {
                if let error { Text(verbatim: error).font(Theme.Font.rowMeta).foregroundStyle(chrome.danger) }
                ForEach(children.filter { showHidden || !$0.isHidden }) { child in
                    WorkspaceFileRow(entry: child, fileSystem: fileSystem, showHidden: showHidden, depth: depth + 1, selectedPath: selectedPath, revision: revision, open: open)
                }
            }
        }
        .task(id: isExpanded ? revision : nil) {
            guard isExpanded else { return }
            isLoading = true; error = nil
            do {
                let entries = try await fileSystem.list(entry.path)
                try Task.checkCancellation()
                children = entries
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            isLoading = false
        }
    }
}

/// 与终端并排的普通卡片，不接管整个窗口的焦点或鼠标。
struct WorkspaceFilePreview: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    var body: some View {
        if let request = window.toolGitPreview {
            WorkspaceGitPreview(request: request, onClose: close)
                .modifier(FloatingContentSurface())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("workspace.gitPreview")
        } else if let column = window.toolPreviewColumn {
            TextPreviewDrawer(column: column, onClose: close, isWorkspaceCard: true)
                .modifier(FloatingContentSurface())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("workspace.filePreview")
        }
    }
    private func close() {
        window.toolPreviewColumn?.preview = nil
        window.toolPreviewColumn = nil
        window.toolGitPreview = nil
        if let tab = model.selectedTab(in: window) { SSHTerminalRegistry.focus(tab.sessionID) }
    }
}

private struct WorkspaceGitPreview: View {
    let request: GitPreviewRequest
    let onClose: () -> Void
    @State private var document = GitDiffDocument("")
    @State private var loadedRequest: GitPreviewRequest?
    @State private var loadedText: String?
    @State private var error: String?
    @State private var isLoading = true
    @Environment(\.windowChrome) private var chrome
    var body: some View {
        GeometryReader { geometry in
            let isSideBySide = document.isPatch && GitDiffDocument.isSideBySide(width: geometry.size.width)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    FileTypeIcon(name: (request.change.path as NSString).lastPathComponent)
                    Text(verbatim: (request.change.path as NSString).lastPathComponent)
                        .font(Theme.Font.paneTitle).lineLimit(1).truncationMode(.middle)
                        .help(request.change.path)
                    if let stats = request.change.lineStats {
                        GitLineStatsLabel(stats: stats).font(Theme.Font.rowMeta).fixedSize()
                    }
                    Spacer(minLength: 4)
                    Text(isSideBySide ? "Side-by-side Diff" : "Unified Diff")
                        .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Close Preview")
                        .accessibilityLabel(Text("Close Preview"))
                        .accessibilityIdentifier("workspace.gitPreview.close")
                }.padding(.horizontal, 12).frame(height: 36)
                    .background(chrome.panelHeader)
                if isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error {
                    ScrollView(showsIndicators: false) { Text(verbatim: error).foregroundStyle(chrome.danger).padding(12).textSelection(.enabled) }
                } else if document.unified.isEmpty {
                    Text("No changes").foregroundStyle(chrome.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    if isSideBySide {
                        HStack(spacing: 1) {
                            Text("Before Change").frame(maxWidth: .infinity, alignment: .leading)
                            Text("After Change").frame(maxWidth: .infinity, alignment: .leading)
                        }.font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                            .padding(.horizontal, 12).frame(height: 28)
                    }
                    NativeGitDiff(document: document, chrome: chrome)
                }
            }.foregroundStyle(chrome.text).background(chrome.background)
        }
        .task(id: request) {
            isLoading = loadedRequest?.location != request.location || loadedRequest?.change != request.change || loadedRequest?.base != request.base
            error = nil
            do {
                let text = try await WorkspaceGit.diff(request.change, snapshot: request.snapshot,
                    at: request.location, base: request.base)
                try Task.checkCancellation()
                if loadedText != text { document = GitDiffDocument(text); loadedText = text }
                loadedRequest = request
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { isLoading = false }
        }
    }

}

/// 保留三个原生文本视图；缩放只改变视口，不重建每一行 SwiftUI 视图。
struct NativeGitDiff: NSViewRepresentable {
    let document: GitDiffDocument
    let chrome: WindowChrome
    func makeNSView(context: Context) -> GitDiffContainer { GitDiffContainer() }
    func updateNSView(_ view: GitDiffContainer, context: Context) {
        view.update(document: document, foreground: NSColor(chrome.text), background: NSColor(chrome.background), secondary: NSColor(chrome.secondary))
    }
}

final class GitDiffContainer: NSView {
    private let unified = GitDiffTextScroll()
    private let before = GitDiffTextScroll()
    private let after = GitDiffTextScroll()
    private var documentID: UUID?
    private var foreground: NSColor?
    private var background: NSColor?
    private var secondary: NSColor?
    private var isPatch = false
    private var isSynchronizing = false
    private var observers: [NSObjectProtocol] = []
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        for scroll in [unified, before, after] { addSubview(scroll) }
        for scroll in [before, after] {
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
                    guard let self, let scroll else { return }
                    self.synchronizeScroll(from: scroll)
                })
        }
        before.isHidden = true; after.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func update(document: GitDiffDocument, foreground: NSColor, background: NSColor, secondary: NSColor) {
        guard documentID != document.id || self.foreground != foreground || self.background != background || self.secondary != secondary else { return }
        documentID = document.id; self.foreground = foreground; self.background = background; self.secondary = secondary
        isPatch = document.isPatch
        unified.load(document.unified.map { ($0, 0) }, foreground: foreground, background: background, secondary: secondary)
        if document.isPatch {
            before.load(document.pairs.map { ($0.left, -1) }, foreground: foreground, background: background, secondary: secondary)
            after.load(document.pairs.map { ($0.right, 1) }, foreground: foreground, background: background, secondary: secondary)
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let isSplit = isPatch && GitDiffDocument.isSideBySide(width: bounds.width)
        unified.isHidden = isSplit; before.isHidden = !isSplit; after.isHidden = !isSplit
        if isSplit {
            let width = (bounds.width - 1) / 2
            before.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
            after.frame = NSRect(x: width + 1, y: 0, width: width, height: bounds.height)
        } else { unified.frame = bounds }
        setAccessibilityIdentifier(isSplit ? "workspace.diff.sideBySide" : "workspace.diff.unified")
    }
    private func synchronizeScroll(from source: NSScrollView) {
        guard !isSynchronizing else { return }
        let target = source === before ? after : before
        let y = source.contentView.bounds.origin.y
        guard abs(target.contentView.bounds.origin.y - y) > 0.5 else { return }
        isSynchronizing = true
        target.contentView.scroll(to: NSPoint(x: target.contentView.bounds.origin.x, y: y))
        target.reflectScrolledClipView(target.contentView)
        isSynchronizing = false
    }
}

private final class GitDiffTextScroll: NSScrollView {
    let code = GitDiffTextView()
    private var contentWidth: CGFloat = 0
    private var contentHeight: CGFloat = 0
    init() {
        super.init(frame: .zero)
        automaticallyAdjustsContentInsets = false
        hasVerticalScroller = false; hasHorizontalScroller = false; autohidesScrollers = true
        borderType = .noBorder
        code.isEditable = false; code.isSelectable = true; code.isRichText = false
        code.isHorizontallyResizable = true; code.isVerticallyResizable = true
        code.textContainer?.widthTracksTextView = false
        code.textContainer?.containerSize = NSSize(width: 10_000_000, height: 10_000_000)
        code.textContainerInset = NSSize(width: 8, height: 0)
        code.textContainer?.lineFragmentPadding = 0
        code.layoutManager?.allowsNonContiguousLayout = true
        documentView = code
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func load(_ rows: [(GitDiffDocument.Line?, Int)], foreground: NSColor, background: NSColor, secondary: NSColor) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 22; paragraph.maximumLineHeight = 22
        paragraph.lineBreakMode = .byClipping
        let result = NSMutableAttributedString()
        var widest: CGFloat = 0
        for (line, side) in rows {
            let old = line?.oldNumber.map(String.init) ?? ""
            let new = line?.newNumber.map(String.init) ?? ""
            let number = side < 0 ? String(format: "%5@ ", old) : side > 0 ? String(format: "%5@ ", new) : String(format: "%5@ %5@ ", old, new)
            let sign = line?.kind == .added ? "+ " : line?.kind == .removed ? "− " : "  "
            let text = number + sign + (line?.text ?? "")
            let rendered = NSMutableAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: foreground, .paragraphStyle: paragraph])
            rendered.addAttribute(.foregroundColor, value: secondary, range: NSRange(location: 0, length: (number + sign).utf16.count))
            widest = max(widest, (text as NSString).size(withAttributes: [.font: font]).width)
            result.append(rendered)
        }
        code.kinds = rows.map { $0.0?.kind }
        code.backgroundColor = background
        backgroundColor = background
        code.textStorage?.setAttributedString(result)
        contentWidth = widest + 16
        contentHeight = CGFloat(rows.count + 1) * 22
        resizeDocument()
        code.needsDisplay = true
    }
    override func layout() {
        super.layout()
        resizeDocument()
    }
    private func resizeDocument() {
        let size = NSSize(width: max(contentSize.width, contentWidth), height: max(contentSize.height, contentHeight))
        if code.frame.size != size { code.setFrameSize(size) }
    }
}

private final class GitDiffTextView: NSTextView {
    var kinds: [GitDiffDocument.Kind?] = []
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let first = max(0, Int(floor(rect.minY / 22)))
        let end = min(kinds.count, Int(ceil(rect.maxY / 22)))
        guard first < end else { return }
        for index in first..<end {
            let color: NSColor
            switch kinds[index] {
            case .added: color = NSColor.systemGreen.withAlphaComponent(0.12)
            case .removed: color = NSColor.systemRed.withAlphaComponent(0.12)
            case .heading: color = NSColor.secondaryLabelColor.withAlphaComponent(0.08)
            default: continue
            }
            color.setFill()
            NSRect(x: 0, y: CGFloat(index) * 22, width: bounds.width, height: 22).fill()
        }
    }
}
