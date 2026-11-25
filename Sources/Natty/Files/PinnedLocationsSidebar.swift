import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PinnedLocationsSidebar: View {
    @ObservedObject var workspace: FileWorkspace
    @ObservedObject var dragArea: PinnedLocationDragArea
    var focusFiles: () -> Void
    @ObservedObject private var locations = PinnedLocations.shared
    @Environment(\.windowChrome) private var chrome
    @StateObject private var folderPicker = NativeFolderPicker()
    @State private var dropTargeted = false
    @State private var dropError = false
    @State private var dropBefore: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Locations").font(Theme.Font.sidebarCategory)
                Spacer(minLength: 0)
                Button(action: chooseFolders) { Image(systemName: "plus").frame(width: 22, height: 24) }
                    .help("Pin Folder").accessibilityLabel(Text("Pin Folder"))
                    .accessibilityIdentifier("locations.add")
            }
            .buttonStyle(FamilyButtonStyle()).foregroundStyle(chrome.secondary)
            .padding(.horizontal, SidebarLayout.rowInset + SidebarLayout.contentInset)
            .padding(.top, SidebarLayout.sectionGap).padding(.bottom, Theme.Space.s)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(locations.items) { item in
                        PinnedLocationRow(item: item, title: title(item),
                                          selected: workspace.focusedColumn === workspace.localColumn && workspace.localColumn.directory == item.path,
                                          open: { workspace.browseLocal(at: item.path); focusFiles() })
                        .overlay {
                            PinnedLocationDragHandle(item: item, title: title(item), path: LocalTerminal.displayPath(item.path),
                                                     area: dragArea, chrome: chrome,
                                                     open: { workspace.browseLocal(at: item.path); focusFiles() },
                                                     dropFolders: { receiveURLs($0, before: item.id) })
                                .accessibilityHidden(true)
                        }
                        .onDrop(of: [.fileURL], delegate: LocationDropDelegate(
                            targeted: { dropBefore = $0 ? item.id : nil }, perform: { receive($0, before: item.id) }))
                        .overlay(alignment: .top) {
                            if dropBefore == item.id || dragArea.insertionBefore == item.id {
                                Rectangle().fill(chrome.accent).frame(height: 2).allowsHitTesting(false)
                            }
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
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
                // Reordering belongs to the folder rows. The viewport's empty space
                // remains inside the sidebar, so releasing there preserves the pins.
                .background(BoundsAnchor { dragArea.list = $0 })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay { Rectangle().stroke(chrome.accent.opacity(dropTargeted || dragArea.targeted ? 0.65 : 0), lineWidth: 1).allowsHitTesting(false) }
        .onDrop(of: [.fileURL], delegate: LocationDropDelegate(
            targeted: { dropTargeted = $0 }, perform: { receive($0, before: nil) }))
        .onDisappear { dragArea.cancel(); dragArea.list = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("locations.list")
        .background(NativeFolderPickerAnchor(picker: folderPicker))
    }

    private func title(_ item: PinnedLocation) -> String {
        if let name = item.name { return name }
        if item.path == NSHomeDirectory() { return String(localized: "Home") }
        if item.path == NSHomeDirectory() + "/Downloads" { return String(localized: "Downloads") }
        return (item.path as NSString).lastPathComponent
    }

    private func chooseFolders() {
        folderPicker.present(directory: workspace.localColumn.directory) { urls in
            locations.add(urls)
            dropError = false
        }
    }

    private func receive(_ providers: [NSItemProvider], before target: UUID?) -> Bool {
        dropTargeted = false
        dropBefore = nil
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        PinnedLocations.requestDroppedURLs(files) { urls in
            receiveURLs(urls, before: target)
        }
        return true
    }

    private func receiveURLs(_ urls: [URL], before target: UUID?) {
        dropTargeted = false
        dropBefore = nil
        guard !urls.isEmpty else { return }
        dropError = locations.add(urls, before: target) < urls.count
    }
}

private struct PinnedLocationRow: View {
    let item: PinnedLocation
    let title: String
    let selected: Bool
    var open: () -> Void
    @Environment(\.windowChrome) private var chrome

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                        .lineLimit(1).truncationMode(.middle)
                    Text(verbatim: LocalTerminal.displayPath(item.path)).font(.system(size: 12)).foregroundStyle(chrome.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, SidebarLayout.contentInset).frame(height: SidebarLayout.rowHeight).contentShape(Rectangle())
        }.buttonStyle(FamilyButtonStyle()).help(item.path).accessibilityAddTraits(selected ? [.isSelected] : [])
        .foregroundStyle(chrome.text)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(selected ? chrome.rowSelection(active: true) : Color.clear))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("locations.row." + item.path)
    }
}

private struct LocationDropDelegate: DropDelegate {
    var targeted: (Bool) -> Void
    var perform: ([NSItemProvider]) -> Bool
    func dropEntered(info: DropInfo) { targeted(true) }
    func dropExited(info: DropInfo) { targeted(false) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted(false)
        return perform(info.itemProviders(for: [.fileURL]))
    }
}
