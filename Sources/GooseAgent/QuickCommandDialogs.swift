import AppKit
import SwiftUI

struct QuickCommandEditor: View {
    @State private var name: String
    @State private var command: String
    @State private var directory: String?
    @State private var commandFocused = false
    @State private var error: String?
    @State private var isSaving = false
    @State private var isSaved = false
    @State private var saveTask: Task<Void, Never>?
    private let initialItem: QuickCommand
    private let collection: QuickCommandCollection
    private let isNew: Bool
    private let isWorkspaceCard: Bool
    let onDirtyChange: (Bool) -> Void
    let onSaved: (QuickCommand) -> Void
    let onClose: () -> Void
    @Environment(\.windowChrome) private var chrome

    init(item: QuickCommand, isWorkspaceCard: Bool = false,
         onDirtyChange: @escaping (Bool) -> Void = { _ in },
         onSaved: @escaping (QuickCommand) -> Void = { _ in },
         onClose: @escaping () -> Void) {
        _name = State(initialValue: item.alias)
        _command = State(initialValue: item.command)
        _directory = State(initialValue: item.directory)
        initialItem = item
        collection = QuickCommandCollection.owner(of: item)
        isNew = !QuickCommandStore.shared.commands.contains { $0.id == item.id }
        self.isWorkspaceCard = isWorkspaceCard
        self.onDirtyChange = onDirtyChange
        self.onSaved = onSaved
        self.onClose = onClose
    }

    private var isDirty: Bool {
        if isNew {
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || directory != initialItem.directory
        }
        return name != initialItem.alias || command != initialItem.command || directory != initialItem.directory
    }

    private var title: LocalizedStringKey { isNew ? "New Quick Command" : "Edit Quick Command" }

    var body: some View {
        Group {
            if isWorkspaceCard {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(Theme.Font.sectionTitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: ShellLayout.compactHeaderHeight)
                        .padding(.horizontal, Theme.Space.l)
                        .background(WindowDragArea())
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            editorFields
                            Divider()
                            HStack { Spacer(minLength: 0); editorActions }
                        }
                        .padding(Theme.Space.l)
                    }
                }
                .foregroundStyle(chrome.text)
            } else {
                CommandDialog(title: title, close: close) {
                    ScrollView { editorFields }
                } actions: { editorActions }
            }
        }
        .onAppear { onDirtyChange(isDirty) }
        .onDisappear { saveTask?.cancel() }
        .onChange(of: isDirty) { _, value in onDirtyChange(value) }
        .onChange(of: directory) { _, _ in error = nil }
    }

    private var editorFields: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            fieldLabel("Command Name") {
                CommandTextField(text: $name, placeholder: "", identifier: "quickCommand.alias")
                    .frame(height: Theme.Control.height)
            }
            if !isNew {
                fieldLabel("Original Command") {
                    commandField(.constant(initialItem.command), value: initialItem.command, editable: false)
                }
            }
            fieldLabel(isNew ? "Command" : "New Command Text") {
                commandField($command, value: command, editable: true)
            }
            if collection != .common { directoryField }
            if initialItem.needsRepair {
                Text("Review the host and folder bindings before saving this imported command.")
                    .font(Theme.Font.rowMeta).foregroundStyle(chrome.warning)
            }
            if let error { Text(verbatim: error).foregroundStyle(chrome.danger).font(Theme.Font.rowMeta) }
        }
        .disabled(isSaving)
    }

    private func fieldLabel<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(Theme.Font.row).foregroundStyle(chrome.secondary)
            content()
        }
    }

    private func commandField(_ text: Binding<String>, value: String, editable: Bool) -> some View {
        let visibleLines = min(value.split(separator: "\n", maxSplits: 7, omittingEmptySubsequences: false).count, 7)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control)
        let background = editable ? chrome.background : QuickCommandCodePalette(chrome: chrome).background
        return CommandLiteralEditor(text: text, textColor: NSColor(chrome.text), backgroundColor: .clear,
                                    identifier: editable ? "quickCommand.script" : "quickCommand.originalScript",
                                    isReadOnly: !editable, onFocusChange: editable ? { commandFocused = $0 } : nil)
            .frame(height: max(Theme.Control.height, CGFloat(visibleLines) * 18 + 12))
            .background(background, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(editable && commandFocused ? chrome.accent : chrome.hairline)
                    .allowsHitTesting(false)
            }
    }

    private var directoryField: some View {
        HStack(spacing: Theme.Space.s) {
            Text("Choose Directory").font(Theme.Font.row).foregroundStyle(chrome.secondary)
                .fixedSize()
            CommandTextField(
                text: Binding(get: { directory ?? "" }, set: { directory = $0.isEmpty ? nil : $0 }),
                placeholder: String(localized: "Any Directory"),
                identifier: "quickCommand.directory"
            )
            .frame(height: Theme.Control.height)
            if collection == .local {
                Button("Choose…", action: chooseDirectory).buttonStyle(FamilyButtonStyle(kind: .secondary))
            }
        }
    }

    @ViewBuilder private var editorActions: some View {
        if isSaving { ProgressView().controlSize(.small) }
        Button("Cancel", action: close).buttonStyle(FamilyButtonStyle(kind: .secondary))
            .accessibilityIdentifier("quickCommand.cancel")
        Button("Save", action: save).buttonStyle(FamilyButtonStyle(kind: .primary))
            .disabled(isSaving || isSaved || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("quickCommand.save")
    }

    private func chooseDirectory() {
        let owner = NSApp.keyWindow
        defer { owner?.makeKeyAndOrderFront(nil) }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let directory { panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }

    private func close() {
        saveTask?.cancel()
        onClose()
    }

    private func save() {
        guard !isSaving, !isSaved else { return }
        isSaving = true
        error = nil
        // 固定本次保存快照，异步目录检查期间不接受第二次提交。
        var next = initialItem
        next.alias = name
        next.command = command
        next.host = collection.host
        let selectedPath = directory
        switch collection {
        case .common: next.scope = .all
        case .local: next.scope = selectedPath == nil ? .local : .directory
        case .host: next.scope = selectedPath == nil ? .host : .directory
        }
        next.directory = next.scope == .directory ? selectedPath : nil
        saveTask = Task {
            defer { isSaving = false }
            do {
                next = try next.validated()
                if let path = next.directory {
                    next.directory = try await QuickCommandDirectory.resolve(path, host: next.host)
                    next.includesSubdirectories = initialItem.includesSubdirectories && next.directory == initialItem.directory
                }
                try Task.checkCancellation()
                next.needsRepair = false
                try QuickCommandStore.shared.save(next)
                isSaved = true
                onSaved(next)
                onClose()
            } catch is CancellationError {
                // 取消后不写入命令库。
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
                    Toggle("Run in a new terminal", isOn: $useNewTerminal).clickableCursor().disabled(!ready || submitted)
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
