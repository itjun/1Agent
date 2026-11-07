import AppKit
import SwiftUI

struct QuickCommandEditor: View {
    @State private var item: QuickCommand
    @State private var target: QuickCommandCollection
    @State private var directories: [QuickCommandCollection: String]
    @State private var isDirectoryScoped: Bool
    @State private var error: String?
    @State private var isSaving = false
    @State private var isSaved = false
    @State private var saveTask: Task<Void, Never>?
    private let isNew: Bool
    private let isWorkspaceCard: Bool
    let hosts: [SSHHost]
    let onSaved: (QuickCommand) -> Void
    let onClose: () -> Void
    @Environment(\.windowChrome) private var chrome
    @Environment(\.isShellTransparent) private var isShellTransparent

    init(item: QuickCommand, hosts: [SSHHost], isWorkspaceCard: Bool = false, onSaved: @escaping (QuickCommand) -> Void = { _ in }, onClose: @escaping () -> Void) {
        let target = QuickCommandCollection.owner(of: item)
        _item = State(initialValue: item)
        _target = State(initialValue: target)
        _directories = State(initialValue: [target: item.directory ?? ""])
        _isDirectoryScoped = State(initialValue: item.scope == .directory)
        isNew = !QuickCommandStore.shared.commands.contains { $0.id == item.id }
        self.hosts = hosts
        self.isWorkspaceCard = isWorkspaceCard
        self.onSaved = onSaved
        self.onClose = onClose
    }
    private var directory: Binding<String> {
        Binding(get: { directories[target] ?? "" }, set: { directories[target] = $0 })
    }
    var body: some View {
        Group {
            if isWorkspaceCard {
                VStack(spacing: 0) {
                    HStack {
                        Text(isNew ? "New Quick Command" : "Edit Quick Command").font(Theme.Font.paneTitle)
                        Spacer()
                        Button(action: close) { Image(systemName: "xmark") }
                            .buttonStyle(FamilyButtonStyle()).help("Cancel")
                            .accessibilityLabel(Text("Cancel"))
                    }.padding(12)
                    Divider()
                    GeometryReader { geometry in
                        ScrollView {
                            editorFields.frame(minHeight: max(0, geometry.size.height - 32)).padding(16)
                        }
                    }
                    Divider()
                    HStack(spacing: Theme.Space.s) { Spacer(); editorActions }.padding(12)
                }.foregroundStyle(chrome.text)
                    .background(Color.clear)
            } else {
                CommandDialog(title: isNew ? "New Quick Command" : "Edit Quick Command", close: close) {
                    editorFields
                } actions: { editorActions }
            }
        }
        .onDisappear { saveTask?.cancel() }
        .onChange(of: target) { _, _ in error = nil }
    }
    private var editorFields: some View {
        VStack(alignment: .leading, spacing: 18) {
            if target != .common {
            VStack(alignment: .leading, spacing: 12) {
                (isWorkspaceCard ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())) {
                    Text("Execution Host").font(Theme.Font.row)
                    if !isWorkspaceCard { Spacer() }
                    FamilyPicker(value: $target, options: hostOptions)
                        .frame(width: isWorkspaceCard ? nil : SheetLayout.commandEditorHostWidth)
                        .accessibilityLabel(Text("Execution Host"))
                        .accessibilityIdentifier("quickCommand.host")
                }
                if target != .common {
                    Toggle("Limit to Folder", isOn: $isDirectoryScoped)
                        .toggleStyle(FamilyToggleStyle(checkbox: true))
                        .accessibilityIdentifier("quickCommand.limitFolder")
                    if isDirectoryScoped {
                        HStack {
                            CommandTextField(text: directory, placeholder: String(localized: "Working Directory"), identifier: "quickCommand.directory", symbol: "folder")
                                .frame(height: Theme.Control.height)
                            if target == .local {
                                Button("Choose…", action: chooseDirectory).buttonStyle(FamilyButtonStyle())
                            }
                        }
                        Toggle("Include Subfolders", isOn: $item.includesSubdirectories)
                            .toggleStyle(FamilyToggleStyle(checkbox: true))
                            .accessibilityIdentifier("quickCommand.subfolders")
                    }
                }
            }
            Divider()
            }
            (isWorkspaceCard ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))) {
                field("Command Name", text: $item.alias, id: "quickCommand.alias")
                field("Group (optional)", text: $item.group, id: "quickCommand.group")
                    .frame(width: isWorkspaceCard ? nil : SheetLayout.commandEditorGroupWidth)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Command").font(Theme.Font.row).foregroundStyle(chrome.secondary)
                CommandLiteralEditor(text: $item.command, textColor: NSColor(chrome.text), backgroundColor: .clear, identifier: "quickCommand.script")
                    .frame(minHeight: isWorkspaceCard ? SheetLayout.commandCardTextHeight : nil, maxHeight: .infinity)
                    .background(chrome.elevated.opacity(isShellTransparent ? ShellLayout.controlOpacity : 1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(chrome.hairline))
            }
            if item.needsRepair { Text("Review the host and folder bindings before saving this imported command.").foregroundStyle(chrome.warning) }
            if let error { Text(verbatim: error).foregroundStyle(chrome.danger).font(Theme.Font.rowMeta) }
        }.disabled(isSaving)
    }
    @ViewBuilder private var editorActions: some View {
        if isSaving { ProgressView().controlSize(.small) }
        Button("Cancel", action: close).buttonStyle(FamilyButtonStyle())
            .accessibilityIdentifier("quickCommand.cancel")
        Button("Save", action: save).buttonStyle(FamilyButtonStyle(kind: .primary))
            .disabled(isSaving || isSaved || item.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("quickCommand.save")
    }
    private var hostOptions: [(QuickCommandCollection, String)] {
        let aliases = Set(hosts.map(\.alias) + [item.host, target.host].compactMap { $0 }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return [(.local, String(localized: "This Mac"))]
            + aliases.map { (.host($0), $0) }
            + [(.common, String(localized: "Command Library"))]
    }
    private func field(_ title: LocalizedStringKey, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.Font.row).foregroundStyle(chrome.secondary)
            CommandTextField(text: text, placeholder: "", identifier: id).frame(height: Theme.Control.height)
        }
    }
    private func chooseDirectory() {
        let owner = NSApp.keyWindow
        defer { owner?.makeKeyAndOrderFront(nil) }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { directories[target] = url.path }
    }
    private func close() {
        saveTask?.cancel()
        onClose()
    }
    private func save() {
        guard !isSaving, !isSaved else { return }
        isSaving = true; error = nil
        // 固定本次保存快照，异步目录检查期间不接受第二次提交。
        var next = item
        next.host = target.host
        next.scope = target == .common ? .all : isDirectoryScoped ? .directory : target == .local ? .local : .host
        next.directory = next.scope == .directory ? directories[target] : nil
        next.includesSubdirectories = next.scope == .directory && item.includesSubdirectories
        let path = next.directory ?? ""
        saveTask = Task {
            defer { isSaving = false }
            do {
                // 先验证名称、命令和主机，避免无效表单发起远程目录请求。
                var validation = next
                if validation.scope == .directory { validation.directory = "/" }
                _ = try validation.validated()
                if next.scope == .directory {
                    next.directory = try await QuickCommandDirectory.resolve(path, host: next.host)
                }
                try Task.checkCancellation()
                next.needsRepair = false
                try QuickCommandStore.shared.save(next)
                isSaved = true
                onSaved(next)
                onClose()
            } catch is CancellationError {
                // 取消后不写入指令库。
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct QuickCommandDetails: View {
    let item: QuickCommand
    let onClose: () -> Void
    var body: some View {
        CommandDialog(title: "Command Details", close: onClose) {
            VStack(alignment: .leading, spacing: 16) {
                CommandInfoRow(title: "Alias", value: item.alias)
                CommandInfoRow(title: "Scope", value: item.scope.title)
                if item.scope == .host || item.scope == .directory {
                    CommandInfoRow(title: "Target Host", value: item.host ?? String(localized: "This Mac"))
                }
                if let directory = item.directory { CommandInfoRow(title: "Working Directory", value: directory) }
                CommandCodePreview(text: item.command)
            }
        } actions: { Button("Close", action: onClose).buttonStyle(FamilyButtonStyle()) }
    }
}

struct QuickCommandConfirmation: View {
    let item: QuickCommand
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    let onClose: () -> Void
    @State private var captured: QuickCommandContext
    @State private var directory: String
    @State private var ready = false
    @State private var checking = true
    @State private var useNewTerminal = true
    @State private var submitted = false
    @State private var error: String?
    @Environment(\.windowChrome) private var chrome

    @MainActor init(confirmation: QuickCommandConfirmationTarget, model: AppModel, window: WindowState, onClose: @escaping () -> Void) {
        let item = confirmation.item
        self.item = item; self.model = model; self.window = window; self.onClose = onClose
        let snapshot = confirmation.context
        _captured = State(initialValue: snapshot)
        _directory = State(initialValue: item.executionDirectory(in: snapshot) ?? "")
    }
    private var changed: Bool { model.quickCommandContext(in: window) != captured }
    private var request: QuickCommandRunRequest? { try? QuickCommandRunRequest(item: item, context: captured, directory: directory) }
    var body: some View {
        CommandDialog(title: "Confirm Execution", close: onClose) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    CommandInfoRow(title: "Alias", value: item.alias)
                    CommandInfoRow(title: "Target Host", value: captured.host ?? String(localized: "This Mac"))
                    if item.executionDirectory(in: captured) == nil {
                        Text("Working Directory").font(Theme.Font.rowMeta)
                        CommandTextField(text: $directory, placeholder: String(localized: "Enter an absolute working directory"), identifier: "quickCommand.run.directory")
                            .frame(height: 32)
                    } else { CommandInfoRow(title: "Working Directory", value: directory) }
                    if checking { ProgressView().controlSize(.small) }
                    Toggle("Run in a new terminal", isOn: $useNewTerminal).disabled(!ready || submitted)
                    Text(useNewTerminal
                         ? "A new shell uses its login environment. Temporary variables and virtual environments from the current terminal are not inherited."
                         : "The current terminal is ready. Its input buffer is checked again when you execute.")
                        .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                    if !ready && !checking {
                        Text("The current terminal is busy or its input state is unknown. Use a new terminal.")
                            .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                    }
                    CommandCodePreview(text: item.command, wrapsLines: true)
                        .frame(height: SheetLayout.quickCommandPreviewHeight)
                    if changed { Text(QuickCommandError.changedTarget.localizedDescription).foregroundStyle(chrome.danger) }
                    if let current = captured.directory, QuickCommand.path(current) != QuickCommand.path(directory) {
                        Text(QuickCommandError.directoryMismatch(current: current, required: QuickCommand.path(directory)).localizedDescription)
                            .foregroundStyle(chrome.danger)
                    }
                    if let error { Text(verbatim: error).foregroundStyle(chrome.danger).font(Theme.Font.rowMeta) }
                }
            }
        } actions: {
            Button("Cancel", action: onClose).buttonStyle(FamilyButtonStyle())
            Button(useNewTerminal ? "Run in New Terminal" : "Run", action: execute)
                .buttonStyle(FamilyButtonStyle(kind: .primary))
                .disabled(submitted || checking || changed || request == nil || item.needsRepair)
                .accessibilityIdentifier("quickCommand.run.confirm")
        }
        .task {
            if captured.isLive, let id = captured.sessionID {
                ready = await SSHTerminalRegistry.quickCommandReady(id)
            }
            useNewTerminal = !ready
            checking = false
        }
    }

    private func execute() {
        guard !submitted, !changed, let request else { return }
        submitted = true
        Task {
            do {
                guard model.quickCommandContext(in: window) == captured else { throw QuickCommandError.changedTarget }
                if captured.host == nil, ExternalOpen.validatedDirectory(directory) == nil { throw QuickCommandError.invalidDirectory }
                try await model.executeQuickCommand(request, in: window, newTerminal: useNewTerminal)
                (NSApp.keyWindow as? FamilyModalWindow)?.cancelOperation(nil)
                onClose()
                if !useNewTerminal, let id = captured.sessionID { SSHTerminalRegistry.focus(id) }
            } catch { self.error = error.localizedDescription }
        }
    }
}
