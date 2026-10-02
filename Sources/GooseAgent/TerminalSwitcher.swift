import AppKit
import Combine
import SwiftUI

/// One open terminal as the switcher shows it: a title and the text on its screen when the switcher opened.
struct SwitcherItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    /// Screen rows with trailing blank rows dropped. Nil when the terminal has no live view yet.
    let lines: [String]?
    /// Widest row, so the thumbnail font fits a whole row across.
    let textColumns: Int
}

/// ⌃⇥ shows every terminal of the main window as a thumbnail and stays open after Control is released.
/// Tab, ⇧Tab and the arrows move the highlight; Return or a click switches to it, Esc keeps the current one.
/// Keys arrive through the app's key monitor (`AppDelegate.handleShortcut`), so the panel never becomes key.
@MainActor
final class TerminalSwitcher: ObservableObject {
    static let shared = TerminalSwitcher()

    @Published private(set) var items: [SwitcherItem] = []
    @Published private(set) var highlighted: UUID?
    /// Columns of the grid on screen, so ↑ and ↓ move by a row.
    var columns = 1
    /// Card and panel frames in `TerminalSwitcherView.space`. Clicks are hit-tested against them because
    /// a click with Control still held after ⌃⇥ never reaches a SwiftUI tap gesture.
    var cardFrames: [UUID: CGRect] = [:]
    var boxFrame: CGRect = .zero

    private weak var model: AppModel?
    private weak var windowState: WindowState?
    private weak var hostWindow: NSWindow?
    private var panel: NSPanel?
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []

    var isOpen: Bool { panel != nil }

    /// Shows the switcher. False when there are fewer than two terminals, so the key reaches the terminal.
    @discardableResult
    func open(model: AppModel, window: WindowState, chord: KeyChord) -> Bool {
        if isOpen {
            move(by: chord.modifiers.contains(.shift) ? -1 : 1)
            return true
        }
        let order = model.sidebarOrder(in: window)
        guard order.count >= 2, let host = MainWindowManager.shared.window(for: window), host.isVisible else {
            return false
        }
        self.model = model
        windowState = window
        hostWindow = host
        items = order.compactMap { id in
            model.tabs.first(where: { $0.id == id }).map(Self.item(for:))
        }
        let current = window.selectedTabID.flatMap { id in items.firstIndex { $0.id == id } } ?? -1
        let step = chord.modifiers.contains(.shift) ? -1 : 1
        highlighted = items[Self.wrapped(current + step, count: items.count)].id
        showPanel(over: host)
        watch(model: model, window: window, host: host)
        return true
    }

    /// Keys while the switcher is open. True when the event is used up.
    func handle(_ event: NSEvent) -> Bool {
        guard isOpen, event.type == .keyDown else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 53: cancel()
        case 36, 76: commit()
        case 48: move(by: shift ? -1 : 1)
        case 123: move(by: -1)
        case 124: move(by: 1)
        case 125: move(by: columns)
        case 126: move(by: -columns)
        default: break
        }
        return true
    }

    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let index = highlighted.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        highlighted = items[Self.wrapped(index + delta, count: items.count)].id
    }

    func commit(_ id: UUID? = nil) {
        let target = id ?? highlighted
        let model = self.model
        let window = windowState
        close()
        guard let target, let model, let window, model.sidebarOrder(in: window).contains(target) else { return }
        model.selectOnly(target, in: window)
    }

    func cancel() {
        close()
    }

    // MARK: - Panel

    private func showPanel(over host: NSWindow) {
        let panel = SwitcherPanel(
            contentRect: Self.panelFrame(over: host),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.appearance = host.appearance
        let chrome = WindowChrome.resolve(isDark: AppearanceDriver.shared.isDark)
        let root = TerminalSwitcherView(switcher: self, chrome: chrome)
            .environment(\.windowChrome, chrome)
            .preferredColorScheme(AppearanceDriver.shared.interfaceColorScheme)
        panel.contentView = FirstMouseHostingView(rootView: root)
        host.addChildWindow(panel, ordered: .above)
        self.panel = panel
    }

    private static func panelFrame(over host: NSWindow) -> NSRect {
        host.frame.insetBy(dx: SwitcherLayout.windowInset, dy: SwitcherLayout.windowInset)
    }

    private func watch(model: AppModel, window: WindowState, host: NSWindow) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: host, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: host, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, let host = self.hostWindow else { return }
                    panel.setFrame(Self.panelFrame(over: host), display: true)
                }
            },
        ]
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return event }
                self.click(event, in: panel)
                return nil
            }
        }
        // Published values fire before they change; the check runs once the new terminals are in place.
        model.$tabs.combineLatest(window.$blocks)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                MainActor.assumeIsolated { self?.dropClosedTerminals() }
            }
            .store(in: &subscriptions)
    }

    /// A card switches to its terminal, the rest of the panel does nothing, anywhere else cancels.
    private func click(_ event: NSEvent, in panel: NSPanel) {
        guard event.window === panel, let view = panel.contentView else {
            cancel()
            return
        }
        var point = view.convert(event.locationInWindow, from: nil)
        if !view.isFlipped {
            point.y = view.bounds.height - point.y
        }
        guard boxFrame.contains(point) else {
            cancel()
            return
        }
        if let hit = cardFrames.first(where: { $0.value.contains(point) }) {
            commit(hit.key)
        }
    }

    private func dropClosedTerminals() {
        guard isOpen, let model, let windowState else { return }
        let open = Set(model.sidebarOrder(in: windowState))
        items.removeAll { !open.contains($0.id) }
        if items.count < 2 {
            cancel()
            return
        }
        if let highlighted, !open.contains(highlighted) {
            self.highlighted = items.first?.id
        }
    }

    private func close() {
        if let panel {
            hostWindow?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        subscriptions = []
        items = []
        highlighted = nil
        cardFrames = [:]
        boxFrame = .zero
    }

    // MARK: - Items

    private static func item(for tab: TerminalTab) -> SwitcherItem {
        var lines: [String]?
        if let text = SSHTerminalRegistry.viewportText(for: tab.sessionID) {
            var rows = text.components(separatedBy: "\n")
            while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                rows.removeLast()
            }
            lines = rows
        }
        let widest = lines?.map(\.count).max() ?? 0
        return SwitcherItem(id: tab.id, title: title(for: tab), lines: lines, textColumns: widest)
    }

    /// Same wording as the sidebar row.
    private static func title(for tab: TerminalTab) -> String {
        if tab.isLocal, let directory = tab.directory {
            return LocalTerminal.displayPath(directory)
        }
        return tab.alias ?? String(localized: "New Tab")
    }

    private static func wrapped(_ index: Int, count: Int) -> Int {
        ((index % count) + count) % count
    }
}

/// Never key: the main window keeps the keyboard and the app's key monitor drives the switcher.
private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel is never key, so the first click must reach the cards instead of only activating the window.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct SwitcherCardFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct SwitcherBoxFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    /// Views that never report keep the default; they must not wipe the panel's frame.
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

struct TerminalSwitcherView: View {
    /// Coordinate space of the whole panel; click hit-testing uses the frames reported in it.
    static let space = "terminalSwitcher"

    @ObservedObject var switcher: TerminalSwitcher
    let chrome: WindowChrome

    var body: some View {
        GeometryReader { proxy in
            let area = CGSize(
                width: proxy.size.width - 2 * SwitcherLayout.panelPadding,
                height: proxy.size.height - 2 * SwitcherLayout.panelPadding - SwitcherLayout.hintHeight
            )
            let grid = SwitcherLayout.grid(count: switcher.items.count, in: area)
            let gridWidth = CGFloat(grid.columns) * grid.cardWidth + CGFloat(grid.columns - 1) * SwitcherLayout.spacing
            let rows = (switcher.items.count + grid.columns - 1) / max(grid.columns, 1)
            let contentHeight = CGFloat(rows) * grid.cardHeight + CGFloat(max(rows - 1, 0)) * SwitcherLayout.spacing
            let gridHeight = min(contentHeight, max(area.height, 0))
            ZStack {
                VStack(spacing: 0) {
                    cards(grid: grid, width: gridWidth, height: gridHeight)
                    hint
                }
                .padding(SwitcherLayout.panelPadding)
                .background(
                    RoundedRectangle(cornerRadius: SwitcherLayout.panelCornerRadius, style: .continuous)
                        .fill(chrome.elevated.opacity(0.97))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SwitcherLayout.panelCornerRadius, style: .continuous)
                        .stroke(chrome.hairline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
                .background(GeometryReader { box in
                    Color.clear.preference(key: SwitcherBoxFrameKey.self, value: box.frame(in: .named(Self.space)))
                })
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(SwitcherCardFramesKey.self) { switcher.cardFrames = $0 }
            .onPreferenceChange(SwitcherBoxFrameKey.self) { switcher.boxFrame = $0 }
            .onAppear { switcher.columns = grid.columns }
            .onChange(of: grid.columns) { _, columns in switcher.columns = columns }
        }
    }

    private func cards(grid: SwitcherLayout.Grid, width: CGFloat, height: CGFloat) -> some View {
        let columns = Array(
            repeating: GridItem(.fixed(grid.cardWidth), spacing: SwitcherLayout.spacing, alignment: .top),
            count: grid.columns
        )
        return ScrollViewReader { reader in
            ScrollView(.vertical, showsIndicators: grid.scrolls) {
                LazyVGrid(columns: columns, spacing: SwitcherLayout.spacing) {
                    ForEach(switcher.items) { item in
                        SwitcherCard(
                            item: item,
                            grid: grid,
                            highlighted: item.id == switcher.highlighted,
                            chrome: chrome
                        )
                        .id(item.id)
                        .background(GeometryReader { card in
                            Color.clear.preference(
                                key: SwitcherCardFramesKey.self,
                                value: [item.id: card.frame(in: .named(Self.space))]
                            )
                        })
                    }
                }
            }
            .scrollDisabled(!grid.scrolls)
            .frame(width: width, height: height)
            .onAppear {
                if let id = switcher.highlighted { reader.scrollTo(id) }
            }
            .onChange(of: switcher.highlighted) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { reader.scrollTo(id) }
            }
        }
    }

    private var hint: some View {
        Text("Return or click to switch · Esc to cancel")
            .font(Theme.Font.rowMeta)
            .foregroundStyle(chrome.tertiary)
            .frame(height: SwitcherLayout.hintHeight, alignment: .bottom)
    }
}

private struct SwitcherCard: View {
    let item: SwitcherItem
    let grid: SwitcherLayout.Grid
    let highlighted: Bool
    let chrome: WindowChrome
    @State private var hovered = false

    private var fill: Color {
        if highlighted {
            return chrome.accentFill
        }
        return hovered ? chrome.hairline.opacity(0.5) : Color.clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SwitcherLayout.titleSpacing) {
            Text(verbatim: item.title)
                .font(Theme.Font.rowMeta.weight(highlighted ? .semibold : .regular))
                .foregroundStyle(highlighted ? chrome.text : chrome.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: grid.thumbnailWidth, height: SwitcherLayout.titleHeight, alignment: .leading)
            thumbnail
        }
        .padding(SwitcherLayout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: SwitcherLayout.cardCornerRadius, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SwitcherLayout.cardCornerRadius, style: .continuous)
                .stroke(highlighted ? chrome.accent : Color.clear, lineWidth: SwitcherLayout.highlightLineWidth)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    /// The terminal's own typeface with the bundled Nerd Font symbols behind it, so prompt icons and
    /// powerline separators draw as they do in the terminal instead of as missing-glyph boxes.
    private static func terminalFont(size: CGFloat) -> Font {
        let symbols = NSFontDescriptor(fontAttributes: [.family: TerminalDefaults.symbolFallbackFamily])
        let base = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: TerminalFontSettings.family]), size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [symbols]])
        let font = NSFont(descriptor: descriptor, size: size) ?? base
        return Font(font as CTFont)
    }

    private var thumbnail: some View {
        let width = grid.thumbnailWidth
        let height = grid.thumbnailHeight
        let fontSize = SwitcherLayout.thumbnailFontSize(width: width, textColumns: item.textColumns)
        let visibleRows = max(1, Int(height / (fontSize * SwitcherLayout.lineHeightRatio)))
        return ZStack(alignment: .topLeading) {
            chrome.background
            if let lines = item.lines {
                Text(verbatim: lines.suffix(visibleRows).joined(separator: "\n"))
                    .font(Self.terminalFont(size: fontSize))
                    .foregroundStyle(chrome.text)
                    .fixedSize()
                    .padding(fontSize * 0.5)
            } else {
                Text("Not started")
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.tertiary)
                    .frame(width: width, height: height)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: SwitcherLayout.thumbnailCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SwitcherLayout.thumbnailCornerRadius, style: .continuous)
                .stroke(chrome.hairline, lineWidth: 1)
        )
    }
}
