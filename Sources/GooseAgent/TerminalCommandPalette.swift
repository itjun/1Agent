import AppKit
import SwiftUI

/// A command keeps its pane identity from the moment the palette opens. Background model updates
/// must not silently redirect Files, Find or a split to another terminal.
struct TerminalCommandPalette: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    let onClose: () -> Void
    @Environment(\.windowChrome) private var chrome
    @AppStorage(AppShortcuts.revisionKey) private var shortcutsRevision = 0
    @State private var targetID: UUID?
    @State private var query = ""
    @State private var highlighted: TerminalPaletteCommand?
    @State private var keyboardTarget: TerminalPaletteCommand?

    init(model: AppModel, window: WindowState, onClose: @escaping () -> Void) {
        self.model = model
        self.window = window
        self.onClose = onClose
        _targetID = State(initialValue: window.selectedTabID)
    }

    private var target: TerminalTab? {
        guard let targetID, model.sidebarOrder(in: window).contains(targetID) else { return nil }
        return model.tabs.first { $0.id == targetID && $0.hasTerminal }
    }

    private var commands: [TerminalPaletteCommand] {
        TerminalPaletteCommand.allCases.filter { $0.matches(query) }
    }

    private var selectable: [TerminalPaletteCommand] {
        commands.filter(isAvailable)
    }

    var body: some View {
        let _ = shortcutsRevision
        VStack(alignment: .leading, spacing: 0) {
            header
            PaletteSearchField(query: $query, move: move, commit: executeHighlighted, cancel: onClose)
                .frame(height: SheetLayout.searchFieldHeight)
                .padding(Theme.Space.l)
            if commands.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("No matching commands").font(Theme.Font.sectionTitle).foregroundStyle(chrome.text)
                    Text("Try “split”, “files”, or “host”.").foregroundStyle(chrome.secondary)
                    Button("Clear search") { query = "" }.buttonStyle(.borderless)
                }
                .font(Theme.Font.body)
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, Theme.Space.s)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(commands) { command in
                                commandRow(command).id(command)
                            }
                        }
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.bottom, Theme.Space.l)
                    }
                    .onChange(of: keyboardTarget) { _, command in
                        if let command { proxy.scrollTo(command, anchor: .center) }
                    }
                }
            }
            Text("↑↓ Select · ↩ Run · Esc Close")
                .font(Theme.Font.rowMeta)
                .foregroundStyle(chrome.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
                .background(chrome.sidebarBackground)
                .overlay(alignment: .top) { Rectangle().fill(chrome.hairline).frame(height: 1) }
        }
        .background(chrome.background)
        .onAppear { reconcileHighlight() }
        .onChange(of: query) { _, _ in highlighted = selectable.first }
        .onChange(of: selectable) { _, _ in reconcileHighlight() }
        .accessibilityIdentifier("terminal.commandPalette")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Command Palette").font(.system(size: 20, weight: .semibold)).foregroundStyle(chrome.text)
                if let target {
                    Text(verbatim: model.sessionTitle(target))
                        .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else if targetID != nil {
                    Text("Current terminal is no longer available")
                        .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                }
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(FamilyButtonStyle()).foregroundStyle(chrome.secondary)
            .help("Close").accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.l)
    }

    private func commandRow(_ command: TerminalPaletteCommand) -> some View {
        let available = isAvailable(command)
        let selected = highlighted == command
        return Button { execute(command) } label: {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: command.symbol).frame(width: 18)
                    .foregroundStyle(selected ? chrome.accent : chrome.secondary)
                Text(verbatim: command.title).foregroundStyle(chrome.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let shortcut = command.shortcut {
                    Text(verbatim: AppShortcuts.display(for: shortcut))
                        .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                }
            }
            .font(Theme.Font.body)
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: SheetLayout.pickerRowHeight)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(selected ? chrome.accentFill : .clear))
        }
        .buttonStyle(.plain).focusable(false).disabled(!available)
        .opacity(available ? 1 : 0.45)
        .onHover { if $0 && available { highlighted = command } }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("terminal.command.\(command.rawValue)")
    }

    private func isAvailable(_ command: TerminalPaletteCommand) -> Bool {
        switch command {
        case .splitLeft, .splitRight, .splitAbove, .splitBelow, .files:
            return target != nil
        case .find:
            return target.map { !$0.exited } ?? false
        case .zoom:
            guard let targetID, target != nil else { return false }
            return (model.panelRow(for: targetID, in: window)?.leafIDs.count ?? 0) > 1
        case .switchTerminal:
            return !model.panelRows(in: window).isEmpty
        case .newLocal, .openHost, .sidebar:
            return true
        }
    }

    private func reconcileHighlight() {
        if !selectable.contains(where: { $0 == highlighted }) { highlighted = selectable.first }
    }

    private func move(_ delta: Int) {
        let rows = selectable
        guard !rows.isEmpty else { return }
        let index = highlighted.flatMap { rows.firstIndex(of: $0) } ?? (delta > 0 ? -1 : 0)
        let next = rows[((index + delta) % rows.count + rows.count) % rows.count]
        highlighted = next
        keyboardTarget = next
    }

    private func executeHighlighted() {
        guard let highlighted else { return }
        execute(highlighted)
    }

    private func execute(_ command: TerminalPaletteCommand) {
        guard isAvailable(command) else { return }
        let capturedID = targetID
        // Dismiss synchronously through the shared modal before restoring focus or presenting the
        // host picker. Merely changing the binding leaves the modal key until a later update.
        (NSApp.keyWindow as? FamilyModalWindow)?.cancelOperation(nil)
        onClose()
        DispatchQueue.main.async {
            let current = capturedID.flatMap { id in
                model.sidebarOrder(in: window).contains(id) ? model.tabs.first { $0.id == id && $0.hasTerminal } : nil
            }
            if command.requiresTerminal && current == nil { return }
            switch command {
            case .newLocal:
                model.openLocalTerminal(in: window)
            case .openHost:
                model.openHostPicker(in: window)
            case .sidebar:
                model.toggleSidebar(in: window)
            case .switchTerminal:
                _ = TerminalSwitcher.shared.open(model: model, window: window,
                    chord: AppShortcuts.chord(for: .terminalSwitcher), searching: true)
            case .splitLeft, .splitRight, .splitAbove, .splitBelow:
                guard let current, let edge = command.edge else { return }
                model.selectOnly(current.id, in: window)
                model.duplicate(current.id, edge: edge)
            case .files:
                guard let current else { return }
                model.selectOnly(current.id, in: window, focusTerminal: false)
                model.showFiles(for: current.id, in: window)
            case .find:
                guard let current, !current.exited else { return }
                model.selectOnly(current.id, in: window)
                // Registry focus is asynchronous; its queued focus must run before the find bar
                // resolves its terminal from the native first responder.
                DispatchQueue.main.async {
                    guard model.tabs.contains(where: { $0.id == current.id && $0.sessionID == current.sessionID }),
                          model.sidebarOrder(in: window).contains(current.id),
                          FocusedTerminal.current?.sessionID == current.sessionID else { return }
                    TerminalFind.shared.showFindBar()
                }
            case .zoom:
                guard let current else { return }
                model.selectOnly(current.id, in: window)
                model.toggleSplitZoom(in: window)
            }
        }
    }
}

enum TerminalPaletteCommand: String, CaseIterable, Identifiable {
    case newLocal, openHost, switchTerminal, sidebar
    case splitRight, splitBelow, splitLeft, splitAbove, files, find, zoom

    var id: Self { self }
    var title: String {
        switch self {
        case .newLocal: return AppShortcutID.newLocalTerminal.title
        case .openHost: return AppShortcutID.openHost.title
        case .switchTerminal: return AppShortcutID.terminalSwitcher.title
        case .sidebar: return AppShortcutID.toggleSidebar.title
        case .splitRight: return AppShortcutID.duplicateRight.title
        case .splitBelow: return AppShortcutID.duplicateDown.title
        case .splitLeft: return String(localized: "Split Left")
        case .splitAbove: return String(localized: "Split Up")
        case .files: return String(localized: "Browse Current Files")
        case .find: return AppShortcutID.find.title
        case .zoom: return AppShortcutID.toggleSplitZoom.title
        }
    }

    var shortcut: AppShortcutID? {
        switch self {
        case .newLocal: return .newLocalTerminal
        case .openHost: return .openHost
        case .switchTerminal: return .terminalSwitcher
        case .sidebar: return .toggleSidebar
        case .splitRight: return .duplicateRight
        case .splitBelow: return .duplicateDown
        case .find: return .find
        case .zoom: return .toggleSplitZoom
        case .files, .splitLeft, .splitAbove: return nil
        }
    }

    var symbol: String {
        switch self {
        case .newLocal: return "plus.rectangle"
        case .openHost: return "server.rack"
        case .switchTerminal: return "rectangle.3.group"
        case .sidebar: return "sidebar.left"
        case .splitRight: return "rectangle.righthalf.inset.filled"
        case .splitBelow: return "rectangle.bottomhalf.inset.filled"
        case .splitLeft: return "rectangle.lefthalf.inset.filled"
        case .splitAbove: return "rectangle.tophalf.inset.filled"
        case .files: return "folder"
        case .find: return "magnifyingglass"
        case .zoom: return "arrow.up.left.and.arrow.down.right"
        }
    }

    var requiresTerminal: Bool {
        switch self {
        case .newLocal, .openHost, .switchTerminal, .sidebar: return false
        default: return true
        }
    }

    var edge: SplitEdge? {
        switch self {
        case .splitRight: return .right
        case .splitBelow: return .bottom
        case .splitLeft: return .left
        case .splitAbove: return .top
        default: return nil
        }
    }

    /// Search aliases are deliberately bilingual regardless of the interface language.
    func matches(_ query: String) -> Bool {
        let aliases: String
        switch self {
        case .newLocal: aliases = "new local terminal shell 新建 本地 终端"
        case .openHost: aliases = "open host server ssh remote 连接 主机 服务器 远程"
        case .switchTerminal: aliases = "terminal switcher switch jump tabs panels 切换 终端 标签 面板"
        case .sidebar: aliases = "toggle sidebar collapse expand show hide 侧栏 侧边栏 收起 展开 隐藏 显示"
        case .splitRight: aliases = "split right pane 分屏 向右 右侧"
        case .splitBelow: aliases = "split down below pane 分屏 向下 下方"
        case .splitLeft: aliases = "split left pane 分屏 向左 左侧"
        case .splitAbove: aliases = "split up above pane 分屏 向上 上方"
        case .files: aliases = "browse current files folder directory 文件 文件夹 目录 浏览 当前"
        case .find: aliases = "find search text 查找 搜索 文本"
        case .zoom: aliases = "zoom split pane maximize restore 放大 缩放 最大化 还原 分屏"
        }
        let text = title + " " + aliases
        return query.split(whereSeparator: { $0.isWhitespace }).allSatisfy { text.localizedStandardContains(String($0)) }
    }
}

/// A native field editor preserves input-method composition, selection and clipboard behavior.
/// The enclosing FamilyModalWindow owns the keyboard, so typed commands cannot reach a shell.
private struct PaletteSearchField: NSViewRepresentable {
    @Binding var query: String
    let move: (Int) -> Void
    let commit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PaletteNativeSearchField {
        let field = PaletteNativeSearchField()
        field.placeholderString = String(localized: "Search commands…")
        field.setAccessibilityLabel(field.placeholderString)
        field.setAccessibilityIdentifier("terminal.commandPalette.search")
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: PaletteNativeSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != query { field.stringValue = query }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PaletteSearchField
        init(_ parent: PaletteSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { parent.query = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.insertNewline(_:)): parent.commit()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
}

private final class PaletteNativeSearchField: NSSearchField {
    private var requestedInitialFocus = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !requestedInitialFocus else { return }
        requestedInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isVisible else { return }
            window.makeFirstResponder(self)
        }
    }
}
