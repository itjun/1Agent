import AppKit
import SwiftUI

struct QuickCommandSidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @ObservedObject private var store = QuickCommandStore.shared
    @Environment(\.windowChrome) private var chrome
    @Environment(\.isShellTransparent) private var isShellTransparent
    @State private var search = ""
    @State private var batchSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var pasteRequest: QuickCommandPasteRequest?
    @State private var status: String?
    @State private var editing: QuickCommand?
    @State private var libraryPresented = false
    @State private var historyPresented = false
    @State private var error: String?
    @State private var collapsedSections: Set<Int> = []
    @State private var selectedCommandID: UUID?
    @State private var previewDividerHovered = false
    @State private var previewDragStart: CGFloat?
    @State private var previewDragHeight: Double?

    private var context: QuickCommandContext { model.quickCommandContext(in: window) }
    private var commands: [QuickCommand] {
        store.commands.filter { $0.matches(context) && (search.isEmpty ||
            ($0.alias + " " + $0.command + " " + $0.group).localizedCaseInsensitiveContains(search)) }
            .sorted(by: QuickCommand.displayOrder)
    }
    private var selectedCommand: QuickCommand? { commands.first { $0.id == selectedCommandID } }

    var body: some View {
        VStack(spacing: 0) {
            Text("Commands").font(Theme.Font.row)
                .frame(maxWidth: .infinity).frame(height: 42)
            Divider()
            commandList
        }
        .foregroundStyle(chrome.text).background(chrome.background.opacity(isShellTransparent ? 0.12 : 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.toolSidebar")
        .onChange(of: commands.map(\.id)) { _, ids in
            if let selectedCommandID, !ids.contains(selectedCommandID) { self.selectedCommandID = nil }
        }
        .onChange(of: context.host) { _, _ in cancelSelection(); status = nil }
        .onChange(of: context.directory) { _, _ in cancelSelection() }
        .onChange(of: store.commands.map(\.id)) { _, ids in selectedIDs.formIntersection(ids) }
        .familySheet(isPresented: optionalBinding($pasteRequest), width: SheetLayout.quickCommand, height: SheetLayout.quickCommandHeight) {
            if let pasteRequest {
                QuickCommandPasteView(request: pasteRequest, onClose: { self.pasteRequest = nil }, onSaved: { additions in
                    self.pasteRequest = nil
                    search = ""; cancelSelection()
                    if let first = additions.first {
                        collapsedSections.remove(first.section)
                        selectedCommandID = first.id
                        let target = [first.host ?? String(localized: "This Mac"), first.directory].compactMap { $0 }.joined(separator: ":")
                        status = String(format: String(localized: "Added %lld commands to %@"), Int64(additions.count), target)
                    }
                }).id(pasteRequest.id)
            }
        }
        .familySheet(isPresented: optionalBinding($editing), width: SheetLayout.quickCommand, height: SheetLayout.quickCommandHeight) {
            if let editing { QuickCommandEditor(item: editing, hosts: model.hosts) { self.editing = nil }.id(editing.id) }
        }
        .familySheet(isPresented: $libraryPresented, width: SheetLayout.commandLibrary, height: SheetLayout.commandLibraryHeight) {
            QuickCommandLibraryView(model: model, window: window) { libraryPresented = false }
        }
        .familySheet(isPresented: $historyPresented, width: SheetLayout.commandLibrary, height: SheetLayout.commandLibraryHeight) {
            QuickCommandHistoryView(context: context, hosts: model.hosts) { historyPresented = false }
        }
    }

    private var commandList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: [context.host ?? String(localized: "This Mac"), context.directory.map { ($0 as NSString).lastPathComponent }]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Theme.Font.sectionTitle).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: context.directory.map { context.host == nil ? LocalTerminal.displayPath($0) : $0 } ?? String(localized: "Directory unknown"))
                        .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary).lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 4)
                Button { editing = draft() } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
                    .buttonStyle(FamilyButtonStyle()).help("New Quick Command").accessibilityIdentifier("quickCommands.new")
                FamilyMenu(items: {
                    [FamilyMenuItem(title: String(localized: "Batch Select"), enabled: !commands.isEmpty && !batchSelecting,
                                    action: { batchSelecting = true; selectedIDs = []; status = nil }),
                     FamilyMenuItem(title: String(localized: "Paste Quick Commands…"), action: beginPaste),
                    ]
                }) {
                    Image(systemName: "ellipsis").frame(width: 28, height: 28)
                }.help("Command Actions").accessibilityIdentifier("quickCommands.actions")
            }
            CommandTextField(text: $search, placeholder: String(localized: "Search aliases or commands"), identifier: "quickCommands.search", symbol: "magnifyingglass")
                .frame(height: 32)
            if batchSelecting { batchControls }
            if let status { Text(verbatim: status).font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary) }
            if let message = error ?? store.loadError { Text(verbatim: message).font(Theme.Font.rowMeta).foregroundStyle(chrome.danger) }
            GeometryReader { geometry in
                let expanded = window.presentation.commandPreviewExpanded
                let height = CommandPreviewLayout.visibleHeight(available: geometry.size.height, expanded: expanded,
                    preferred: previewDragHeight ?? window.presentation.commandPreviewHeight)
                VStack(spacing: 0) {
                    commandRows
                    previewDivider(height: height, available: geometry.size.height, expanded: expanded)
                    QuickCommandPreview(item: selectedCommand, context: context, isExpanded: expanded) {
                        model.updatePresentation(in: window) { $0.commandPreviewExpanded.toggle() }
                    }
                    .padding(.top, 8).frame(height: height).clipped()
                }
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text(batchSelecting ? "Select commands to copy. Double-click and drag execution are paused." : "Drag up or down to reorder. Double-click or drag into a terminal to confirm execution.")
            }.font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
        }.padding(16)
    }

    private var commandRows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(0..<3, id: \.self) { section in
                    let rows = commands.filter { $0.section == section }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
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
                            if !collapsedSections.contains(section) {
                                ForEach(rows) { item in
                                    CommandListRow(item: item, action: {
                                        selectedCommandID = item.id
                                        if batchSelecting {
                                            if !selectedIDs.insert(item.id).inserted { selectedIDs.remove(item.id) }
                                        }
                                    }, allowsDragging: !batchSelecting,
                                                   isSelected: batchSelecting ? selectedIDs.contains(item.id) : selectedCommandID == item.id,
                                                   onDoubleClick: {
                                        guard !batchSelecting else { return }
                                        selectedCommandID = item.id
                                        model.confirmQuickCommand(item, in: window)
                                    }, showsSelection: batchSelecting, onReorder: { source, target, after in
                                        do { try store.move(source, relativeTo: target, after: after); error = nil }
                                        catch { self.error = error.localizedDescription }
                                    })
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
                        Text(search.isEmpty ? "No commands for this context" : "No matching commands").font(Theme.Font.sectionTitle)
                        Text("Add a command for this folder or choose one from shell history.")
                            .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                    }.padding(.vertical, 12)
                }
                Divider()
                VStack(spacing: 2) {
                    footer("Add from History", symbol: "clock") { historyPresented = true }
                        .accessibilityIdentifier("quickCommands.history")
                    footer("Manage Command Library", symbol: "slider.horizontal.3") { libraryPresented = true }
                        .accessibilityIdentifier("quickCommands.library")
                }
            }
        }
    }

    private var batchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: String(format: String(localized: "%lld Selected"), Int64(selectedIDs.count)))
                Spacer()
                Button("Cancel", action: cancelSelection).buttonStyle(FamilyButtonStyle())
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

    private func previewDivider(height: CGFloat, available: CGFloat, expanded: Bool) -> some View {
        ZStack {
            Rectangle().fill(previewDividerHovered && expanded ? chrome.accent : chrome.hairline).frame(height: 1)
            if expanded {
                PaneDividerHandle(vertical: false, onHover: { previewDividerHovered = $0 }, onDragChanged: { delta in
                    if previewDragStart == nil { previewDragStart = height }
                    previewDragHeight = Double(CommandPreviewLayout.visibleHeight(available: available, expanded: true,
                        preferred: Double((previewDragStart ?? height) - delta)))
                }, onDragEnded: {
                    if let value = previewDragHeight, let start = previewDragStart, abs(value - Double(start)) > 0.5 {
                        model.updatePresentation(in: window) { $0.commandPreviewHeight = CommandPreviewLayout.storedHeight(value) }
                    }
                    previewDragStart = nil
                    previewDragHeight = nil
                }, onDoubleClick: {})
                .accessibilityLabel(Text("Resize Command Preview"))
                .accessibilityIdentifier("quickCommands.preview.resize")
                .help("Drag up or down to resize the preview")
                .accessibilityAdjustableAction { direction in
                    let delta: Double = direction == .increment ? 32 : -32
                    let value = CommandPreviewLayout.visibleHeight(available: available, expanded: true,
                                                                  preferred: Double(height) + delta)
                    model.updatePresentation(in: window) { $0.commandPreviewHeight = CommandPreviewLayout.storedHeight(Double(value)) }
                }
            }
        }.frame(height: CommandPreviewLayout.dividerHeight)
    }
    private func footer(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Image(systemName: symbol).frame(width: 20); Text(title); Spacer(); Image(systemName: "chevron.right").font(.system(size: 10)) }
                .padding(10).contentShape(Rectangle())
        }.buttonStyle(FamilyButtonStyle()).foregroundStyle(chrome.secondary)
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
    var showsSelection = false
    var onReorder: (UUID, UUID, Bool) -> Void = { _, _, _ in }
    @Environment(\.windowChrome) private var chrome
    @State private var hovered = false
    var body: some View {
        HStack(spacing: 6) {
            Group {
                if allowsDragging {
                    commandButton.overlay {
                        QuickCommandDragHandle(item: item, chrome: chrome, onClick: action, onDoubleClick: onDoubleClick)
                            .accessibilityHidden(true)
                    }
                        .help("Drag up or down to reorder; drag into a terminal to confirm execution")
                } else { commandButton }
            }
            if let menu {
                FamilyMenu(items: menu) { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                    .help("Command Actions")
            }
        }
        .padding(10).background(isSelected ? chrome.accentFill : hovered ? chrome.elevated : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay {
            if allowsDragging {
                QuickCommandReorderTarget(item: item, chrome: chrome, onMove: onReorder)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onHover { hovered = $0 }
    }

    private var commandButton: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if showsSelection {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square").foregroundStyle(chrome.accent)
                }
                Image(systemName: item.needsRepair ? "exclamationmark.triangle" : "terminal").foregroundStyle(item.needsRepair ? chrome.warning : chrome.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: item.alias).font(Theme.Font.row).lineLimit(1)
                    Text(verbatim: item.command.replacingOccurrences(of: "\n", with: " ↵ "))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(chrome.secondary).lineLimit(1)
                    if !item.group.isEmpty { Text(verbatim: item.group).font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary) }
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("quickCommand." + item.id.uuidString)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct QuickCommandPreview: View {
    let item: QuickCommand?
    let context: QuickCommandContext
    let isExpanded: Bool
    let onToggle: () -> Void
    @Environment(\.windowChrome) private var chrome

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                    Text("Preview").font(Theme.Font.sidebarSection)
                    Spacer(minLength: 0)
                }.foregroundStyle(chrome.secondary).frame(height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(Text(isExpanded ? "Collapse Command Preview" : "Expand Command Preview"))
                .accessibilityIdentifier("quickCommands.preview.toggle")
                .help(isExpanded ? "Collapse Command Preview" : "Expand Command Preview")
            if isExpanded, let item {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(verbatim: item.alias).font(Theme.Font.sectionTitle).textSelection(.enabled)
                            detail("Scope", value: item.scope.title)
                            detail("Target Host", value: context.host ?? String(localized: "This Mac"))
                            detail("Working Directory", value: item.executionDirectory(in: context) ?? String(localized: "Directory unknown"))
                            if !item.group.isEmpty { detail("Command Group", value: item.group) }
                            if item.includesSubdirectories {
                                Text("Include Subfolders").font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                            }
                            CommandCodePreview(text: item.command, wrapsLines: true)
                                .frame(height: max(130, geometry.size.height - 150))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.id(item.id)
                }
            } else if isExpanded {
                Text("Select a command to preview its details.")
                    .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                Spacer(minLength: 0)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain).accessibilityIdentifier("quickCommands.preview")
    }

    private func detail(_ title: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title).foregroundStyle(chrome.secondary).frame(width: 72, alignment: .leading)
            Text(verbatim: value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(Theme.Font.rowMeta)
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
    var body: some View {
        HStack(spacing: 0) {
            if let symbol { Image(systemName: symbol).foregroundStyle(chrome.secondary).padding(.leading, 10) }
            CommandLiteralField(text: $text, placeholder: placeholder, textColor: NSColor(chrome.text),
                          backgroundColor: NSColor(chrome.elevated), identifier: identifier,
                          font: .systemFont(ofSize: 13), fillsProposedHeight: true)
        }
            .background(chrome.elevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(chrome.hairline))
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
            ScrollView(wrapsLines ? .vertical : [.horizontal, .vertical]) {
                Text(verbatim: text).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
            }.background(chrome.elevated).clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}
