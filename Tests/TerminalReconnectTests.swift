import AppKit
@testable import GooseAgent

@main enum TerminalReconnectTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let model = AppModel()
        model.openRemoteTerminal("reconnect-fixture", at: "/tmp", placement: .newTab, beside: UUID(), in: model.mainWindow)
        wait(until: { !model.tabs.isEmpty }, seconds: 5)
        let id = model.tabs.first!.id
        defer { model.closeTab(id) }
        model.terminalDidExit(id, code: 255, lived: 3600)
        wait(until: { model.tabs.first!.reconnectAttempts == 1 }, seconds: 2)
        model.terminalDidExit(id, code: 255, lived: 0.1)
        expect(model.tabs.first!.reconnecting, "短暂的 SSH 传输失败后仍应继续第 2 次重试")
        wait(until: { model.tabs.first!.reconnectAttempts == 2 }, seconds: 4)
        model.terminalDidExit(id, code: 255, lived: 0.1)
        wait(until: { model.tabs.first!.reconnectAttempts == 3 }, seconds: 9)
        model.terminalDidExit(id, code: 255, lived: 0.1)
        expect(model.tabs.first!.connectionNotice == .failed(3), "三次失败后应停止，避免无限重试")
        print("PASS: 短暂失败继续重试，三次失败后停止")
    }

    @MainActor static func wait(until condition: () -> Bool, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        expect(condition(), "等待状态变化超时")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
