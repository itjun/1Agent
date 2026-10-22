import SwiftUI

struct AppUpdateSettingsPage: View {
    @ObservedObject private var updates = AppUpdateController.shared
    @Environment(\.windowChrome) private var chrome

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
                            Text("Optional updates stay quiet while this is off. A required update still appears.")
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
                .padding(.horizontal, Theme.Space.l)
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
            if !failed && !updates.state.notes.isEmpty {
                ScrollView {
                    Text(updates.state.notes)
                        .font(Theme.Font.rowMeta)
                        .foregroundStyle(chrome.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
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
        if failed { return String(localized: "Could not check for updates") }
        if updates.state.mandatory { return String(localized: "This update is required to keep using 1Agent.") }
        return String(format: String(localized: "Version %@ is available."), updates.state.latest)
    }

    private var message: String {
        if failed {
            return String(localized: "Could not reach the update server. Download the new version from the releases page.")
        }
        if updates.state.mandatory {
            return String(localized: "This version is no longer supported. Update to continue.")
        }
        return String(format: String(localized: "Version %@ is available."), updates.state.latest)
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
            Button("Open Releases") { updates.openReleases() }
                .buttonStyle(FamilyButtonStyle(kind: .primary))
            Button("Close") { updates.dismissOptional() }
                .buttonStyle(FamilyButtonStyle(kind: .secondary))
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
