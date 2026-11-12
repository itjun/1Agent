import AppKit
import Sparkle
@testable import GooseAgent

@main
enum AppUpdateControllerTests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        let controller = AppUpdateController()
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: controller)
        var installed = 0
        var rejected = 0
        var saved = false
        await controller.prepareInstallation(operation: {
            try await Task.sleep(for: .milliseconds(20))
            saved = true
        }, installHandler: {
            precondition(saved)
            if controller.updaterShouldRelaunchApplication(updater) { installed += 1 }
        }, onFailure: { fatalError("Unexpected failure") })
        precondition(installed == 1 && controller.isSparkleRestart)
        let failure = AppUpdateController()
        await failure.prepareInstallation(operation: { throw CocoaError(.fileWriteNoPermission) }, installHandler: {
            if failure.updaterShouldRelaunchApplication(updater) { installed += 1 }
            else { rejected += 1 }
        }, onFailure: { rejected += 1 })
        precondition(installed == 1 && rejected == 2 && !failure.isSparkleRestart)
        failure.updater(updater, didFinishUpdateCycleFor: .updates, error: nil)
        precondition(failure.updaterShouldRelaunchApplication(updater))
        print("PASS: Sparkle installation waits for saved logs; failed save vetoes installation; abort permits retry")
    }
}
