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
    @Environment(\.isShellTransparent) private var isShellTransparent

    init(model: AppModel, window: WindowState, relay: CanvasDropRelay) {
        self.model = model
        self.window = window
        workspace = model.fileWorkspace(for: window)
        self.relay = relay
    }

    var body: some View {
        FilePairGrid(workspace: workspace, model: model, window: window, relay: relay, tabDrag: workspace.tabDrag)
        .padding(.horizontal, 0)
        .padding(.vertical, 0)
        .background(Color.clear)
        .overlay(alignment: .bottom) { TransferStatusBar(window: window).allowsHitTesting(false) }
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
    @ObservedObject var tabDrag: FileTabDragTracker
    @Environment(\.windowChrome) private var chrome
    @Environment(\.isShellTransparent) private var isShellTransparent
    @Environment(\.workspaceTitlebarLeadingInset) private var titlebarLeadingInset
    @State private var ratioDrag: (id: UUID, start: CGFloat)?
    @State private var hoveredDividerID: UUID?

    var body: some View {
        GeometryReader { geometry in
            let panelInset: CGFloat = 0
            let rect = CGRect(origin: .zero, size: geometry.size)
            let frames = ShellLayout.paneFrames(of: workspace.layout, in: rect, isFloating: isShellTransparent)
            ZStack(alignment: .topLeading) {
                ForEach(workspace.groupIDs, id: \.self) { id in
                    if let frame = frames[id] {
                        FileEndpointWithPreview(workspace: workspace, groupID: id, model: model, window: window, relay: relay, tabDrag: tabDrag, width: max(0, frame.width - panelInset * 2), showsHeader: !window.presentation.fullFilesWorkspace || frame.minY > 1)
                            .environment(\.workspaceTitlebarLeadingInset, frame.minX < 1 && frame.minY < 1 ? titlebarLeadingInset : 0)
                            .padding(.horizontal, panelInset)
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
        let lineWidth = Theme.PaneStyle.dividerLineWidth
        return Color.clear
            .frame(width: divider.frame.width, height: divider.frame.height)
            .overlay {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
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

/// 每个文件面板独立预览：本机向右展开，远程向左展开，卡片靠近中间。
private struct FileEndpointWithPreview: View {
    @ObservedObject var workspace: FileWorkspace
    var groupID: UUID
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    var relay: CanvasDropRelay
    @ObservedObject var tabDrag: FileTabDragTracker
    var width: CGFloat
    var showsHeader = true
    @State private var previewWidth = WorkspacePreviewLayout.defaultWidth
    @State private var previewDragStart: Double?
    @State private var isPreviewEqualSplit = false

    private var column: FileColumn? { workspace.groups[groupID]?.active }

    var body: some View {
        let isPreviewOpen = column?.preview != nil
        let isPreviewLeading = column?.isRemote == true
        let cardWidth = WorkspacePreviewLayout.visibleWidth(available: width,
            isOpen: isPreviewOpen, preferred: previewWidth, isEqualSplit: isPreviewEqualSplit)
        let gap = cardWidth > 0 ? ShellLayout.workspaceInset : 0
        let listWidth = max(0, width - cardWidth - gap)
        ZStack(alignment: .leading) {
            FileEndpointPanel(workspace: workspace, groupID: groupID, model: model, window: window,
                              relay: relay, tabDrag: tabDrag, width: listWidth, showsHeader: showsHeader)
                .frame(width: listWidth)
                .offset(x: isPreviewLeading ? cardWidth + gap : 0)
            if let column, isPreviewOpen, cardWidth > 0 {
                TextPreviewDrawer(column: column, onClose: { column.preview = nil }, isWorkspaceCard: true)
                    .id(column.id)
                    .frame(width: cardWidth)
                    .modifier(FloatingContentSurface())
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("files.preview.\(column.id)")
                    .offset(x: isPreviewLeading ? 0 : listWidth + gap)
                    .simultaneousGesture(TapGesture().onEnded { workspace.focus(column) })
                PaneDividerHandle(vertical: true, onHover: { _ in }, onDragChanged: { delta in
                    if previewDragStart == nil { previewDragStart = Double(cardWidth) }
                    isPreviewEqualSplit = false
                    let growth = isPreviewLeading ? delta : -delta
                    previewWidth = WorkspacePreviewLayout.storedWidth((previewDragStart ?? Double(cardWidth)) + growth)
                }, onDragEnded: { previewDragStart = nil }, onDoubleClick: {
                    isPreviewEqualSplit = true
                })
                .frame(width: 6)
                .background(alignment: .center) { Divider() }
                .offset(x: (isPreviewLeading ? cardWidth : listWidth) - 2.5)
                .accessibilityLabel(Text("Resize File Preview"))
            }
        }
        .frame(width: width, alignment: .leading)
        .onChange(of: isPreviewOpen) { _, _ in
            previewWidth = WorkspacePreviewLayout.defaultWidth
            previewDragStart = nil
            isPreviewEqualSplit = false
        }
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
    var showsHeader = true
    @Environment(\.windowChrome) private var parentChrome
    @Environment(\.isShellTransparent) private var isShellTransparent

    private var column: FileColumn? { workspace.groups[groupID]?.active }
    private var local: Bool { groupID == workspace.localGroupID }

    private var chrome: WindowChrome {
        parentChrome
    }

    var body: some View {
        VStack(spacing: 0) {
            if let column {
                if showsHeader {
                    FileColumnHeader(workspace: workspace, column: column, width: width) {
                        FileEndpointTitle(workspace: workspace, column: column)
                    }
                }
                FileColumnView(workspace: workspace, column: column).id(column.id)
            } else {
                VStack(spacing: Theme.Space.m) {
                    Image(systemName: SidebarConnectionGroup.remote.symbol).font(Theme.Font.emptySymbol).foregroundStyle(chrome.tertiary)
                    Text("Choose a server").font(Theme.Font.emptyTitle)

                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .modifier(FloatingContentSurface())
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
        .environment(\.windowChrome, chrome)
    }

}

/// 文件标题与操作进入窗口原生通栏，横向位置跟随下面的面板分隔。
struct FilesWorkspaceToolbar: View {
    @ObservedObject var workspace: FileWorkspace
    var contentWidth: CGFloat
    var contentLeadingInset: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let frames = ShellLayout.paneFrames(of: workspace.layout,
                in: CGRect(x: 0, y: 0, width: max(contentWidth, geometry.size.width), height: 100), isFloating: false)
            ZStack(alignment: .leading) {
                ForEach(workspace.groupIDs, id: \.self) { id in
                    if let frame = frames[id], frame.minY < 1 {
                        let start = max(0, frame.minX - contentLeadingInset)
                        let end = min(geometry.size.width, frame.maxX - contentLeadingInset)
                        let width = max(0, end - start)
                        Group {
                            if let column = workspace.groups[id]?.active {
                                FileColumnHeader(workspace: workspace, column: column, width: width, isWindowToolbar: true) {
                                    FileEndpointTitle(workspace: workspace, column: column)
                                }
                            } else {
                                Label("Choose a server", systemImage: "cloud")
                                    .labelStyle(.titleAndIcon)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(width: width, height: geometry.size.height)
                        .offset(x: start)
                    }
                }
            }
        }
    }
}

private struct FileEndpointTitle: View {
    @ObservedObject var workspace: FileWorkspace
    @ObservedObject var column: FileColumn

    var body: some View {
        Label {
            Text(verbatim: column.title).font(.headline).lineLimit(1)
        } icon: {
            Image(systemName: column.isRemote ? "cloud" : "laptopcomputer")
        }
        .labelStyle(.titleAndIcon)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .familyContextMenu {
            [FamilyMenuItem(title: String(localized: "Open in Terminal"), enabled: !column.directory.isEmpty, action: {
                workspace.openTerminal([], in: column)
            })]
        }
        .accessibilityIdentifier(column.isRemote ? "files.remoteLocation" : "files.localLocation")
    }
}
