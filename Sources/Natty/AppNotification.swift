import AppKit
import Combine
import SwiftUI

/// 应用内通知共用语义色；强调色设置不会把信息蓝改成其他颜色。
enum AppNotificationLevel: String, CaseIterable {
    case information, progress, success, warning, error

    var symbol: String {
        switch self {
        case .information: "info.circle.fill"
        case .progress: "arrow.triangle.2.circlepath"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .error: "exclamationmark.circle.fill"
        }
    }

    func colors(in chrome: WindowChrome) -> (icon: Color, background: Color) {
        let pair: (UInt32, UInt32)
        switch self {
        case .information: pair = chrome.isDark ? (0x699EF5, 0x1B2F51) : (0x0052D9, 0xF2F3FF)
        case .success: pair = chrome.isDark ? (0x46BF96, 0x193A2A) : (0x2BA471, 0xE3F9E9)
        case .warning: pair = chrome.isDark ? (0xE8935C, 0x4F2A1D) : (0x954500, 0xFFF1E9)
        case .error: pair = chrome.isDark ? (0xEC888E, 0x472324) : (0xAD352F, 0xFFF0ED)
        case .progress: return (chrome.secondary, chrome.notificationBackground)
        }
        return (Color(nsColor: Theme.hex(pair.0)), Color(nsColor: Theme.hex(pair.1)))
    }
}

struct AppNotificationItem: Identifiable {
    let id: String
    var title: String
    var message: String
    var level: AppNotificationLevel
    var detail: String? = nil
    var fraction: Double? = nil
    var actionTitle: String? = nil
    var actionHelp: String? = nil
    var action: (() -> Void)? = nil
    var terminalSessionID: String? = nil

    var text: String {
        [title, message].map { part in
            var line = part.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            while let last = line.last, "，,。.!！?？:：;；…".contains(last) || last.isWhitespace {
                line.removeLast()
            }
            return line
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

enum AppNotificationLayout {
    static let maxWidth: CGFloat = 560
    static let inset: CGFloat = 16
    static let lingerSeconds: TimeInterval = 3
    static let fadeSeconds: TimeInterval = 0.2
}

struct AppNotificationCard: View {
    @Environment(\.windowChrome) private var chrome
    let item: AppNotificationItem
    var onDismiss: () -> Void

    var body: some View {
        let colors = item.level.colors(in: chrome)
        HStack(spacing: 8) {
            if item.level == .progress {
                ProgressView().controlSize(.small).frame(width: 16)
                    .accessibilityLabel("In Progress")
            } else {
                Image(systemName: item.level.symbol)
                    .font(.system(size: 16)).foregroundStyle(colors.icon)
                    .accessibilityHidden(true)
            }
            Text(verbatim: item.text)
                .font(Theme.Font.body).foregroundStyle(chrome.text)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .help(item.detail ?? item.text)
            if let fraction = item.fraction {
                ProgressView(value: min(1, max(0, fraction)))
                    .frame(width: 56).controlSize(.small)
                    .accessibilityLabel("Transfer Progress")
            }
            if let title = item.actionTitle, let action = item.action {
                Button(action: action) { Text(verbatim: title) }
                    .controlSize(.small).help(item.actionHelp ?? title)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 12))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(chrome.secondary)
            .help("Dismiss Notification").accessibilityLabel("Dismiss Notification")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(colors.background, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app.notification.\(item.level.rawValue)")
    }
}

@MainActor
final class AppNotificationStore: ObservableObject {
    @Published private(set) var current: AppNotificationItem?
    @Published private(set) var isFading = false
    private var expiry: Task<Void, Never>?
    private var delay: TimeInterval?
    private var isHovered = false

    func show(_ item: AppNotificationItem, expiresAfter: TimeInterval? = nil, isNewEvent: Bool = true) {
        // 新通知占用同一位置 旧传输的进度不能让已被替换或关闭的提醒再次出现
        guard isNewEvent || current?.id == item.id else { return }
        current = item
        delay = expiresAfter ?? (item.level == .progress ? nil : AppNotificationLayout.lingerSeconds)
        scheduleExpiry()
    }

    func setHovered(_ hovered: Bool) {
        guard current != nil, isHovered != hovered else { return }
        isHovered = hovered
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        isFading = false
        guard !isHovered, let delay else { return }
        expiry = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                self?.isFading = true
                try await Task.sleep(for: .seconds(AppNotificationLayout.fadeSeconds))
                self?.reset()
            } catch { return }
        }
    }

    func dismiss(_ id: String) {
        if current?.id == id { reset() }
    }

    func reset() {
        expiry?.cancel()
        expiry = nil
        delay = nil
        isHovered = false
        isFading = false
        current = nil
    }
}

/// 独立非激活子窗口保证通知位于 Metal 终端上方，不抢走终端键盘焦点。
@MainActor
final class AppNotificationPresenter: NSObject {
    let store = AppNotificationStore()
    private weak var parent: NSWindow?
    private var panel: NSPanel?
    private var observation: AnyCancellable?
    private var windowObservation: AnyCancellable?
    private var host: NSHostingController<AppNotificationSurface>?

    init(window: NSWindow) {
        parent = window
        super.init()
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(layout), name: name, object: window)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(close), name: NSWindow.willCloseNotification, object: window)
        observation = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        }
        windowObservation = MainWindowManager.shared.state(for: window)?.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc func layout() {
        guard let parent, store.current != nil else {
            if let panel { parent?.removeChildWindow(panel); panel.orderOut(nil) }
            return
        }
        guard parent.isVisible, !parent.isMiniaturized else {
            panel?.orderOut(nil)
            return
        }
        let panel = panel ?? makePanel()
        let bounds = parent.convertToScreen(parent.contentLayoutRect)
        let maxWidth = min(AppNotificationLayout.maxWidth, max(1, bounds.width - 2 * AppNotificationLayout.inset))
        guard let host else { return }
        let size = host.sizeThatFits(in: CGSize(width: maxWidth, height: bounds.height))
        let width = min(ceil(size.width), maxWidth)
        let height = ceil(size.height)
        let state = MainWindowManager.shared.state(for: parent)
        let navigationHeight = state?.section == .files ? FileBrowserLayout.navigationHeight : 0
        let top = bounds.maxY - navigationHeight - AppNotificationLayout.inset
        panel.setFrame(CGRect(x: bounds.midX - width / 2, y: top - height, width: width, height: height), display: true)
        if panel.parent !== parent { parent.addChildWindow(panel, ordered: .above) }
        if !panel.isVisible { panel.orderFront(nil) }
    }

    @objc private func close() {
        store.reset()
        if let panel { parent?.removeChildWindow(panel); panel.orderOut(nil) }
    }

    private func makePanel() -> NSPanel {
        let panel = AppNotificationPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("app.notification")
        let host = NSHostingController(rootView: AppNotificationSurface(store: store))
        host.sizingOptions = []
        panel.contentViewController = host
        self.host = host
        self.panel = panel
        return panel
    }

}

private final class AppNotificationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct AppNotificationSurface: View {
    @ObservedObject var store: AppNotificationStore
    @ObservedObject private var appearance = AppearanceDriver.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false

    var body: some View {
        if let item = store.current {
            AppNotificationCard(item: item, onDismiss: { store.dismiss(item.id) })
                .environment(\.windowChrome, WindowChrome.resolve(isDark: appearance.isDark))
                .preferredColorScheme(appearance.interfaceColorScheme)
                .onHover { store.setHovered($0) }
                .opacity(isPresented && !store.isFading ? 1 : 0)
                .onAppear {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.28)) { isPresented = true }
                }
                .onDisappear { isPresented = false }
                .animation(store.isFading && !reduceMotion ? .easeIn(duration: AppNotificationLayout.fadeSeconds) : nil,
                           value: store.isFading)
        }
    }
}

@MainActor
enum AppNotifications {
    private static let presenters = NSMapTable<NSWindow, AppNotificationPresenter>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    static func show(title: String, message: String, level: AppNotificationLevel, in window: NSWindow? = nil) {
        guard let owner = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        presenter(for: owner).store.show(
            AppNotificationItem(id: UUID().uuidString, title: "", message: title.isEmpty ? message : title,
                                level: level, detail: message))
    }

    static func presenter(for window: NSWindow) -> AppNotificationPresenter {
        if let existing = presenters.object(forKey: window) { return existing }
        let presenter = AppNotificationPresenter(window: window)
        presenters.setObject(presenter, forKey: window)
        return presenter
    }
}
