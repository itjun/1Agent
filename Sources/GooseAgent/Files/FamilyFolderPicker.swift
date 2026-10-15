import AppKit
import SwiftUI

/// Directory selection stays inside the app's visual language. Browsing here is independent of
/// the file workspace; cancelling never changes its path or pinned locations.
struct FamilyFolderPicker: View {
    let initialDirectory: String
    let onCancel: () -> Void
    let onChoose: ([URL]) -> Void
    @Environment(\.windowChrome) private var chrome
    @State private var directory = ""
    @State private var pathDraft = ""
    @State private var folders: [URL] = []
    @State private var selection = Set<URL>()
    @State private var anchor: URL?
    @State private var error: String?
    @State private var loading = false
    @State private var requestID = UUID()
    @FocusState private var focusedFolder: URL?
    @State private var showHidden = false
    @State private var hovered: URL?
    @FocusState private var pathFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pin Folder").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: onCancel) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(FamilyButtonStyle()).accessibilityLabel(Text("Close"))
            }.padding(24)
            HStack(spacing: 8) {
                Button { open((directory as NSString).deletingLastPathComponent) } label: { Image(systemName: "arrow.up").frame(width: 32, height: 32) }
                    .accessibilityLabel(Text("Parent Folder")).disabled(directory == "/")
                Button { open(NSHomeDirectory()) } label: { Image(systemName: "house").frame(width: 32, height: 32) }
                    .accessibilityLabel(Text("Home"))
                TextField("Path", text: $pathDraft).textFieldStyle(.plain).font(Theme.Font.body)
                    .padding(.horizontal, 8).frame(height: 32).focused($pathFocused)
                    .background(RoundedRectangle(cornerRadius: 4).fill(pathFocused ? chrome.background : chrome.elevated))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(pathFocused ? chrome.accent : .clear, lineWidth: 1))
                    .familyFocusRing(pathFocused).onSubmit { open((pathDraft as NSString).expandingTildeInPath) }
                    .accessibilityIdentifier("folders.path")
            }.buttonStyle(FamilyButtonStyle()).padding(.horizontal, 24).padding(.bottom, 16)
            Rectangle().fill(chrome.hairline).frame(height: 1)
            if loading { Text("Loading…").foregroundStyle(chrome.secondary).padding(8) }
            if let error {
                Text(verbatim: error).foregroundStyle(chrome.danger).frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(folders, id: \.self) { folder in
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill").foregroundStyle(FileBrowserLayout.folderColor).frame(width: 20)
                            Text(verbatim: folder.lastPathComponent).lineLimit(1)
                            Spacer()
                            if selection.contains(folder) { Image(systemName: "checkmark").foregroundStyle(chrome.accent) }
                        }
                        .frame(height: 40).padding(.horizontal, 16)
                        .foregroundStyle(selection.contains(folder) ? chrome.accent : chrome.text)
                        .background(selection.contains(folder) ? chrome.accentFill : hovered == folder ? chrome.elevated : .clear)
                        .overlay(alignment: .bottom) { Rectangle().fill(chrome.hairline).frame(height: 1) }
                        .contentShape(Rectangle()).onHover { hovered = $0 ? folder : nil }
                        .onTapGesture(count: 2) { open(folder.path) }
                        .onTapGesture { select(folder); focusedFolder = folder }
                        .focusable().focusEffectDisabled().focused($focusedFolder, equals: folder)
                        .familyFocusRing(focusedFolder == folder)
                        .onKeyPress(.return) { open(folder.path); return .handled }
                        .onKeyPress(.space) { select(folder); return .handled }
                        .onMoveCommand { direction in
                            guard let index = folders.firstIndex(of: folder) else { return }
                            let next = direction == .up ? index - 1 : direction == .down ? index + 1 : index
                            if folders.indices.contains(next) { focusedFolder = folders[next]; select(folders[next]) }
                        }
                        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                        .accessibilityAddTraits(selection.contains(folder) ? [.isSelected] : [])
                        .accessibilityAction { select(folder) }
                    }
                }.padding(.horizontal, 8)
            }.frame(maxHeight: .infinity)
            Rectangle().fill(chrome.hairline).frame(height: 1)
            HStack(spacing: 8) {
                Toggle("Show Hidden Files", isOn: $showHidden).toggleStyle(FamilyToggleStyle(checkbox: true))
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    .buttonStyle(FamilyButtonStyle(kind: .secondary))
                Button("Pin Folder") {
                    onChoose(selection.isEmpty ? [URL(fileURLWithPath: directory, isDirectory: true)] : selection.sorted { $0.path < $1.path })
                }.buttonStyle(FamilyButtonStyle(kind: .primary)).disabled(directory.isEmpty || error != nil || loading)
            }.padding(24)
        }
        .font(Theme.Font.body).foregroundStyle(chrome.text).background(chrome.background)
        .onAppear { open(initialDirectory) }.onChange(of: showHidden) { _, _ in open(directory) }
    }

    private func open(_ path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let request = UUID()
        requestID = request; loading = true
        let hidden = showHidden
        Task {
            do {
                let entries = try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: hidden ? [] : [.skipsHiddenFiles])
                        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                }.value
                guard requestID == request else { return }
                folders = entries; directory = url.path; pathDraft = directory
                selection = []; anchor = nil; error = nil
            } catch {
                guard requestID == request else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private func select(_ folder: URL) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor, let a = folders.firstIndex(of: anchor), let b = folders.firstIndex(of: folder) {
            selection = Set(folders[min(a, b)...max(a, b)])
        } else if flags.contains(.command) {
            if selection.contains(folder) { selection.remove(folder) } else { selection.insert(folder) }
            anchor = folder
        } else { selection = [folder]; anchor = folder }
    }
}
