import Foundation

/// 通知状态不参与会话持久化，也不把「进程仍活着」误报成认证成功。
enum TerminalConnectionNotice: Equatable {
    case waiting(Int)
    case connecting(Int)
    case disconnected
    case failed(Int)
    case recovered

    @MainActor
    func notification(for tab: TerminalTab, model: AppModel) -> AppNotificationItem {
        let level: AppNotificationLevel
        let message: String
        switch self {
        case .waiting:
            level = .warning
            message = String(localized: "Connection interrupted, waiting to retry")
        case .connecting(let attempt):
            level = .progress
            message = attempt > 0
                ? String(format: String(localized: "Reconnecting (%lld/%lld)"), attempt, AppModel.maxAutoReconnectAttempts)
                : String(localized: "Reconnecting…")
        case .disconnected:
            level = .warning
            message = tab.isLocal ? String(localized: "Terminal Exited") : String(localized: "Connection closed")
        case .failed(let attempts):
            level = .error
            message = attempts > 0
                ? String(format: String(localized: "Reconnection failed after %lld attempts"), attempts)
                : String(localized: "Unable to connect")
        case .recovered:
            level = .success
            message = String(localized: "Connection restored")
        }
        var item = AppNotificationItem(id: "connection-\(tab.id)", title: model.sessionTitle(tab), message: message, level: level)
        switch self {
        case .connecting:
            item.actionTitle = String(localized: "Cancel")
            item.action = { [weak model] in model?.cancelReconnect(tab.id) }
        case .waiting, .disconnected, .failed:
            item.actionHelp = AppShortcuts.display(for: .reconnect)
            item.actionTitle = tab.isLocal ? String(localized: "Reopen Terminal") : String(localized: "Reconnect")
            item.action = { [weak model] in
                guard let model, let current = model.tabs.first(where: { $0.id == tab.id }), current.exited else { return }
                if current.isLocal { model.reopenLocalTerminal(current.id) }
                else { model.reconnect(current.id) }
            }
        case .recovered: break
        }
        return item
    }
}
