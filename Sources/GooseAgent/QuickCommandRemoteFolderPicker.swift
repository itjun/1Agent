import SwiftUI

struct QuickCommandRemoteFolderPicker: View {
    private enum Listing {
        case folders([FileEntry])
        case failed(String)
    }

    private let host: String
    private let onClose: () -> Void
    private let onChoose: (String) -> Void
    @State private var selection: String?
    @State private var listings: [String: Listing] = [:]
    @State private var retries: [String: Int] = [:]
    @State private var homeAttempt = 0
    @State private var homeError: String?
    @State private var pendingChildOf: String?
    @State private var showHidden = false
    @FocusState private var browserFocused: Bool
    @Environment(\.windowChrome) private var chrome

    init(host: String, directory: String?, onClose: @escaping () -> Void, onChoose: @escaping (String) -> Void) {
        self.host = host
        self.onClose = onClose
        self.onChoose = onChoose
        _selection = State(initialValue: directory.flatMap { QuickCommand.validPath($0) ? FileRules.normalize($0) : nil })
    }

    // Each column lists the children of one directory on the active path.
    // The last column previews the selection itself, including when it has no children.
    private var columnPaths: [String] {
        guard let selection else { return [] }
        var paths = ["/"]
        for component in selection.split(separator: "/") {
            paths.append(FileRules.join(paths[paths.count - 1], String(component)))
        }
        return paths
    }

    private var canChoose: Bool {
        guard let selection else { return false }
        if case .folders = listings[selection] { return true }
        return loadedFolders(in: FileRules.parent(of: selection)).contains { $0.path == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text("Choose Directory").font(.system(size: 20, weight: .semibold))
                Spacer(minLength: Theme.Space.s)
                Text(verbatim: "SSH · \(host)").font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            browser
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusable(interactions: .edit)
                .focusEffectDisabled()
                .focused($browserFocused)
                .defaultFocus($browserFocused, true)
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
                    guard press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
                    navigate(press.key)
                    return .handled
                }
                .onKeyPress(phases: .down) { press in
                    guard press.modifiers == [.command, .shift], press.characters == "." || press.characters == ">" else {
                        return .ignored
                    }
                    showHidden.toggle()
                    return .handled
                }
            HStack(spacing: Theme.Space.s) {
                if let selection {
                    Text(verbatim: selection).font(.system(size: 12, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(chrome.secondary)
                        .help(selection)
                        .accessibilityIdentifier("quickCommand.folderSelection")
                }
                Spacer(minLength: 0)
                Button("Cancel", action: onClose)
                    .buttonStyle(FamilyButtonStyle(kind: .secondary))
                    .accessibilityIdentifier("quickCommand.folderCancel")
                Button("Choose…") {
                    if canChoose, let selection { onChoose(selection) }
                }
                .buttonStyle(FamilyButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!canChoose)
                .accessibilityIdentifier("quickCommand.folderChoose")
            }
        }
        .padding(Theme.Space.l)
        .foregroundStyle(chrome.text)
        .task(id: homeAttempt) { await openHomeIfNeeded() }
    }

    @ViewBuilder
    private var browser: some View {
        if selection != nil {
            let paths = columnPaths
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(paths.indices, id: \.self) { index in
                            let path = paths[index]
                            if index > 0 { Divider() }
                            column(path, highlighted: index + 1 < paths.count ? paths[index + 1] : nil)
                                .id(path)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
                .onChange(of: selection, initial: true) { _, path in
                    if let path { proxy.scrollTo(path, anchor: .trailing) }
                }
            }
            .familyContextMenu {
                [FamilyMenuItem(title: showHidden ? String(localized: "Hide Hidden Files") : String(localized: "Show Hidden Files"),
                                action: { showHidden.toggle() })]
            }
        } else if let homeError {
            loadError(homeError) {
                self.homeError = nil
                homeAttempt += 1
            }
        } else {
            loadingIndicator
        }
    }

    private func column(_ path: String, highlighted: String?) -> some View {
        Group {
            switch listings[path] {
            case .folders:
                let folders = visibleFolders(in: path, highlighted: highlighted)
                if folders.isEmpty {
                    Text("No Folders").font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(folders) { entry in
                                    folderRow(entry, highlighted: entry.path == highlighted).id(entry.path)
                                }
                            }
                            .padding(.horizontal, Theme.Space.xs)
                            .padding(.vertical, Theme.Space.xs)
                        }
                        .onChange(of: highlighted, initial: true) { _, path in
                            if let path { proxy.scrollTo(path) }
                        }
                    }
                }
            case .failed(let error):
                loadError(error) {
                    listings[path] = nil
                    retries[path, default: 0] += 1
                }
            case nil:
                loadingIndicator
            }
        }
        .frame(width: SheetLayout.commandFolderColumnWidth)
        .frame(maxHeight: .infinity)
        .task(id: retries[path, default: 0]) { await load(path) }
    }

    private func folderRow(_ entry: FileEntry, highlighted: Bool) -> some View {
        let isTarget = entry.path == selection
        let ink = isTarget ? chrome.filledForeground(on: chrome.accent) : chrome.text
        let fill = isTarget ? chrome.accent : highlighted ? chrome.rowSelection(active: false) : .clear
        return Button { select(entry.path) } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "folder")
                Text(verbatim: entry.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Theme.Space.xs)
                Image(systemName: "chevron.right")
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(isTarget ? ink : chrome.secondary)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 27)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(FamilyPlainButtonStyle())
        .accessibilityAddTraits(highlighted ? .isSelected : [])
        .accessibilityIdentifier("quickCommand.folderEntry.\(entry.name)")
        .help(entry.name)
    }

    private var loadingIndicator: some View {
        ProgressView().controlSize(.small).accessibilityLabel(Text("Loading…"))
    }

    private func loadError(_ error: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: Theme.Space.s) {
            Text(verbatim: error)
                .font(Theme.Font.rowMeta).foregroundStyle(chrome.danger)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .help(error)
                .accessibilityIdentifier("quickCommand.folderError")
            Button("Retry", action: retry).buttonStyle(FamilyButtonStyle(kind: .secondary))
        }
        .padding(.horizontal, Theme.Space.s)
    }

    private func loadedFolders(in path: String) -> [FileEntry] {
        if case .folders(let folders) = listings[path] { return folders }
        return []
    }

    private func visibleFolders(in path: String, highlighted: String? = nil) -> [FileEntry] {
        let folders = loadedFolders(in: path)
        return showHidden ? folders : folders.filter { !$0.isHidden || $0.path == highlighted }
    }

    private func select(_ path: String) {
        pendingChildOf = nil
        selection = path
        browserFocused = true
    }

    private func navigate(_ key: KeyEquivalent) {
        guard let selection else { return }
        let parent = FileRules.parent(of: selection)
        switch key {
        case .leftArrow:
            select(parent)
        case .rightArrow:
            if let child = visibleFolders(in: selection).first { select(child.path) }
            else if listings[selection] == nil { pendingChildOf = selection }
        case .upArrow, .downArrow:
            let delta = key == .upArrow ? -1 : 1
            let siblings = visibleFolders(in: parent, highlighted: selection)
            let index = siblings.firstIndex { $0.path == selection } ?? (delta > 0 ? -1 : siblings.count)
            if siblings.indices.contains(index + delta) { select(siblings[index + delta].path) }
        default:
            break
        }
    }

    private func openHomeIfNeeded() async {
        guard selection == nil else { return }
        do {
            let home = try await readRemote { try await $0.home() }
            try Task.checkCancellation()
            select(FileRules.normalize(home))
        } catch {
            if !Task.isCancelled { homeError = error.localizedDescription }
        }
    }

    private func load(_ path: String) async {
        guard listings[path] == nil else { return }
        do {
            let entries = try await readRemote { try await $0.list(path) }
            try Task.checkCancellation()
            listings[path] = .folders(entries.filter { $0.isDirectory && QuickCommand.validPath($0.path) })
            if pendingChildOf == path {
                pendingChildOf = nil
                if selection == path, let child = visibleFolders(in: path).first { select(child.path) }
            }
        } catch {
            guard !Task.isCancelled else { return }
            listings[path] = .failed(error.localizedDescription)
            if pendingChildOf == path { pendingChildOf = nil }
        }
    }

    // When a different branch replaces a column, discard the old result and stop its read-only SSH subprocess.
    private func readRemote<T>(_ operation: (any FileSystem) async throws -> T) async throws -> T {
        let fs = fileSystem(for: host)
        let cancellation = FileOperationCancellation()
        return try await withTaskCancellationHandler {
            try await FileOperationContext.$cancellation.withValue(cancellation) { try await operation(fs) }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
