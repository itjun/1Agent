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
    @FocusState private var isListFocused: Bool
    @State private var splitDragStart: CGFloat?
    @State private var isDividerHovered = false
    @State private var copiedCommandID: UUID?
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
    @Environment(\.workspaceTitlebarLeadingInset) private var titlebarLeadingInset

    private var collections: [QuickCommandCollection] { QuickCommandCollection.available(in: store.commands) }
    private var sidebarContext: QuickCommandContext? {
        guard collection != .common else { return nil }
        let current = model.currentTerminalContext(in: window)
        if current.sessionID != nil, current.host == collection.host { return current }
        let tabIDs = Set(model.sidebarOrder(in: window))
        guard let tab = model.tabs.first(where: { tabIDs.contains($0.id) && $0.hasTerminal && $0.alias == collection.host }) else { return nil }
        return model.commandContext(in: window, targetTabID: tab.id)
    }

    private var numberedCommands: [(offset: Int, element: QuickCommand)] {
        collection.orderedCommands(in: store.commands, sidebarContext: sidebarContext)
            .enumerated().filter { $0.element.matchesSearch(query) }
    }

    private var commands: [QuickCommand] { numberedCommands.map(\.element) }
    private var selected: QuickCommand? { commands.first { $0.id == selectedID } }
    private var isCreatingNewDraft: Bool {
        guard isWorkspace, let editing else { return false }
        return !store.commands.contains { $0.id == editing.id }
    }
    private var allowsReordering: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            if !collections.contains(collection) { collection = .common }
            if !commands.contains(where: { $0.id == selectedID }) { selectedID = commands.first?.id }
        }
        .onChange(of: collection) { _, _ in
            if !commands.contains(where: { $0.id == selectedID }) { selectedID = commands.first?.id }
        }
        .onChange(of: commands.map(\.id)) { _, ids in
            if !ids.contains(where: { $0 == selectedID }) { selectedID = ids.first }
        }
        .onChange(of: collections) { _, values in
            if !values.contains(collection) { collection = .common }
        }
        .task(id: copiedCommandID) {
            guard copiedCommandID != nil else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            copiedCommandID = nil
        }
        .familySheet(isPresented: Binding(get: { !isWorkspace && editing != nil }, set: { if !$0 && !isWorkspace { editing = nil } }), width: SheetLayout.commandEditor, height: SheetLayout.commandEditorHeight) {
            if let editing {
                QuickCommandEditor(item: editing, hosts: model.hosts, onSaved: didSave) { self.editing = nil }.id(editing.id)
            }
        }
    }

    private func didSave(_ saved: QuickCommand) {
        window.isCommandLibraryDraftDirty = false
        query = ""
        collection = QuickCommandCollection.owner(of: saved)
        selectedID = saved.id
    }

    private func moveSelection(by delta: Int) {
        guard !commands.isEmpty else { return }
        let current = commands.firstIndex { $0.id == selectedID }
        let next = current.map { min(max($0 + delta, 0), commands.count - 1) }
            ?? (delta > 0 ? 0 : commands.count - 1)
        let targetID = commands[next].id
        guard targetID != selectedID || editing != nil else { return }
        if isWorkspace, editing != nil {
            window.confirmDiscardCommandDraftIfNeeded {
                editing = nil
                selectedID = targetID
            }
        } else {
            selectedID = targetID
        }
    }

    private func select(_ item: QuickCommand) {
        if isWorkspace, let currentDraft = editing {
            if currentDraft.id == item.id {
                selectedID = item.id
                return
            }
            window.confirmDiscardCommandDraftIfNeeded {
                editing = nil
                selectedID = item.id
                isListFocused = true
            }
        } else {
            selectedID = item.id
            isListFocused = true
        }
    }

    private func requestEdit(_ item: QuickCommand) {
        if isWorkspace, editing != nil, editing?.id != item.id {
            window.confirmDiscardCommandDraftIfNeeded {
                selectedID = item.id
                editing = item
            }
        } else {
            selectedID = item.id
            editing = item
        }
    }

    private var libraryContent: some View {
        VStack(spacing: Theme.Space.m) {
            QuickCommandLibraryHeader(model: model, window: window)
            HStack(alignment: .top, spacing: 20) {
                QuickCommandLibraryNavigation(model: model, window: window).frame(width: SheetLayout.commandLibraryNavigation)
                Divider()
                detailContent
            }
        }
    }

    private var detailContent: some View {
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
                rightPane.frame(width: max(0, availableWidth - listWidth))
            }
            .frame(height: geometry.size.height)
            .onDisappear {
                splitDragStart = nil
                isDividerHovered = false
            }
        }
    }

    private var commandList: some View {
        let entries = numberedCommands
        let groups = QuickCommandDirectoryGroup.group(entries: entries, in: collection)
        return VStack(alignment: .leading, spacing: 0) {
            commandListHeader
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        if isCreatingNewDraft {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(chrome.accent)
                                    .accessibilityHidden(true)
                                Text("Editing New Command")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(chrome.text)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(chrome.rowSelection(active: true), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.control)
                                    .strokeBorder(chrome.accent.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            )
                        }
                        if entries.isEmpty {
                            Text(query.isEmpty && collection == .common
                                 ? "No Library Commands"
                                 : store.commands.isEmpty ? "Your command library is empty." : "No matching commands")
                                .foregroundStyle(chrome.secondary)
                                .font(Theme.Font.body)
                                .padding(.horizontal, Theme.Space.xs)
                                .padding(.vertical, Theme.Space.l)
                        } else {
                            ForEach(groups) { group in
                                VStack(alignment: .leading, spacing: Theme.Space.m) {
                                    if group.showsHeader {
                                        QuickCommandDirectorySectionHeader(
                                            kind: group.kind,
                                            isLocalCollection: collection == .local,
                                            count: group.entries.count
                                        )
                                    }
                                    ForEach(group.entries) { entry in
                                        let item = entry.item
                                        let isRowSelected = !isCreatingNewDraft && selectedID == item.id
                                        CommandLibraryRow(
                                            item: item,
                                            number: entry.number,
                                            isSelected: isRowSelected,
                                            allowsReordering: allowsReordering,
                                            select: { select(item) },
                                            edit: { requestEdit(item) },
                                            onReorder: reorderCommand,
                                            actions: { rowActions(item) }
                                        )
                                        .id(item.id)
                                    }
                                }
                            }
                        }
                    }
                    .padding(Theme.Space.s)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: selectedID) { _, id in
                    if let id, commands.contains(where: { $0.id == id }) { proxy.scrollTo(id) }
                }
            }
            .focusable(interactions: .edit)
            .focusEffectDisabled()
            .focused($isListFocused)
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                guard press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
                moveSelection(by: press.key == .upArrow ? -1 : 1)
                return .handled
            }
        }
        .background(commandPaneBackground)
        .clipShape(RoundedRectangle(cornerRadius: isWorkspace ? ShellLayout.contentRadius : Theme.Radius.row))
        .modifier(FloatingContentSurface())
    }

    private var commandListHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if isWorkspace {
                HStack(spacing: Theme.Space.xs) {
                    Text(verbatim: collection.title)
                        .font(.headline)
                        .lineLimit(1)
                        .padding(.leading, titlebarLeadingInset)
                    Spacer(minLength: 0)
                    QuickCommandLibraryHeader(model: model, window: window, showsTitle: false, showsPlusButton: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: ShellLayout.compactHeaderHeight)
                .background(WindowDragArea())
            }
            CommandTextField(text: $query, placeholder: String(localized: "Search names, commands, hosts or folders"),
                             identifier: "quickCommands.library.search", symbol: "magnifyingglass",
                             onMoveSelection: { moveSelection(by: $0) })
                .frame(height: Theme.Control.height)
            if let message = window.commandLibraryMessage {
                Text(verbatim: message).foregroundStyle(chrome.secondary).font(Theme.Font.rowMeta)
            }
            if let message = error ?? store.loadError {
                Text(verbatim: message).foregroundStyle(chrome.danger).font(Theme.Font.rowMeta)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.top, isWorkspace ? 2 : Theme.Space.m)
        .padding(.bottom, Theme.Space.m)
    }

    @ViewBuilder
    private var rightPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isWorkspace, let editing {
                QuickCommandEditor(
                    item: editing,
                    hosts: model.hosts,
                    isWorkspaceCard: true,
                    onDirtyChange: { window.isCommandLibraryDraftDirty = $0 },
                    onSaved: didSave
                ) {
                    window.isCommandLibraryDraftDirty = false
                    self.editing = nil
                }
                .id(editing.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                commandInspector
            }
        }
        .background(commandPaneBackground)
        .clipShape(RoundedRectangle(cornerRadius: isWorkspace ? ShellLayout.contentRadius : Theme.Radius.row))
        .modifier(FloatingContentSurface())
    }

    @ViewBuilder
    private var commandInspector: some View {
        if isWorkspace {
            WindowDragArea()
                .frame(height: ShellLayout.compactHeaderHeight)
                .accessibilityHidden(true)
        }
        if let item = selected {
            let parameters = QuickCommandLexer.extractLongFlags(item.command)
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: Theme.Space.s) {
                        inspectorTitle(item)
                        Spacer(minLength: 0)
                        inspectorActions(item)
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        inspectorTitle(item)
                        HStack(spacing: Theme.Space.s) {
                            inspectorActions(item)
                            Spacer(minLength: 0)
                        }
                    }
                }
                if item.needsRepair {
                    Label("Needs binding review — edit to repair", systemImage: "exclamationmark.triangle")
                        .font(Theme.Font.rowMeta)
                        .foregroundStyle(chrome.warning)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, isWorkspace ? 0 : Theme.Space.l)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    QuickCommandCodeBlock(command: item.command)
                    if !parameters.isEmpty {
                        QuickCommandParametersGrid(parameters: parameters)
                    }
                }
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(item.id)
        } else {
            Text("Select a command to preview its details.")
                .font(Theme.Font.body)
                .foregroundStyle(chrome.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Theme.Space.l)
        }
    }

    private func inspectorTitle(_ item: QuickCommand) -> some View {
        Text(verbatim: item.alias)
            .font(.system(size: 16, weight: .semibold))
            .lineLimit(2)
            .accessibilityIdentifier("quickCommands.library.title")
    }

    @ViewBuilder
    private func inspectorActions(_ item: QuickCommand) -> some View {
        if item.scope == .all {
            FamilyMenu("Copy to Host", items: { hostCopyActions(item) })
                .accessibilityIdentifier("quickCommands.library.copyToHost")
        }
        Button {
            CommandClipboard.copy(item.command)
            copiedCommandID = item.id
        } label: {
            Label(copiedCommandID == item.id ? "Copied" : "Copy",
                  systemImage: copiedCommandID == item.id ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(FamilyButtonStyle(kind: .secondary))
        .accessibilityIdentifier("quickCommands.library.copy")

        Button { requestEdit(item) } label: { Label("Edit", systemImage: "pencil") }
            .buttonStyle(FamilyButtonStyle(kind: .primary))
            .accessibilityIdentifier("quickCommands.library.edit")
    }

    private var commandPaneBackground: Color { chrome.background }

    private func rowActions(_ item: QuickCommand) -> [FamilyMenuItem] {
        [FamilyMenuItem(title: String(localized: "Copy to Host"), children: hostCopyActions(item)),
         FamilyMenuItem(title: String(localized: "Save to Library"), enabled: item.scope != .all,
                        action: { model.copyLibraryCommand(item.id, to: .common, in: window) }),
         FamilyMenuItem(title: String(localized: "Edit"), action: { requestEdit(item) }),
         FamilyMenuItem(title: String(localized: "Copy Quick Command"), action: {
             do { try QuickCommandClipboard.copy([item]) } catch { self.error = error.localizedDescription }
         }),
         FamilyMenuItem(title: String(localized: "Copy Command Text"), action: { CommandClipboard.copy(item.command) }),
         FamilyMenuItem(title: String(localized: "Duplicate Command"), action: {
             var copy = item
             copy.id = UUID()
             window.confirmDiscardCommandDraftIfNeeded { editing = copy }
         }),
         .separator,
         FamilyMenuItem(title: String(localized: "Delete"), destructive: true, action: {
             do {
                 if editing?.id == item.id {
                     window.isCommandLibraryDraftDirty = false
                     editing = nil
                 }
                 try store.remove(item.id)
             } catch { self.error = error.localizedDescription }
         })]
    }

    private func hostCopyActions(_ item: QuickCommand) -> [FamilyMenuItem] {
        ([QuickCommandCollection.local] + model.hosts.map { .host($0.alias) }).map { destination in
            FamilyMenuItem(title: destination.title, action: { model.copyLibraryCommand(item.id, to: destination, in: window) })
        }
    }

    private func reorderCommand(sourceID: UUID, destinationID: UUID, isAfter: Bool) {
        do { try _ = store.move(sourceID, relativeTo: destinationID, after: isAfter) }
        catch { self.error = error.localizedDescription }
    }
}

private struct CommandLibraryRow: View {
    let item: QuickCommand
    let number: Int
    let isSelected: Bool
    let allowsReordering: Bool
    let select: () -> Void
    let edit: () -> Void
    let onReorder: (UUID, UUID, Bool) -> Void
    let actions: () -> [FamilyMenuItem]
    @Environment(\.windowChrome) private var chrome
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @FocusState private var isMenuFocused: Bool
    @State private var isHovered = false
    @State private var isMenuOpen = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        return Button(action: select) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if item.needsRepair {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(chrome.warning)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(verbatim: "\(number)-")
                            .monospacedDigit()
                            .foregroundStyle(chrome.secondary)
                            .fixedSize()
                        Text(verbatim: item.alias)
                            .fontWeight(.semibold)
                            .foregroundStyle(chrome.text)
                            .lineLimit(1)
                    }
                    .font(Theme.Font.row)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "\(number)-\(item.alias)"))
                    if !item.group.isEmpty {
                        Text(verbatim: item.group)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(chrome.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(chrome.elevated, in: RoundedRectangle(cornerRadius: 4))
                    }
                }

                Text(verbatim: item.singleLinePreview)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(chrome.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, Theme.Space.m)
            .padding(.trailing, 30)
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(FamilyPlainButtonStyle())
        .accessibilityIdentifier("quickCommand." + item.id.uuidString)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .overlay {
            QuickCommandDragHandle(item: item, chrome: chrome, onClick: select,
                                   onDoubleClick: edit, onDragStart: select)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .trailing) {
            FamilyMenu(items: actions, onPresentationChange: { isMenuOpen = $0 }) {
                Image(systemName: "ellipsis")
                    .foregroundStyle(chrome.secondary)
                    .frame(width: 26, height: 26)
            }
            .accessibilityLabel(Text("Command Actions"))
            .help("Command Actions")
            .padding(.trailing, Theme.Space.xs)
            .opacity(isHovered || isMenuOpen || isVoiceOverEnabled || isMenuFocused ? 1 : 0)
            .focused($isMenuFocused)
        }
        .overlay {
            if allowsReordering {
                QuickCommandReorderTarget(item: item, chrome: chrome, onMove: onReorder)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background(rowFill, in: shape)
        .overlay {
            if isSelected {
                shape.strokeBorder(chrome.accent.opacity(chrome.isDark ? 0.68 : 0.45), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .onHover { isHovered = $0 }
        .familyContextMenu(actions)
        .help(item.alias + "\n" + item.command)
    }

    private var rowFill: Color {
        if isSelected { return chrome.rowSelection(active: true) }
        if isHovered { return chrome.elevated }
        return Color.clear
    }
}

/// 分类标记和操作共用窗口通栏；管理弹窗仍可复用同一组控件。
struct QuickCommandLibraryHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    var showsTitle = true
    var showsPlusButton = false
    @ObservedObject private var store = QuickCommandStore.shared
    @Environment(\.windowChrome) private var chrome
    @State private var importing: QuickCommandLibrary?
    @State private var pasteRequest: QuickCommandPasteRequest?
    @State private var historyPresented = false
    private var collection: QuickCommandCollection { window.commandLibraryCollection }
    private var maintenanceContext: QuickCommandContext {
        let current = model.currentTerminalContext(in: window)
        if collection == .common || collection.host == current.host { return current }
        return QuickCommandContext(host: collection.host)
    }

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            if showsTitle { Text(verbatim: collection.title).font(.headline).lineLimit(1) }
            if showsTitle { Spacer(minLength: 0) }
            if showsPlusButton, store.loadError == nil {
                SidebarIconButton(
                    symbol: "plus",
                    help: String(localized: "New Quick Command"),
                    accessibilityLabel: "New Quick Command",
                    hoverFill: chrome.elevated,
                    action: startNewCommand
                )
                .accessibilityIdentifier("quickCommands.library.new")
            }
            FamilyMenu("Actions", items: { libraryActions })
                .font(Theme.Font.body).foregroundStyle(chrome.text)
                .padding(.horizontal, Theme.Space.xs)
                .fixedSize()
                .accessibilityLabel(Text("Actions"))
                .accessibilityIdentifier("quickCommands.library.actions")
        }
        .familySheet(isPresented: optionalBinding($importing), width: SheetLayout.commandLibrary, height: SheetLayout.commandLibraryHeight) {
            if let importing { QuickCommandImportView(library: importing, hosts: model.hosts) { self.importing = nil } }
        }
        .familySheet(isPresented: optionalBinding($pasteRequest), width: SheetLayout.quickCommand, height: SheetLayout.quickCommandHeight) {
            if let pasteRequest {
                QuickCommandPasteView(request: pasteRequest, onClose: { self.pasteRequest = nil }, onSaved: { additions in
                    self.pasteRequest = nil
                    if let first = additions.first {
                        window.isCommandLibraryDraftDirty = false
                        window.commandLibraryDraft = nil
                        window.commandLibraryCollection = QuickCommandCollection.owner(of: first)
                        window.commandLibrarySelection = first.id
                    }
                }).id(pasteRequest.id)
            }
        }
        .familySheet(isPresented: $historyPresented, width: SheetLayout.commandLibrary, height: SheetLayout.commandLibraryHeight) {
            QuickCommandHistoryView(context: maintenanceContext, hosts: model.hosts) { historyPresented = false }
        }
    }

    private func startNewCommand() {
        window.confirmDiscardCommandDraftIfNeeded {
            window.commandLibraryDraft = collection.draft(in: model.currentTerminalContext(in: window))
        }
    }

    private var libraryActions: [FamilyMenuItem] {
        [FamilyMenuItem(title: String(localized: "New Quick Command"), enabled: store.loadError == nil,
                        action: startNewCommand),
         FamilyMenuItem(title: String(localized: "Add from History"), enabled: store.loadError == nil,
                        action: { historyPresented = true }),
         FamilyMenuItem(title: String(localized: "Paste Quick Commands…"), enabled: store.loadError == nil, action: {
             do { pasteRequest = try QuickCommandPasteRequest(transfer: QuickCommandClipboard.read(), context: maintenanceContext) }
             catch { window.commandLibraryMessage = error.localizedDescription }
         }),
         FamilyMenuItem(title: String(localized: "Copy Collection Commands"), enabled: store.commands.contains(where: collection.contains), action: {
             do { try QuickCommandClipboard.copy(store.commands.filter(collection.contains).sorted(by: QuickCommand.displayOrder)) }
             catch { window.commandLibraryMessage = error.localizedDescription }
         }),
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
                    Text("SSH Hosts").font(Theme.Font.sidebarCategory).foregroundStyle(chrome.secondary)
                        .padding(.horizontal, SidebarLayout.contentInset)
                        .frame(height: SidebarLayout.sectionHeaderHeight)
                        .padding(.top, SidebarLayout.sectionGap)
                    ForEach(collections.filter { $0.host != nil }) { row($0) }
                }
            }.padding(.horizontal, SidebarLayout.rowInset).padding(.top, Theme.Space.s)
        }
    }
    private func row(_ value: QuickCommandCollection) -> some View {
        Button {
            guard window.commandLibraryCollection != value || window.commandLibraryDraft != nil else { return }
            window.confirmDiscardCommandDraftIfNeeded {
                window.commandLibraryDraft = nil
                window.commandLibraryMessage = nil
                window.commandLibraryCollection = value
            }
        } label: {
            HStack(spacing: 10) {
                Text(verbatim: value.title).lineLimit(2)
                    .fontWeight(window.commandLibraryCollection == value ? .semibold : .regular)
                Spacer(minLength: 0)
                Text(verbatim: String(store.commands.filter { value.contains($0) }.count)).foregroundStyle(chrome.secondary)
            }.font(Theme.Font.row).foregroundStyle(chrome.text)
                .padding(.horizontal, SidebarLayout.contentInset).padding(.vertical, Theme.Space.s)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .contentShape(Rectangle())
                .background(window.commandLibraryCollection == value ? chrome.rowSelection(active: true) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        }.buttonStyle(FamilyPlainButtonStyle()).accessibilityAddTraits(window.commandLibraryCollection == value ? .isSelected : [])
            .accessibilityIdentifier("quickCommands.library.collection." + value.id)
            .background {
                if value != .common {
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
