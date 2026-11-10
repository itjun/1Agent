import AppKit
import Combine

/// 跟随窗口保存提交状态，切换终端或重建侧栏也不能重复发送。
@MainActor
final class QuickCommandSidebarExecution: ObservableObject {
    @Published private(set) var commandID: UUID?
    @Published var error: String?
    var isSubmitting: Bool { commandID != nil }

    func run(_ request: QuickCommandRunRequest,
             perform: @escaping (QuickCommandRunRequest) async throws -> Void,
             onSuccess: @escaping () -> Void = {}) {
        guard !isSubmitting else { return }
        commandID = request.item.id
        error = nil
        let started = Date()
        Task { @MainActor in
            do { try await perform(request); onSuccess() }
            catch { report(error) }
            // 快速返回也吸收同一次双击的第二下，预览和拖拽共用这一守卫。
            let remaining = NSEvent.doubleClickInterval - Date().timeIntervalSince(started)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            commandID = nil
        }
    }

    func report(_ error: Error) {
        switch error {
        case QuickCommandError.changedTarget:
            self.error = String(localized: "The command or target changed. Open the preview again.")
        case QuickCommandError.unavailable:
            self.error = String(localized: "The current terminal cannot accept a command. Wait for it to finish or clear its input, then try again.")
        default:
            self.error = error.localizedDescription
        }
    }
}
