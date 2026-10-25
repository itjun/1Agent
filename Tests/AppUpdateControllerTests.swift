import AppKit
import Foundation
@testable import GooseAgent

/// 拦截真实更新请求，验证控制器和原生弹窗，不访问网络或用户数据。
final class UpdateFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let scenario = CommandLine.arguments.dropFirst().first ?? "same-version"
    private static let lock = NSLock()
    private static var requests = 0
    private static var cancellations = 0
    private let loadingLock = NSLock()
    private var isStopped = false

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static var cancellationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellations
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        Self.lock.unlock()
        if ["disable-during-check", "disable-during-manual"].contains(Self.scenario), request.url?.path.hasSuffix("latest.json") == true {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
                loadingLock.lock()
                let shouldFail = !isStopped
                loadingLock.unlock()
                if shouldFail { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
            }
            return
        }
        if request.url?.path.hasSuffix("releases.atom") == true && Self.scenario != "no-release" {
            let version: String
            switch Self.scenario {
            case "older-version": version = "v0.9.0"
            case "newer-version", "disabled", "skipped", "remind", "disable-during-check", "disable-during-manual": version = "v1.1.0"
            default: version = "v1.0.0"
            }
            let feed = """
            <feed xmlns="http://www.w3.org/2005/Atom"><entry>
            <title>\(version)</title><content type="html">Fixture release</content>
            </entry></feed>
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(feed.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        }
    }

    override func stopLoading() {
        loadingLock.lock()
        isStopped = true
        loadingLock.unlock()
        Self.lock.lock()
        Self.cancellations += 1
        Self.lock.unlock()
    }
}

@main
enum AppUpdateControllerTests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        URLProtocol.registerClass(UpdateFixtureProtocol.self)
        defer { URLProtocol.unregisterClass(UpdateFixtureProtocol.self) }
        let window = NSWindow(contentRect: NSRect(x: 180, y: 160, width: 880, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.identifier = MainWindowManager.windowID
        window.makeKeyAndOrderFront(nil)
        defer { AppUpdatePresenter.close(); window.orderOut(nil) }

        let updates = AppUpdateController.shared
        require(updates.state.enabled, "fixture app enables the real update controller")
        let scenario = UpdateFixtureProtocol.scenario
        if ["disable-during-check", "disable-during-manual"].contains(scenario) {
            updates.start()
            let isManual = scenario == "disable-during-manual"
            let check = Task { await updates.check(manual: isManual) }
            let deadline = Date().addingTimeInterval(2)
            while UpdateFixtureProtocol.requestCount == 0 && Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            require(UpdateFixtureProtocol.requestCount == 1, "the update request has started")
            updates.setAutoCheck(false)
            await check.value
            if isManual {
                require(isDialogVisible() && UpdateFixtureProtocol.requestCount == 2, "turning off automatic checks does not cancel a manual check")
            } else {
                require(UpdateFixtureProtocol.cancellationCount > 0, "turning off automatic checks cancels the active request")
                require(!isDialogVisible() && UpdateFixtureProtocol.requestCount == 1, "a cancelled automatic check does not fetch release notes or show a dialog")
            }
            require(updates.state.status == .idle, "the controller returns to idle")
            AppUpdatePresenter.close()
            updates.setAutoCheck(true)
            await updates.check(manual: false)
            require(updates.state.hasUpdate && isDialogVisible(), "automatic checks work again after re-enabling")
            print("AppUpdateControllerTests passed: \(scenario)")
            return
        }
        if scenario == "disabled" {
            updates.start()
            updates.poke()
            await updates.check(manual: false)
            try? await Task.sleep(nanoseconds: 10_200_000_000)
            require(UpdateFixtureProtocol.requestCount == 0, "disabled automatic checks must not make any update requests")
            require(!isDialogVisible(), "disabled automatic checks must not show dialogs")
            await updates.check(manual: true, showResult: true)
            require(UpdateFixtureProtocol.requestCount > 0 && isDialogVisible(), "manual checks still work when automatic checks are disabled")
            print("AppUpdateControllerTests passed: disabled")
            return
        }
        await updates.check(manual: false)
        let isNewer = ["newer-version", "disabled", "skipped", "remind"].contains(scenario)
        require(updates.state.hasUpdate == isNewer, "release version comparison: \(scenario)")
        if scenario == "same-version" {
            require(updates.state.latest == "v1.0.0", "the feed reports the same version")
        }
        require(isDialogVisible() == (scenario == "newer-version"), "automatic checks only open a dialog for a newer release that allows reminders: \(scenario)")
        require(!updates.state.error.isEmpty, "the settings page retains the check failure")
        AppUpdatePresenter.close()
        if scenario == "newer-version" {
            updates.setAutoCheck(false)
            let requests = UpdateFixtureProtocol.requestCount
            updates.poke()
            await updates.check(manual: false)
            require(!updates.state.prompt && !isDialogVisible() && UpdateFixtureProtocol.requestCount == requests, "turning off automatic checks clears pending reminders and prevents activation checks")
        }

        await updates.check(manual: false)
        require(!isDialogVisible(), "repeated automatic failures stay quiet: \(scenario)")

        await updates.check(manual: true, showResult: true)
        require(isDialogVisible(), "a manual check still displays the failure")
        print("AppUpdateControllerTests passed: \(scenario)")
    }

    @MainActor static func isDialogVisible() -> Bool {
        NSApp.windows.contains { $0.identifier?.rawValue == "family.dialog" && $0.isVisible }
    }

    static func require(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("AppUpdateControllerTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
