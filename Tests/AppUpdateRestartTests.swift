import AppKit
import Foundation
@testable import GooseAgent

/// 用真实更新控制器验证异步退出准备和重启标记。
@MainActor
final class RestartTestDelegate: NSObject, NSApplicationDelegate {
    private var didFinishPreparing = false
    private let owner: AppDelegate

    init(owner: AppDelegate) {
        self.owner = owner
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdateController.shared.start(appDelegate: owner)
        Task { @MainActor in
            AppUpdateController.shared.restart(at: Bundle.main.bundlePath)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard owner.model.isRestarting, owner.relaunchBundlePath == Bundle.main.bundlePath else {
            fputs("FAIL: updater did not prepare the owning app delegate to relaunch\n", stderr)
            exit(1)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            didFinishPreparing = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard didFinishPreparing else {
            fputs("FAIL: app exited without completing asynchronous termination preparation\n", stderr)
            exit(1)
        }
        print("PASS: updater restart waits for asynchronous termination preparation")
        fflush(stdout)
    }
}

@main
enum AppUpdateRestartTests {
    @MainActor static func main() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            fputs("FAIL: updater restart stalled waiting for termination\n", stderr)
            exit(1)
        }
        UserDefaults.standard.register(defaults: ["migration.from1Agent.done": true])
        let owner = AppDelegate()
        let delegate = RestartTestDelegate(owner: owner)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
        withExtendedLifetime(delegate) {}
    }
}
