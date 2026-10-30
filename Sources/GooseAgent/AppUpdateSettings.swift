import SwiftUI

struct AppUpdateSettingsPage: View {
    @ObservedObject private var updates = AppUpdateController.shared
    @Environment(\.windowChrome) private var chrome
    let onRestart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingsCard("Updates") {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    Text(versionText)
                        .font(Theme.Font.body)
                        .foregroundStyle(chrome.text)
                    Toggle(isOn: Binding(
                        get: { updates.state.autoCheck },
                        set: { updates.setAutoCheck($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automatically check for updates")
                                .font(Theme.Font.body)
                                .foregroundStyle(chrome.text)
                            Text("When off, 1Agent won’t check for updates or show update reminders automatically. You can still check manually.")
                                .font(Theme.Font.rowMeta)
                                .foregroundStyle(chrome.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(FamilyToggleStyle(checkbox: true))
                    .disabled(!updates.state.enabled)
                    Text(statusText)
                        .font(Theme.Font.rowMeta)
                        .foregroundStyle(updates.state.error.isEmpty ? chrome.secondary : chrome.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    if updates.state.hasUpdate && !updates.state.notes.isEmpty {
                        Text(updates.state.notes)
                            .font(Theme.Font.rowMeta)
                            .foregroundStyle(chrome.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: Theme.Space.s) {
                        Button("Check for Updates") {
                            Task { await updates.check(manual: true) }
                        }
                        .buttonStyle(FamilyButtonStyle(kind: .primary))
                        .disabled(!updates.state.enabled || busy)
                        if updates.state.hasUpdate {
                            Button("Update Now") { updates.startUpdate() }
                                .buttonStyle(FamilyButtonStyle(kind: .secondary))
                                .disabled(busy)
                        }
                    }
                }
            }

            SettingsCard("Restart 1Agent") {
                SettingsRow("Restart", detail: "Terminal sessions are saved and restored after the restart. Running commands will be interrupted.") {
                    Button(action: onRestart) {
                        Label("Restart 1Agent", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(FamilyButtonStyle(kind: .secondary))
                    .accessibilityIdentifier("settings.restart")
                }
            }
        }
    }

    private var busy: Bool {
        switch updates.state.status {
        case .checking, .downloading, .installing: return true
        case .idle, .error: return false
        }
    }

    private var versionText: String {
        String(format: String(localized: "Version %@"), updates.state.current)
    }

    private var statusText: String {
        if !updates.state.enabled { return updates.state.disabledReason }
        switch updates.state.status {
        case .checking:
            return String(localized: "Checking for updates…")
        case .downloading:
            return String(format: String(localized: "Downloading the update (%@)"), progressText)
        case .installing:
            return String(localized: "Installing the update")
        case .idle, .error:
            break
        }
        if !updates.state.error.isEmpty { return updates.state.error }
        if updates.state.hasUpdate {
            if updates.state.mandatory {
                return String(localized: "This update is required to keep using 1Agent.")
            }
            return String(format: String(localized: "Version %@ is available."), updates.state.latest)
        }
        if updates.state.lastChecked.isEmpty {
            return String(localized: "1Agent is up to date.")
        }
        return String(localized: "1Agent is up to date.")
    }

    private var progressText: String {
        let done = ByteCountFormatter.string(fromByteCount: updates.state.downloaded, countStyle: .file)
        if updates.state.total <= 0 { return done }
        let total = ByteCountFormatter.string(fromByteCount: updates.state.total, countStyle: .file)
        return "\(done) / \(total)"
    }
}

struct AppUpdateDialogView: View {
    @ObservedObject private var updates = AppUpdateController.shared
    @Environment(\.windowChrome) private var chrome
    let failed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title)
                .font(Theme.Font.emptyTitle)
                .foregroundStyle(chrome.text)
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(chrome.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if updates.state.hasUpdate && !updates.state.notes.isEmpty {
                ScrollView {
                    Text(updates.state.notes)
                        .font(Theme.Font.rowMeta)
                        .foregroundStyle(chrome.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: .infinity)
            }
            if updates.state.status == .downloading || updates.state.status == .installing {
                ProgressView(value: progressValue)
                    .tint(chrome.accent)
                Text(progressLabel)
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.secondary)
            }
            if !failed && !updates.state.error.isEmpty && updates.state.status == .error {
                Text(updates.state.error)
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                buttons
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var title: String {
        if updates.state.hasUpdate {
            if !failed && updates.state.mandatory {
                return String(localized: "This update is required to keep using 1Agent.")
            }
            return String(format: String(localized: "Version %@ is available."), shownVersion(updates.state.latest))
        }
        if failed { return String(localized: "Could not check for updates") }
        return String(localized: "1Agent is up to date.")
    }

    private var message: String {
        if failed && updates.state.hasUpdate {
            return String(format: String(localized: "Version %@ is available. The package could not be verified. The notes are below, or download it from the releases page."), shownVersion(updates.state.latest))
        }
        if failed && !updates.state.latest.isEmpty {
            return String(format: String(localized: "This copy is %1$@, and the published release is %2$@. They are the same version. The update server could not be reached."), shownVersion(updates.state.current), shownVersion(updates.state.latest))
        }
        if failed {
            return String(localized: "Could not reach the update server. Download the new version from the releases page.")
        }
        if !updates.state.hasUpdate {
            return String(format: String(localized: "Version %@"), shownVersion(updates.state.current))
        }
        if updates.state.mandatory {
            return String(localized: "This version is no longer supported. Update to continue.")
        }
        return String(format: String(localized: "Version %@ is available."), shownVersion(updates.state.latest))
    }

    private func shownVersion(_ raw: String) -> String {
        if let version = AppVersionParser.parse(raw) { return version.canonical }
        return raw
    }

    private var progressValue: Double {
        if updates.state.status == .installing { return 1 }
        if updates.state.total <= 0 { return 0 }
        return Double(updates.state.downloaded) / Double(updates.state.total)
    }

    private var progressLabel: String {
        if updates.state.status == .installing { return String(localized: "Installing the update") }
        let done = ByteCountFormatter.string(fromByteCount: updates.state.downloaded, countStyle: .file)
        if updates.state.total <= 0 {
            return String(format: String(localized: "Downloading the update (%@)"), done)
        }
        let total = ByteCountFormatter.string(fromByteCount: updates.state.total, countStyle: .file)
        return String(format: String(localized: "Downloading the update (%@)"), "\(done) / \(total)")
    }

    @ViewBuilder private var buttons: some View {
        if failed {
            if updates.state.hasUpdate && updates.state.size > 0 {
                Button("Update Now") { updates.startUpdate() }
                    .buttonStyle(FamilyButtonStyle(kind: .primary))
                    .disabled(updates.state.status == .downloading || updates.state.status == .installing)
            }
            Button("Open Releases") { updates.openReleases() }
                .buttonStyle(FamilyButtonStyle(kind: updates.state.hasUpdate && updates.state.size > 0 ? .secondary : .primary))
            Button("Close") { updates.dismissOptional() }
                .buttonStyle(FamilyButtonStyle(kind: .secondary))
        } else if !updates.state.hasUpdate {
            Button("Close") { updates.dismissOptional() }
                .buttonStyle(FamilyButtonStyle(kind: .primary))
        } else if updates.state.mandatory {
            if updates.state.status == .downloading {
                Button("Cancel Download") { updates.cancelDownload() }
                    .buttonStyle(FamilyButtonStyle(kind: .secondary))
            }
            Button("Update Now") { updates.startUpdate() }
                .buttonStyle(FamilyButtonStyle(kind: .primary))
                .disabled(updates.state.status == .downloading || updates.state.status == .installing)
            Button("Quit 1Agent") { updates.quit() }
                .buttonStyle(FamilyButtonStyle(kind: .secondary))
                .disabled(updates.state.status == .installing)
        } else {
            if updates.state.status == .downloading {
                Button("Cancel Download") { updates.cancelDownload() }
                    .buttonStyle(FamilyButtonStyle(kind: .secondary))
            }
            Button("Update Now") { updates.startUpdate() }
                .buttonStyle(FamilyButtonStyle(kind: .primary))
                .disabled(updates.state.status == .downloading || updates.state.status == .installing)
            Button("Remind Me Later") { updates.remindLater() }
                .buttonStyle(FamilyButtonStyle(kind: .secondary))
                .disabled(updates.state.status == .downloading || updates.state.status == .installing)
            Button("Skip This Version") { updates.skipVersion() }
                .buttonStyle(FamilyButtonStyle(kind: .secondary))
                .disabled(updates.state.status == .downloading || updates.state.status == .installing)
        }
    }
}
