import AppKit
import Foundation
import SwiftUI
import UserNotifications

struct AppUpdateSnapshot: Equatable {
    var enabled = true
    var disabledReason = ""
    var devBuild = false
    var current = ""
    var status = AppUpdateStatus.idle
    var hasUpdate = false
    var mandatory = false
    var latest = ""
    var minSupported = ""
    var notes = ""
    var size: Int64 = 0
    var downloaded: Int64 = 0
    var total: Int64 = 0
    var error = ""
    var lastChecked = ""
    var releaseURL = ""
    var checkFailed = false
    var prompt = false
    var autoCheck = true
    var skippedVersion = ""
}

@MainActor
final class AppUpdateController: ObservableObject {
    static let shared = AppUpdateController()

    @Published private(set) var state = AppUpdateSnapshot()

    private var client: AppUpdateClient
    private var manifest: AppUpdateManifest?
    private var prefs = AppUpdatePrefs()
    private var started = false
    private var lastAttempt = Date.distantPast
    private var netFailNotified = false
    private var checkLoop: Task<Void, Never>?
    private var automaticCheck: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private let currentBase: String
    private let devBuild: Bool

    private init() {
        let directory = AppUpdatePrefs.directory()
        prefs = AppUpdatePrefs.load(directory: directory)
        var baseURL = AppUpdate.defaultBaseURL
        var rawVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        if let override = ProcessInfo.processInfo.environment["ONEAGENT_UPDATE_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            baseURL = override
            if let current = ProcessInfo.processInfo.environment["ONEAGENT_UPDATE_CURRENT_VERSION"]?.trimmingCharacters(in: .whitespacesAndNewlines), !current.isEmpty {
                rawVersion = current
            }
        }
        let parsed = AppVersionParser.parseCurrent(rawVersion)
        currentBase = parsed.base
        devBuild = parsed.dev
        client = AppUpdateClient(baseURL: baseURL, publicKey: AppUpdate.publicKey, directory: directory)
        state.current = rawVersion
        state.devBuild = parsed.dev
        state.autoCheck = prefs.autoCheck
        state.skippedVersion = prefs.skippedVersion
        state.releaseURL = baseURL.hasSuffix("/download") ? String(baseURL.dropLast("/download".count)) : baseURL
        if baseURL.isEmpty {
            state.enabled = false
            state.disabledReason = AppUpdateFailure.noSource.message
        } else if AppUpdateCrypto.verify(publicKey: AppUpdate.publicKey, data: Data(), signatureText: Data("".utf8)) == .badPublicKey {
            state.enabled = false
            state.disabledReason = AppUpdateFailure.badPublicKey.message
        } else if !parsed.ok {
            state.enabled = false
            state.disabledReason = AppUpdateFailure.incomparableVersion.message
        } else if AppVersionParser.platformKey().isEmpty {
            state.enabled = false
            state.disabledReason = AppUpdateFailure.unsupportedPlatform.message
        } else if case .failure(let error) = AppUpdateInstall.currentBundle() {
            state.enabled = false
            state.disabledReason = error.message
        }
    }

    func start() {
        if started { return }
        started = true
        AppUpdateInstall.cleanup()
        if !state.enabled { return }
        if case .success(let cached) = client.loadCached() {
            apply(cached)
            if prefs.autoCheck && state.mandatory {
                state.prompt = true
                presentUpdate()
            }
        }
        startAutomaticChecks()
    }

    private func startAutomaticChecks() {
        guard started, state.enabled, prefs.autoCheck, !devBuild else { return }
        checkLoop?.cancel()
        checkLoop = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(AppUpdate.firstCheckDelay * 1_000_000_000))
            } catch { return }
            while !Task.isCancelled {
                await self?.check(manual: false)
                let jitter = Double.random(in: -AppUpdate.checkJitter...AppUpdate.checkJitter)
                let wait = AppUpdate.checkInterval + jitter
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(wait, 1) * 1_000_000_000))
                } catch { return }
            }
        }
    }

    func poke() {
        if !prefs.autoCheck { return }
        presentIfNeeded()
        if !state.enabled || devBuild || !started { return }
        switch state.status {
        case .checking, .downloading, .installing:
            return
        case .idle, .error:
            break
        }
        if Date().timeIntervalSince(lastAttempt) < AppUpdate.pokeMinInterval { return }
        lastAttempt = Date()
        Task { await check(manual: false) }
    }

    func check(manual: Bool) async {
        if !manual && (!prefs.autoCheck || Task.isCancelled) { return }
        if !state.enabled {
            if manual { state.error = state.disabledReason }
            return
        }
        switch state.status {
        case .checking, .downloading, .installing:
            return
        case .idle, .error:
            break
        }
        let previous = state.status
        state.status = .checking
        lastAttempt = Date()
        if manual {
            await performCheck(manual: true, previous: previous)
        } else {
            let task = Task { await self.performCheck(manual: false, previous: previous) }
            automaticCheck = task
            await task.value
        }
    }

    private func performCheck(manual: Bool, previous: AppUpdateStatus) async {
        defer {
            if state.status == .checking { state.status = .idle }
        }
        if Task.isCancelled || (!manual && !prefs.autoCheck) { return }
        let fetched = await client.fetch()
        if Task.isCancelled || (!manual && !prefs.autoCheck) { return }
        switch fetched {
        case .failure(let error):
            let release = await client.fetchReleasePost()
            if Task.isCancelled || (!manual && !prefs.autoCheck) { return }
            if case .success(let post) = release {
                applyReleasePost(post)
            }
            if previous == .error && !manual {
                state.status = .error
            } else {
                state.status = .idle
            }
            // 后台请求失败只在设置页反馈；仅确认有新版本且符合提醒偏好时才打扰用户。
            let isAutomaticNotice = !manual && !netFailNotified && shouldPrompt()
            state.error = error.message
            state.checkFailed = true
            if isAutomaticNotice { netFailNotified = true }
            if manual || isAutomaticNotice {
                if state.hasUpdate && state.size > 0 {
                    state.prompt = true
                    announceUpdate(manual: manual)
                } else if state.hasUpdate {
                    announceRelease(manual: manual)
                } else {
                    announceFailure()
                }
            }
            return
        case .success(let manifest):
            state.error = ""
            state.checkFailed = false
            netFailNotified = false
            state.lastChecked = ISO8601DateFormatter().string(from: Date())
            apply(manifest)
            if state.notes.isEmpty {
                let release = await client.fetchReleasePost()
                if Task.isCancelled || (!manual && !prefs.autoCheck) { return }
                if case .success(let post) = release {
                    applyReleasePost(post)
                }
            }
            state.status = .idle
            var prompt = false
            if !manual && shouldPrompt() {
                state.prompt = true
                prompt = true
            }
            if manual && state.hasUpdate {
                state.prompt = true
                prompt = true
            }
            if prompt { announceUpdate(manual: manual) }
        }
    }

    func startUpdate() {
        if !state.enabled {
            state.error = state.disabledReason
            return
        }
        if state.status == .downloading || state.status == .installing { return }
        guard state.hasUpdate, let manifest, let asset = manifest.asset(for: AppVersionParser.platformKey()) else {
            state.error = state.hasUpdate ? AppUpdateFailure.noAsset.message : AppUpdateFailure.alreadyLatest.message
            return
        }
        state.status = .downloading
        state.error = ""
        state.downloaded = 0
        state.total = asset.size
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            let downloaded = await self.client.download(asset) { done, total in
                Task { @MainActor in
                    self.state.downloaded = done
                    self.state.total = total
                }
            }
            if Task.isCancelled {
                self.state.status = .idle
                return
            }
            switch downloaded {
            case .failure(let error):
                self.state.status = .error
                self.state.error = error.message
            case .success(let path):
                self.client.pruneDownloads(keeping: (path as NSString).lastPathComponent)
                self.state.status = .installing
                let installed = await Task.detached { AppUpdateInstall.apply(archive: path) }.value
                switch installed {
                case .failure(let error):
                    self.state.status = .error
                    self.state.error = error.message
                case .success(let bundle):
                    self.restart(at: bundle)
                }
            }
        }
    }

    func cancelDownload() {
        work?.cancel()
        work = nil
        if state.status == .downloading {
            state.status = .idle
            state.error = ""
        }
    }

    func skipVersion() {
        if state.mandatory {
            state.error = AppUpdateFailure.cannotSkip.message
            return
        }
        prefs.skippedVersion = AppVersionParser.canonical(state.latest)
        state.skippedVersion = prefs.skippedVersion
        state.prompt = false
        prefs.save()
        AppUpdatePresenter.close()
    }

    func remindLater() {
        if state.mandatory {
            state.error = AppUpdateFailure.cannotDelay.message
            return
        }
        prefs.remindVersion = state.latest
        prefs.remindAfter = Date().addingTimeInterval(AppUpdate.remindLater)
        state.prompt = false
        prefs.save()
        AppUpdatePresenter.close()
    }

    func setAutoCheck(_ on: Bool) {
        if prefs.autoCheck == on { return }
        prefs.autoCheck = on
        state.autoCheck = on
        prefs.save()
        if on {
            startAutomaticChecks()
        } else {
            checkLoop?.cancel()
            checkLoop = nil
            automaticCheck?.cancel()
            automaticCheck = nil
            state.prompt = false
            AppUpdatePresenter.close()
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: ["oneagent-update"])
            center.removeDeliveredNotifications(withIdentifiers: ["oneagent-update"])
        }
    }

    func dismissOptional() {
        if state.mandatory { return }
        state.prompt = false
        AppUpdatePresenter.close()
    }

    func showFromNotification() {
        NSApp.activate()
        if state.hasUpdate && state.size > 0 {
            presentUpdate()
            return
        }
        if state.hasUpdate || state.checkFailed { presentFailure() }
    }

    func openReleases() {
        guard let url = URL(string: state.releaseURL) else { return }
        NSWorkspace.shared.open(url)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    /// 发布页说明只用于展示。版本不比已有签名清单新时，保留可安装的包。
    private func applyReleasePost(_ post: AppReleasePost) {
        guard let version = AppVersionParser.parse(post.version) else { return }
        let canonical = version.canonical
        if !state.latest.isEmpty, let order = AppVersionParser.compare(canonical, state.latest) {
            if order < 0 { return }
            if order == 0 {
                if state.notes.isEmpty { state.notes = post.notes }
                if !post.pageURL.isEmpty { state.releaseURL = post.pageURL }
                return
            }
        }
        manifest = nil
        state.latest = canonical
        state.notes = post.notes
        state.size = 0
        state.minSupported = ""
        if !post.pageURL.isEmpty { state.releaseURL = post.pageURL }
        let decision = AppVersionParser.evaluate(current: currentBase, dev: devBuild, manifest: AppUpdateManifest(version: canonical))
        state.hasUpdate = decision.hasUpdate
        state.mandatory = false
        if !decision.hasUpdate { state.prompt = false }
    }

    private func apply(_ manifest: AppUpdateManifest) {
        self.manifest = manifest
        let decision = AppVersionParser.evaluate(current: currentBase, dev: devBuild, manifest: manifest)
        state.hasUpdate = decision.hasUpdate
        state.mandatory = decision.mandatory
        state.latest = manifest.version
        state.minSupported = manifest.minSupportedVersion
        state.notes = manifest.notes
        state.size = manifest.asset(for: AppVersionParser.platformKey())?.size ?? 0
        if !decision.hasUpdate { state.prompt = false }
    }

    private func shouldPrompt() -> Bool {
        AppVersionParser.shouldPrompt(
            hasUpdate: state.hasUpdate,
            mandatory: state.mandatory,
            autoCheck: prefs.autoCheck,
            latest: state.latest,
            skipped: prefs.skippedVersion,
            remindVersion: prefs.remindVersion,
            remindAfter: prefs.remindAfter,
            now: Date()
        )
    }

    private func announceUpdate(manual: Bool) {
        if windowIsVisible() {
            presentUpdate()
            return
        }
        let title: String
        let body: String
        if state.mandatory {
            title = String(format: String(localized: "1Agent must update to %@"), state.latest)
            body = String(localized: "This version is no longer supported. Update to continue.")
        } else {
            title = String(format: String(localized: "1Agent %@ is available"), state.latest)
            body = String(localized: "Click to read the notes and install.")
        }
        postNotification(title: title, body: body, manual: manual)
    }

    private func announceRelease(manual: Bool) {
        if windowIsVisible() || manual {
            presentFailure()
            return
        }
        postNotification(
            title: String(format: String(localized: "1Agent %@ is available"), state.latest),
            body: String(localized: "Click to read the release notes."),
            manual: manual
        )
    }

    private func announceFailure() {
        if windowIsVisible() {
            presentFailure()
            return
        }
        postNotification(
            title: String(localized: "Could not check for updates"),
            body: String(localized: "Could not reach the update server. Download the new version from the releases page."),
            manual: true
        )
    }

    private func presentIfNeeded() {
        if prefs.autoCheck && state.prompt && state.hasUpdate { presentUpdate() }
    }

    private func presentUpdate() {
        AppUpdatePresenter.show(failed: false)
    }

    private func presentFailure() {
        AppUpdatePresenter.show(failed: true)
    }

    private func windowIsVisible() -> Bool {
        if let settings = SettingsWindowController.shared.window, settings.isVisible, !settings.isMiniaturized {
            return true
        }
        for window in NSApp.windows where window.identifier?.rawValue == MainWindowManager.windowID.rawValue {
            if window.isVisible && !window.isMiniaturized { return true }
        }
        return false
    }

    private func frontWindow() -> NSWindow? {
        if let settings = SettingsWindowController.shared.window, settings.isVisible { return settings }
        for window in NSApp.windows where window.identifier?.rawValue == MainWindowManager.windowID.rawValue {
            if window.isVisible { return window }
        }
        return nil
    }

    private func postNotification(title: String, body: String, manual: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [AppUpdate.notificationKey: "show"]
        let request = UNNotificationRequest(identifier: "oneagent-update", content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard granted else { return }
            Task { @MainActor in
                guard let self, manual || self.prefs.autoCheck else { return }
                center.add(request)
            }
        }
    }

    private func restart(at bundle: String) {
        if let app = NSApp.delegate as? AppDelegate {
            app.model.isRestarting = true
            app.relaunchBundlePath = bundle
        }
        NSApp.terminate(nil)
    }
}

private struct AppUpdatePrefs: Codable {
    var autoCheck = true
    var skippedVersion = ""
    var remindVersion = ""
    var remindAfter: Date?

    static func directory() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("1Agent/update").path ?? ""
    }

    static func load(directory: String) -> AppUpdatePrefs {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("prefs.json")
        guard let data = try? Data(contentsOf: url) else { return AppUpdatePrefs() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AppUpdatePrefs.self, from: data)) ?? AppUpdatePrefs()
    }

    func save() {
        let directory = Self.directory()
        if directory.isEmpty { return }
        let folder = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: folder.appendingPathComponent("prefs.json"), options: .atomic)
    }
}

@MainActor
enum AppUpdatePresenter {
    private static var presentation: FamilyModalPresentation?
    private static var failed = false

    static func show(failed: Bool) {
        if presentation != nil && self.failed == failed { return }
        close()
        self.failed = failed
        let height = AppUpdateController.shared.state.notes.isEmpty ? SheetLayout.appUpdateCompactHeight : SheetLayout.appUpdateHeight
        let owner = frontWindow()
        let chrome = WindowChrome.resolve(isDark: AppearanceDriver.shared.isDark, icon: ApplicationIcon.stored())
        let root = AnyView(
            AppUpdateDialogView(failed: failed)
                .environment(\.windowChrome, chrome)
                .font(Theme.Font.body)
                .tint(chrome.accent)
                .buttonStyle(FamilyButtonStyle(kind: .secondary))
                .frame(width: SheetLayout.appUpdate, height: height)
                .background(chrome.background)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(chrome.hairline, lineWidth: 1))
        )
        let host = NSHostingView(rootView: root)
        let mandatory = AppUpdateController.shared.state.mandatory && !failed
        let presentation = FamilyModalPresentation(
            content: host,
            size: NSSize(width: SheetLayout.appUpdate, height: height),
            owner: owner
        ) {
            if mandatory { return }
            AppUpdateController.shared.dismissOptional()
        }
        self.presentation = presentation
        presentation.show()
    }

    static func close() {
        presentation?.close()
        presentation = nil
    }

    private static func frontWindow() -> NSWindow? {
        if let settings = SettingsWindowController.shared.window, settings.isVisible { return settings }
        for window in NSApp.windows where window.identifier?.rawValue == MainWindowManager.windowID.rawValue {
            if window.isVisible { return window }
        }
        return NSApp.keyWindow
    }
}
