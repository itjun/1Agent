import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdateController()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var unavailableReason = ""
    private(set) var isSparkleRestart = false
    private var isInstallationVetoed = false
    private var controller: SPUStandardUpdaterController?
    private weak var appDelegate: AppDelegate?

    func start(appDelegate: AppDelegate) {
        guard controller == nil else { return }
        self.appDelegate = appDelegate
        AppUpdatePreferences.migrate()
        automaticallyChecksForUpdates = UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks")
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32 else {
            unavailableReason = String(localized: "This build has no update signing key.")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        controller.updater.automaticallyDownloadsUpdates = false
        do { try controller.updater.start() }
        catch { unavailableReason = error.localizedDescription }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ value: Bool) {
        controller?.updater.automaticallyChecksForUpdates = value
        automaticallyChecksForUpdates = value
        UserDefaults.standard.set(value, forKey: "SUEnableAutomaticChecks")
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        !isInstallationVetoed
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        Task { @MainActor in
            await prepareInstallation(operation: { [weak self] in
                guard let appDelegate = self?.appDelegate else { throw CocoaError(.userCancelled) }
                try await appDelegate.prepareForTermination()
            }, installHandler: installHandler, onFailure: { [weak self] in self?.appDelegate?.showExitPreparationError() })
        }
        return true
    }

    func prepareInstallation(operation: @escaping @MainActor () async throws -> Void,
                             installHandler: () -> Void, onFailure: () -> Void) async {
        do {
            try await operation()
            isSparkleRestart = true
            installHandler()
        } catch {
            // 继续回调会先进入 updaterShouldRelaunchApplication；否决后 Sparkle 中止安装。
            isInstallationVetoed = true
            installHandler()
            onFailure()
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        resetInstallationState()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        // Sparkle 的委托否决以 nil error 结束，不一定进入 didAbortWithError。
        if isInstallationVetoed || error != nil { resetInstallationState() }
    }

    private func resetInstallationState() {
        if isSparkleRestart || isInstallationVetoed { appDelegate?.cancelPreparedTermination() }
        isInstallationVetoed = false
        isSparkleRestart = false
    }
}
