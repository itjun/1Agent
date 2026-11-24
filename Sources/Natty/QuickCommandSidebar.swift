import AppKit
import SwiftUI

struct TerminalCommandSidebarState: Codable, Equatable {
    var isExpanded = false
    var width = SheetLayout.terminalCommandSidebarWidth
    var selectedCommandID: UUID?
}

struct QuickCommandSidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    let tabID: UUID
    /// 分屏共用一列命令栏时，标题里写明命令会发给哪个终端。
    let targetTitle: String?
    @ObservedObject private var store = QuickCommandStore.shared
    @ObservedObject private var execution: QuickCommandSidebarExecution
    @Environment(\.windowChrome) private var chrome
    @State private var copiedCommandID: UUID?
    @FocusState private var isListFocused: Bool
    private static let listSpacing: CGFloat = 4
    private static let listInset: CGFloat = 8
    private static let detailsSpacing: CGFloat = 16
    init(model: AppModel, window: WindowState, tabID: UUID, targetTitle: String? = nil) {
        self.model = model
        self.window = window
        self.tabID = tabID
        self.targetTitle = targetTitle
        execution = model.commandExecution(for: tabID)
    }

    private var context: QuickCommandContext { model.commandContext(in: window, targetTabID: tabID) }
    private var commands: [QuickCommand] {
        store.commands.filter { $0.appearsInSidebar(for: context) }.sorted(by: QuickCommand.displayOrder)
    }
    private var selectedCommandID: UUID? {
        get { model.commandSidebars[tabID]?.selectedCommandID }
        nonmutating set { model.commandSidebars[tabID, default: TerminalCommandSidebarState()].selectedCommandID = newValue }
    }
    /// 命令较少时，列表按内容取高，让详情留在列表下方。
    private var listHeight: CGFloat {
        let count = CGFloat(commands.count)
        return count * SheetLayout.commandSidebarUsageRowHeight + (count - 1) * Self.listSpacing + Self.listInset * 2
    }

    var body: some View {
        GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Text("Commands")
                    .font(Theme.Font.paneTitle).fontWeight(.semibold)
                if let targetTitle {
                    Text(verbatim: targetTitle)
                        .font(Theme.Font.paneTitle).foregroundStyle(chrome.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("quickCommands.target." + tabID.uuidString)
                }
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: ShellLayout.compactHeaderHeight)
                .background(WindowDragArea(onClick: focusTerminal).accessibilityHidden(true))
            if let message = execution.error ?? store.loadError {
                Text(verbatim: message).font(Theme.Font.rowMeta).foregroundStyle(chrome.danger)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
                    .accessibilityIdentifier("quickCommands.error." + tabID.uuidString)
            }
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Self.listSpacing) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, item in
                        commandRow(item, number: index + 1).id(item.id)
                    }
                    if commands.isEmpty {
                        Text("No Commands").font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                }.padding(Self.listInset)
            }.frame(maxWidth: .infinity, maxHeight: commands.isEmpty ? .infinity : listHeight)
            .onChange(of: selectedCommandID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            }
            .focusable(interactions: .edit)
            .focusEffectDisabled()
            .focused($isListFocused)
            .onKeyPress(keys: [.upArrow, .downArrow, .escape], phases: [.down, .repeat], action: handleKey)
            if !commands.isEmpty {
                Group {
                    if let item = commands.first(where: { $0.id == selectedCommandID }) {
                        commandDetails(item)
                    } else {
                        Text("Select a command to view its details.")
                            .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(12)
                    }
                }
                .frame(height: min(SheetLayout.commandSidebarDetailsHeight, geometry.size.height * 0.4), alignment: .top)
                .padding(.top, Self.detailsSpacing)
            }
        }
        }
        .foregroundStyle(chrome.text)
        .contentShape(Rectangle())
        .onTapGesture(perform: focusTerminal)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quickCommands.pane." + tabID.uuidString)
        .onChange(of: commands.map(\.id), initial: true) { _, ids in
            if let selectedCommandID, ids.contains(selectedCommandID) { return }
            selectedCommandID = ids.first
        }
        .onChange(of: context.sessionID) { _, _ in execution.error = nil }
        .task(id: copiedCommandID) {
            guard copiedCommandID != nil else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            copiedCommandID = nil
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard model.sharedCommandSidebar(for: tabID) != nil, window.selectedTabID == tabID,
              window.section == .terminals, !window.presentation.fullFilesWorkspace,
              window.quickCommandConfirmation == nil,
              press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
        switch press.key {
        case .upArrow, .downArrow:
            guard !commands.isEmpty else { return .handled }
            let current = commands.firstIndex { $0.id == selectedCommandID }
            let next = current.map { min(max($0 + (press.key == .downArrow ? 1 : -1), 0), commands.count - 1) }
                ?? (press.key == .downArrow ? 0 : commands.count - 1)
            selectedCommandID = commands[next].id
            execution.error = nil
            return .handled
        case .escape:
            model.updateSharedCommandSidebar(for: tabID) { $0.isExpanded = false }
            if let sessionID = context.sessionID { SSHTerminalRegistry.focus(sessionID) }
            return .handled
        default:
            return .ignored
        }
    }

    private func focusTerminal() {
        isListFocused = false
        model.selectOnly(tabID, in: window)
    }

    private func copy(_ item: QuickCommand) {
        focusTerminal()
        CommandClipboard.copy(item.command)
        copiedCommandID = item.id
    }

    private func commandRow(_ item: QuickCommand, number: Int) -> some View {
        QuickCommandSidebarRow(item: item, number: number, isSelected: selectedCommandID == item.id,
                              select: {
            if let sessionID = context.sessionID { SSHTerminalRegistry.selectForCommandList(sessionID) }
            model.selectOnly(tabID, in: window, focusTerminal: false)
            selectedCommandID = item.id
            execution.error = nil
            isListFocused = true
        })
    }

    private func commandDetails(_ item: QuickCommand) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: item.alias).font(Theme.Font.row).fontWeight(.semibold).lineLimit(2)
            VStack(alignment: .trailing, spacing: 8) {
                // 仅滚动长命令的正文，代码块右下角的拷贝按钮始终可见。
                ViewThatFits(in: .vertical) {
                    commandText(item)
                    ScrollView { commandText(item) }
                }
                .frame(maxWidth: .infinity)
                .id(item.id)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("quickCommands.preview." + tabID.uuidString)
                Button { copy(item) } label: {
                    Label(copiedCommandID == item.id ? "Copied" : "Copy",
                          systemImage: copiedCommandID == item.id ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(FamilyButtonStyle())
                .font(Theme.Font.rowMeta).controlSize(.small)
                .accessibilityIdentifier("quickCommands.copy." + item.id.uuidString)
            }
            .padding(12)
            .background(chrome.text.opacity(chrome.isDark ? 0.08 : 0.05),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("quickCommands.codeBlock." + tabID.uuidString)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quickCommands.details." + tabID.uuidString)
    }

    private func commandText(_ item: QuickCommand) -> some View {
        Text(verbatim: item.command).font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("quickCommands.code." + item.id.uuidString)
    }

}

private struct QuickCommandSidebarRow: View {
    let item: QuickCommand
    let number: Int
    let isSelected: Bool
    let select: () -> Void
    @Environment(\.windowChrome) private var chrome
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Text(verbatim: String(number)).font(Theme.Font.row).monospacedDigit()
                    .foregroundStyle(chrome.secondary)
                    .frame(minWidth: Theme.DefaultLayout.iconWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 5) {
                    if item.needsRepair {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(chrome.warning)
                    }
                    Text(verbatim: item.alias).font(Theme.Font.row)
                        .fontWeight(isSelected ? .semibold : .regular).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: .infinity, alignment: .top)
                Text(verbatim: item.command.replacingOccurrences(of: "\n", with: " ↵ "))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(chrome.secondary)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 22, alignment: .leading)
            }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(height: SheetLayout.commandSidebarUsageRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(FamilyPlainButtonStyle())
        .accessibilityIdentifier("quickCommand." + item.id.uuidString)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .overlay {
            QuickCommandDragHandle(item: item, chrome: chrome, onClick: select,
                                   onDoubleClick: select, onDragStart: select)
                .accessibilityHidden(true)
        }
        .help(item.alias + "\n" + item.command + "\n" + String(localized: "Drag into a terminal to run"))
        .defaultRowSurface(selected: isSelected, legacyFill: isHovered ? chrome.elevated : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        .onHover { isHovered = $0 }
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
    var namePreview: AnyView? = nil
    var showsCommandPreview = false
    var inlineDetails: AnyView? = nil
    @Environment(\.windowChrome) private var chrome
    @State private var hovered = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 6) {
            Group {
                if allowsDragging {
                    commandButton.overlay {
                        QuickCommandDragHandle(item: item, chrome: chrome, onClick: action, onDoubleClick: onDoubleClick, onDragStart: onDragStart)
                            .accessibilityHidden(true)
                    }
                        .help(item.scope == .all ? "Drag to a host to copy, or to a terminal to paste text" : "Drag up or down to reorder; drag into a terminal to run")
                } else { commandButton }
            }
            .background { if let namePreview { namePreview } }
            if let menu {
                FamilyMenu(items: menu) { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                    .help("Command Actions")
            }
        }
            if let inlineDetails { inlineDetails }
        }
        .padding(.horizontal, isCompact ? 8 : 10)
        .padding(.vertical, isCompact ? 0 : 10)
        .frame(minHeight: isCompact ? SheetLayout.commandSidebarRowHeight : nil)
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
        .help(isCompact ? "" : item.alias + "\n" + item.command)
    }

    private var commandButton: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                if showsSelection {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square").foregroundStyle(chrome.accent)
                }
                if item.needsRepair {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(chrome.warning)
                        .frame(width: isCompact ? Theme.DefaultLayout.iconWidth : nil, height: isCompact ? 18 : nil)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: item.alias).font(Theme.Font.row).fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(chrome.text).lineLimit(isCompact ? 2 : 1)
                        .frame(minHeight: isCompact ? Theme.DefaultLayout.commandTextHeight : nil, alignment: .topLeading)
                    if !isCompact || showsCommandPreview {
                    Text(verbatim: item.command.replacingOccurrences(of: "\n", with: " ↵ "))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(chrome.secondary).lineLimit(1)
                    if !isCompact && !item.group.isEmpty { Text(verbatim: item.group).font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary) }
                    }
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }.buttonStyle(FamilyPlainButtonStyle()).accessibilityIdentifier("quickCommand." + item.id.uuidString)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .frame(minHeight: isCompact ? SheetLayout.commandSidebarRowHeight : nil)
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
    var onMoveSelection: ((Int) -> Void)?
    @Environment(\.windowChrome) private var chrome
    @Environment(\.isShellTransparent) private var isShellTransparent
    var body: some View {
        if symbol == "magnifyingglass" {
            NativeSearchField(text: $text, placeholder: placeholder, identifier: identifier, onMoveSelection: onMoveSelection,
                              textColor: NSColor(chrome.text), backgroundColor: NSColor(chrome.background))
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
