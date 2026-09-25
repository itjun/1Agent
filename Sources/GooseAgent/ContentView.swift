import AppKit
import GhosttyTheme
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppShortcuts.revisionKey) private var shortcutsRevision = 0
    @AppStorage(TabPlacement.storageKey) private var tabLayoutRaw = TabPlacement.vertical.rawValue
    @AppStorage(TerminalAppearance.storageKey) private var appearanceRaw = TerminalAppearance.system.rawValue
    @AppStorage(TerminalThemeFamily.storageKey) private var themeFamilyRaw = TerminalThemeFamily.github.rawValue
    @AppStorage("appearance.sidebarCollapsed") private var sidebarCollapsed = false
    @StateObject private var dropRelay = CanvasDropRelay()

    private var tabLayout: TabPlacement {
        TabPlacement(rawValue: tabLayoutRaw) ?? .vertical
    }

    private var appearance: TerminalAppearance {
        TerminalAppearance(rawValue: appearanceRaw) ?? .system
    }

    private var chrome: WindowChrome {
        WindowChrome.resolve(isDark: appearance.isDark(system: colorScheme))
    }

    private var themeFamily: TerminalThemeFamily {
        TerminalThemeFamily.from(raw: themeFamilyRaw)
    }

    var body: some View {
        let _ = shortcutsRevision
        Group {
            if sidebarCollapsed {
                detail
            } else {
                switch tabLayout {
                case .vertical:
                    HStack(spacing: 0) {
                        sidebar
                            .frame(width: 248)
                        Rectangle().fill(chrome.hairline).frame(width: 1)
                        detail
                    }
                case .top:
                    VStack(spacing: 0) {
                        horizontalTabs
                            .padding(.leading, 78)
                            .padding(.top, 8)
                        Rectangle().fill(chrome.hairline).frame(height: 1)
                        detail
                    }
                case .bottom:
                    VStack(spacing: 0) {
                        detail
                        Rectangle().fill(chrome.hairline).frame(height: 1)
                        horizontalTabs
                            .padding(.bottom, 6)
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if sidebarCollapsed {
                HStack(spacing: 8) {
                    windowControls
                    settingsEntry
                        .frame(width: 88)
                }
                .padding(.leading, 78)
                .padding(.top, 10)
            }
        }
        .frame(minWidth: 880, minHeight: 520)
        .background(chrome.background)
        .environment(\.windowChrome, chrome)
        .ignoresSafeArea(edges: .top)
        .preferredColorScheme(appearance.preferredColorScheme)
        .oneagentHideFocusRing()
        .task { model.reloadHosts() }
        .onOpenURL { model.openExternalURL($0) }
        .onAppear {
            TerminalAppearance.migrateLegacyThemeIfNeeded()
            TerminalThemeFamily.migrateIfNeeded()
            GhosttyRuntime.apply(family: themeFamily)
        }
        .onChange(of: themeFamilyRaw) { _, _ in
            GhosttyRuntime.apply(family: themeFamily)
        }
        .sheet(isPresented: $model.hostPickerPresented) {
            HostPicker(model: model)
                .frame(width: SheetLayout.search, height: SheetLayout.sessionBodyHeight)
                .environment(\.windowChrome, chrome)
                .oneagentHideFocusRing()
        }
    }

    private var newTabHelp: String {
        String(format: String(localized: "New Tab (%@)"), AppShortcuts.display(for: .newTab))
    }

    private var closeTabHelp: String {
        String(format: String(localized: "Close Tab (%@)"), AppShortcuts.display(for: .closeTab))
    }

    private var sidebarToggleHelp: String {
        if sidebarCollapsed {
            String(localized: "Show Sidebar")
        } else {
            String(localized: "Hide Sidebar")
        }
    }

    private var windowControls: some View {
        HStack(spacing: 8) {
            Button(action: model.newTab) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(newTabHelp)
            .accessibilityLabel(Text("New Tab"))

            Button {
                sidebarCollapsed.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(sidebarToggleHelp)
            .accessibilityLabel(Text(sidebarToggleHelp))
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Tabs")
                    .font(Theme.sidebarGroupHeader)
                    .foregroundStyle(chrome.text)
                Spacer()
                windowControls
            }
            .padding(.leading, 78)
            .padding(.trailing, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if model.tabs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No open terminals")
                        .font(Theme.sidebarRowTitle)
                        .foregroundStyle(chrome.text)
                    Text(String(format: String(localized: "Press %@ to choose a host."), AppShortcuts.display(for: .newTab)))
                        .font(Theme.sidebarRowMeta)
                        .foregroundStyle(chrome.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.tabs) { tab in
                            tabRow(tab, compact: false)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
            settingsEntry
        }
        .background(BoundsAnchor { dropRelay.sidebarAnchor = $0 })
    }

    private var horizontalTabs: some View {
        HStack(spacing: 6) {
            windowControls
                .padding(.leading, 8)

            if model.tabs.isEmpty {
                Text("No open terminals")
                    .font(Theme.sidebarRowMeta)
                    .foregroundStyle(chrome.secondary)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.tabs) { tab in
                            tabRow(tab, compact: true)
                                .frame(width: 180)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.trailing, 8)
                }
            }
            settingsEntry
                .frame(width: 88)
        }
        .frame(height: 44)
        .background(BoundsAnchor { dropRelay.sidebarAnchor = $0 })
    }

    private var settingsHelp: String {
        String(format: String(localized: "Settings (%@)"), AppShortcuts.display(for: .settings))
    }

    private var settingsEntry: some View {
        Button {
            model.toggleSettings()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                Text("Settings")
                    .font(Theme.sidebarRowTitle)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(chrome.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(model.showingSettings ? chrome.accent.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(settingsHelp)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func tabRow(_ tab: TerminalTab, compact: Bool) -> some View {
        let selected = model.selectedTabID == tab.id && !model.showingSettings
        let host = tab.alias.flatMap { model.host($0) }
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.alias ?? String(localized: "New Tab"))
                    .font(Theme.sidebarRowTitle)
                    .foregroundStyle(chrome.text)
                    .lineLimit(1)
                if !compact, let host, !host.subtitle.isEmpty {
                    Text(host.subtitle)
                        .font(Theme.sidebarRowMeta)
                        .foregroundStyle(chrome.secondary)
                        .lineLimit(1)
                }
                if !compact, tab.exited {
                    Text("Connection closed")
                        .font(Theme.sidebarRowMeta)
                        .foregroundStyle(chrome.danger)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay {
                TabDragHandle(
                    onClick: { model.selectTab(tab.id) },
                    onBegan: { dropRelay.dragBegan(tab.id) },
                    onMoved: { dropRelay.dragMoved(windowPoint: $0) },
                    onEnded: { dropRelay.dragEnded(windowPoint: $0) }
                )
            }
            .help(compact ? (host?.sessionBadge ?? "") : "")

            Button {
                model.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(chrome.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help(closeTabHelp)
            .accessibilityLabel(Text("Close Tab"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFill(selected: selected, tabID: tab.id))
        )
        .background(RowAnchor(id: tab.id, relay: dropRelay))
    }

    private func rowFill(selected: Bool, tabID: UUID) -> Color {
        if model.dropHighlight == .sidebarRow(tabID) || model.dropHighlight == .sidebar {
            return chrome.accent.opacity(0.28)
        }
        return selected ? chrome.accent.opacity(0.16) : Color.clear
    }

    private var detail: some View {
        ZStack {
            TerminalCanvas(
                model: model,
                dropRelay: dropRelay,
                dark: appearance.isDark(system: colorScheme),
                usesCatalogTheme: true
            )
            .opacity(model.showingSettings ? 0 : 1)
            .allowsHitTesting(!model.showingSettings)
            if model.showingSettings {
                SettingsView()
            } else if model.selectedTab == nil {
                VStack(spacing: 8) {
                    Text("No open terminals")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(chrome.text)
                    Text(String(format: String(localized: "Press %@ to choose a host."), AppShortcuts.display(for: .newTab)))
                        .font(.system(size: 13))
                        .foregroundStyle(chrome.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(chrome.background)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(chrome.background)
    }
}

enum SheetLayout {
    static let search: CGFloat = 440
    static let sessionBodyHeight: CGFloat = 520
}

private final class AnchorBox {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}

private final class CanvasDropRelay: ObservableObject {
    var frames: [UUID: CGRect] = [:]
    weak var modelBox: AppModel?
    weak var catcher: PaneDropCatcherView?
    weak var sidebarAnchor: NSView?
    var rowAnchors: [UUID: AnchorBox] = [:]
    var dragTitle = ""

    func dragBegan(_ id: UUID) {
        MainActor.assumeIsolated {
            guard let model = modelBox else { return }
            let alias = model.tabs.first { $0.id == id }?.alias ?? ""
            dragTitle = model.host(alias)?.sessionBadge ?? alias
            model.beginDrag(id)
        }
    }

    func dragMoved(windowPoint: NSPoint) {
        let frames = frames
        let title = dragTitle
        guard let catcher else { return }
        catcher.layoutSubtreeIfNeeded()
        let local = catcher.localPoint(windowPoint)
        let overCanvas = catcher.bounds.contains(local) && catcher.bounds.width > 2
        if overCanvas {
            let zone = MainActor.assumeIsolated { () -> CGRect? in
                guard let model = modelBox, let dragged = model.draggingTabID else { return nil }
                guard let hit = PaneLayout.dropTarget(at: local, frames: frames, dragged: dragged) else {
                    if case .edge = model.dropHighlight { model.dropHighlight = nil }
                    return nil
                }
                let next = TabDropHighlight.edge(hit.0, hit.1)
                if model.dropHighlight != next { model.dropHighlight = next }
                guard let frame = frames[hit.0] else { return nil }
                return PaneLayout.reminder(for: hit.1, in: frame)
            }
            catcher.present(zone: zone, windowPoint: windowPoint, title: title)
            return
        }
        let sidebarHit = sidebarTarget(windowPoint)
        MainActor.assumeIsolated {
            guard let model = modelBox else { return }
            let next: TabDropHighlight? = {
                if let row = sidebarHit { return .sidebarRow(row) }
                if sidebarAnchorContains(windowPoint) { return .sidebar }
                return nil
            }()
            if model.dropHighlight != next { model.dropHighlight = next }
        }
        catcher.present(zone: nil, windowPoint: windowPoint, title: title)
    }

    func dragEnded(windowPoint: NSPoint) {
        let frames = frames
        let local = catcher?.localPoint(windowPoint) ?? .zero
        let overCanvas = catcher.map { $0.bounds.contains(local) && $0.bounds.width > 2 } ?? false
        let sidebarHit = sidebarTarget(windowPoint)
        let onSidebar = sidebarAnchorContains(windowPoint)
        catcher?.hide()
        MainActor.assumeIsolated {
            guard let model = modelBox, let dragged = model.draggingTabID else { return }
            if overCanvas, let hit = PaneLayout.dropTarget(at: local, frames: frames, dragged: dragged) {
                model.dropTab(dragged, onto: hit.0, edge: hit.1)
                return
            }
            if onSidebar || sidebarHit != nil {
                model.receiveSidebarDrop(dragged, before: sidebarHit)
                return
            }
            model.endDrag()
        }
    }

    private func sidebarAnchorContains(_ windowPoint: NSPoint) -> Bool {
        guard let sidebarAnchor, sidebarAnchor.window != nil else { return false }
        let local = sidebarAnchor.convert(windowPoint, from: nil)
        return sidebarAnchor.bounds.contains(local)
    }

    private func sidebarTarget(_ windowPoint: NSPoint) -> UUID? {
        for (id, box) in rowAnchors {
            guard let view = box.view, view.window != nil else { continue }
            let local = view.convert(windowPoint, from: nil)
            if view.bounds.contains(local) { return id }
        }
        return nil
    }
}

/// Drawn above the terminal while a tab is dragged. It does not take clicks.
private final class DropSessionOverlay: NSView {
    let zone = DropZoneView()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(zone)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(rect: CGRect?) {
        guard let rect else {
            zone.isHidden = true
            return
        }
        zone.isHidden = false
        if zone.frame != rect {
            zone.frame = rect
        }
        zone.needsDisplay = true
    }
}

private final class DropZoneView: NSView {
    var accent = NSColor.systemBlue
    var zoneBackground = NSColor.windowBackgroundColor

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        guard rect.width > 2, rect.height > 2 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        zoneBackground.setFill()
        path.fill()
        accent.withAlphaComponent(0.5).setFill()
        path.fill()
        accent.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}

/// Anchor for the terminal area. The visible zone is a separate view above the terminal.
private final class PaneDropCatcherView: NSView {
    weak var relay: CanvasDropRelay?
    let overlay = DropSessionOverlay()
    let chip = DragChipView()
    var accent = NSColor.systemBlue
    var zoneBackground = NSColor.windowBackgroundColor

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit {
        overlay.removeFromSuperview()
        chip.removeFromSuperview()
    }

    func syncAppearance() {
        overlay.zone.accent = accent
        overlay.zone.zoneBackground = zoneBackground
        chip.fill = zoneBackground
    }

    func localPoint(_ windowPoint: NSPoint) -> CGPoint {
        convert(windowPoint, from: nil)
    }

    func present(zone: CGRect?, windowPoint: NSPoint, title: String) {
        guard let content = window?.contentView, bounds.width > 2 else { return }
        let frame = convert(bounds, to: content)
        overlay.frame = frame
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.show(rect: zone)
        let size = DragChipView.size(for: title)
        let cursor = content.convert(windowPoint, from: nil)
        chip.title = title
        chip.frame = CGRect(x: cursor.x + 14, y: cursor.y - size.height - 8, width: size.width, height: size.height)
        chip.needsDisplay = true
        content.addSubview(chip, positioned: .above, relativeTo: nil)
    }

    func hide() {
        overlay.show(rect: nil)
        overlay.removeFromSuperview()
        chip.removeFromSuperview()
    }
}

private struct PaneDropCatcher: NSViewRepresentable {
    var relay: CanvasDropRelay
    var accent: Color
    var background: Color

    func makeNSView(context: Context) -> PaneDropCatcherView {
        let view = PaneDropCatcherView()
        view.relay = relay
        relay.catcher = view
        return view
    }

    func updateNSView(_ view: PaneDropCatcherView, context: Context) {
        view.relay = relay
        relay.catcher = view
        view.accent = NSColor(accent)
        view.zoneBackground = NSColor(background)
        view.syncAppearance()
    }
}

private final class DragChipView: NSView {
    var title = ""
    var fill = NSColor.windowBackgroundColor

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        fill.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (title as NSString).draw(at: origin, withAttributes: attributes)
    }

    static func size(for title: String) -> CGSize {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        return CGSize(width: max(size.width + 20, 44), height: size.height + 10)
    }
}

/// Follows the pointer until mouse-up. A system drag session does not report the landing point reliably.
private final class TabDragHandleView: NSView {
    var onClick: () -> Void = {}
    var onBegan: () -> Void = {}
    var onMoved: (NSPoint) -> Void = { _ in }
    var onEnded: (NSPoint) -> Void = { _ in }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow
        var dragging = false
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: 3600,
            mode: .eventTracking
        ) { event, stop in
            guard let event else {
                stop.pointee = true
                return
            }
            let point = event.locationInWindow
            if event.type == .leftMouseUp {
                if dragging {
                    self.onEnded(point)
                } else {
                    self.onClick()
                }
                stop.pointee = true
                return
            }
            if !dragging, hypot(point.x - start.x, point.y - start.y) >= 6 {
                dragging = true
                self.onBegan()
            }
            if dragging {
                self.onMoved(point)
            }
        }
    }
}

private struct TabDragHandle: NSViewRepresentable {
    var onClick: () -> Void
    var onBegan: () -> Void
    var onMoved: (NSPoint) -> Void
    var onEnded: (NSPoint) -> Void

    func makeNSView(context: Context) -> TabDragHandleView { TabDragHandleView() }

    func updateNSView(_ view: TabDragHandleView, context: Context) {
        view.onClick = onClick
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
    }
}

private final class BoundsAnchorView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct BoundsAnchor: NSViewRepresentable {
    var onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> BoundsAnchorView { BoundsAnchorView() }

    func updateNSView(_ view: BoundsAnchorView, context: Context) {
        onResolve(view)
    }
}

private struct RowAnchor: NSViewRepresentable {
    var id: UUID
    var relay: CanvasDropRelay

    func makeNSView(context: Context) -> BoundsAnchorView { BoundsAnchorView() }

    func updateNSView(_ view: BoundsAnchorView, context: Context) {
        relay.rowAnchors[id] = AnchorBox(view)
    }
}

private struct TerminalCanvas: View {
    /// Room above the terminal text for the host badge, so the two do not share a line.
    static let headerHeight: CGFloat = 44

    @Environment(\.windowChrome) private var chrome
    @ObservedObject var model: AppModel
    var dropRelay: CanvasDropRelay
    var dark: Bool
    var usesCatalogTheme: Bool
    @State private var ratioDrag: (id: UUID, start: CGFloat)?

    var body: some View {
        GeometryReader { geo in
            let root = model.displayRoot()
            let bounds = CGRect(origin: .zero, size: geo.size)
            let frames = root.map { PaneLayout.frames(of: $0, in: bounds) } ?? [:]
            let dividers = root.map { PaneLayout.dividers(of: $0, in: bounds) } ?? []
            let _ = dropRelay.sync(frames: frames, model: model)
            ZStack(alignment: .topLeading) {
                chrome.background
                ForEach(model.tabs.filter { $0.alias != nil }) { tab in
                    let content = frames[tab.id].map(Self.contentFrame)
                    SSHTerminalView(
                        sessionID: tab.sessionID,
                        alias: tab.alias ?? "",
                        environment: model.launchEnvironment,
                        dark: dark,
                        usesCatalogTheme: usesCatalogTheme,
                        onExit: { model.markClosed(tab.id) },
                        onFocus: { model.notePaneFocused(tab.id) }
                    )
                    .id(tab.sessionID)
                    .frame(
                        width: max(content?.width ?? 1, 1),
                        height: max(content?.height ?? 1, 1)
                    )
                    .position(
                        x: content?.midX ?? -1000,
                        y: content?.midY ?? -1000
                    )
                    .opacity(content == nil ? 0 : 1)
                    .allowsHitTesting(content != nil)
                    .accessibilityHidden(content == nil)
                    .zIndex(content == nil ? 0 : 1)
                }
                ForEach(dividers) { divider in
                    dividerControl(divider)
                }
                ForEach(model.tabs.filter { frames[$0.id] != nil }) { tab in
                    if let frame = frames[tab.id] {
                        paneChrome(tab, frame: frame)
                    }
                }
            }
            .overlay {
                PaneDropCatcher(relay: dropRelay, accent: chrome.accent, background: chrome.background)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
            }
        }
    }

    private func dividerControl(_ divider: PaneDivider) -> some View {
        Rectangle()
            .fill(chrome.hairline)
            .frame(width: divider.frame.width, height: divider.frame.height)
            .offset(x: divider.frame.minX, y: divider.frame.minY)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = ratioDrag?.id == divider.id ? ratioDrag!.start : currentRatio(divider.id)
                        if ratioDrag?.id != divider.id {
                            ratioDrag = (divider.id, start)
                        }
                        let delta = divider.axis == .vertical ? value.translation.width : value.translation.height
                        guard divider.span > 1 else { return }
                        model.setSplitRatio(divider.id, to: start + delta / divider.span)
                    }
                    .onEnded { _ in ratioDrag = nil }
            )
            .zIndex(4)
    }

    private func currentRatio(_ id: UUID) -> CGFloat {
        func find(_ node: PaneNode) -> CGFloat? {
            guard case .split(let split) = node else { return nil }
            if split.id == id { return split.ratio }
            return find(split.leading) ?? find(split.trailing)
        }
        guard let layout = model.layout else { return 0.5 }
        return find(layout) ?? 0.5
    }

    @ViewBuilder
    private func paneChrome(_ tab: TerminalTab, frame: CGRect) -> some View {
        let alias = tab.alias ?? ""
        let focused = model.selectedTabID == tab.id
        ZStack {
            chrome.background
            Text(model.host(alias)?.sessionBadge ?? alias)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(chrome.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    TabDragHandle(
                        onClick: { model.selectTab(tab.id) },
                        onBegan: { dropRelay.dragBegan(tab.id) },
                        onMoved: { dropRelay.dragMoved(windowPoint: $0) },
                        onEnded: { dropRelay.dragEnded(windowPoint: $0) }
                    )
                }
                .help(String(localized: "Drag across a pane. The highlighted side is where it splits. Drag back to the sidebar to dock."))
        }
        .frame(width: frame.width, height: Self.headerHeight)
        .position(x: frame.midX, y: frame.minY + Self.headerHeight / 2)
        .zIndex(4)
        if focused, tab.exited {
            Button("Reconnect") { model.reconnect(tab.id) }
                .position(x: frame.midX, y: frame.maxY - 28)
                .zIndex(4)
        }
    }
}

private extension TerminalCanvas {
    static func contentFrame(_ frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX,
            y: frame.minY + headerHeight,
            width: frame.width,
            height: max(frame.height - headerHeight, 1)
        )
    }
}

private extension CanvasDropRelay {
    func sync(frames: [UUID: CGRect], model: AppModel) {
        self.frames = frames
        self.modelBox = model
    }
}

private struct HostPicker: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject var model: AppModel
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [SSHHost] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return model.hosts }
        return model.hosts.filter {
            $0.alias.lowercased().contains(needle) || $0.subtitle.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose a Host")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(chrome.text)
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 12)

            TextField("Search hosts", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
                .onAppear { searchFocused = true }

            if model.configFailed {
                Text("Could not read SSH config.")
                    .font(Theme.sidebarRowMeta)
                    .foregroundStyle(chrome.secondary)
                    .padding(.horizontal, 28)
                Spacer()
            } else if filtered.isEmpty {
                Group {
                    if model.hosts.isEmpty {
                        Text("SSH config has no hosts to connect to.")
                    } else {
                        Text("No matching hosts")
                    }
                }
                .font(Theme.sidebarRowMeta)
                .foregroundStyle(chrome.secondary)
                .padding(.horizontal, 28)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { host in
                            Button {
                                model.openHost(host.alias)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.alias)
                                        .font(Theme.sidebarRowTitle)
                                        .foregroundStyle(chrome.text)
                                    if !host.subtitle.isEmpty {
                                        Text(host.subtitle)
                                            .font(Theme.sidebarRowMeta)
                                            .foregroundStyle(chrome.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.hostPickerPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(chrome.background)
    }
}
