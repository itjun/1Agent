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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, window: WindowState, relay: CanvasDropRelay) {
        self.model = model
        self.window = window
        workspace = model.fileWorkspace(for: window)
        self.relay = relay
    }

    var body: some View {
        VStack(spacing: 0) {
            FilePairGrid(workspace: workspace, model: model, window: window, relay: relay, tabDrag: workspace.tabDrag)
                .padding(Theme.Space.s)
            if let remote = workspace.remoteColumn {
                FileColumnTransferControls(workspace: workspace, column: workspace.localColumn, other: remote)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Space.xs)
            }
            FileTransferQueueView()
        }
        .background(chrome.background)
        .allowsHitTesting(workspace.selectedPreviewColumn == nil)
        .accessibilityHidden(workspace.selectedPreviewColumn != nil)
        .overlay { previewOverlay }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: workspace.selectedPreviewColumn?.id)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.files.content")
        .simultaneousGesture(TapGesture().onEnded { model.focusFiles(in: window) })
        .onDisappear { relay.filesSideAnchors.removeAll() }
    }

    @ViewBuilder private var previewOverlay: some View {
        if let column = workspace.selectedPreviewColumn {
            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size)
                let frames = PaneLayout.frames(of: workspace.layout, in: bounds)
                let source = workspace.groupID(of: column).flatMap { frames[$0] } ?? bounds
                let frame = FileBrowserLayout.previewFrame(in: bounds, source: source)
                let leading = frame.minX == bounds.minX
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(FileBrowserLayout.previewScrimOpacity)
                        .contentShape(Rectangle())
                        .onTapGesture { workspace.dismissPreview() }
                        .accessibilityHidden(true)
                    TextPreviewDrawer(column: column, onClose: { workspace.dismissPreview() })
                        .id(column.id)
                        .frame(width: frame.width, height: frame.height)
                        .overlay(alignment: leading ? .trailing : .leading) {
                            Rectangle().fill(chrome.hairline).frame(width: 1)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(leading ? "files.preview.left" : "files.preview.right")
                        .offset(x: frame.minX)
                        .transition(.move(edge: leading ? .leading : .trailing).combined(with: .opacity))
                }
            }
            .clipped()
        }
    }
}

private struct FilePairGrid: View {
    @ObservedObject var workspace: FileWorkspace
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    var relay: CanvasDropRelay
    @ObservedObject var tabDrag: FileTabDragTracker
    @Environment(\.windowChrome) private var chrome
    @State private var ratioDrag: (id: UUID, start: CGFloat)?
    @State private var hoveredDividerID: UUID?

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(origin: .zero, size: geometry.size)
            let frames = PaneLayout.frames(of: workspace.layout, in: rect)
            ZStack(alignment: .topLeading) {
                ForEach(workspace.groupIDs, id: \.self) { id in
                    if let frame = frames[id] {
                        FileEndpointPanel(workspace: workspace, groupID: id, model: model, window: window, relay: relay, tabDrag: tabDrag, width: max(0, frame.width - Theme.Space.s))
                            .padding(.horizontal, Theme.Space.xs)
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
                    .fill(active ? chrome.accent : Color.clear)
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
    @State private var filterFocused = false

    private var column: FileColumn? { workspace.groups[groupID]?.active }
    private var local: Bool { groupID == workspace.localGroupID }

    var body: some View {
        VStack(spacing: 0) {
            if let column {
                FileColumnHeader(workspace: workspace, column: column, width: width, onFilterFocusChange: { filterFocused = $0 }) { endpointHeader }
                FileColumnView(workspace: workspace, column: column, filterFocused: filterFocused).id(column.id)
            } else {
                endpointHeader.padding(.horizontal, Theme.Space.m)
                VStack(spacing: Theme.Space.m) {
                    Image(systemName: SidebarConnectionGroup.remote.symbol).font(Theme.Font.emptySymbol).foregroundStyle(chrome.tertiary)
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

    private var endpointHeader: some View {
        HStack(spacing: Theme.Space.s) {
            if local {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 14))
                    .foregroundStyle(chrome.text)
                Text(verbatim: column?.title ?? String(localized: "This Mac"))
                    .font(Theme.Font.body.weight(.semibold)).lineLimit(1)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .familyContextMenu {
                        guard let column else { return [] }
                        return [FamilyMenuItem(title: String(localized: "Open in Terminal"), enabled: !column.directory.isEmpty, action: {
                            workspace.openTerminal([], in: column)
                        })]
                    }
                    .accessibilityIdentifier("files.localLocation")
            } else {
                remoteLocation
            }
        }
        .frame(height: FileBrowserLayout.tabStripHeight)
    }

    /// Only the pane's current server. Its tabs are listed vertically in the sidebar.
    private var remoteLocation: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "server.rack")
                .font(.system(size: 13))
                .foregroundStyle(chrome.text)
            if let host = column?.fileSystem.host {
                Text(verbatim: host)
                    .font(Theme.Font.body.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(chrome.text)
            } else {
                Text("Choose a server")
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.secondary)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .familyContextMenu {
            guard let column else { return [] }
            return [FamilyMenuItem(title: String(localized: "Open in Terminal"), enabled: !column.directory.isEmpty, action: {
                workspace.openTerminal([], in: column)
            })]
        }
        .accessibilityIdentifier("files.remoteLocation")
    }
}

private struct FileTransferQueueView: View {
    @ObservedObject private var queue = FileTransferQueue.shared
    @Environment(\.windowChrome) private var chrome
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.Space.s) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    Text("Transfers")
                    if queue.activeCount > 0 { Text(verbatim: "\(queue.activeCount)").foregroundStyle(chrome.accent) }
                }.buttonStyle(FamilyButtonStyle())
                    .accessibilityIdentifier("files.transferQueue.toggle")
                Spacer()
                if expanded, queue.jobs.contains(where: { $0.phase == .completed || $0.phase == .cancelled }) {
                    Button("Clear Completed") { queue.clearFinished() }.buttonStyle(FamilyButtonStyle()).foregroundStyle(chrome.secondary)
                }
            }
            .font(Theme.Font.rowMeta.weight(.medium))
            .padding(.horizontal, Theme.Space.m).frame(height: FileBrowserLayout.transferBarHeight)
            if expanded, !queue.jobs.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(queue.jobs.reversed()) { job in row(job) }
                    }
                }.frame(height: min(FileBrowserLayout.transferListMaxHeight, CGFloat(queue.jobs.count) * FileBrowserLayout.transferRowHeight))
                    .accessibilityIdentifier("files.transferQueue.history")
            }
        }
        .background(chrome.panelHeader)
        .foregroundStyle(chrome.text)
        .accessibilityElement(children: .contain)
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
        .padding(.horizontal, Theme.Space.m).frame(height: FileBrowserLayout.transferRowHeight)
        .overlay(alignment: .top) { Divider() }
    }
}
