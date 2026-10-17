import AppKit
import SwiftUI

struct QuickCommandFiles: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    let context: QuickCommandContext
    @Environment(\.windowChrome) private var chrome
    @State private var directory: String?
    @State private var entries: [FileEntry] = []
    @State private var back: [String] = []
    @State private var busy = false
    @State private var error: String?
    @State private var preview: String?
    @State private var previewPath = ""
    @State private var revision = UUID()
    @State private var showHidden = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    if let previous = back.popLast() { directory = previous; revision = UUID() }
                } label: { Image(systemName: "chevron.left") }.disabled(back.isEmpty).help("Back")
                Button { directory = context.directory; back = []; revision = UUID() } label: { Image(systemName: "scope") }
                    .help("Back to Terminal Folder")
                Button { revision = UUID() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                Spacer()
                Toggle(isOn: $showHidden) { Image(systemName: "eye") }.toggleStyle(.button).help("Show Hidden Files")
            }.buttonStyle(FamilyButtonStyle())
            Text(verbatim: directory ?? String(localized: "Directory unknown"))
                .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                .foregroundStyle(chrome.secondary)
            if busy { ProgressView().controlSize(.small) }
            if let error { Text(verbatim: error).font(Theme.Font.rowMeta).foregroundStyle(chrome.danger) }
            if let preview {
                Button("Close Preview") { self.preview = nil }.buttonStyle(FamilyButtonStyle())
                NativeTextPreview(text: preview, path: previewPath, findRequest: 0, onClose: { self.preview = nil })
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(entries.filter { showHidden || !$0.isHidden }) { entry in
                            HStack(spacing: 8) {
                                Button { open(entry) } label: {
                                    HStack {
                                        if entry.isDirectory { Image(systemName: "folder").foregroundStyle(chrome.accent).frame(width: 20) }
                                        else { FileTypeIcon(name: entry.name) }
                                        Text(verbatim: entry.name).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { CommandClipboard.copy(entry.path) } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(FamilyButtonStyle()).help("Copy Path")
                            }.padding(.vertical, 6)
                        }
                        if entries.isEmpty && !busy && error == nil {
                            Text(directory == nil ? "The terminal has not reported its directory." : "This folder is empty.")
                                .foregroundStyle(chrome.secondary).font(Theme.Font.rowMeta).padding(.vertical, 16)
                        }
                    }
                }
            }
            Divider()
            Button("Open in Files") { openFullFiles() }.buttonStyle(FamilyButtonStyle()).disabled(directory == nil)
        }.padding(16)
        .onAppear { directory = context.directory; revision = UUID() }
        .onChange(of: context) { old, new in
            if old.sessionID != new.sessionID || old.directory != new.directory || old.host != new.host {
                directory = new.directory; back = []; revision = UUID(); preview = nil
            }
        }
        .task(id: revision) { await load() }
    }
    private func load() async {
        let captured = revision
        entries = []; error = nil; preview = nil
        guard let directory else { busy = false; return }
        busy = true
        do {
            let result = try await fileSystem(for: context.host).list(directory)
            guard captured == revision, !Task.isCancelled else { return }
            entries = result; busy = false
        } catch {
            guard captured == revision, !Task.isCancelled else { return }
            self.error = error.localizedDescription; busy = false
        }
    }
    private func open(_ entry: FileEntry) {
        if entry.isDirectory {
            if let directory { back.append(directory) }
            directory = entry.path; revision = UUID(); return
        }
        let captured = revision, host = context.host
        Task {
            do {
                let bytes = try await fileSystem(for: host).read(entry.path, limit: 256 * 1024)
                guard captured == revision else { return }
                guard !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else {
                    throw FileError.message(String(localized: "Use the full Files page to preview this file type."))
                }
                preview = text; previewPath = entry.path
                if entry.size > 256 * 1024 { error = String(localized: "Preview shows the first 256 KiB.") }
            } catch { if captured == revision { self.error = error.localizedDescription } }
        }
    }
    private func openFullFiles() {
        let files = model.fileWorkspace(for: window)
        if let host = context.host { files.openRemote(host: host, at: directory) }
        else { files.showLocal(directory) }
        model.selectFilesLayout(.sideBySide, in: window)
    }
}
