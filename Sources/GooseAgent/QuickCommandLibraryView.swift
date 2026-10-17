import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct QuickCommandLibraryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @ObservedObject private var store = QuickCommandStore.shared
    let onClose: () -> Void
    @State private var query = ""
    @State private var editing: QuickCommand?
    @State private var inspecting: QuickCommand?
    @State private var importing: QuickCommandLibrary?
    @State private var error: String?
    @Environment(\.windowChrome) private var chrome

    var body: some View {
        CommandDialog(title: "Manage Command Library", close: onClose) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CommandTextField(text: $query, placeholder: String(localized: "Search all commands"), identifier: "quickCommands.library.search").frame(height: 32)
                    Button("New Quick Command") { editing = QuickCommand(scope: .local) }.buttonStyle(FamilyButtonStyle())
                    Button("Import…", action: importLibrary).buttonStyle(FamilyButtonStyle())
                    Button("Export…", action: exportLibrary).buttonStyle(FamilyButtonStyle()).disabled(store.loadError != nil)
                }
                if let message = error ?? store.loadError { Text(verbatim: message).foregroundStyle(chrome.danger).font(Theme.Font.rowMeta) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.commands.filter { query.isEmpty || ($0.alias + $0.command + $0.group).localizedCaseInsensitiveContains(query) }
                            .sorted { $0.order < $1.order }) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                CommandListRow(item: item, action: { inspecting = item }, menu: {
                                    [FamilyMenuItem(title: String(localized: "View Full Command"), action: { inspecting = item }),
                                     FamilyMenuItem(title: String(localized: "Copy Command"), action: { CommandClipboard.copy(item.command) }),
                                     FamilyMenuItem(title: String(localized: "Edit"), action: { editing = item }),
                                     FamilyMenuItem(title: String(localized: "Duplicate Command"), action: { var copy = item; copy.id = UUID(); editing = copy }),
                                     FamilyMenuItem(title: String(localized: "Move Up"), action: { move(item, delta: -1) }),
                                     FamilyMenuItem(title: String(localized: "Move Down"), action: { move(item, delta: 1) }),
                                     .separator,
                                     FamilyMenuItem(title: String(localized: "Delete"), destructive: true, action: {
                                         do { try store.remove(item.id) } catch { self.error = error.localizedDescription }
                                     })]
                                })
                                Text(verbatim: [item.scope.title, item.host, item.directory].compactMap { $0 }.joined(separator: " · "))
                                    .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary).padding(.horizontal, 10)
                                if item.needsRepair { Text("Needs binding review — edit to repair").font(Theme.Font.rowMeta).foregroundStyle(chrome.warning).padding(.horizontal, 10) }
                                Divider()
                            }
                        }
                        if store.commands.isEmpty { Text("Your command library is empty.").foregroundStyle(chrome.secondary).padding(.vertical, 20) }
                    }
                }
            }
        } actions: { Button("Close", action: onClose).buttonStyle(FamilyButtonStyle()) }
        .familySheet(isPresented: optionalBinding($editing), width: SheetLayout.quickCommand, height: SheetLayout.quickCommandHeight) {
            if let editing { QuickCommandEditor(item: editing, hosts: model.hosts) { self.editing = nil }.id(editing.id) }
        }
        .familySheet(isPresented: optionalBinding($inspecting), width: SheetLayout.quickCommand, height: SheetLayout.quickCommandHeight) {
            if let inspecting { QuickCommandDetails(item: inspecting) { self.inspecting = nil } }
        }
        .familySheet(isPresented: optionalBinding($importing), width: SheetLayout.commandLibrary, height: SheetLayout.commandLibraryHeight) {
            if let importing { QuickCommandImportView(library: importing, hosts: model.hosts) { self.importing = nil } }
        }
    }
    private func move(_ item: QuickCommand, delta: Int) {
        var commands = store.commands.sorted { $0.order < $1.order }
        guard let index = commands.firstIndex(where: { $0.id == item.id }), commands.indices.contains(index + delta) else { return }
        commands.swapAt(index, index + delta)
        for i in commands.indices { commands[i].order = i }
        do { try store.replace(commands) } catch { self.error = error.localizedDescription }
    }
    private func importLibrary() {
        let owner = NSApp.keyWindow
        defer { owner?.makeKeyAndOrderFront(nil) }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw QuickCommandError.invalidBackup }
            importing = try QuickCommandLibrary.decode(Data(contentsOf: url))
        } catch { self.error = error.localizedDescription }
    }
    private func exportLibrary() {
        let owner = NSApp.keyWindow
        defer { owner?.makeKeyAndOrderFront(nil) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "1Agent-commands.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let referencedHosts = Set(store.commands.compactMap(\.host))
            let hints = Dictionary(uniqueKeysWithValues: model.hosts.filter { referencedHosts.contains($0.alias) }.map { ($0.alias, $0.subtitle) })
            try QuickCommandLibrary(commands: store.commands, hostHints: hints).encoded().write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
}

struct QuickCommandImportView: View {
    let library: QuickCommandLibrary
    let hosts: [SSHHost]
    let onClose: () -> Void
    @ObservedObject private var store = QuickCommandStore.shared
    @State private var hostMap: [String: String] = [:]
    @State private var paths: [UUID: String] = [:]
    @State private var choices: [UUID: QuickCommandConflict] = [:]
    @State private var busy = false
    @State private var error: String?
    @Environment(\.windowChrome) private var chrome

    private var incomingHosts: [String] { Array(Set(library.commands.compactMap(\.host))).sorted() }
    var body: some View {
        CommandDialog(title: "Restore Command Library", close: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Review host mappings and folders. Unresolved bindings are imported disabled until repaired.")
                        .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                    Text(String(format: String(localized: "%d commands in this backup"), library.commands.count)).font(Theme.Font.sectionTitle)
                    ForEach(incomingHosts, id: \.self) { alias in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: alias)
                                if let hint = library.hostHints[alias] { Text(verbatim: hint).font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary) }
                            }
                            Spacer()
                            FamilyPicker(value: Binding(get: { hostMap[alias] ?? "" }, set: { hostMap[alias] = $0 }),
                                options: [("", String(localized: "Not mapped"))] + hosts.map { ($0.alias, $0.alias) })
                        }
                    }
                    Divider()
                    ForEach(library.commands) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(verbatim: item.alias).font(Theme.Font.sectionTitle)
                                Spacer()
                                if let existing = store.commands.first(where: { $0.id == item.id }) {
                                    if existing == item { Text("Unchanged — skip").font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary) }
                                    else {
                                        FamilyPicker(value: Binding(get: { choices[item.id] ?? .keep }, set: { choices[item.id] = $0 }),
                                            options: QuickCommandConflict.allCases.map { ($0, $0.title) })
                                    }
                                } else { Text("New").font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary) }
                            }
                            Text(verbatim: item.command).font(.system(size: 12, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                            Text(verbatim: [item.scope.title, item.host].compactMap { $0 }.joined(separator: " · "))
                                .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                            if let path = item.directory {
                                CommandTextField(text: Binding(get: { paths[item.id] ?? path }, set: { paths[item.id] = $0 }),
                                    placeholder: String(localized: "Working Directory"), identifier: "quickCommands.import.path." + item.id.uuidString)
                                    .frame(height: 32)
                            }
                            Divider()
                        }
                    }
                    if let error { Text(verbatim: error).foregroundStyle(chrome.danger) }
                }
            }
        } actions: {
            if busy { ProgressView().controlSize(.small) }
            Button("Cancel", action: onClose).buttonStyle(FamilyButtonStyle())
            Button("Merge Commands", action: merge).buttonStyle(FamilyButtonStyle(kind: .primary)).disabled(busy)
                .accessibilityIdentifier("quickCommands.import.merge")
        }
    }
    private func merge() {
        busy = true
        Task {
            var incoming: [QuickCommand] = []
            var checked: [String: Bool] = [:]
            for original in library.commands {
                if let existing = store.commands.first(where: { $0.id == original.id }), existing == original || (choices[original.id] ?? .keep) == .keep {
                    continue
                }
                var item = original
                item.needsRepair = false
                if let host = original.host {
                    if let mapped = hostMap[host], !mapped.isEmpty { item.host = mapped }
                    else { item.needsRepair = true }
                }
                if let originalPath = original.directory {
                    let newPath = paths[item.id] ?? originalPath
                    if QuickCommand.validPath(newPath) { item.directory = QuickCommand.path(newPath) }
                    else { item.needsRepair = true }
                    if !item.needsRepair, let path = item.directory {
                        let key = (item.host ?? "") + "\0" + path
                        if checked[key] == nil {
                            if item.host == nil { checked[key] = ExternalOpen.validatedDirectory(path) != nil }
                            else { checked[key] = (try? await fileSystem(for: item.host).list(path)) != nil }
                        }
                        if checked[key] != true { item.needsRepair = true }
                    }
                }
                incoming.append(item)
            }
            do {
                try store.replace(QuickCommandMerge.merge(existing: store.commands, incoming: incoming, choices: choices))
                onClose()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
