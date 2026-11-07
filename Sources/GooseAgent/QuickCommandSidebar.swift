import AppKit
import SwiftUI

struct QuickCommandSidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @ObservedObject private var store = QuickCommandStore.shared
    @Environment(\.windowChrome) private var chrome
    @Environment(\.isShellTransparent) private var isShellTransparent
    var showsHeader = true
    @State private var batchSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var pasteRequest: QuickCommandPasteRequest?
    @State private var status: String?
    @State private var historyPresented = false
    @State private var error: String?
    @State private var collapsedSections: Set<Int> = []
    @State private var selectedCommandID: UUID?
    @State private var previewCommandID: UUID?

    private var context: QuickCommandContext { model.quickCommandContext(in: window) }
    private var commands: [QuickCommand] {
        store.commands.filter { $0.scope != .all && $0.matches(context) }
            .sorted(by: QuickCommand.displayOrder)
    }
    private var selectedCommand: QuickCommand? { commands.first { $0.id == selectedCommandID } }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                Text("Commands").font(Theme.Font.row)
                    .frame(maxWidth: .infinity).frame(height: 42)
                Divider()
            }
            commandList
        }
        .foregroundStyle(chrome.text).background(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.toolSidebar")
        .onChange(of: commands.map(\.id)) { _, ids in
            if let selectedCommandID, !ids.contains(selectedCommandID) { self.selectedCommandID = nil }
            if let previewCommandID, !ids.contains(previewCommandID) { self.previewCommandID = nil }
        }
        .onChange(of: context.host) { _, _ in cancelSelection(); status = nil; previewCommandID = nil }
        .onChange(of: context.directory) { _, _ in cancelSelection(); previewCommandID = nil }
        .onChange(of: store.commands.map(\.id)) { _, ids in selectedIDs.formIntersection(ids) }
        .familySheet(isPresented: optionalBinding($pasteRequest), width: SheetLayout.quickCommand, height: SheetLayout.quickCommandHeight) {
            if let pasteRequest {
                QuickCommandPasteView(request: pasteRequest, onClose: { self.pasteRequest = nil }, onSaved: { additions in
                    self.pasteRequest = nil
                    cancelSelection()
                    if let first = additions.first {
                        collapsedSections.remove(first.section)
                        selectedCommandID = first.id
                        let target = [first.host ?? String(localized: "This Mac"), first.directory].compactMap { $0 }.joined(separator: ":")
                        status = String(format: String(localized: "Added %lld commands to %@"), Int64(additions.count), target)
                    }
                }).id(pasteRequest.id)
            }
        }
        .familySheet(isPresented: $historyPresented, width: SheetLayout.commandLibrary, height: SheetLayout.commandLibraryHeight) {
            QuickCommandHistoryView(context: context, hosts: model.hosts) { historyPresented = false }
        }
    }

    private var commandList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: context.host ?? String(localized: "This Mac"))
                        .font(Theme.Font.sectionTitle).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: context.directory.map { context.host == nil ? LocalTerminal.displayPath($0) : $0 } ?? String(localized: "Directory unknown"))
                        .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary).lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(context.directory ?? String(localized: "Directory unknown"))
                }
                Spacer(minLength: 4)
                Button { editInLibrary(draft()) } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
                    .buttonStyle(FamilyButtonStyle()).help("New Quick Command").accessibilityIdentifier("quickCommands.new")
                FamilyMenu(items: {
                    [FamilyMenuItem(title: String(localized: "Batch Copy Commands"), enabled: !commands.isEmpty && !batchSelecting,
                                    action: { batchSelecting = true; selectedIDs = []; status = nil }),
                     FamilyMenuItem(title: String(localized: "Paste Quick Commands…"), action: beginPaste),
                     FamilyMenuItem(title: String(localized: "Add from History"), action: { historyPresented = true }),
                     FamilyMenuItem(title: String(localized: "Edit Quick Command"), enabled: selectedCommand != nil,
                                    action: { if let selectedCommand { editInLibrary(selectedCommand) } }),
                    ]
                }) {
                    Image(systemName: "ellipsis").frame(width: 28, height: 28)
                }.help("Command Actions").accessibilityIdentifier("quickCommands.actions")
            }
            if batchSelecting { batchControls }
            if let status { Text(verbatim: status).font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary) }
            if let message = error ?? store.loadError { Text(verbatim: message).font(Theme.Font.rowMeta).foregroundStyle(chrome.danger) }
            commandRows
        }.padding(Theme.DefaultLayout.toolInset)
    }

    private var commandRows: some View {
        ScrollView(showsIndicators: chrome.isSystem) {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(0..<3, id: \.self) { section in
                    let rows = commands.filter { $0.section == section }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            if Set(commands.map(\.section)).count > 1 {
                            Button {
                                if collapsedSections.contains(section) { collapsedSections.remove(section) }
                                else { collapsedSections.insert(section) }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: collapsedSections.contains(section) ? "chevron.right" : "chevron.down").font(.system(size: 9))
                                    Text(section == 0 ? "Current Folder" : section == 1 ? "Host Commands" : "Common Commands")
                                    Spacer()
                                }.font(Theme.Font.sidebarSection).foregroundStyle(chrome.secondary).padding(.bottom, 4).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            }
                            if Set(commands.map(\.section)).count == 1 || !collapsedSections.contains(section) {
                                ForEach(rows) { item in
                                    CommandListRow(item: item, action: {
                                        selectedCommandID = item.id
                                        if batchSelecting {
                                            if !selectedIDs.insert(item.id).inserted { selectedIDs.remove(item.id) }
                                        } else {
                                            previewCommandID = item.id
                                        }
                                    }, allowsDragging: !batchSelecting,
                                                   isSelected: batchSelecting ? selectedIDs.contains(item.id) : selectedCommandID == item.id,
                                                   onDoubleClick: {
                                        guard !batchSelecting else { return }
                                        selectedCommandID = item.id
                                        previewCommandID = nil
                                        model.confirmQuickCommand(item, in: window)
                                    }, onDragStart: { selectedCommandID = item.id; previewCommandID = nil }, showsSelection: batchSelecting, isCompact: true, onReorder: { source, target, after in
                                        do { try store.move(source, relativeTo: target, after: after); error = nil }
                                        catch { self.error = error.localizedDescription }
                                    })
                                    .popover(isPresented: Binding(
                                        get: { previewCommandID == item.id },
                                        set: { if !$0 && previewCommandID == item.id { previewCommandID = nil } }
                                    ), arrowEdge: .leading) {
                                        commandPreview(item)
                                    }
                                    .familyContextMenu { commandActions(item) }
                                }
                            }
                            if commands.contains(where: { $0.section > section }) {
                                Divider().padding(.top, 10)
                            }
                        }
                    }
                }
                if commands.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No Commands").font(Theme.Font.sectionTitle)
                    }.padding(.vertical, 12)
                }
            }
        }
    }

    private var batchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: String(format: String(localized: "%lld Selected"), Int64(selectedIDs.count)))
                Spacer()
                Button("Cancel Selection", action: cancelSelection).buttonStyle(FamilyButtonStyle())
            }
            HStack {
                Button("Select All Results") { selectedIDs.formUnion(commands.map(\.id)) }
                    .buttonStyle(FamilyButtonStyle()).accessibilityIdentifier("quickCommands.selectAll")
                Spacer(minLength: 4)
                Button("Copy Selected") {
                    copyCommands(store.commands.filter { selectedIDs.contains($0.id) }.sorted(by: QuickCommand.displayOrder))
                }.buttonStyle(FamilyButtonStyle()).disabled(selectedIDs.isEmpty)
                    .accessibilityIdentifier("quickCommands.copySelected")
            }
        }.font(Theme.Font.rowMeta)
    }
    private func cancelSelection() { batchSelecting = false; selectedIDs = [] }
    private func copyCommands(_ items: [QuickCommand]) {
        do {
            try QuickCommandClipboard.copy(items)
            error = nil
            status = String(format: String(localized: "Copied %lld quick commands"), Int64(items.count))
            cancelSelection()
        } catch { self.error = error.localizedDescription }
    }
    private func beginPaste() {
        do {
            pasteRequest = try QuickCommandPasteRequest(transfer: QuickCommandClipboard.read(), context: context)
            error = nil; status = nil
        } catch { self.error = error.localizedDescription }
    }

    private func commandActions(_ item: QuickCommand) -> [FamilyMenuItem] {
        [FamilyMenuItem(title: String(localized: "Edit Quick Command"), action: { editInLibrary(item) }),
         FamilyMenuItem(title: String(localized: "Copy Preview Text"), action: { CommandClipboard.copy(item.command) }),
         FamilyMenuItem(title: String(localized: "Copy Quick Command"), action: { copyCommands([item]) }),
         FamilyMenuItem(title: String(localized: "Save Command Copy"), action: { var copy = item; copy.id = UUID(); editInLibrary(copy) })]
    }
    private func editInLibrary(_ item: QuickCommand) {
        previewCommandID = nil
        window.commandLibraryDraft = item
        model.showSection(.commands, in: window)
    }
    private func commandPreview(_ item: QuickCommand) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Command Preview").font(Theme.Font.sidebarSection).foregroundStyle(chrome.secondary)
                Spacer()
                Button { CommandClipboard.copy(item.command) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(FamilyButtonStyle()).help("Copy Preview Text")
                    .accessibilityLabel(Text("Copy Preview Text")).accessibilityIdentifier("quickCommands.preview.copy")
            }
            ScrollView {
                Text(verbatim: item.command).font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: previewTextHeight(item.command))
        }
        .padding(16)
        .frame(width: SheetLayout.commandSidebarPreviewWidth)
        .foregroundStyle(chrome.text).background(chrome.background)
        .accessibilityElement(children: .contain).accessibilityIdentifier("quickCommands.preview")
    }
    private func previewTextHeight(_ text: String) -> CGFloat {
        let bounds = (text as NSString).boundingRect(with: NSSize(width: SheetLayout.commandSidebarPreviewWidth - 32, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        return min(SheetLayout.commandSidebarPreviewHeight, max(44, bounds.height + 12))
    }
    private func draft() -> QuickCommand {
        QuickCommand(scope: context.directory == nil ? (context.host == nil ? .local : .host) : .directory,
                     host: context.host, directory: context.directory)
    }
}

func optionalBinding<T>(_ value: Binding<T?>) -> Binding<Bool> {
    Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
}

enum CommandClipboard {
    static func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}

struct CommandListRow: View {
    let item: QuickCommand
    let action: () -> Void
    var menu: (() -> [FamilyMenuItem])? = nil
    var allowsDragging = false
    var isSelected = false
    var onDoubleClick: () -> Void = {}
    var onDragStart: () -> Void = {}
    var showsSelection = false
    var isCompact = false
    var onReorder: (UUID, UUID, Bool) -> Void = { _, _, _ in }
    @Environment(\.windowChrome) private var chrome
    @State private var hovered = false
    var body: some View {
        HStack(spacing: 6) {
            Group {
                if allowsDragging {
                    commandButton.overlay {
                        QuickCommandDragHandle(item: item, chrome: chrome, onClick: action, onDoubleClick: onDoubleClick, onDragStart: onDragStart)
                            .accessibilityHidden(true)
                    }
                        .help(item.scope == .all ? "Drag to a host to copy, or to a terminal to paste text" : "Drag up or down to reorder; drag into a terminal to confirm execution")
                } else { commandButton }
            }
            if let menu {
                FamilyMenu(items: menu) { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                    .help("Command Actions")
            }
        }
        .padding(10)
        .defaultRowSurface(selected: isSelected, legacyFill: isSelected ? chrome.accentFill : hovered ? chrome.elevated : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .strokeBorder(isSelected && chrome.isDark && !chrome.isSystem ? chrome.accent.opacity(0.75) : .clear, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay {
            if allowsDragging {
                QuickCommandReorderTarget(item: item, chrome: chrome, onMove: onReorder)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onHover { hovered = $0 }
        .help(item.alias + "\n" + item.command)
    }

    private var commandButton: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                if showsSelection {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square").foregroundStyle(chrome.accent)
                }
                Image(systemName: item.needsRepair ? "exclamationmark.triangle" : "terminal")
                    .foregroundStyle(item.needsRepair ? chrome.warning : chrome.isSystem && !isSelected ? chrome.secondary : chrome.accent)
                    .frame(width: isCompact ? Theme.DefaultLayout.iconWidth : nil, height: isCompact ? 18 : nil)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: item.alias).font(Theme.Font.row).fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(chrome.text).lineLimit(isCompact ? 2 : 1)
                        .frame(minHeight: isCompact ? Theme.DefaultLayout.commandTextHeight : nil, alignment: .topLeading)
                    if !isCompact {
                    Text(verbatim: item.command.replacingOccurrences(of: "\n", with: " ↵ "))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(chrome.secondary).lineLimit(1)
                    if !item.group.isEmpty { Text(verbatim: item.group).font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary) }
                    }
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("quickCommand." + item.id.uuidString)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct CommandInfoRow: View {
    let title: LocalizedStringKey
    let value: String
    @Environment(\.windowChrome) private var chrome
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
            Text(verbatim: value).font(Theme.Font.body).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CommandTextField: View {
    @Binding var text: String
    let placeholder: String
    var identifier = "quickCommands.field"
    var symbol: String?
    @Environment(\.windowChrome) private var chrome
    @Environment(\.isShellTransparent) private var isShellTransparent
    var body: some View {
        if symbol == "magnifyingglass" {
            NativeSearchField(text: $text, placeholder: placeholder, identifier: identifier)
        } else {
            CommandLiteralField(text: $text, placeholder: placeholder, textColor: .labelColor,
                backgroundColor: .textBackgroundColor, identifier: identifier,
                font: .systemFont(ofSize: NSFont.systemFontSize), fillsProposedHeight: true)
        }
    }

}

struct CommandDialog<Content: View, Actions: View>: View {
    let title: LocalizedStringKey
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions
    @Environment(\.windowChrome) private var chrome
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.system(size: 20, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(FamilyButtonStyle()).help("Close").keyboardShortcut(.cancelAction)
            }
            Divider()
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack { Spacer(); actions() }
        }.padding(SheetLayout.dialogInset).foregroundStyle(chrome.text).background(chrome.background)
    }
}

struct CommandCodePreview: View {
    let text: String
    var wrapsLines = false
    @Environment(\.windowChrome) private var chrome
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Full Command").font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
            ScrollView(wrapsLines ? .vertical : [.horizontal, .vertical], showsIndicators: false) {
                Text(verbatim: text).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
            }.background(chrome.elevated).clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}
