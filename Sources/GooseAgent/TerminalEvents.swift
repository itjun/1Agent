import AppKit
import GhosttyTerminal
import SwiftUI
import UserNotifications

/// Receives the engine's callbacks for one terminal. The terminal view owns it, so a session that no
/// window shows still reports; a SwiftUI coordinator is gone once its container is torn down.
@MainActor
final class TerminalEventRelay: TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceClipboardConfirmationDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceProgressReportDelegate,
    TerminalSurfaceOpenURLDelegate,
    TerminalSurfaceHoverLinkDelegate,
    TerminalSurfaceMouseShapeDelegate,
    TerminalSurfacePwdDelegate {
    weak var terminal: SSHTerminalNSView?



    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        terminal?.attachedSurface = surface
    }

    func terminalDidDetachSurface() {
        terminal?.attachedSurface = nil
    }

    /// Only pastes are asked about. OSC 52 reads stay denied, as they were before this delegate existed.
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        guard request.kind == .paste, let terminal else {
            request.respond(allow: false)
            return
        }
        terminal.confirmPaste(request)
    }

    /// OSC 9 and OSC 777.
    func terminalDidRequestDesktopNotification(title: String, body: String) {
        guard let sessionID = terminal?.sessionID else { return }
        TerminalActivity.shared.desktopNotification(sessionID: sessionID, title: title, body: body)
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        guard let terminal, let sessionID = terminal.sessionID else { return }
        TerminalActivity.shared.commandFinished(
            sessionID: sessionID,
            terminal: terminal,
            exitCode: exitCode,
            durationNanos: durationNanos
        )
    }

    func terminalDidRingBell() {
        guard let terminal, let sessionID = terminal.sessionID else { return }
        TerminalActivity.shared.ringBell(sessionID: sessionID, terminal: terminal)
    }

    /// OSC 9;4.
    func terminalDidReportProgress(state: TerminalProgressState, percent: Int?) {
        guard let sessionID = terminal?.sessionID else { return }
        TerminalProgress.shared.report(sessionID: sessionID, state: state, percent: percent)
    }

    /// ⌘-click on a link.
    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        TerminalLinks.open(url, from: terminal?.window)
    }

    func terminalDidUpdateHoverLink(_ url: String?) {
        terminal?.showHoverLink(url)
    }

    func terminalDidChangeMouseShape(_ shape: TerminalMouseShape) {
        terminal?.applyMouseShape(shape)
    }

    /// OSC 7.
    func terminalDidChangeWorkingDirectory(_ path: String) {
        guard let sessionID = terminal?.sessionID else { return }
        TerminalActivity.shared.model?.noteWorkingDirectory(path, forSession: sessionID)
    }
}

/// Links opened from a terminal. A program can print any link, so only common schemes open at once;
/// anything else, `oneagent://` included, is shown in full and asked about first.
@MainActor
enum TerminalLinks {
    static let directSchemes: Set<String> = ["http", "https", "mailto", "file"]

    /// Text without a scheme is a path, as in Ghostty.
    static func open(_ text: String, from window: NSWindow?) {
        let url: URL
        if let parsed = URL(string: text), let scheme = parsed.scheme, !scheme.isEmpty {
            url = parsed
        } else {
            url = URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if TerminalLinks.directSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        let alert = FamilyAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Open this link?")
        alert.informativeText = String(
            format: String(localized: "A program in the terminal asked to open a link that another app handles:\n\n%@"),
            url.absoluteString
        )
        alert.addButton(withTitle: String(localized: "Open Link"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(url)
            }
            return
        }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

struct TerminalProgressReport: Equatable {
    var state: TerminalProgressState
    /// 0…100. Nil when the program sent none.
    var percent: Int?
}

/// The latest OSC 9;4 report per session. Kept apart from `TerminalActivity` because programs send
/// these often, and only the progress bars should redraw for them.
@MainActor
final class TerminalProgress: ObservableObject {
    static let shared = TerminalProgress()
    /// A report nobody updates is dropped after this long, like Ghostty's own timeout.
    static let staleAfter: TimeInterval = 15

    @Published private(set) var reports: [String: TerminalProgressReport] = [:]
    private var expiry: [String: DispatchWorkItem] = [:]

    func report(sessionID: String, state: TerminalProgressState, percent: Int?) {
        expiry[sessionID]?.cancel()
        expiry[sessionID] = nil
        if state == .remove {
            reports[sessionID] = nil
            return
        }
        var clamped: Int?
        if let percent {
            clamped = min(max(percent, 0), 100)
        }
        let next = TerminalProgressReport(state: state, percent: clamped)
        if reports[sessionID] != next {
            reports[sessionID] = next
        }
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                TerminalProgress.shared.forget(sessionID: sessionID)
            }
        }
        expiry[sessionID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TerminalProgress.staleAfter, execute: work)
    }

    /// Timed out, or the tab closed.
    func forget(sessionID: String) {
        expiry[sessionID]?.cancel()
        expiry[sessionID] = nil
        reports[sessionID] = nil
    }
}

/// OSC 9;4 progress along the bottom of a pane's title bar. Watches the reports itself, so an update
/// does not redraw the whole canvas.
struct PaneProgressBar: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject private var progress = TerminalProgress.shared
    var sessionID: String

    var body: some View {
        let report = progress.reports[sessionID]
        ZStack(alignment: .leading) {
            if let report {
                PaneProgressFill(report: report, color: color(for: report.state))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.PaneStyle.progressBarHeight)
        .clipped()
        .animation(.easeOut(duration: Theme.PaneStyle.progressFadeDuration), value: report == nil)
        .allowsHitTesting(false)
    }

    private func color(for state: TerminalProgressState) -> Color {
        switch state {
        case .error: return chrome.danger
        case .pause: return chrome.warning
        default: return chrome.accent
        }
    }
}

private struct PaneProgressFill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var report: TerminalProgressReport
    var color: Color
    @State private var sweep: CGFloat = 0

    /// Paused without a percentage reads as a full bar, as in Ghostty.
    private var percent: Int? {
        if let value = report.percent {
            return value
        }
        if report.state == .pause {
            return 100
        }
        return nil
    }

    var body: some View {
        GeometryReader { geo in
            if let percent {
                Rectangle()
                    .fill(color)
                    .frame(width: geo.size.width * CGFloat(percent) / 100)
                    .animation(.easeInOut(duration: 0.2), value: percent)
            } else {
                let ratio = Theme.PaneStyle.progressSweepWidthRatio
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(color.opacity(0.3))
                    Rectangle()
                        .fill(color)
                        .frame(width: geo.size.width * ratio)
                        .offset(x: sweep * geo.size.width * (1 - ratio))
                }
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: Theme.PaneStyle.progressSweepDuration).repeatForever(autoreverses: true)) {
                        sweep = 1
                    }
                }
                .onDisappear {
                    sweep = 0
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Terminal Progress"))
        .accessibilityValue(Text(verbatim: percent.map { "\($0)%" } ?? ""))
    }
}

/// Per-session reactions to terminal events. Memory only; nothing here is saved with the session.
@MainActor
final class TerminalActivity: ObservableObject {
    static let shared = TerminalActivity()
    /// A program ringing in a loop gets one reaction per this interval.
    static let bellThrottle: TimeInterval = 0.5

    weak var model: AppModel?
    /// Sessions whose bell rang while the user was not looking. Their sidebar rows show a bell.
    @Published private(set) var bellMarks: Set<String> = []
    private var lastBell: [String: TimeInterval] = [:]
    private var activationObserver: NSObjectProtocol?

    private init() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                TerminalActivity.shared.clearBellOfSelectedPane()
            }
        }
    }

    /// The app is frontmost and the pane is on screen, so the user can see what the terminal does.
    func isAttended(_ tab: TerminalTab) -> Bool {
        guard NSApp.isActive, let model else { return false }
        return model.isPaneOnScreen(tab.id)
    }

    func isOnScreen(sessionID: String) -> Bool {
        guard let model, let tab = model.tab(forSession: sessionID) else { return false }
        return model.isPaneOnScreen(tab.id)
    }

    func desktopNotification(sessionID: String, title: String, body: String) {
        guard let model, let tab = model.tab(forSession: sessionID) else { return }
        if isAttended(tab) {
            return
        }
        TerminalNotifications.shared.post(
            title: model.sessionTitle(tab),
            subtitle: title,
            body: body,
            tabID: tab.id
        )
    }

    func commandFinished(sessionID: String, terminal: SSHTerminalNSView, exitCode: Int?, durationNanos: UInt64) {
        guard let model, let tab = model.tab(forSession: sessionID) else { return }
        let entries = TerminalSettings.parseCustomConfig(TerminalSettings.load().customConfig).entries
        let policy = CommandFinishedPolicy.from(entries)
        let duration = TimeInterval(durationNanos) / 1_000_000_000
        let actions = policy.actions(duration: duration, attended: isAttended(tab))
        if actions.bell {
            ringBell(sessionID: sessionID, terminal: terminal)
        }
        guard actions.notify else { return }
        let subtitle: String
        let body: String
        let took = TerminalActivity.durationText(duration)
        if let exitCode {
            if exitCode == 0 {
                subtitle = String(localized: "Command Succeeded")
            } else {
                subtitle = String(localized: "Command Failed")
            }
            body = String(format: String(localized: "Took %@ and exited with code %lld."), took, exitCode)
        } else {
            subtitle = String(localized: "Command Finished")
            body = String(format: String(localized: "Took %@."), took)
        }
        TerminalNotifications.shared.post(title: model.sessionTitle(tab), subtitle: subtitle, body: body, tabID: tab.id)
    }

    /// `bell-features`: `system`, `attention`, `border` and `title`. `audio` needs a sound file setting
    /// the app does not have, so it does nothing.
    func ringBell(sessionID: String, terminal: SSHTerminalNSView) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastBell[sessionID], now - last < TerminalActivity.bellThrottle {
            return
        }
        lastBell[sessionID] = now
        let features = TerminalSettings.load().bellFeatures
        if features.contains("system") {
            NSSound.beep()
        }
        if features.contains("attention") && !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
        if features.contains("border") {
            let chrome = WindowChrome.resolve(isDark: AppearanceDriver.shared.isDark)
            terminal.flashBellBorder(color: NSColor(chrome.warning))
        }
        if features.contains("title") {
            markBell(sessionID: sessionID)
        }
    }

    /// Not marked when the user is typing in that very terminal.
    private func markBell(sessionID: String) {
        guard let model, let tab = model.tab(forSession: sessionID) else { return }
        if isAttended(tab) && model.window(containing: tab.id)?.selectedTabID == tab.id {
            return
        }
        bellMarks.insert(sessionID)
    }

    /// The session was selected or focused.
    func clearBell(sessionID: String) {
        if bellMarks.contains(sessionID) {
            bellMarks.remove(sessionID)
        }
    }

    private func clearBellOfSelectedPane() {
        guard let model, let state = model.keyWindow, let tab = model.selectedTab(in: state) else { return }
        clearBell(sessionID: tab.sessionID)
    }

    /// The tab closed.
    func forget(sessionID: String) {
        clearBell(sessionID: sessionID)
        lastBell[sessionID] = nil
    }

    /// Clicked notification: bring the app forward with that session selected.
    func reveal(tabID: UUID) {
        NSApp.activate()
        guard let model, let state = model.window(containing: tabID) else { return }
        MainWindowManager.shared.show(state, model: model)
        model.selectOnly(tabID, in: state)
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: max(duration, 1)) ?? ""
    }
}

/// Posts macOS notifications for terminals and routes a click back to the session.
/// Authorization is asked the first time a notification is needed, not at launch.
@MainActor
final class TerminalNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TerminalNotifications()
    static let tabIDKey = "tabID"

    /// Before launch finishes, so a click that launched the app is still delivered here.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func post(title: String, subtitle: String, body: String, tabID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.userInfo = [TerminalNotifications.tabIDKey: tabID.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else {
                NSLog("Ghostty notification not authorized: \(error?.localizedDescription ?? "denied")")
                return
            }
            center.add(request) { error in
                if let error {
                    NSLog("Ghostty notification failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Notifications are only posted for a session the user is not looking at, so show them even
    /// while the app is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo[TerminalNotifications.tabIDKey] as? String
        let tabID = raw.flatMap { UUID(uuidString: $0) }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let tabID {
                    TerminalActivity.shared.reveal(tabID: tabID)
                } else {
                    NSApp.activate()
                }
            }
            completionHandler()
        }
    }
}
