import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One tab of the Files area: title bar, breadcrumb and the file table of one folder, on this Mac
/// or on a host. Look and behavior follow 1Panel's SFTP page.
struct FileColumnView: View {
    @ObservedObject var workspace: FileWorkspace
    @ObservedObject var column: FileColumn
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
    @State private var width: CGFloat = 0

    private var window: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            toolbar
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
                    header
                    rows
                }
                .overlay(alignment: .top) {
                    if column.loading {
                        Rectangle().fill(chrome.accent).frame(height: 2)
                    }
                }
                .overlay { dropHint }
                if column.preview != nil {
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            TextPreviewDrawer(column: column)
                                .frame(height: geometry.size.height * FileBrowserLayout.previewHeightShare)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .simultaneousGesture(TapGesture().onEnded { workspace.focus(column) })
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: column.isRemote ? "cloud" : "desktopcomputer")
                .font(.system(size: 13))
                .foregroundStyle(chrome.text)
            Text(verbatim: column.title)
                .font(Theme.Font.body.weight(.semibold))
                .foregroundStyle(chrome.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.s)
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(chrome.secondary)
                TextField(String(localized: "Filter"), text: $column.filter)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(width: FileBrowserLayout.filterWidth, height: FileBrowserLayout.toolbarButtonSize + 4)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(chrome.elevated))
            Menu {
                actionItems(for: column.selectedEntries)
            } label: {
                Text("Actions")
                    .font(Theme.Font.body)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: FileBrowserLayout.titleBarHeight)
    }

    // MARK: Toolbar and breadcrumb

    private var toolbar: some View {
        HStack(spacing: 2) {
            toolbarButton("chevron.left", help: String(localized: "Back"), enabled: !column.backStack.isEmpty) {
                column.back()
            }
            toolbarButton("chevron.right", help: String(localized: "Forward"), enabled: !column.forwardStack.isEmpty) {
                column.forward()
            }
            toolbarButton("house", help: String(localized: "Home Folder"), enabled: !column.home.isEmpty) {
                column.goHome()
            }
            breadcrumb
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: FileBrowserLayout.toolbarHeight)
    }

    private func toolbarButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: FileBrowserLayout.toolbarButtonSize, height: FileBrowserLayout.toolbarButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(chrome.text)
        .opacity(enabled ? 1 : 0.3)
        .disabled(!enabled)
        .help(help)
    }

    private var breadcrumb: some View {
        Group {
            if editingPath {
                TextField("", text: $pathDraft)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .focused($pathFieldFocused)
                    .onSubmit {
                        editingPath = false
                        let next = pathDraft.trimmingCharacters(in: .whitespaces)
                        if !next.isEmpty { column.open(next) }
                    }
                    .onExitCommand { editingPath = false }
                    .onChange(of: pathFieldFocused) { _, isFocused in
                        if !isFocused { editingPath = false }
                    }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        crumb(String(localized: "Root"), path: "/", last: column.directory == "/")
                        ForEach(segments, id: \.path) { segment in
                            Text(verbatim: "›").foregroundStyle(chrome.secondary)
                            crumb(segment.name, path: segment.path, last: segment.path == column.directory)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { startEditing() }
            }
        }
        .padding(.horizontal, Theme.Space.xs)
        .frame(maxWidth: .infinity, minHeight: FileBrowserLayout.toolbarButtonSize, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(editingPath ? chrome.elevated : Color.clear)
        )
    }

    private func crumb(_ name: String, path: String, last: Bool) -> some View {
        Button {
            if last { startEditing() } else { column.open(path) }
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(FileBrowserLayout.folderColor)
                Text(verbatim: name)
                    .font(Theme.Font.body.weight(last ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(chrome.text)
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

    // MARK: Table

    /// Which optional columns fit, dropped from the right as the column narrows.
    private var visible: (modified: Bool, size: Bool, kind: Bool) {
        let gap = Theme.Space.s
        var room = width - Theme.Space.m * 2 - FileBrowserLayout.nameMinWidth
        let modified = room >= FileBrowserLayout.modifiedWidth + gap
        if modified { room -= FileBrowserLayout.modifiedWidth + gap }
        let size = modified && room >= FileBrowserLayout.sizeWidth + gap
        if size { room -= FileBrowserLayout.sizeWidth + gap }
        let kind = size && room >= FileBrowserLayout.kindWidth + gap
        return (modified, size, kind)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            sortButton(String(localized: "Name"), key: .name)
                .frame(minWidth: FileBrowserLayout.nameMinWidth, maxWidth: .infinity, alignment: .leading)
            if visible.modified {
                sortButton(String(localized: "Modified"), key: .modified)
                    .frame(width: FileBrowserLayout.modifiedWidth, alignment: .leading)
            }
            if visible.size {
                sortButton(String(localized: "File Size"), key: .size)
                    .frame(width: FileBrowserLayout.sizeWidth, alignment: .trailing)
            }
            if visible.kind {
                sortButton(String(localized: "Kind"), key: .kind)
                    .frame(width: FileBrowserLayout.kindWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: FileBrowserLayout.headerHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(chrome.hairline).frame(height: 1) }
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
        .buttonStyle(.plain)
    }

    private var rows: some View {
        let shown = column.shown
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !column.loading && shown.isEmpty {
                        Text(verbatim: emptyText)
                            .font(Theme.Font.body)
                            .foregroundStyle(chrome.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.Space.l)
                            .padding(.vertical, Theme.Space.xl)
                    }
                    ForEach(shown) { entry in
                        row(entry)
                            .id(entry.path)
                    }
                }
            }
            .onChange(of: column.selection) { _, selection in
                guard selection.count == 1, let path = selection.first else { return }
                proxy.scrollTo(path)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            focused = true
            column.clearSelection()
        }
        .focusable(interactions: .edit)
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .contextMenu { actionItems(for: column.selectedEntries) }
        .onDrop(of: [.fileURL, .plainText], delegate: FileDropDelegate(
            check: { dropCheck(into: nil) },
            targeted: { dropTargeted = $0 },
            refused: { dropRefusal = $0 },
            released: refusedRelease,
            perform: { receive($0, into: nil) }
        ))
    }

    private func row(_ entry: FileEntry) -> some View {
        let selected = column.selection.contains(entry.path)
        let dropping = dropFolder == entry.path
        return HStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                FileIcon(directory: entry.isDirectory)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.name)
                        .font(Theme.Font.body.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? chrome.accent : (entry.isHidden ? chrome.secondary : chrome.text))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: entry.mode)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(chrome.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: FileBrowserLayout.nameMinWidth, maxWidth: .infinity, alignment: .leading)
            if visible.modified {
                Text(verbatim: entry.modified.map(Self.timeFormatter.string(from:)) ?? "—")
                    .frame(width: FileBrowserLayout.modifiedWidth, alignment: .leading)
            }
            if visible.size {
                Text(verbatim: entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .monospacedDigit()
                    .frame(width: FileBrowserLayout.sizeWidth, alignment: .trailing)
            }
            if visible.kind {
                Text(verbatim: FileColumn.kind(of: entry))
                    .frame(width: FileBrowserLayout.kindWidth, alignment: .leading)
            }
        }
        .font(Theme.Font.rowMeta)
        .foregroundStyle(chrome.secondary)
        .lineLimit(1)
        .padding(.horizontal, Theme.Space.m)
        .frame(height: FileBrowserLayout.rowHeight)
        .background(selected || dropping ? chrome.accentFill : (hovered == entry.path ? chrome.elevated : Color.clear))
        .overlay {
            if dropping {
                Rectangle().stroke(chrome.accent, lineWidth: 1)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(chrome.hairline).frame(height: 1) }
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
        .contextMenu { actionItems(for: targets(for: entry)) }
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

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private var emptyText: String {
        if !column.filter.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "No matching files")
        }
        if !column.showHidden, column.hasHiddenEntries {
            return String(localized: "Hidden files are collapsed; show them from Actions")
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

    @ViewBuilder
    private func actionItems(for entries: [FileEntry]) -> some View {
        Button(String(localized: "New Folder")) { workspace.create(folder: true, in: column, window: window) }
        Button(String(localized: "New File")) { workspace.create(folder: false, in: column, window: window) }
        Divider()
        Button(String(localized: "Open Item")) {
            if let entry = entries.first { workspace.open(entry, in: column, window: window) }
        }
        .disabled(entries.count != 1)
        if workspace.other(than: column) != nil {
            Button(column.isRemote ? String(localized: "Download to This Mac") : String(localized: "Upload to Host")) {
                workspace.send(entries, from: column, window: window)
            }
            .disabled(entries.isEmpty)
        }
        Button(String(localized: "Delete"), role: .destructive) {
            workspace.delete(entries, in: column, window: window)
        }
        .disabled(entries.isEmpty)
        Divider()
        Button(String(localized: "Copy Path")) { workspace.copyPaths(entries, in: column) }
        Button(String(localized: "Open in Terminal")) { workspace.openTerminal(entries, in: column) }
        Divider()
        Button(String(localized: "Refresh")) { column.refresh() }
        Button(column.showHidden ? String(localized: "Hide Hidden Files") : String(localized: "Show Hidden Files")) {
            column.showHidden.toggle()
        }
        Button(String(localized: "Select All")) { column.selectAll() }
            .disabled(column.shown.isEmpty)
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

/// Folder in 1Panel's blue; file as a light page with a folded corner.
private struct FileIcon: View {
    let directory: Bool

    var body: some View {
        Image(systemName: directory ? "folder.fill" : "doc.fill")
            .font(.system(size: directory ? 15 : 16))
            .foregroundStyle(directory ? FileBrowserLayout.folderColor : Color(white: 0.85))
            .frame(width: FileBrowserLayout.iconSize, height: FileBrowserLayout.iconSize)
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
