import AppKit
import SwiftUI

/// The independent file page has a local pane and a remote workspace with movable tabs.
struct FilesWorkspaceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    var relay: CanvasDropRelay

    var body: some View { FilesDockView(model: model, window: window, relay: relay) }
}

/// Kept as a compatibility entry point for saved presentations. It now renders the same page.
struct FilesDockView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @ObservedObject var workspace: FileWorkspace
    var relay: CanvasDropRelay
    @Environment(\.windowChrome) private var chrome

    init(model: AppModel, window: WindowState, relay: CanvasDropRelay) {
        self.model = model
        self.window = window
        workspace = model.fileWorkspace(for: window)
        self.relay = relay
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    FilePairGrid(workspace: workspace, model: model, window: window, relay: relay)
                    if let column = workspace.selectedPreviewColumn {
                        Divider()
                        TextPreviewDrawer(column: column)
                            .id(column.id)
                            .frame(height: min(300, max(160, geometry.size.height * 0.36)))
                    }
                }
            }
            FileTransferQueueView()
        }
        .background(chrome.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.files.content")
        .simultaneousGesture(TapGesture().onEnded { model.focusFiles(in: window) })
        .onDisappear { relay.filesSideAnchors.removeAll() }
    }
}

private struct FilePairGrid: View {
    @ObservedObject var workspace: FileWorkspace
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    var relay: CanvasDropRelay
    @Environment(\.windowChrome) private var chrome
    @StateObject private var tabDrag = FileTabDragTracker()
    @State private var ratioDrag: (id: UUID, start: CGFloat)?
    @State private var hoveredDividerID: UUID?

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(origin: .zero, size: geometry.size)
            let frames = PaneLayout.frames(of: workspace.layout, in: rect)
            ZStack(alignment: .topLeading) {
                ForEach(workspace.groupIDs, id: \.self) { id in
                    if let frame = frames[id] {
                        FileEndpointPanel(workspace: workspace, groupID: id, model: model, window: window, relay: relay, tabDrag: tabDrag, width: frame.width)
                            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                            .clipped()
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                ForEach(PaneLayout.dividers(of: workspace.layout, in: rect)) { divider in
                    dividerControl(divider)
                }
                if let zone = tabDrag.zone, !zone.reordering, let frame = frames[zone.group] {
                    let area = PaneLayout.reminder(for: zone.edge, in: frame)
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .fill(chrome.accentFill.opacity(0.65))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(chrome.accent, lineWidth: 2))
                        .frame(width: area.width, height: area.height)
                        .offset(x: area.minX, y: area.minY)
                        .allowsHitTesting(false)
                        .zIndex(5)
                }
            }
        }
    }

    private func dividerControl(_ divider: PaneDivider) -> some View {
        let vertical = divider.axis == .vertical
        let active = hoveredDividerID == divider.id || ratioDrag?.id == divider.id
        let lineWidth = active ? Theme.PaneStyle.dividerActiveLineWidth : Theme.PaneStyle.dividerLineWidth
        return Color.clear
            .frame(width: divider.frame.width, height: divider.frame.height)
            .overlay {
                Rectangle()
                    .fill(active ? chrome.accent : chrome.hairline)
                    .frame(width: vertical ? lineWidth : divider.frame.width,
                           height: vertical ? divider.frame.height : lineWidth)
                    .allowsHitTesting(false)
            }
            .overlay {
                PaneDividerHandle(
                    vertical: vertical,
                    onHover: { inside in
                        if inside {
                            hoveredDividerID = divider.id
                        } else if hoveredDividerID == divider.id {
                            hoveredDividerID = nil
                        }
                    },
                    onDragChanged: { delta in
                        if ratioDrag?.id != divider.id {
                            ratioDrag = (divider.id, workspace.ratio(of: divider.splitID))
                        }
                        guard let drag = ratioDrag, divider.span > 1 else { return }
                        workspace.setSplitRatio(divider.splitID, to: drag.start + delta / divider.span)
                    },
                    onDragEnded: { ratioDrag = nil },
                    onDoubleClick: { workspace.evenOutSplit(divider.splitID) }
                )
            }
            .offset(x: divider.frame.minX, y: divider.frame.minY)
            .zIndex(4)
    }
}

private struct FileEndpointPanel: View {
    @ObservedObject var workspace: FileWorkspace
    var groupID: UUID
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    var relay: CanvasDropRelay
    @ObservedObject var tabDrag: FileTabDragTracker
    var width: CGFloat
    @Environment(\.windowChrome) private var chrome

    private var column: FileColumn? { workspace.groups[groupID]?.active }
    private var local: Bool { groupID == workspace.localGroupID }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: local ? "desktopcomputer" : "server.rack")
                    .font(.system(size: 17)).foregroundStyle(chrome.accent)
                if local {
                    Text(verbatim: column?.title ?? String(localized: "This Mac"))
                        .font(Theme.Font.body.weight(.semibold)).lineLimit(1)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .contextMenu {
                            if let column {
                                Button("Open in Terminal") { workspace.openTerminal([], in: column) }
                                    .disabled(column.directory.isEmpty)
                            }
                        }
                        .accessibilityIdentifier("files.localLocation")
                } else {
                    remoteLocations
                }
                if width >= 320, let column, !column.directory.isEmpty {
                    Text(String(format: String(localized: "%d items"), column.shown.count))
                        .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(height: FileBrowserLayout.tabStripHeight)
            .background(chrome.panelHeader)
            .background(BoundsAnchor { tabDrag.strips[groupID] = AnchorBox($0) })
            .overlay(alignment: .bottom) {
                Rectangle().fill(workspace.focusedColumn?.id == column?.id ? chrome.accent : chrome.hairline).frame(height: 1)
            }
            if let column {
                FileColumnView(workspace: workspace, column: column) { EmptyView() }.id(column.id)
            } else {
                VStack(spacing: Theme.Space.m) {
                    Image(systemName: "server.rack").font(Theme.Font.emptySymbol).foregroundStyle(chrome.tertiary)
                    Text("Choose a server").font(Theme.Font.emptyTitle)

                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(chrome.background)
        .background(BoundsAnchor {
            relay.filesSideAnchors[.group(groupID)] = AnchorBox($0)
            tabDrag.panes[groupID] = AnchorBox($0)
        })
        .background(FilePointerObserver {
            if workspace.focusedGroupID != groupID { workspace.focusGroup(groupID) }
        })
        .onDisappear {
            relay.filesSideAnchors.removeValue(forKey: .group(groupID))
            tabDrag.panes.removeValue(forKey: groupID)
            tabDrag.strips.removeValue(forKey: groupID)
        }
        .overlay {
            if window.filesDropTarget == .group(groupID) {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(chrome.accentFill.opacity(0.65))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(chrome.accent, lineWidth: 2))
                    .overlay { Text("Release to open files").font(Theme.Font.sectionTitle) }
                    .padding(4).allowsHitTesting(false)
            }
        }
    }

    /// Remote endpoints are visible as a horizontal tab row; the sidebar owns local pins.
    private var remoteLocations: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(workspace.groups[groupID]?.tabs ?? []) { location in
                        FileTabButton(workspace: workspace, column: location, groupID: groupID, tabDrag: tabDrag)
                            .id(location.id)
                    }
                    if workspace.groups[groupID]?.tabs.isEmpty == true {
                        Text("Choose a server")
                            .font(Theme.Font.rowMeta)
                            .foregroundStyle(chrome.secondary)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onAppear { if let column { proxy.scrollTo(column.id) } }
            .onChange(of: column?.id) { _, id in
                if tabDrag.draggingID == nil, let id { proxy.scrollTo(id) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("files.remoteLocations")
    }
}

private struct FileTransferQueueView: View {
    @ObservedObject private var queue = FileTransferQueue.shared
    @Environment(\.windowChrome) private var chrome
    @State private var expanded = true

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.Space.s) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    Text("Transfers")
                    if queue.activeCount > 0 { Text(verbatim: "\(queue.activeCount)").foregroundStyle(chrome.accent) }
                }.buttonStyle(FamilyButtonStyle())
                Spacer()
                if queue.jobs.contains(where: { $0.phase == .completed || $0.phase == .cancelled }) {
                    Button("Clear Completed") { queue.clearFinished() }.buttonStyle(FamilyButtonStyle()).foregroundStyle(chrome.secondary)
                }
            }
            .font(Theme.Font.rowMeta.weight(.medium))
            .padding(.horizontal, Theme.Space.m).frame(height: 32)
            if expanded, !queue.jobs.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(queue.jobs.reversed()) { job in row(job) }
                    }
                }.frame(height: min(144, CGFloat(queue.jobs.count) * 48))
            }
        }
        .background(chrome.panelHeader)
        .foregroundStyle(chrome.text)
        .accessibilityIdentifier("files.transferQueue")
    }

    private func row(_ job: FileTransferQueue.Job) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: job.directionSymbol).foregroundStyle(chrome.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: job.name).font(Theme.Font.body).lineLimit(1)
                Text(verbatim: job.sourceDescription + " → " + job.targetDescription)
                    .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if job.phase == .running {
                ProgressView(value: job.progress).frame(width: 100).controlSize(.small)
                Text(verbatim: "\(Int(job.progress * 100))%").monospacedDigit().frame(width: 35, alignment: .trailing)
            } else {
                Text(verbatim: job.error ?? job.phase.title)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 200, alignment: .trailing)
                    .foregroundStyle(job.phase == .failed ? chrome.danger : chrome.secondary)
                    .help(job.error ?? job.phase.title)
            }
            if job.phase.isActive {
                Button { queue.cancel(job.id) } label: { Image(systemName: "xmark.circle") }
                    .disabled(job.phase == .cancelling).help("Cancel Transfer").accessibilityLabel(Text("Cancel Transfer"))
            } else if job.phase.canRetry {
                Button { queue.retry(job.id, window: NSApp.keyWindow) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Retry Transfer").accessibilityLabel(Text("Retry Transfer"))
            } else { Image(systemName: "checkmark.circle").foregroundStyle(chrome.success) }
        }
        .buttonStyle(FamilyButtonStyle()).font(Theme.Font.rowMeta)
        .padding(.horizontal, Theme.Space.m).frame(height: 48)
        .overlay(alignment: .top) { Divider() }
    }
}
