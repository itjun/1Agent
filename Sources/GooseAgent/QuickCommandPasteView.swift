import SwiftUI

/// Shared with the editor: remote homes and folders are resolved on the target host.
enum QuickCommandDirectory {
    static func resolve(_ value: String, host: String?) async throws -> String {
        var path = value
        if path == "~" || path.hasPrefix("~/") {
            path = try await fileSystem(for: host).home() + String(path.dropFirst())
        }
        guard QuickCommand.validPath(path) else { throw QuickCommandError.invalidDirectory }
        path = QuickCommand.path(path)
        if host == nil {
            guard ExternalOpen.validatedDirectory(path) != nil else { throw QuickCommandError.invalidDirectory }
        } else { _ = try await fileSystem(for: host).list(path) }
        return path
    }
}

struct QuickCommandPasteView: View {
    let request: QuickCommandPasteRequest
    let onClose: () -> Void
    let onSaved: ([QuickCommand]) -> Void
    @ObservedObject private var store = QuickCommandStore.shared
    @Environment(\.windowChrome) private var chrome
    @State private var folderScope = false
    @State private var directory: String
    @State private var includesSubdirectories = false
    @State private var resolvedDirectory: String?
    @State private var validatedInput: String?
    @State private var directoryError: String?
    @State private var error: String?
    @State private var saving = false

    init(request: QuickCommandPasteRequest, onClose: @escaping () -> Void, onSaved: @escaping ([QuickCommand]) -> Void) {
        self.request = request; self.onClose = onClose; self.onSaved = onSaved
        _directory = State(initialValue: request.context.directory ?? "")
    }
    private var directoryReady: Bool { !folderScope || (validatedInput == directory && resolvedDirectory != nil) }
    private var copies: [QuickCommand]? {
        guard directoryReady else { return nil }
        return try? request.copies(existing: store.commands, directory: folderScope ? resolvedDirectory : nil,
                                   includesSubdirectories: includesSubdirectories)
    }
    private var validationKey: String? { folderScope ? directory : nil }

    var body: some View {
        CommandDialog(title: "Paste Quick Commands", close: onClose) {
            VStack(alignment: .leading, spacing: 14) {
                CommandInfoRow(title: "Target Host", value: request.context.host ?? String(localized: "This Mac"))
                HStack {
                    Text("Scope"); Spacer()
                    FamilyPicker(value: $folderScope, options: [
                        (false, String(localized: "Target Host Commands")),
                        (true, String(localized: "Specific Folder"))
                    ])
                }
                if folderScope {
                    CommandTextField(text: $directory, placeholder: String(localized: "Enter a target folder, such as ~/sample-project"),
                                     identifier: "quickCommands.paste.directory").frame(height: 32)
                    Toggle("Include Subfolders", isOn: $includesSubdirectories)
                    if let resolvedDirectory, validatedInput == directory {
                        Text(verbatim: resolvedDirectory).font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary).textSelection(.enabled)
                    } else if directoryError == nil && !directory.isEmpty { ProgressView().controlSize(.small) }
                    if let directoryError { Text(verbatim: directoryError).font(Theme.Font.rowMeta).foregroundStyle(chrome.danger) }
                    Text("Folder commands appear only when the terminal reports a matching folder. You can always find them in the command library.")
                        .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                }
                Text("Commands to Add").font(Theme.Font.sectionTitle)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(copies ?? request.drafts) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(verbatim: item.alias).font(Theme.Font.row).textSelection(.enabled)
                                Text(verbatim: item.command).font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(chrome.secondary).textSelection(.enabled)
                                if !item.group.isEmpty { Text(verbatim: item.group).font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }
                }
                Text("Independent copies are added without running any commands.").font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                if let message = error ?? store.loadError { Text(verbatim: message).font(Theme.Font.rowMeta).foregroundStyle(chrome.danger) }
            }
        } actions: {
            Button("Cancel", action: onClose).buttonStyle(FamilyButtonStyle())
            Button(action: save) {
                Text(verbatim: String(format: String(localized: "Add %lld Commands"), Int64(request.drafts.count)))
            }.buttonStyle(FamilyButtonStyle(kind: .primary))
                .disabled(saving || copies == nil || store.loadError != nil)
                .accessibilityIdentifier("quickCommands.paste.save")
        }
        .task(id: validationKey) {
            resolvedDirectory = nil; validatedInput = nil; directoryError = nil; error = nil
            guard let input = validationKey else { return }
            guard !input.isEmpty else { directoryError = QuickCommandError.invalidDirectory.localizedDescription; return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                let resolved = try await QuickCommandDirectory.resolve(input, host: request.context.host)
                try Task.checkCancellation()
                resolvedDirectory = resolved; validatedInput = input
            } catch {
                guard !Task.isCancelled else { return }
                directoryError = error.localizedDescription
            }
        }
    }

    private func save() {
        guard !saving, directoryReady else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            // Read the latest library immediately before the single synchronous commit.
            let additions = try request.copies(existing: store.commands, directory: folderScope ? resolvedDirectory : nil,
                                               includesSubdirectories: includesSubdirectories)
            try store.replace(store.commands + additions)
            onSaved(additions)
        } catch { self.error = error.localizedDescription }
    }
}
