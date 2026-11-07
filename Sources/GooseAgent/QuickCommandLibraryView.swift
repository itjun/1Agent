import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct QuickCommandLibraryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @ObservedObject private var store = QuickCommandStore.shared
    var isWorkspace = false
    let onClose: () -> Void
    @State private var query = ""
    @State private var splitDragStart: CGFloat?
    @State private var isDividerHovered = false
    private var collection: QuickCommandCollection {
        get { window.commandLibraryCollection }
        nonmutating set { window.commandLibraryCollection = newValue }
    }
    private var selectedID: UUID? {
        get { window.commandLibrarySelection }
        nonmutating set { window.commandLibrarySelection = newValue }
    }
    private var editing: QuickCommand? {
        get { window.commandLibraryDraft }
        nonmutating set { window.commandLibraryDraft = newValue }
    }
    @State private var error: String?
    @Environment(\.windowChrome) private var chrome
    @Environment(\.isShellTransparent) private var isShellTransparent

    private var collections: [QuickCommandCollection] { QuickCommandCollection.available(in: store.commands) }
    private var commands: [QuickCommand] {
        store.commands.filter { collection.contains($0) && $0.matchesSearch(query) }.sorted(by: QuickCommand.displayOrder)
    }
    private var selected: QuickCommand? { commands.first { $0.id == selectedID } }
    private var sections: [QuickCommandCollection] {
        collection == .all ? collections.filter { $0 != .all } : [collection]
    }

    var body: some View {
        Group {
            if isWorkspace {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(chrome.text)
            } else {
                CommandDialog(title: "Manage Command Library", close: onClose) {
                    libraryContent
                } actions: { Button("Close", action: onClose).buttonStyle(FamilyButtonStyle(kind: .secondary)) }
            }
        }
        .onAppear {
            if let editing { collection = QuickCommandCollection.owner(of: editing) }
            if !collections.contains(collection) { collection = .all }
            if !commands.contains(where: { $0.id == selectedID }) { selectedID = commands.first?.id }
        }
        .onChange(of: collection) { _, _ in
            if !commands.contains(where: { $0.id == selectedID }) { selectedID = commands.first?.id }
        }
        .onChange(of: commands.map(\.id)) { _, ids in
            if !ids.contains(where: { $0 == selectedID }) { selectedID = ids.first }
        }
        .onChange(of: collections) { _, values in
            if !values.contains(collection) { collection = .all }
        }
        .familySheet(isPresented: Binding(get: { !isWorkspace && editing != nil }, set: { if !$0 && !isWorkspace { editing = nil } }), width: SheetLayout.commandEditor, height: SheetLayout.commandEditorHeight) {
            if let editing {
                QuickCommandEditor(item: editing, hosts: model.hosts, onSaved: didSave) { self.editing = nil }.id(editing.id)
            }
        }

    }

    private func didSave(_ saved: QuickCommand) {
        query = ""
        collection = QuickCommandCollection.owner(of: saved)
        selectedID = saved.id
    }
    private var libraryContent: some View {
    HStack(alignment: .top, spacing: 20) {
        QuickCommandLibraryNavigation(model: model, window: window).frame(width: SheetLayout.commandLibraryNavigation)
        Divider()
        detailContent
    }
    }

    @ViewBuilder
    private var detailContent: some View {
        if isWorkspace, let editing {
            QuickCommandEditor(item: editing, hosts: model.hosts, isWorkspaceCard: true, onSaved: didSave) {
                self.editing = nil
            }.id(editing.id).frame(maxWidth: SheetLayout.commandEditor).frame(maxWidth: .infinity)
                .padding(Theme.Space.xl)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.clear)
                .modifier(FloatingContentSurface(showsShadow: false))
        } else {
            VStack(alignment: .leading, spacing: ShellLayout.workspaceInset) {
                GeometryReader { geometry in
                    let availableWidth = max(0, geometry.size.width - ShellLayout.workspaceInset)
                    let minimumWidth = min(SheetLayout.commandLibraryPaneMinWidth, availableWidth / 2)
                    let listWidth = min(availableWidth - minimumWidth,
                        max(minimumWidth, availableWidth * window.commandLibrarySplitRatio))
                    HStack(spacing: 0) {
                        commandList.frame(width: listWidth)
                        Color.clear
                            .frame(width: ShellLayout.workspaceInset)
                            .overlay {
                                Rectangle()
                                    .fill(Color(nsColor: .separatorColor))
                                    .frame(width: Theme.PaneStyle.dividerLineWidth)
                                    .allowsHitTesting(false)
                            }
                            .overlay {
                                PaneDividerHandle(vertical: true, onHover: { isDividerHovered = $0 }, onDragChanged: { delta in
                                    guard availableWidth > 0 else { return }
                                    if splitDragStart == nil { splitDragStart = listWidth }
                                    let width = min(availableWidth - minimumWidth,
                                        max(minimumWidth, (splitDragStart ?? listWidth) + delta))
                                    window.commandLibrarySplitRatio = width / availableWidth
                                }, onDragEnded: { splitDragStart = nil }, onDoubleClick: {
                                    window.commandLibrarySplitRatio = 0.5
                                })
                                .frame(width: 8)
                                .accessibilityLabel(Text("Resize Command Columns"))
                                .help("Drag to resize. Double-click to split equally.")
                            }
                        commandPreview.frame(width: max(0, availableWidth - listWidth))
                    }
                    .frame(height: geometry.size.height)
                    .onDisappear {
                        splitDragStart = nil
                        isDividerHovered = false
                    }
                }
            }
        }
    }

    private var commandList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if !isWorkspace {
                QuickCommandLibraryHeader(model: model, window: window)
                    .frame(height: ShellLayout.compactHeaderHeight)
            }
            CommandTextField(text: $query, placeholder: String(localized: "Search names, commands, hosts or folders"),
                             identifier: "quickCommands.library.search", symbol: "magnifyingglass")
                .frame(height: Theme.Control.height)
            if let message = window.commandLibraryMessage {
                Text(verbatim: message).foregroundStyle(chrome.secondary).font(Theme.Font.rowMeta)
            }
            if let message = error ?? store.loadError {
                Text(verbatim: message).foregroundStyle(chrome.danger).font(Theme.Font.rowMeta)
            }
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(sections) { section in
                        let rows = commands.filter { section.contains($0) }
                        if !rows.isEmpty {
                            if collection == .all {
                                Text(verbatim: section.title).font(Theme.Font.sectionTitle)
                                    .padding(.horizontal, 10).padding(.top, Theme.Space.s)
                            }
                            // 编辑后刷新行里的名称、正文和菜单快照，不复用旧内容。
                            ForEach(rows) { item in libraryRow(item).id(item) }
                        }
                    }
                    if commands.isEmpty {
                        Text(query.isEmpty && collection == .common ? "No Library Commands" : store.commands.isEmpty ? "Your command library is empty." : "No matching commands")
                            .foregroundStyle(chrome.secondary).padding(.vertical, Theme.Space.l)
                        if collection != .all && !query.isEmpty {
                            Button("Search All Commands") { collection = .all }
                                .buttonStyle(FamilyButtonStyle())
                        }
                    }
                }
            }.frame(maxHeight: .infinity)
        }
        .padding(Theme.Space.m)
        .background(commandPaneBackground)
        .modifier(FloatingContentSurface())
    }

    private var commandPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let selected {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "terminal").foregroundStyle(chrome.accent)
                        Text(verbatim: selected.alias).font(Theme.Font.sectionTitle).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: Theme.Space.s) {
                        Text(verbatim: QuickCommandCollection.owner(of: selected).title)
                            .fixedSize()
                        if let directory = selected.directory {
                            Text(verbatim: selected.host == nil ? LocalTerminal.displayPath(directory) : directory)
                                .lineLimit(1).truncationMode(.middle).help(directory)
                        }
                    }.font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                    HStack(spacing: Theme.Space.s) {
                        if selected.scope == .all {
                            FamilyMenu("Copy to Host", items: { hostCopyActions(selected) })
                                .accessibilityIdentifier("quickCommands.library.copyToHost")
                        } else {
                            Button("Save to Library") { model.copyLibraryCommand(selected.id, to: .common, in: window) }
                                .buttonStyle(FamilyButtonStyle(kind: .secondary))
                        }
                        Spacer(minLength: 0)
                        Button { CommandClipboard.copy(selected.command) } label: { Label("Copy", systemImage: "doc.on.doc") }
                            .buttonStyle(FamilyButtonStyle(kind: .secondary)).accessibilityIdentifier("quickCommands.library.copy")
                        Button { editing = selected } label: { Label("Edit", systemImage: "pencil") }
                            .buttonStyle(FamilyButtonStyle(kind: .secondary)).accessibilityIdentifier("quickCommands.library.edit")
                    }
                }.padding(Theme.Space.l)
                Divider()
                ScrollView {
                    Text(verbatim: selected.command).font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.l)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).id(selected.id)
            } else {
                Text("Select a command to preview its details.")
                    .font(Theme.Font.body).foregroundStyle(chrome.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Theme.Space.l)
            }
        }
        .background(commandPaneBackground)
        .modifier(FloatingContentSurface())
    }

    private var commandPaneBackground: Color { isWorkspace ? .clear : chrome.background }

    private func libraryRow(_ item: QuickCommand) -> some View {
        HStack(spacing: 0) {
            Button { selectedID = item.id } label: {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: item.needsRepair ? "exclamationmark.triangle" : "terminal")
                                .foregroundStyle(item.needsRepair ? chrome.warning : chrome.accent)
                            Text(verbatim: item.alias).font(Theme.Font.row).lineLimit(2)
                        }
                        if let directory = item.directory {
                            Text(verbatim: item.host == nil ? LocalTerminal.displayPath(directory) : directory)
                                .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary).lineLimit(1).truncationMode(.middle)
                                .help(directory)
                        }
                        if item.needsRepair {
                            Text("Needs binding review — edit to repair").font(Theme.Font.rowMeta).foregroundStyle(chrome.warning)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: item.command.replacingOccurrences(of: "\n", with: " ↵ "))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(chrome.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, minHeight: 20, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("quickCommand." + item.id.uuidString)
                .accessibilityAddTraits(selectedID == item.id ? .isSelected : [])
                .overlay {
                    if item.scope == .all {
                        QuickCommandDragHandle(item: item, chrome: chrome, onClick: { selectedID = item.id },
                                               onDoubleClick: { editing = item }, onDragStart: { selectedID = item.id })
                            .accessibilityHidden(true)
                    }
                }
            FamilyMenu(items: { rowActions(item) }) { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .help("Command Actions")
        }.padding(.horizontal, 10).padding(.vertical, Theme.Space.m).background(selectedID == item.id ? chrome.rowSelection(active: true) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
            .familyContextMenu { rowActions(item) }
    }
    private func rowActions(_ item: QuickCommand) -> [FamilyMenuItem] {
        [FamilyMenuItem(title: String(localized: "Copy to Host"), children: hostCopyActions(item)),
         FamilyMenuItem(title: String(localized: "Save to Library"), enabled: item.scope != .all,
                        action: { model.copyLibraryCommand(item.id, to: .common, in: window) }),
         FamilyMenuItem(title: String(localized: "Edit"), action: { editing = item }),
         FamilyMenuItem(title: String(localized: "Copy Quick Command"), action: {
             do { try QuickCommandClipboard.copy([item]) } catch { self.error = error.localizedDescription }
         }),
         FamilyMenuItem(title: String(localized: "Copy Command Text"), action: { CommandClipboard.copy(item.command) }),
         FamilyMenuItem(title: String(localized: "Duplicate Command"), action: { var copy = item; copy.id = UUID(); editing = copy }),
         FamilyMenuItem(title: String(localized: "Move Up"), action: { move(item, delta: -1) }),
         FamilyMenuItem(title: String(localized: "Move Down"), action: { move(item, delta: 1) }),
         .separator,
         FamilyMenuItem(title: String(localized: "Delete"), destructive: true, action: {
             do { try store.remove(item.id) } catch { self.error = error.localizedDescription }
         })]
    }
    private func hostCopyActions(_ item: QuickCommand) -> [FamilyMenuItem] {
        ([QuickCommandCollection.local] + model.hosts.map { .host($0.alias) }).map { destination in
            FamilyMenuItem(title: destination.title, action: { model.copyLibraryCommand(item.id, to: destination, in: window) })
        }
    }
    private func move(_ item: QuickCommand, delta: Int) {
        let peers = commands.filter { QuickCommandCollection.owner(of: $0) == QuickCommandCollection.owner(of: item) && $0.section == item.section }
        guard let index = peers.firstIndex(where: { $0.id == item.id }), peers.indices.contains(index + delta) else { return }
        do { try store.move(item.id, relativeTo: peers[index + delta].id, after: delta > 0) }
        catch { self.error = error.localizedDescription }
    }

}


/// 分类标记和操作共用窗口通栏；管理弹窗仍可复用同一组控件。
struct QuickCommandLibraryHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @ObservedObject private var store = QuickCommandStore.shared
    @Environment(\.windowChrome) private var chrome
    @State private var importing: QuickCommandLibrary?
    private var collection: QuickCommandCollection { window.commandLibraryCollection }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: collection == .common ? "books.vertical" : collection == .local ? "laptopcomputer" : collection.host == nil ? "square.stack" : "terminal")
            Text(verbatim: collection.title).font(.headline).lineLimit(1)
            Spacer(minLength: 0)
            FamilyMenu("Actions", items: { libraryActions })
                .font(Theme.Font.body).foregroundStyle(chrome.text)
                .padding(.horizontal, Theme.Space.s)
                .fixedSize()
                .accessibilityLabel(Text("Actions"))
                .accessibilityIdentifier("quickCommands.library.actions")
        }
        .familySheet(isPresented: optionalBinding($importing), width: SheetLayout.commandLibrary, height: SheetLayout.commandLibraryHeight) {
            if let importing { QuickCommandImportView(library: importing, hosts: model.hosts) { self.importing = nil } }
        }
    }

    private var libraryActions: [FamilyMenuItem] {
        [FamilyMenuItem(title: String(localized: "New Quick Command"), enabled: store.loadError == nil,
                        action: { window.commandLibraryDraft = collection.draft(in: model.quickCommandContext(in: window)) }),
         .separator,
         FamilyMenuItem(title: String(localized: "Import Commands"), action: importLibrary),
         FamilyMenuItem(title: String(localized: "Export Commands"), enabled: store.loadError == nil, action: exportLibrary)]
    }

    private func importLibrary() {
        let owner = NSApp.keyWindow
        defer { owner?.makeKeyAndOrderFront(nil) }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw QuickCommandError.invalidBackup }
            importing = try QuickCommandLibrary.decode(Data(contentsOf: url))
        } catch { window.commandLibraryMessage = error.localizedDescription }
    }
    private func exportLibrary() {
        let owner = NSApp.keyWindow
        defer { owner?.makeKeyAndOrderFront(nil) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "1Agent-commands.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let referencedHosts = Set(store.commands.compactMap(\.host))
            let hints = Dictionary(uniqueKeysWithValues: model.hosts.filter { referencedHosts.contains($0.alias) }.map { ($0.alias, $0.subtitle) })
            try QuickCommandLibrary(commands: store.commands, hostHints: hints).encoded().write(to: url, options: .atomic)
        } catch { window.commandLibraryMessage = error.localizedDescription }
    }
}

/// 指令管理的分类属于主侧栏，和文件页沿用相同的导航位置。
struct QuickCommandLibraryNavigation: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @ObservedObject private var store = QuickCommandStore.shared
    @Environment(\.windowChrome) private var chrome
    private var collections: [QuickCommandCollection] { QuickCommandCollection.available(in: store.commands) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(collections.filter { $0.host == nil }) { row($0) }
                if collections.contains(where: { $0.host != nil }) {
                    Divider().padding(.vertical, 10)
                    Text("SSH Hosts").font(Theme.Font.sidebarSection).foregroundStyle(chrome.secondary).padding(.horizontal, 10)
                    ForEach(collections.filter { $0.host != nil }) { row($0) }
                }
            }.padding(.horizontal, SidebarLayout.rowInset).padding(.top, Theme.Space.s)
        }
    }
    private func row(_ value: QuickCommandCollection) -> some View {
        Button {
            window.commandLibraryDraft = nil
            window.commandLibraryMessage = nil
            window.commandLibraryCollection = value
        } label: {
            HStack(spacing: 10) {
                Image(systemName: value == .common ? "books.vertical" : value == .local ? "laptopcomputer" : value.host == nil ? "square.stack" : "terminal")
                Text(verbatim: value.title).lineLimit(2)
                Spacer(minLength: 0)
                Text(verbatim: String(store.commands.filter { value.contains($0) }.count)).foregroundStyle(chrome.secondary)
            }.font(Theme.Font.row).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(window.commandLibraryCollection == value ? chrome.rowSelection(active: true) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        }.buttonStyle(.plain).accessibilityAddTraits(window.commandLibraryCollection == value ? .isSelected : [])
            .accessibilityIdentifier("quickCommands.library.collection." + value.id)
            .background {
                if value != .all && value != .common {
                    QuickCommandCopyTarget(chrome: chrome) { model.copyLibraryCommand($0, to: value, in: window) }
                }
            }
    }
}

struct QuickCommandImportView: View {
    let library: QuickCommandLibrary
    let hosts: [SSHHost]
    let onClose: () -> Void
    @ObservedObject private var store = QuickCommandStore.shared
    @State private var hostMap: [String: String] = [:]
    @State private var paths: [UUID: String] = [:]
    @State private var choices: [UUID: QuickCommandConflict] = [:]
    @State private var busy = false
    @State private var error: String?
    @Environment(\.windowChrome) private var chrome

    private var incomingHosts: [String] { Array(Set(library.commands.compactMap(\.host))).sorted() }
    var body: some View {
        CommandDialog(title: "Restore Command Library", close: onClose) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Review host mappings and folders. Unresolved bindings are imported disabled until repaired.")
                        .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                    Text(String(format: String(localized: "%d commands in this backup"), library.commands.count)).font(Theme.Font.sectionTitle)
                    ForEach(incomingHosts, id: \.self) { alias in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: alias)
                                if let hint = library.hostHints[alias] { Text(verbatim: hint).font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary) }
                            }
                            Spacer()
                            FamilyPicker(value: Binding(get: { hostMap[alias] ?? "" }, set: { hostMap[alias] = $0 }),
                                options: [("", String(localized: "Not mapped"))] + hosts.map { ($0.alias, $0.alias) })
                        }
                    }
                    Divider()
                    ForEach(library.commands) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(verbatim: item.alias).font(Theme.Font.sectionTitle)
                                Spacer()
                                if let existing = store.commands.first(where: { $0.id == item.id }) {
                                    if existing == item { Text("Unchanged — skip").font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary) }
                                    else {
                                        FamilyPicker(value: Binding(get: { choices[item.id] ?? .keep }, set: { choices[item.id] = $0 }),
                                            options: QuickCommandConflict.allCases.map { ($0, $0.title) })
                                    }
                                } else { Text("New").font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary) }
                            }
                            Text(verbatim: item.command).font(.system(size: 12, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                            Text(verbatim: [item.scope.title, item.host].compactMap { $0 }.joined(separator: " · "))
                                .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                            if let path = item.directory {
                                CommandTextField(text: Binding(get: { paths[item.id] ?? path }, set: { paths[item.id] = $0 }),
                                    placeholder: String(localized: "Working Directory"), identifier: "quickCommands.import.path." + item.id.uuidString)
                                    .frame(height: 32)
                            }
                            Divider()
                        }
                    }
                    if let error { Text(verbatim: error).foregroundStyle(chrome.danger) }
                }
            }
        } actions: {
            if busy { ProgressView().controlSize(.small) }
            Button("Cancel", action: onClose).buttonStyle(FamilyButtonStyle())
            Button("Merge Commands", action: merge).buttonStyle(FamilyButtonStyle(kind: .primary)).disabled(busy)
                .accessibilityIdentifier("quickCommands.import.merge")
        }
    }
    private func merge() {
        busy = true
        Task {
            var incoming: [QuickCommand] = []
            var checked: [String: Bool] = [:]
            for original in library.commands {
                if let existing = store.commands.first(where: { $0.id == original.id }), existing == original || (choices[original.id] ?? .keep) == .keep {
                    continue
                }
                var item = original
                item.needsRepair = false
                if let host = original.host {
                    if let mapped = hostMap[host], !mapped.isEmpty { item.host = mapped }
                    else { item.needsRepair = true }
                }
                if let originalPath = original.directory {
                    let newPath = paths[item.id] ?? originalPath
                    if QuickCommand.validPath(newPath) { item.directory = QuickCommand.path(newPath) }
                    else { item.needsRepair = true }
                    if !item.needsRepair, let path = item.directory {
                        let key = (item.host ?? "") + "\0" + path
                        if checked[key] == nil {
                            if item.host == nil { checked[key] = ExternalOpen.validatedDirectory(path) != nil }
                            else { checked[key] = (try? await fileSystem(for: item.host).list(path)) != nil }
                        }
                        if checked[key] != true { item.needsRepair = true }
                    }
                }
                incoming.append(item)
            }
            do {
                try store.replace(QuickCommandMerge.merge(existing: store.commands, incoming: incoming, choices: choices))
                onClose()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
