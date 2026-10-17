import AppKit
import SwiftUI

/// Starts an installed CLI in a new native terminal, keeping existing sessions untouched.
struct AgentLauncher: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    let onClose: () -> Void
    @State private var target: AgentLaunchTarget
    @State private var preset: AgentPreset = .codex
    @State private var executable = AgentPreset.codex.executable
    @State private var arguments = ""
    @State private var directory: String
    @State private var error: String?

    @MainActor
    init(model: AppModel, window: WindowState, onClose: @escaping () -> Void) {
        self.model = model
        self.window = window
        self.onClose = onClose
        let target = model.agentLaunchTarget(in: window)
        _target = State(initialValue: target)
        _directory = State(initialValue: target.directory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                Text("Launch Agent").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(FamilyButtonStyle())
                .help("Close")
                .keyboardShortcut(.cancelAction)
            }

            ScrollView { fields }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).buttonStyle(FamilyButtonStyle())
                Button("Launch Agent", action: launch)
                    .buttonStyle(FamilyButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(executable.isEmpty)
                    .accessibilityIdentifier("agent.launch.confirm")
            }
        }
        .padding(SheetLayout.dialogInset)
        .frame(width: SheetLayout.folderPicker, height: SheetLayout.agentLauncherHeight)
        .foregroundStyle(chrome.text)
        .background(chrome.background)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: isRemote ? "server.rack" : "desktopcomputer")
                Text(destinationLabel)
                Spacer()
            }
            .font(Theme.Font.rowMeta)
            .foregroundStyle(chrome.secondary)

            HStack {
                Text("Agent").font(Theme.Font.rowMeta)
                Spacer()
                FamilyPicker(value: $preset, options: AgentPreset.allCases.map { ($0, $0.name) })
            }
            .onChange(of: preset) { _, value in
                executable = value.executable
                arguments = ""
                error = nil
            }
            .accessibilityIdentifier("agent.launch.preset")

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Executable").font(Theme.Font.rowMeta)
                literalField($executable, placeholder: String(localized: "Executable name or absolute path"), identifier: "agent.launch.executable")
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Arguments (one per line)").font(Theme.Font.rowMeta)
                AgentLiteralEditor(text: $arguments, textColor: NSColor(chrome.text), backgroundColor: NSColor(chrome.elevated), identifier: "agent.launch.arguments")
                    .frame(minHeight: SheetLayout.searchFieldHeight * 2, maxHeight: SheetLayout.searchFieldHeight * 3)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(chrome.hairline))
                    .accessibilityIdentifier("agent.launch.arguments")
                Text("Each line is one literal argument. Shell syntax is not evaluated.")
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.secondary)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Working Directory").font(Theme.Font.rowMeta)
                literalField($directory, placeholder: isRemote ? String(localized: "Remote absolute path, or empty for home") : String(localized: "Local directory"), identifier: "agent.launch.directory")
            }
            Text("Opens a separate terminal. When the Agent exits, its shell remains open.")
                .font(Theme.Font.rowMeta)
                .foregroundStyle(chrome.secondary)
            if let error {
                Text(error).font(Theme.Font.rowMeta).foregroundStyle(chrome.danger)
                    .accessibilityIdentifier("agent.launch.error")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isRemote: Bool {
        if case .remote = target { return true }
        return false
    }

    private func literalField(_ text: Binding<String>, placeholder: String, identifier: String) -> some View {
        AgentLiteralField(text: text, placeholder: placeholder, textColor: NSColor(chrome.text), backgroundColor: NSColor(chrome.elevated), identifier: identifier)
            .frame(height: SheetLayout.searchFieldHeight)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(chrome.hairline))
    }

    private var destinationLabel: String {
        switch target {
        case .local: return String(localized: "This Mac")
        case .remote(let host, _): return "SSH · " + host
        }
    }

    private func launch() {
        do {
            let argv = arguments.components(separatedBy: .newlines).filter { !$0.isEmpty }
            let request = try AgentLaunchRequest(executable: executable, arguments: argv)
            let destination = try target.replacingDirectory(directory).validated()
            // Finish restoring the old responder before a new terminal requests focus.
            (NSApp.keyWindow as? FamilyModalWindow)?.cancelOperation(nil)
            onClose()
            try model.launchAgent(request, at: destination, in: window)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
