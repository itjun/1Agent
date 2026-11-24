import Foundation

/// 连接状态不参与会话持久化，也不把「进程仍活着」误报成认证成功。
enum TerminalConnectionNotice: Equatable {
    case waiting(Int)
    case connecting(Int)
    case disconnected
    case failed(Int)
    case recovered

}
