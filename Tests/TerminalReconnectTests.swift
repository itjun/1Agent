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
        model.networkDidRecover()
        model.terminalDidExit(id, code: 255, lived: 0.1)
        expect(model.tabs.first!.connectionNotice == .waiting(0), "网络恢复时旧尝试尚未结束，也应在失败后自动开启新一轮")
        wait(until: { model.tabs.first!.reconnectAttempts == 1 }, seconds: 2)
        model.terminalDidExit(id, code: 255, lived: 0.1)
        wait(until: { model.tabs.first!.reconnectAttempts == 2 }, seconds: 4)
        model.terminalDidExit(id, code: 255, lived: 0.1)
        wait(until: { model.tabs.first!.reconnectAttempts == 3 }, seconds: 9)
        model.terminalDidExit(id, code: 255, lived: 0.1)
        expect(model.tabs.first!.connectionNotice == .failed(3), "同一网络下三次失败后应停止，避免无限重试")
        let monitor = NetworkRecoveryMonitor { model.networkDidRecover() }
        let office = NetworkRecoveryMonitor.State(isAvailable: true, configuration: ["en0=office"])
        monitor.receive(office)
        run(for: 2.2)
        expect(model.tabs.first!.connectionNotice == .failed(3), "首次网络快照不应无故刷新重试额度")
        monitor.receive(.init(isAvailable: false, configuration: []))
        monitor.receive(office)
        wait(until: { model.tabs.first!.connectionNotice == .connecting(1) }, seconds: 4)
        expect(!model.tabs.first!.exited, "网络恢复后失败会话应自动启动新一轮连接")
        let generation = model.tabs.first!.generation
        model.networkDidRecover()
        expect(model.tabs.first!.generation == generation, "网络通知不能重复启动正在连接的终端")
        // 未收到远端 shell 报告前，即使进程活过五秒也不能清空失败次数。
        run(for: 5.2)
        expect(model.tabs.first!.reconnectAttempts == 1, "等待认证或连接超时不等于连接稳定")
        model.cancelReconnect(id)
        model.networkDidRecover()
        run(for: 1.2)
        expect(model.tabs.first!.connectionNotice == .disconnected, "用户取消的连接不应被网络恢复重新启动")
        model.reconnect(id)
        model.noteWorkingDirectory("/srv/recovered", forSession: model.tabs.first!.sessionID)
        model.networkDidRecover()
        expect(model.tabs.first!.connectionNotice == .recovered, "已恢复的终端不应被网络通知打断")
        expect(model.tabs.first!.remoteDirectory == "/srv/recovered", "恢复连接应保留远程工作目录")
        model.terminalDidExit(id, code: 255, lived: 0.1)
        model.closeTab(id)
        model.networkDidRecover()
        run(for: 1.2)
        expect(model.tabs.isEmpty, "关闭的终端不能被待执行重试复活")
        monitorTransitions()
        print("PASS: 三次退避重试、网络恢复、取消、关闭、稳定连接与网络事件去重")
    }

    @MainActor static func monitorTransitions() {
        var recoveries = 0
        let monitor = NetworkRecoveryMonitor { recoveries += 1 }
        let home = NetworkRecoveryMonitor.State(isAvailable: true, configuration: ["utun5", "en0=home"])
        let office = NetworkRecoveryMonitor.State(isAvailable: true, configuration: ["utun5", "en0=office"])
        monitor.receive(home)
        monitor.receive(office)
        monitor.receive(office)
        wait(until: { recoveries == 1 }, seconds: 3)
        monitor.receive(office)
        run(for: 2.2)
        expect(recoveries == 1, "相同网络重复通知不能重复恢复")
        monitor.receive(home)
        monitor.receive(.init(isAvailable: false, configuration: []))
        run(for: 2.2)
        expect(recoveries == 1, "网络再次断开应取消待执行的恢复")
        monitor.receive(office)
        wait(until: { recoveries == 2 }, seconds: 3)
        var transient: NetworkRecoveryMonitor? = NetworkRecoveryMonitor { recoveries += 100 }
        transient?.receive(home)
        transient?.receive(office)
        transient = nil
        run(for: 2.2)
        expect(recoveries == 2, "释放监听器应取消待执行的恢复")
    }

    @MainActor static func run(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
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
