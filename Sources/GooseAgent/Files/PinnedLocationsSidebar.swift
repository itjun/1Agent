import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PinnedLocationsSidebar: View {
    @ObservedObject var workspace: FileWorkspace
    var focusFiles: () -> Void
    @ObservedObject private var locations = PinnedLocations.shared
    @Environment(\.windowChrome) private var chrome
    @State private var editing = false
    @State private var dropTargeted = false
    @State private var dropError = false
    @State private var dropBefore: UUID?
    private static let dragType = "com.itjun.1agent.pinned-location"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Locations").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Button(action: chooseFolders) { Image(systemName: "plus").frame(width: 22, height: 24) }
                    .help("Pin Folder").accessibilityLabel(Text("Pin Folder"))
                    .accessibilityIdentifier("locations.add")
                Button { editing.toggle() } label: {
                    Image(systemName: editing ? "checkmark" : "pencil").frame(width: 22, height: 24)
                }.help(editing ? "Done" : "Edit Locations")
                    .accessibilityLabel(Text(editing ? "Done" : "Edit Locations"))
                    .accessibilityIdentifier("locations.edit")
            }
            .buttonStyle(FamilyButtonStyle()).foregroundStyle(chrome.secondary)
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(locations.items) { item in
                        PinnedLocationRow(item: item, title: title(item), editing: editing,
                                          selected: workspace.focusedColumn === workspace.localColumn && workspace.localColumn.directory == item.path,
                                          first: locations.items.first?.id == item.id, last: locations.items.last?.id == item.id,
                                          open: { workspace.browseLocal(at: item.path); focusFiles() },
                                          rename: { locations.rename(item.id, to: $0) },
                                          remove: { locations.remove(item.id) },
                                          shift: { locations.shift(item.id, by: $0) })
                        .onDrag {
                            let provider = NSItemProvider()
                            provider.registerDataRepresentation(forTypeIdentifier: Self.dragType, visibility: .ownProcess) { completion in
                                completion(Data(item.id.uuidString.utf8), nil)
                                return nil
                            }
                            return provider
                        }
                        .onDrop(of: [Self.dragType, UTType.fileURL.identifier], delegate: LocationDropDelegate(
                            internalType: Self.dragType, targeted: { dropBefore = $0 ? item.id : nil }, perform: { receive($0, before: item.id) }))
                        .overlay(alignment: .top) {
                            if dropBefore == item.id { Rectangle().fill(chrome.accent).frame(height: 2).allowsHitTesting(false) }
                        }
                    }
                    if locations.items.isEmpty {
                        Text("Drop folders here").font(.system(size: 12)).foregroundStyle(chrome.secondary)
                            .frame(maxWidth: .infinity, minHeight: 64)
                    }
                    if dropError {
                        Text("Only local folders can be pinned.").font(.system(size: 12)).foregroundStyle(chrome.danger)
                            .padding(.horizontal, 10)
                    }
                }.padding(.horizontal, 8).padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay { Rectangle().stroke(chrome.accent.opacity(dropTargeted ? 0.65 : 0), lineWidth: 1).allowsHitTesting(false) }
        .onDrop(of: [Self.dragType, UTType.fileURL.identifier], delegate: LocationDropDelegate(
            internalType: Self.dragType, targeted: { dropTargeted = $0 }, perform: { receive($0, before: nil) }))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("locations.list")
    }

    private func title(_ item: PinnedLocation) -> String {
        if let name = item.name { return name }
        if item.path == NSHomeDirectory() { return String(localized: "Home") }
        if item.path == NSHomeDirectory() + "/Downloads" { return String(localized: "Downloads") }
        return (item.path as NSString).lastPathComponent
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Pin Folder")
        panel.directoryURL = URL(fileURLWithPath: workspace.localColumn.directory)
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { response in
            if response == .OK { locations.add(panel.urls); dropError = false }
        }
    }

    private func receive(_ providers: [NSItemProvider], before target: UUID?) -> Bool {
        dropTargeted = false
        dropBefore = nil
        if let internalItem = providers.first(where: { $0.hasItemConformingToTypeIdentifier(Self.dragType) }) {
            internalItem.loadDataRepresentation(forTypeIdentifier: Self.dragType) { data, _ in
                guard let data, let string = String(data: data, encoding: .utf8), let id = UUID(uuidString: string) else { return }
                Task { @MainActor in locations.move(id, before: target) }
            }
            return true
        }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        PinnedLocations.requestDroppedURLs(files) { urls in
            dropError = locations.add(urls, before: target) < files.count
        }
        return true
    }
}

private struct PinnedLocationRow: View {
    let item: PinnedLocation
    let title: String
    let editing: Bool
    let selected: Bool
    let first: Bool
    let last: Bool
    var open: () -> Void
    var rename: (String) -> Void
    var remove: () -> Void
    var shift: (Int) -> Void
    @Environment(\.windowChrome) private var chrome

    var body: some View {
        VStack(spacing: 2) {
            if editing {
                HStack(spacing: 8) {
                    Image(systemName: "folder").frame(width: 20)
                    TextField("Location Name", text: Binding(get: { item.name ?? title }, set: rename)).textFieldStyle(.plain)
                }.padding(.horizontal, 11).padding(.top, 8)
                HStack(spacing: 6) {
                    Text(verbatim: LocalTerminal.displayPath(item.path)).font(.system(size: 12))
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    Button { shift(-1) } label: { Image(systemName: "arrow.up") }
                        .disabled(first).help("Move Location Up").accessibilityLabel(Text("Move Location Up"))
                    Button { shift(1) } label: { Image(systemName: "arrow.down") }
                        .disabled(last).help("Move Location Down").accessibilityLabel(Text("Move Location Down"))
                    Button(action: remove) { Image(systemName: "xmark") }
                        .help("Unpin Folder").accessibilityLabel(Text("Unpin Folder"))
                }.buttonStyle(FamilyButtonStyle()).foregroundStyle(chrome.secondary)
                    .padding(.horizontal, 11).padding(.bottom, 8)
            } else {
                Button(action: open) {
                    HStack(spacing: 9) {
                        Image(systemName: item.path == NSHomeDirectory() + "/Downloads" ? "arrow.down.circle" : "folder")
                            .font(.system(size: 15)).frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                                .lineLimit(1).truncationMode(.middle)
                            Text(verbatim: LocalTerminal.displayPath(item.path)).font(.system(size: 12)).foregroundStyle(chrome.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.horizontal, 11).frame(height: 46).contentShape(Rectangle())
                }.buttonStyle(FamilyButtonStyle()).help(item.path).accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .foregroundStyle(selected ? chrome.accent : chrome.text)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(selected ? chrome.accentFill : Color.clear))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("locations.row." + item.path)
    }
}

private struct LocationDropDelegate: DropDelegate {
    var internalType: String
    var targeted: (Bool) -> Void
    var perform: ([NSItemProvider]) -> Bool
    func dropEntered(info: DropInfo) { targeted(true) }
    func dropExited(info: DropInfo) { targeted(false) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: info.hasItemsConforming(to: [internalType]) ? .move : .copy)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted(false)
        return perform(info.itemProviders(for: [internalType, UTType.fileURL.identifier]))
    }
}
