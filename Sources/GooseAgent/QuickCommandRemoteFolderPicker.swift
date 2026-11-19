import SwiftUI

struct QuickCommandRemoteFolderPicker: View {
    private struct Request: Equatable {
        let directory: String?
        let id = UUID()
    }

    private let host: String
    private let onClose: () -> Void
    private let onChoose: (String) -> Void
    @State private var request: Request
    @State private var selection: String?
    @State private var displayedPath: String?
    @State private var folders: [FileEntry] = []
    @State private var loading = true
    @State private var error: String?
    @Environment(\.windowChrome) private var chrome

    init(host: String, directory: String?, onClose: @escaping () -> Void, onChoose: @escaping (String) -> Void) {
        self.host = host
        self.onClose = onClose
        self.onChoose = onChoose
        let current = directory.flatMap { QuickCommand.validPath($0) ? FileRules.normalize($0) : nil }
        _request = State(initialValue: Request(directory: current.map { FileRules.parent(of: $0) }))
        _selection = State(initialValue: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Choose Directory").font(.system(size: 20, weight: .semibold))
            Text(verbatim: "SSH · \(host)").font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
            Divider()
            HStack(spacing: Theme.Space.s) {
                Button { if let displayedPath { browse(FileRules.parent(of: displayedPath)) } } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(FamilyButtonStyle(kind: .secondary))
                .disabled(displayedPath == nil || displayedPath == "/" || loading)
                .help("Parent Folder")
                .accessibilityLabel(Text("Parent Folder"))
                .accessibilityIdentifier("quickCommand.folderParent")
                if let displayedPath {
                    Text(verbatim: (["/"] + displayedPath.split(separator: "/").map(String.init)).joined(separator: " › "))
                        .font(Theme.Font.row)
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("quickCommand.folderBreadcrumb")
                }
            }

            folderList.frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: Theme.Space.s) {
                if let path = selection ?? displayedPath {
                    Text(verbatim: path).font(.system(size: 12, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(chrome.secondary)
                        .help(path)
                        .accessibilityIdentifier("quickCommand.folderSelection")
                }
                Spacer(minLength: 0)
                Button("Cancel", action: onClose)
                    .buttonStyle(FamilyButtonStyle(kind: .secondary))
                    .accessibilityIdentifier("quickCommand.folderCancel")
                Button("Choose…") {
                    if let path = selection ?? displayedPath { onChoose(path) }
                }
                .buttonStyle(FamilyButtonStyle(kind: .primary))
                .disabled(loading || error != nil || displayedPath == nil)
                .accessibilityIdentifier("quickCommand.folderChoose")
            }
        }
        .padding(Theme.Space.l)
        .foregroundStyle(chrome.text)
        .task(id: request) { await load(request) }
    }

    @ViewBuilder
    private var folderList: some View {
        if loading {
            ProgressView().controlSize(.small).accessibilityLabel(Text("Loading…"))
        } else if let error {
            VStack(spacing: Theme.Space.s) {
                Text(verbatim: error)
                    .font(Theme.Font.rowMeta).foregroundStyle(chrome.danger)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("quickCommand.folderError")
                Button("Retry") { browse(displayedPath) }.buttonStyle(FamilyButtonStyle(kind: .secondary))
            }
        } else if folders.isEmpty {
            Text("No Folders").font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(folders) { entry in
                        HStack(spacing: 0) {
                            Button { selection = entry.path } label: {
                                Label { Text(verbatim: entry.name).lineLimit(1) } icon: { Image(systemName: "folder") }
                                    .padding(.leading, Theme.Space.s)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(height: SheetLayout.pickerRowHeight)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(FamilyPlainButtonStyle())
                            .accessibilityAddTraits(selection == entry.path ? .isSelected : [])
                            .accessibilityIdentifier("quickCommand.folderEntry.\(entry.name)")
                            Button { browse(entry.path) } label: {
                                Image(systemName: "chevron.right").font(Theme.Font.rowMeta)
                                    .frame(width: SheetLayout.pickerRowHeight, height: SheetLayout.pickerRowHeight)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(FamilyPlainButtonStyle())
                            .accessibilityLabel(Text("Open Folder \(entry.name)"))
                            .accessibilityIdentifier("quickCommand.folderOpen.\(entry.name)")
                        }
                        .background(selection == entry.path ? chrome.accent.opacity(0.16) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    }
                }
            }
        }
    }

    private func browse(_ path: String?) {
        loading = true
        error = nil
        selection = nil
        request = Request(directory: path)
    }

    private func load(_ request: Request) async {
        let fs = fileSystem(for: host)
        displayedPath = request.directory
        do {
            let path: String
            if let directory = request.directory { path = directory }
            else { path = try await fs.home() }
            try Task.checkCancellation()
            displayedPath = path
            let listed = try await fs.list(path)
            try Task.checkCancellation()
            folders = listed.filter { $0.isDirectory && QuickCommand.validPath($0.path) }
            if let selection, selection != path, !folders.contains(where: { $0.path == selection }) {
                self.selection = nil
            }
            loading = false
        } catch {
            guard !Task.isCancelled else { return }
            selection = nil
            self.error = error.localizedDescription
            loading = false
        }
    }
}
