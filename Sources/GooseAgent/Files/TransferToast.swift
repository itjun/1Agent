import AppKit

/// 文件操作与终端通知共用右下角卡片。每次操作保留自己的窗口和编号，过期进度不会串到新任务。
@MainActor
final class TransferToast {
    static let shared = TransferToast()
    private struct Transfer {
        weak var window: NSWindow?
        var isRunning: Bool
        var lastReport: Date = .distantPast
    }
    private var transfers: [Int: Transfer] = [:]
    private var current = 0

    func begin(_ text: String, in window: NSWindow?) -> Int {
        current += 1
        let owner = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        transfers[current] = Transfer(window: owner, isRunning: true)
        show(current, text: text, level: .progress, fraction: 0)
        return current
    }

    func progress(_ id: Int, _ text: String, fraction: Double) {
        guard let transfer = transfers[id], transfer.isRunning else { return }
        let now = Date()
        guard now.timeIntervalSince(transfer.lastReport) > 0.1 || fraction >= 1 else { return }
        transfers[id]?.lastReport = now
        show(id, text: text, level: .progress, fraction: fraction, isNewEvent: false)
    }

    func finish(_ id: Int, _ text: String) {
        guard transfers[id]?.isRunning == true else { return }
        transfers[id]?.isRunning = false
        let level: AppNotificationLevel = text == String(localized: "Cancelled") ? .information : .success
        show(id, text: text, level: level, expiresAfter: AppNotificationLayout.lingerSeconds)
        transfers[id] = nil
    }

    func fail(_ id: Int?, _ text: String, in window: NSWindow? = nil) {
        let target: Int
        if let id {
            guard transfers[id] != nil else { return }
            target = id
        } else {
            current += 1
            target = current
            transfers[target] = Transfer(window: window ?? NSApp.keyWindow ?? NSApp.mainWindow, isRunning: false)
        }
        show(target, text: text, level: .error)
        transfers[target] = nil
    }

    private func show(_ id: Int, text: String, level: AppNotificationLevel, fraction: Double? = nil,
                      expiresAfter: TimeInterval? = nil, isNewEvent: Bool = true) {
        guard let window = transfers[id]?.window else { return }
        AppNotifications.presenter(for: window).store.show(
            AppNotificationItem(id: "transfer-\(id)", title: String(localized: "Files"), message: text,
                                level: level, fraction: fraction),
            expiresAfter: expiresAfter, isNewEvent: isNewEvent)
    }
}
