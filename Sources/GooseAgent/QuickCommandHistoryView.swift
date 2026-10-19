import SwiftUI

struct QuickCommandHistoryView: View {
    let context: QuickCommandContext
    let hosts: [SSHHost]
    let onClose: () -> Void
    @State private var host: String
    @State private var format: CommandHistoryFormat = .zsh
    @State private var path = "~/.zsh_history"
    @State private var query = ""
    @State private var recentFirst = false
    @State private var result: CommandHistoryResult?
    @State private var selected: Set<String> = []
    @State private var drafts: [QuickCommand] = []
    @State private var review = false
    @State private var scope: QuickCommandScope
    @State private var directory = ""
    @State private var includesSubdirectories = false
    @State private var busy = false
    @State private var error: String?
    @Environment(\.windowChrome) private var chrome

    init(context: QuickCommandContext, hosts: [SSHHost], onClose: @escaping () -> Void) {
        self.context = context; self.hosts = hosts; self.onClose = onClose
        _host = State(initialValue: context.host ?? "")
        _scope = State(initialValue: context.host == nil ? .local : .host)
    }
    private var candidates: [CommandHistoryCandidate] {
        let values = (result?.candidates ?? []).filter { query.isEmpty || $0.command.localizedCaseInsensitiveContains(query) }
        return recentFirst ? values.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) } : values
    }
    var body: some View {
        CommandDialog(title: review ? "Review History Commands" : "Add from History", close: onClose) {
            VStack(alignment: .leading, spacing: 12) {
                if review { reviewFields } else { historyFields }
                if let error { Text(verbatim: error).foregroundStyle(chrome.danger).font(Theme.Font.rowMeta) }
            }
        } actions: {
            if busy { ProgressView().controlSize(.small) }
            if review {
                Button("Back") { review = false }.buttonStyle(FamilyButtonStyle()).disabled(busy)
                Button("Save Selected Commands", action: save).buttonStyle(FamilyButtonStyle(kind: .primary)).disabled(busy || drafts.isEmpty)
                    .accessibilityIdentifier("quickCommands.history.save")
            } else {
                Button("Cancel", action: onClose).buttonStyle(FamilyButtonStyle())
                Button("Review Selected") {
                    drafts = (result?.candidates ?? []).filter { selected.contains($0.command) }.map {
                        QuickCommand(alias: String($0.command.split(separator: "\n").first?.prefix(80) ?? ""), command: $0.command, scope: scope)
                    }
                    review = true
                }.buttonStyle(FamilyButtonStyle(kind: .primary)).disabled(selected.isEmpty || busy)
            }
        }
    }
    private var historyFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Target Host")
                FamilyPicker(value: $host, options: [("", String(localized: "This Mac"))] + hosts.map { ($0.alias, $0.alias) })
                Spacer()
                FamilyPicker(value: $format, options: CommandHistoryFormat.allCases.map { ($0, $0.rawValue) })
            }.disabled(busy)
            .onChange(of: format) { _, value in path = "~/" + value.relativePath; result = nil; selected = [] }
            .onChange(of: host) { _, value in result = nil; selected = []; scope = value.isEmpty ? .local : .host }
            HStack {
                CommandTextField(text: $path, placeholder: String(localized: "History file path"), identifier: "quickCommands.history.path").frame(height: 32)
                Button("Read History", action: load).buttonStyle(FamilyButtonStyle(kind: .secondary)).disabled(busy)
                    .accessibilityIdentifier("quickCommands.history.read")
            }
            Text("Reads a saved history snapshot only. Unsaved shell history may be absent; execution directories are not inferred.")
                .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
            if let result {
                Text(String(format: String(localized: "Read %d records, %d unique commands (up to 4 MiB / 5,000 records)."), result.parsedCount, result.candidates.count))
                    .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                if result.truncated { Text("Older or incomplete records were omitted.").font(Theme.Font.rowMeta).foregroundStyle(chrome.warning) }
                if format == .bash { Text("Bash history without timestamps may split multiline commands. Review the text before saving.").font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary) }
            }
            HStack {
                CommandTextField(text: $query, placeholder: String(localized: "Search commands"), identifier: "quickCommands.history.search").frame(height: 32)
                FamilyPicker(value: $recentFirst, options: [(false, String(localized: "Most Frequent")), (true, String(localized: "Most Recent"))])
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(candidates) { candidate in
                        HStack(alignment: .top) {
                            Toggle(isOn: Binding(get: { selected.contains(candidate.command) }, set: { value in
                                if value { selected.insert(candidate.command) } else { selected.remove(candidate.command) }
                            })) { EmptyView() }.labelsHidden()
                            VStack(alignment: .leading, spacing: 5) {
                                Text(verbatim: candidate.command).font(.system(size: 12, design: .monospaced)).lineLimit(3)
                                HStack {
                                    Text(String(format: String(localized: "%d occurrences in snapshot"), candidate.count))
                                    if let date = candidate.lastUsed { Text(date, style: .date) }
                                }.font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        Divider()
                    }
                }
            }
        }
    }
    private var reviewFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scope")
                FamilyPicker(value: $scope, options: QuickCommandScope.allCases.filter { $0 != .host || !host.isEmpty }.map { ($0, $0.title) })
                Spacer()
                Text(verbatim: host.isEmpty ? String(localized: "This Mac") : host).foregroundStyle(chrome.secondary)
            }
            if scope == .directory {
                HStack {
                    CommandTextField(text: $directory, placeholder: String(localized: "Enter an absolute working directory"), identifier: "quickCommands.history.directory").frame(height: 32)
                    if context.host == (host.isEmpty ? nil : host), let current = context.directory {
                        Button("Use Current Folder") { directory = current }.buttonStyle(FamilyButtonStyle())
                    }
                }
                Toggle("Include Subfolders", isOn: $includesSubdirectories)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach($drafts) { $draft in
                        VStack(alignment: .leading, spacing: 6) {
                            CommandTextField(text: $draft.alias, placeholder: String(localized: "Alias"), identifier: "quickCommands.history.alias." + draft.id.uuidString).frame(height: 32)
                            CommandLiteralEditor(text: $draft.command, textColor: NSColor(chrome.text), backgroundColor: NSColor(chrome.elevated), identifier: "quickCommands.history.script." + draft.id.uuidString)
                                .frame(height: 85).overlay(RoundedRectangle(cornerRadius: 4).stroke(chrome.hairline))
                        }
                    }
                }
            }
        }
    }
    private func load() {
        busy = true; result = nil; selected = []; error = nil
        let selectedHost = host.isEmpty ? nil : host, selectedFormat = format, inputPath = path
        Task {
            do {
                let fs = fileSystem(for: selectedHost)
                var absolute = inputPath
                if absolute == "~" || absolute.hasPrefix("~/") { absolute = try await fs.home() + String(absolute.dropFirst()) }
                guard QuickCommand.validPath(absolute) else { throw QuickCommandError.invalidDirectory }
                let snapshot = try await fs.readTail(absolute, limit: CommandHistoryParser.byteLimit)
                result = await Task.detached { CommandHistoryParser.parse(snapshot.data, format: selectedFormat, truncated: snapshot.truncated) }.value
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    private func save() {
        busy = true; error = nil
        Task {
            do {
                let selectedHost = host.isEmpty ? nil : host
                if scope == .directory {
                    guard QuickCommand.validPath(directory) else { throw QuickCommandError.invalidDirectory }
                    if selectedHost == nil {
                        guard ExternalOpen.validatedDirectory(directory) != nil else { throw QuickCommandError.invalidDirectory }
                    } else { _ = try await fileSystem(for: selectedHost).list(directory) }
                }
                var next = QuickCommandStore.shared.commands
                let firstOrder = (next.map(\.order).max() ?? -1) + 1
                for (index, draft) in drafts.enumerated() {
                    var item = draft
                    item.scope = scope; item.host = selectedHost
                    item.directory = scope == .directory ? directory : nil
                    item.includesSubdirectories = includesSubdirectories
                    item.order = firstOrder + index
                    next.append(try item.validated())
                }
                try QuickCommandStore.shared.replace(next)
                onClose()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
