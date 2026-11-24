import SwiftUI

struct AppUpdateSettingsPage: View {
    @ObservedObject private var updates = AppUpdateController.shared
    let onRestart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingsCard("Updates") {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    Text(String(format: String(localized: "Version %@"), Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticallyChecksForUpdates($0) }
                    )).toggleStyle(FamilyToggleStyle(checkbox: true))
                    if !updates.unavailableReason.isEmpty {
                        Text(verbatim: updates.unavailableReason).foregroundStyle(.secondary)
                    }
                    Button("Check for Updates") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                    Button("Restart 1Agent", action: onRestart)
                }
            }
        }
    }
}
