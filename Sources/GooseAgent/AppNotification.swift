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
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.circle.fill"
        }
    }

    func color(in chrome: WindowChrome) -> Color {
        switch self {
        case .information: SystemTheme.color(.systemBlue, isDark: chrome.isDark)
        case .progress: chrome.secondary
        case .success: chrome.success
        case .warning: chrome.warning
        case .error: chrome.danger
        }
    }
}

struct AppNotificationItem: Identifiable {
    let id: String
    var title: String
    var message: String
    var level: AppNotificationLevel
    var fraction: Double? = nil
    var actionTitle: String? = nil
    var actionHelp: String? = nil
    var action: (() -> Void)? = nil
}

enum AppNotificationLayout {
    static let width: CGFloat = 340
    static let height: CGFloat = 124
    static let inset: CGFloat = 20
    static let cornerRadius: CGFloat = 10
    static let lingerSeconds: Double = 4
}

struct AppNotificationCard: View {
    @Environment(\.windowChrome) private var chrome
    let item: AppNotificationItem
    var onDismiss: () -> Void

    var body: some View {
        let tint = item.level.color(in: chrome)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                if item.level == .progress {
                    ProgressView().controlSize(.small).frame(width: 18, height: 18)
                        .accessibilityLabel("In Progress")
                } else {
                    Image(systemName: item.level.symbol)
                        .font(.system(size: 20)).foregroundStyle(tint)
                        .accessibilityHidden(true)
                }
                Text(verbatim: item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(chrome.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(chrome.secondary)
                .help("Dismiss Notification").accessibilityLabel("Dismiss Notification")
            }
            Text(verbatim: item.message)
                .font(.system(size: 14)).foregroundStyle(tint)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                .help(item.message)
            Spacer(minLength: 0)
            HStack {
                if let fraction = item.fraction {
                    ProgressView(value: min(1, max(0, fraction)))
                        .tint(tint).controlSize(.small)
                        .accessibilityLabel("Transfer Progress")
                }
                Spacer(minLength: 8)
                if let title = item.actionTitle, let action = item.action {
                    Button(action: action) { Text(verbatim: title).font(.system(size: 13)).frame(minHeight: 22) }
                        .buttonStyle(.bordered).controlSize(.regular)
                        .foregroundStyle(chrome.text)
                        .help(item.actionHelp ?? title)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .frame(height: AppNotificationLayout.height)
        .background(chrome.notificationBackground, in: RoundedRectangle(cornerRadius: AppNotificationLayout.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AppNotificationLayout.cornerRadius)
                .strokeBorder(chrome.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app.notification.\(item.level.rawValue)")
    }
}

/// 一次只展示一张；更新同一任务不抢占新通知，关闭后可看到上一条待处理通知。
@MainActor
final class AppNotificationStore: ObservableObject {
    @Published private(set) var items: [AppNotificationItem] = []
    private var dismissed = Set<String>()
    private var expiry: [String: Task<Void, Never>] = [:]
    var current: AppNotificationItem? { items.last }

    func show(_ item: AppNotificationItem, expiresAfter: TimeInterval? = nil, isNewEvent: Bool = true) {
        if isNewEvent { dismissed.remove(item.id) }
        guard !dismissed.contains(item.id) else { return }
        expiry.removeValue(forKey: item.id)?.cancel()
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        else { items.append(item) }
        // 防止后台事件无限积累，保留最近的二十条。
        while items.count > 20 { remove(items[0].id) }
        if let delay = expiresAfter {
            expiry[item.id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self?.remove(item.id)
            }
        }
    }

    func dismiss(_ id: String) {
        dismissed.insert(id)
        remove(id)
    }

    func remove(_ id: String) {
        expiry.removeValue(forKey: id)?.cancel()
        items.removeAll { $0.id == id }
    }

    func reset() {
        for task in expiry.values { task.cancel() }
        expiry.removeAll()
        dismissed.removeAll()
        items.removeAll()
    }
}

/// 独立非激活子窗口保证通知位于 Metal 终端上方，不抢走终端键盘焦点。
@MainActor
final class AppNotificationPresenter: NSObject {
    let store = AppNotificationStore()
    private weak var parent: NSWindow?
    private var panel: NSPanel?
    private var observation: AnyCancellable?

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
    }

    deinit { NotificationCenter.default.removeObserver(self) }

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
        let bounds = parent.contentView.map { parent.convertToScreen($0.convert($0.bounds, to: nil)) } ?? parent.frame
        let width = min(AppNotificationLayout.width, max(1, bounds.width - 2 * AppNotificationLayout.inset))
        panel.setFrame(CGRect(x: bounds.maxX - AppNotificationLayout.inset - width,
                             y: bounds.minY + AppNotificationLayout.inset,
                             width: width, height: AppNotificationLayout.height), display: true)
        if panel.parent !== parent { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    @objc private func close() {
        store.reset()
        if let panel { parent?.removeChildWindow(panel); panel.orderOut(nil) }
    }

    private func makePanel() -> NSPanel {
        let panel = AppNotificationPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("app.notification")
        panel.contentView = NSHostingView(rootView: AppNotificationSurface(store: store))
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

    var body: some View {
        if let item = store.current {
            AppNotificationCard(item: item, onDismiss: { store.dismiss(item.id) })
                .environment(\.windowChrome, WindowChrome.resolve(isDark: appearance.isDark))
                .preferredColorScheme(appearance.interfaceColorScheme)
        }
    }
}

@MainActor
enum AppNotifications {
    private static let presenters = NSMapTable<NSWindow, AppNotificationPresenter>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    static func show(title: String, message: String, level: AppNotificationLevel, in window: NSWindow? = nil) {
        guard let owner = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        presenter(for: owner).store.show(
            AppNotificationItem(id: UUID().uuidString, title: title, message: message, level: level),
            expiresAfter: level == .information || level == .success ? AppNotificationLayout.lingerSeconds : nil)
    }

    static func presenter(for window: NSWindow) -> AppNotificationPresenter {
        if let existing = presenters.object(forKey: window) { return existing }
        let presenter = AppNotificationPresenter(window: window)
        presenters.setObject(presenter, forKey: window)
        return presenter
    }
}
