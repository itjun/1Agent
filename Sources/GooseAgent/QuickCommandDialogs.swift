import AppKit
import SwiftUI

struct QuickCommandEditor: View {
    @State private var item: QuickCommand
    @State private var directory: String
    @State private var host: String
    @State private var error: String?
    @State private var saving = false
    let hosts: [SSHHost]
    let onClose: () -> Void
    @Environment(\.windowChrome) private var chrome

    init(item: QuickCommand, hosts: [SSHHost], onClose: @escaping () -> Void) {
        _item = State(initialValue: item)
        _directory = State(initialValue: item.directory ?? "")
        _host = State(initialValue: item.host ?? "")
        self.hosts = hosts; self.onClose = onClose
    }
    var body: some View {
        CommandDialog(title: "Edit Quick Command", close: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Alias", text: $item.alias, id: "quickCommand.alias")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Command").font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                        AgentLiteralEditor(text: $item.command, textColor: NSColor(chrome.text), backgroundColor: NSColor(chrome.elevated), identifier: "quickCommand.script")
                            .frame(height: 130).overlay(RoundedRectangle(cornerRadius: 4).stroke(chrome.hairline))
                    }
                    field("Group (optional)", text: $item.group, id: "quickCommand.group")
                    HStack { Text("Scope"); Spacer()
                        FamilyPicker(value: $item.scope, options: QuickCommandScope.allCases.map { ($0, $0.title) })
                    }
                    if item.scope == .host || item.scope == .directory {
                        HStack { Text("Target Host"); Spacer()
                            FamilyPicker(value: $host, options: hostOptions)
                        }
                    }
                    if item.scope == .directory {
                        HStack(alignment: .bottom) {
                            field("Working Directory", text: $directory, id: "quickCommand.directory")
                            if host.isEmpty {
                                Button("Choose…", action: chooseDirectory).buttonStyle(FamilyButtonStyle())
                            }
                        }
                        Toggle("Include Subfolders", isOn: $item.includesSubdirectories)
                        Text("Folder commands always run in their bound folder.").font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                    }
                    if item.needsRepair { Text("Review the host and folder bindings before saving this imported command.").foregroundStyle(chrome.warning) }
                    if let error { Text(verbatim: error).foregroundStyle(chrome.danger).font(Theme.Font.rowMeta) }
                }
            }
        } actions: {
            Button("Cancel", action: onClose).buttonStyle(FamilyButtonStyle())
            Button("Save", action: save).buttonStyle(FamilyButtonStyle(kind: .primary)).disabled(saving)
                .accessibilityIdentifier("quickCommand.save")
        }
    }
    private var hostOptions: [(String, String)] {
        [("", item.scope == .host ? String(localized: "Choose SSH host") : String(localized: "This Mac"))]
            + hosts.map { ($0.alias, $0.alias) }
            + (!host.isEmpty && !hosts.contains(where: { $0.alias == host }) ? [(host, host)] : [])
    }
    private func field(_ title: LocalizedStringKey, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
            CommandTextField(text: text, placeholder: "", identifier: id).frame(height: 32)
        }
    }
    private func chooseDirectory() {
        let owner = NSApp.keyWindow
        defer { owner?.makeKeyAndOrderFront(nil) }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }
    private func save() {
        saving = true; error = nil
        Task {
            do {
                var next = item
                next.host = host.isEmpty ? nil : host
                if next.scope == .directory {
                    var path = directory
                    if path == "~" || path.hasPrefix("~/") {
                        let home = try await fileSystem(for: next.host).home()
                        path = home + String(path.dropFirst())
                    }
                    guard QuickCommand.validPath(path) else { throw QuickCommandError.invalidDirectory }
                    next.directory = QuickCommand.path(path)
                    if next.host == nil {
                        guard ExternalOpen.validatedDirectory(path) != nil else { throw QuickCommandError.invalidDirectory }
                    } else { _ = try await fileSystem(for: next.host).list(path) }
                }
                next.needsRepair = false
                try QuickCommandStore.shared.save(next)
                onClose()
            } catch { self.error = error.localizedDescription }
            saving = false
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
            ScrollView {
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
                    CommandCodePreview(text: item.command).frame(height: 150)
                    if let request {
                        DisclosureGroup("Actual Execution Text") {
                            CommandCodePreview(text: useNewTerminal ? request.startupCommand(shell: captured.host == nil ? LocalTerminal.shellExecutable : nil) : request.currentShellCommand)
                                .frame(height: 180)
                        }.font(Theme.Font.rowMeta)
                    }
                    if changed { Text(QuickCommandError.changedTarget.localizedDescription).foregroundStyle(chrome.danger) }
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
            if captured.host == nil, captured.isLive, let id = captured.sessionID {
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
