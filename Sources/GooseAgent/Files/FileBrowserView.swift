import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum FileBrowserTimestamp {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

/// A stable header keeps native tab handles alive when the selected folder changes.
struct FileColumnHeader<Endpoint: View>: View {
    @ObservedObject var workspace: FileWorkspace
    @ObservedObject var column: FileColumn
    var width: CGFloat
    var onFilterFocusChange: (Bool) -> Void = { _ in }
    @ViewBuilder var endpoint: () -> Endpoint
    @Environment(\.windowChrome) private var chrome
    @State private var showingFilter = false
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            titleBar(width: width)
            if width < FileBrowserLayout.compactHeaderThreshold && (showingFilter || !column.filter.isEmpty) {
                filterField
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.bottom, Theme.Space.xs)
            }
        }
        .onChange(of: column.id) { _, _ in
            showingFilter = false
            filterFocused = false
        }
        .onChange(of: filterFocused) { _, focused in onFilterFocusChange(focused) }
    }

    private var filterField: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12)).foregroundStyle(chrome.secondary)
            TextField(String(localized: "Filter"), text: $column.filter)
                .textFieldStyle(.plain).font(Theme.Font.body)
                .focused($filterFocused)
                .background(FilePointerObserver { onFilterFocusChange(true) })
                .accessibilityLabel(Text("Filter"))
                .accessibilityIdentifier("files.filter")
                .onExitCommand {
                    column.filter = ""
                    showingFilter = false
                }
            if !column.filter.isEmpty {
                Button {
                    column.filter = ""
                    showingFilter = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(chrome.secondary)
                }
                .buttonStyle(FamilyButtonStyle())
                .help(String(localized: "Clear Filter"))
                .accessibilityLabel(Text("Clear Filter"))
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: Theme.Control.height)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(filterFocused ? chrome.background : chrome.elevated))
        .familyFocusRing(filterFocused)
    }

    // MARK: Navigation and actions

    private func titleBar(width: CGFloat) -> some View {
        HStack(spacing: Theme.Space.s) {
            endpoint()
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if width >= FileBrowserLayout.compactHeaderThreshold {
                filterField.frame(width: FileBrowserLayout.filterWidth)
            } else {
                toolbarButton("line.3.horizontal.decrease", help: String(localized: "Filter"), enabled: true) {
                    showingFilter.toggle(); filterFocused = showingFilter
                }
            }
            FamilyMenu("Actions") {
                FileColumnActions(workspace: workspace, column: column).items
            }
            .font(Theme.Font.body)
            .tint(chrome.text)
            .foregroundStyle(chrome.text)
            .padding(.horizontal, Theme.Space.s)
            .fixedSize()
            .accessibilityLabel(Text("Actions"))
            .accessibilityIdentifier("files.actions")
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: FileBrowserLayout.tabStripHeight)
        .background(chrome.background)
    }

    private func toolbarButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: FileBrowserLayout.toolbarButtonSize, height: FileBrowserLayout.toolbarButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(FamilyButtonStyle())
        .foregroundStyle(chrome.text)
        .opacity(enabled ? 1 : 0.3)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
    }

}

/// One tab of the Files area: breadcrumbs and the file table of one folder, on this Mac
/// or on a host. Look and behavior follow 1Panel's SFTP page.
struct FileColumnView: View {
    @ObservedObject var workspace: FileWorkspace
    @ObservedObject var column: FileColumn
    var filterFocused = false
    @Environment(\.windowChrome) private var chrome
    @FocusState private var focused: Bool
    @State private var editingPath = false
    @State private var pathDraft = ""
    @FocusState private var pathFieldFocused: Bool
    @State private var dropTargeted = false
    @State private var dropFolder: String?
    /// Why the drag over this pane cannot drop here; shown in place of the drop hint.
    @State private var dropRefusal: String?
    @State private var hovered: String?
    @State private var pathHovered = false

    private var window: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    var body: some View {
        // Read the assigned pane width, not the content's intrinsic width. Long paths must not
        // make the table believe that optional columns fit inside a narrow endpoint panel.
        GeometryReader { geometry in
            content(width: geometry.size.width)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func content(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            navigationBar(width: width)
            Rectangle().fill(chrome.hairline).frame(height: 1)
            if let error = column.error {
                Text(verbatim: error)
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.top, Theme.Space.xs)
            }
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    header(width: width)
                    rows(width: width)
                }
                .overlay(alignment: .top) {
                    if column.loading {
                        Rectangle().fill(chrome.accent).frame(height: 2)
                    }
                }
                .overlay { dropHint }

            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .simultaneousGesture(TapGesture().onEnded { workspace.focus(column) })
        .onChange(of: workspace.selectedPreviewColumn?.id) { previous, current in
            if current != nil {
                focused = false
            } else if previous != nil, workspace.focusedColumn === column {
                focused = true
            }
        }
    }

    private func navigationBar(width: CGFloat) -> some View {
        HStack(spacing: width < 250 ? 2 : Theme.Space.xs) {
            toolbarButton("chevron.left", help: String(localized: "Back"), enabled: !column.backStack.isEmpty) { column.back() }
            toolbarButton("chevron.right", help: String(localized: "Forward"), enabled: !column.forwardStack.isEmpty) { column.forward() }
            toolbarButton("house", help: String(localized: "Home Folder"), enabled: !column.home.isEmpty) {
                column.goHome()
            }
            .accessibilityIdentifier("files.home")
            pathField
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("files.path")
                .frame(minWidth: 0, maxWidth: .infinity)
                .frame(height: Theme.Control.height)
                .background {
                    if !editingPath {
                        Color.clear.contentShape(Rectangle()).onTapGesture(perform: startEditing)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(editingPath || pathHovered ? chrome.elevated : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .stroke(pathFieldFocused ? chrome.accent : Color.clear, lineWidth: 1))
                .familyFocusRing(pathFieldFocused)
                .onHover { pathHovered = $0 }

        }
        .padding(.horizontal, width < 250 ? Theme.Space.xs : Theme.Space.m)
        .frame(height: FileBrowserLayout.navigationHeight)
    }

    private func toolbarButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: FileBrowserLayout.toolbarButtonSize, height: FileBrowserLayout.toolbarButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(FamilyButtonStyle())
        .foregroundStyle(chrome.text)
        .opacity(enabled ? 1 : 0.3)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
    }

    private var pathField: some View {
        Group {
            if editingPath {
                TextField("", text: $pathDraft)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .accessibilityLabel(Text("Edit Path"))
                    .accessibilityIdentifier("files.path.editor")
                    .focused($pathFieldFocused)
                    .onSubmit(commitPath)
                    .onExitCommand { editingPath = false }
                    .onChange(of: pathFieldFocused) { _, isFocused in
                        if !isFocused { commitPath() }
                    }
            } else {
                breadcrumbs
                .help(column.directory)
                .familyContextMenu {
                    [FamilyMenuItem(title: String(localized: "Home Folder"), enabled: !column.home.isEmpty, action: { column.goHome() }),
                     FamilyMenuItem(title: String(localized: "Root"), action: { column.open("/") })] +
                    segments.map { segment in FamilyMenuItem(title: segment.name, action: { column.open(segment.path) }) }
                }
            }
        }
        .padding(.horizontal, Theme.Space.xs)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: FileBrowserLayout.toolbarButtonSize, alignment: .leading)
    }

    private var breadcrumbs: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        pathComponent(String(localized: "Root"), path: "/", current: column.directory == "/") {
                            column.open("/")
                        }
                        ForEach(segments, id: \.path) { segment in
                            Button(action: startEditing) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(chrome.secondary)
                                    .frame(width: FileBrowserLayout.pathSeparatorWidth, height: FileBrowserLayout.toolbarButtonSize)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(FamilyButtonStyle())
                            .help("Edit Path")
                            .accessibilityLabel(Text("Edit Path"))
                            .accessibilityIdentifier("files.path.separator." + segment.path)
                            pathComponent(segment.name, path: segment.path, current: segment.path == column.directory) {
                                if segment.path == column.directory { startEditing() }
                                else { column.open(segment.path) }
                            }
                        }
                        Button(action: startEditing) {
                            Color.clear
                                .frame(minWidth: 24, maxWidth: .infinity)
                                .frame(height: FileBrowserLayout.toolbarButtonSize)
                                .contentShape(Rectangle())
                        }
                        // The empty area belongs to the whole path field; it must not
                        // paint an independent hover block after the last breadcrumb.
                        .buttonStyle(.plain)
                        .help("Edit Path")
                        .accessibilityLabel(Text("Edit Path"))
                        .accessibilityIdentifier("files.path.edit")
                        .id("path.end")
                    }
                    .frame(minWidth: geometry.size.width, alignment: .leading)
                }
                .onChange(of: column.directory, initial: true) { _, _ in
                    DispatchQueue.main.async { proxy.scrollTo("path.end", anchor: .trailing) }
                }
            }
        }
        .frame(height: FileBrowserLayout.toolbarButtonSize)
    }

    private func pathComponent(_ name: String, path: String, current: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                FileFolderGlyph().fill(FileBrowserLayout.folderColor)
                    .frame(width: 14, height: 14)
                Text(verbatim: name)
                    .font(Theme.Font.body.weight(current ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 160)
            }
            .padding(.horizontal, Theme.Space.xs)
            .frame(height: FileBrowserLayout.toolbarButtonSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(FamilyButtonStyle())
        .foregroundStyle(chrome.text)
        .fixedSize(horizontal: true, vertical: false)
        .help(path)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityIdentifier("files.path.component." + path)
    }

    private var segments: [(name: String, path: String)] {
        var path = ""
        return column.directory.split(separator: "/").map { part in
            path += "/" + part
            return (String(part), path)
        }
    }

    private func startEditing() {
        pathDraft = column.directory
        editingPath = true
        DispatchQueue.main.async { pathFieldFocused = true }
    }

    private func commitPath() {
        guard editingPath else { return }
        editingPath = false
        let next = pathDraft.trimmingCharacters(in: .whitespaces)
        if !next.isEmpty { column.open(next) }
    }

    // MARK: Table

    private func header(width: CGFloat) -> some View {
        let columns = FileBrowserLayout.tableColumns(in: width)
        return HStack(spacing: Theme.Space.s) {
            sortButton(String(localized: "Name"), key: .name)
                .frame(width: columns.name, alignment: .leading)
            if let modified = columns.modified {
                sortButton(String(localized: "Modified"), key: .modified)
                    .frame(width: modified, alignment: .leading)
            }
            if columns.size {
                sortButton(String(localized: "File Size"), key: .size)
                    .frame(width: FileBrowserLayout.sizeWidth, alignment: .trailing)
            }
            if columns.kind {
                sortButton(String(localized: "Kind"), key: .kind)
                    .frame(width: FileBrowserLayout.kindWidth, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: FileBrowserLayout.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(chrome.hairline).frame(height: 1)
        }
    }

    private func sortButton(_ title: String, key: FileColumn.SortKey) -> some View {
        Button {
            column.toggleSort(key)
        } label: {
            let mark = column.sortKey == key ? (column.ascending ? " ↑" : " ↓") : ""
            Text(verbatim: title + mark)
                .font(Theme.Font.rowMeta)
                .foregroundStyle(chrome.secondary)
                .lineLimit(1)
        }
        .buttonStyle(FamilyButtonStyle())
    }

    private func rows(width: CGFloat) -> some View {
        let shown = column.shown
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !column.loading && column.error == nil && !column.directory.isEmpty && shown.isEmpty {
                        Text(verbatim: emptyText)
                            .font(Theme.Font.body)
                            .foregroundStyle(chrome.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.Space.l)
                            .padding(.vertical, Theme.Space.xl)
                    }
                    ForEach(shown) { entry in
                        row(entry, width: width)
                            .id(entry.path)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: Binding(
                get: { column.scrollAnchor },
                set: { anchor in
                    // A view being removed temporarily reports nil; the browsing position belongs
                    // to the column, not the lifetime of this ScrollView.
                    if let anchor { column.scrollAnchor = anchor }
                }
            ), anchor: .top)
            .onChange(of: column.selection) { _, selection in
                guard selection.count == 1, let path = selection.first else { return }
                proxy.scrollTo(path)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.focus(column)
            focused = true
            column.clearSelection()
        }
        .familyContextMenu {
            workspace.focus(column)
            return FileColumnActions(workspace: workspace, column: column).items
        }
        .focusable(interactions: .edit)
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = workspace.focusedColumn === column }
        .onChange(of: workspace.focusedColumn?.id) { _, id in
            if id != column.id {
                focused = false
            } else if !editingPath && !filterFocused {
                focused = true
            }
        }
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .background(FilePointerObserver {
            if workspace.focusedColumn !== column { workspace.focus(column) }
            focused = true
        })

        .onDrop(of: [.fileURL, .plainText], delegate: FileDropDelegate(
            check: { dropCheck(into: nil) },
            targeted: { dropTargeted = $0 },
            refused: { dropRefusal = $0 },
            released: refusedRelease,
            perform: { receive($0, into: nil) }
        ))
    }

    private func row(_ entry: FileEntry, width: CGFloat) -> some View {
        let columns = FileBrowserLayout.tableColumns(in: width)
        let selected = column.selection.contains(entry.path)
        let dropping = dropFolder == entry.path
        return HStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                FileIcon(directory: entry.isDirectory)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: entry.name)
                        .font(Theme.Font.body.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? chrome.accent : entry.isHidden ? chrome.secondary : chrome.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: entry.mode)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(chrome.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: columns.name, alignment: .leading)
            if let modified = columns.modified {
                Text(verbatim: entry.modified.map(FileBrowserTimestamp.formatter.string(from:)) ?? "—")
                    .frame(width: modified, alignment: .leading)
            }
            if columns.size {
                Text(verbatim: entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .monospacedDigit()
                    .frame(width: FileBrowserLayout.sizeWidth, alignment: .trailing)
            }
            if columns.kind {
                Text(verbatim: FileColumn.kind(of: entry))
                    .frame(width: FileBrowserLayout.kindWidth, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .font(Theme.Font.rowMeta)
        .foregroundStyle(selected ? chrome.accent : chrome.secondary)
        .lineLimit(1)
        .padding(.horizontal, Theme.Space.m)
        .frame(height: FileBrowserLayout.rowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files.row.\(entry.path)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .background {
            Rectangle()
                .fill(selected || dropping ? chrome.accentFill : (hovered == entry.path ? chrome.elevated : Color.clear))
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: Theme.Radius.row)
                    .stroke(chrome.accent, lineWidth: 1)
                    .padding(.horizontal, Theme.Space.xs)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(chrome.hairline).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = entry.path } else if hovered == entry.path { hovered = nil }
        }
        .onTapGesture(count: 2) {
            workspace.open(entry, in: column, window: window)
        }
        .simultaneousGesture(TapGesture().onEnded {
            focused = true
            column.click(entry, modifiers: NSEvent.modifierFlags)
        })

        .familyContextMenu {
            workspace.focus(column)
            column.prepareContextMenu(for: entry)
            return FileColumnActions(workspace: workspace, column: column, targets: targets(for: entry)).items
        }
        .onDrag { dragProvider(for: entry) }
        .onDrop(of: [.fileURL, .plainText], delegate: FileDropDelegate(
            check: { dropCheck(into: entry.isDirectory ? entry.path : nil) },
            targeted: { on in
                if on, entry.isDirectory { dropFolder = entry.path } else if dropFolder == entry.path { dropFolder = nil }
            },
            refused: { dropRefusal = $0 },
            released: refusedRelease,
            perform: { receive($0, into: entry.isDirectory ? entry.path : nil) }
        ))
    }

    private var emptyText: String {
        if !column.filter.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "No matching files")
        }
        if !column.showHidden, column.hasHiddenEntries {
            return String(localized: "Hidden files are collapsed")
        }
        return String(localized: "This folder is empty")
    }

    @ViewBuilder
    private var dropHint: some View {
        if let dropRefusal {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(chrome.danger, lineWidth: 1)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(chrome.danger.opacity(0.1)))
                .overlay {
                    Label(dropRefusal, systemImage: "nosign")
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(chrome.danger)
                        .padding(.horizontal, Theme.Space.l)
                }
                .padding(10)
                .allowsHitTesting(false)
        } else if dropTargeted || dropFolder != nil {
            let text: String = {
                if let dropFolder {
                    return String(format: String(localized: "Drop into “%@”"), (dropFolder as NSString).lastPathComponent)
                }
                return column.isRemote ? String(localized: "Release to upload") : String(localized: "Release to copy here")
            }()
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(chrome.accent, lineWidth: 1)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(chrome.accentFill.opacity(0.6)))
                .overlay {
                    Text(verbatim: text)
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(chrome.text)
                }
                .padding(10)
                .allowsHitTesting(false)
        }
    }

    // MARK: Menus

    /// The row's selection when the row is part of it, otherwise just the row.
    private func targets(for entry: FileEntry) -> [FileEntry] {
        column.selection.contains(entry.path) ? column.selectedEntries : [entry]
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !editingPath else { return .ignored }
        if press.characters == "\u{7f}" || press.key == .delete || press.key == .deleteForward {
            let selected = column.selectedEntries
            if !selected.isEmpty {
                workspace.delete(selected, in: column, window: window)
            } else if press.key != .deleteForward {
                column.back()
            }
            return .handled
        }
        switch press.key {
        case .upArrow:
            column.moveSelection(by: -1)
            return .handled
        case .downArrow:
            column.moveSelection(by: 1)
            return .handled
        case .return:
            let selected = column.selectedEntries
            guard selected.count == 1 else { return .ignored }
            workspace.open(selected[0], in: column, window: window)
            return .handled
        case .escape:
            if column.preview != nil {
                column.preview = nil
                return .handled
            }
            return .ignored
        default:
            if press.characters == "a", press.modifiers.contains(.command) {
                column.selectAll()
                return .handled
            }
            return .ignored
        }
    }

    // MARK: Drag and drop

    private func dragProvider(for entry: FileEntry) -> NSItemProvider {
        let entries = targets(for: entry)
        let text = ShellEscape.dropText(paths: entries.map(\.path))
        FileBrowserDrag.current = FileBrowserDrag.Payload(column: column, entries: entries, text: text)
        if !column.isRemote, entries.count == 1 {
            let provider = NSItemProvider(contentsOf: URL(fileURLWithPath: entry.path)) ?? NSItemProvider()
            provider.registerObject(text as NSString, visibility: .all)
            return provider
        }
        return NSItemProvider(object: text as NSString)
    }

    /// A drag starts over its own pane, so drops there are refused silently. Over another pane,
    /// rows dropped into the folder they are already in, or a folder into itself, are refused with
    /// a reason.
    private func dropCheck(into folder: String?) -> FileDropCheck {
        guard let payload = FileBrowserDrag.active else { return .allowed }
        if payload.column === column { return .refused(nil) }
        guard payload.column.fileSystem.host == column.fileSystem.host else { return .allowed }
        let sources = payload.entries.map { (path: $0.path, isDirectory: $0.isDirectory) }
        let reason = FileRules.sameSideRefusal(sources: sources, into: folder ?? column.directory)
        return reason.map { .refused($0) } ?? .allowed
    }

    /// Runs during the drag session, when the key window may be the drag image's.
    private func refusedRelease(_ reason: String) {
        TransferToast.shared.fail(nil, reason, in: NSApp.mainWindow ?? NSApp.keyWindow)
    }

    private func receive(_ providers: [NSItemProvider], into folder: String?) -> Bool {
        dropFolder = nil
        if let payload = FileBrowserDrag.active {
            guard payload.column !== column else { return false }
            workspace.receive(
                payload.entries.map { FileTransfer.Item(path: $0.path, isDirectory: $0.isDirectory) },
                from: payload.column.fileSystem, on: column, into: folder, window: window
            )
            return true
        }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await Self.fileURL(from: provider) { urls.append(url) }
            }
            let items = urls.map { url -> FileTransfer.Item in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                return FileTransfer.Item(path: url.path, isDirectory: isDirectory.boolValue)
            }
            workspace.receive(items, from: LocalFileSystem(), on: column, into: folder, window: window)
        }
        return true
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}

/// The title menu and both context menus act on the same pane and selection.
@MainActor
private struct FileColumnActions {
    var workspace: FileWorkspace
    var column: FileColumn
    var targets: [FileEntry]? = nil

    var items: [FamilyMenuItem] {
        let entries = targets ?? column.selectedEntries
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let available = !column.directory.isEmpty && !column.loading
        let other = workspace.other(than: column)
        let canSend = !entries.isEmpty && available && other != nil && other !== column &&
            other?.loading == false && other?.directory.isEmpty == false
        return [
            FamilyMenuItem(title: String(localized: "New Folder"), enabled: available, action: {
                workspace.focus(column)
                workspace.create(folder: true, in: column, window: window)
            }),
            FamilyMenuItem(title: String(localized: "New File"), enabled: available, action: {
                workspace.focus(column)
                workspace.create(folder: false, in: column, window: window)
            }),
            .separator,
            FamilyMenuItem(title: String(localized: "Open Item"), enabled: entries.count == 1 && available, action: {
                if let entry = entries.first { workspace.open(entry, in: column, window: window) }
            }),
            FamilyMenuItem(title: String(localized: "Send to Other Pane"), enabled: canSend, action: {
                workspace.send(entries, from: column, window: window)
            }),
            FamilyMenuItem(title: String(localized: "Rename"), enabled: entries.count == 1 && available, action: {
                if let entry = entries.first { workspace.rename(entry, in: column, window: window) }
            }),
            FamilyMenuItem(title: String(localized: "Copy Path"), enabled: !entries.isEmpty, action: {
                workspace.copyPaths(entries, in: column)
            }),
            FamilyMenuItem(title: String(localized: "Delete"), enabled: !entries.isEmpty && available, destructive: true, action: {
                workspace.delete(entries, in: column, window: window)
            }),
            .separator,
            FamilyMenuItem(title: String(localized: "Refresh"), enabled: !column.loading, action: { column.refresh() }),
            FamilyMenuItem(title: column.showHidden ? String(localized: "Hide Hidden Files") : String(localized: "Show Hidden Files"), action: {
                column.showHidden.toggle()
            }),
            FamilyMenuItem(title: String(localized: "Select All"), enabled: !column.shown.isEmpty, action: {
                workspace.focus(column)
                column.selectAll()
            }),
        ]
    }
}

/// A single shared pair reads selections from the actual endpoints, independent of focus.
struct FileColumnTransferControls: View {
    @ObservedObject var workspace: FileWorkspace
    @ObservedObject var column: FileColumn
    @ObservedObject var other: FileColumn
    @Environment(\.windowChrome) private var chrome

    private enum Direction {
        case upload, download, copy

        var title: String {
            switch self {
            case .upload: return String(localized: "Upload")
            case .download: return String(localized: "Download")
            case .copy: return String(localized: "Copy to Other Pane")
            }
        }

        var format: String {
            switch self {
            case .upload: return String(localized: "Upload to %@: %@")
            case .download: return String(localized: "Download to %@: %@")
            case .copy: return String(localized: "Copy to %@: %@")
            }
        }

        var symbol: String {
            switch self {
            case .upload: return "arrow.right"
            case .download: return "arrow.left"
            case .copy: return "doc.on.doc"
            }
        }
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if column.isRemote != other.isRemote {
                let local = column.isRemote ? other : column
                let remote = column.isRemote ? column : other
                transferButton(from: local, to: remote, direction: .upload)
                transferButton(from: remote, to: local, direction: .download)
            } else {
                transferButton(from: column, to: other, direction: .copy)
            }
        }
    }

    private func transferButton(from source: FileColumn, to target: FileColumn, direction: Direction) -> some View {
        let enabled = !source.selectedEntries.isEmpty && !source.loading && !target.loading && !target.directory.isEmpty
        let prominent = direction != .download
        let hint = String(format: direction.format, target.title, target.directory)
        return Button {
            guard enabled else { return }
            workspace.receive(
                source.selectedEntries.map { FileTransfer.Item(path: $0.path, isDirectory: $0.isDirectory) },
                from: source.fileSystem, on: target, into: target.directory,
                window: NSApp.keyWindow ?? NSApp.mainWindow
            )
        } label: {
            Label(direction.title, systemImage: direction.symbol)
                .font(Theme.Font.body.weight(.medium))
                .padding(.horizontal, Theme.Space.m)
                .frame(height: FileBrowserLayout.toolbarHeight - 4)
                .foregroundStyle(enabled && prominent ? Color.white : enabled ? chrome.text : chrome.tertiary)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(enabled && prominent ? chrome.accent : Color.clear))
        }
        .buttonStyle(FamilyButtonStyle())
        .disabled(!enabled)
        .help(hint)
    }
}

/// Blue folders and an uncluttered page outline keep the two lists easy to compare.
private struct FileIcon: View {
    let directory: Bool
    @Environment(\.windowChrome) private var chrome

    var body: some View {
        if directory {
            FileFolderGlyph().fill(FileBrowserLayout.folderColor)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "doc")
                .font(.system(size: 18))
                .foregroundStyle(chrome.lineStrong.opacity(0.55))
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }
}

/// 1Panel's folder outline, rendered as a native vector instead of an OS-dependent symbol.
private struct FileFolderGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 10, y: 4))
        path.addLine(to: CGPoint(x: 4, y: 4))
        path.addQuadCurve(to: CGPoint(x: 2, y: 6), control: CGPoint(x: 2, y: 4))
        path.addLine(to: CGPoint(x: 2, y: 18))
        path.addQuadCurve(to: CGPoint(x: 4, y: 20), control: CGPoint(x: 2, y: 20))
        path.addLine(to: CGPoint(x: 20, y: 20))
        path.addQuadCurve(to: CGPoint(x: 22, y: 18), control: CGPoint(x: 22, y: 20))
        path.addLine(to: CGPoint(x: 22, y: 8))
        path.addQuadCurve(to: CGPoint(x: 20, y: 6), control: CGPoint(x: 22, y: 6))
        path.addLine(to: CGPoint(x: 12, y: 6))
        path.closeSubpath()
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

private enum FileDropCheck {
    case allowed
    /// Nil reason: refused without telling the user, e.g. a row dropped back into its own pane.
    case refused(String?)
}

/// A refused drop never gets `performDrop`; AppKit sends `dropExited` on release instead, before
/// the button reads as up. A button up within half a second means the user let go over a refused
/// target; dragging on to another pane keeps it down.
private struct FileDropDelegate: DropDelegate {
    var check: () -> FileDropCheck
    var targeted: (Bool) -> Void
    var refused: (String?) -> Void
    var released: (String) -> Void
    var perform: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL, .plainText])
    }

    /// SwiftUI sends one more dropUpdated after performDrop, which would mark the target again.
    @MainActor private static var dropped = false

    func dropEntered(info: DropInfo) {
        Self.dropped = false
        update()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: update() ? .copy : .forbidden)
    }

    func dropExited(info: DropInfo) {
        targeted(false)
        refused(nil)
        if case .refused(let reason?) = check() {
            waitForRelease(reason, tries: 6)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        Self.dropped = true
        clear()
        switch check() {
        case .allowed:
            return perform(info.itemProviders(for: [.fileURL, .plainText]))
        case .refused(let reason):
            if let reason { released(reason) }
            return false
        }
    }

    private func clear() {
        targeted(false)
        refused(nil)
    }

    private func waitForRelease(_ reason: String, tries: Int) {
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if NSEvent.pressedMouseButtons == 0 {
                released(reason)
            } else {
                waitForRelease(reason, tries: tries - 1)
            }
        }
    }

    @discardableResult
    private func update() -> Bool {
        if Self.dropped { return false }
        switch check() {
        case .allowed:
            refused(nil)
            targeted(true)
            return true
        case .refused(let reason):
            targeted(false)
            refused(reason)
            return false
        }
    }
}

/// Observe native mouse-downs without consuming them. Scroll-view blank areas and native
/// controls do not reliably complete an enclosing SwiftUI tap gesture.
struct FilePointerObserver: NSViewRepresentable {
    var contextClicksOnly = false
    var prepare: () -> Void
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) {
        view.contextClicksOnly = contextClicksOnly
        view.prepare = prepare
    }
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.stop() }

    final class Observer: NSView {
        var contextClicksOnly = false
        var prepare: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                if self.contextClicksOnly && event.type != .rightMouseDown && !event.modifierFlags.contains(.control) {
                    return event
                }
                self.prepare?()
                return event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
