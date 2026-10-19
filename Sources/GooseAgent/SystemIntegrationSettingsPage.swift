import AppKit
import SwiftUI

struct SystemIntegrationSettingsPage: View {
    @Environment(\.windowChrome) private var chrome
    @StateObject private var associations = TerminalAssociationStore.shared
    @State private var showsScriptTypes = false
    @State private var showsAutomation = false
    @AppStorage(TerminalAutomation.enabledKey) private var automationEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Terminal Entries")
                    .font(.system(size: SettingsLayout.integrationTitleSize, weight: .semibold))
                    .foregroundStyle(chrome.text)
                Text("Choose what opens with 1Agent.")
                    .foregroundStyle(chrome.secondary)
            }

            defaultTerminal
            entries

            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Folders keep opening in Finder. Configure .sh and .zsh separately if needed.")
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Other Script Types", isExpanded: $showsScriptTypes) {
                    VStack(spacing: 0) {
                        entry(.shell)
                        line
                        entry(.zsh)
                    }
                    .padding(.top, Theme.Space.s)
                }
            }

            HStack(spacing: Theme.Space.m) {
                Button("Apply Selected Associations") {
                    Task { await associations.applySelection() }
                }
                .buttonStyle(FamilyButtonStyle(kind: .primary))
                .disabled(!associations.canApplySelection)
                .accessibilityIdentifier("systemIntegration.apply")

                Button("Restore Previous Associations") {
                    Task { await associations.restore() }
                }
                .buttonStyle(FamilyButtonStyle(kind: .secondary))
                .disabled(associations.isBusy || !associations.hasBackup || !associations.backupIsReadable)
                .accessibilityIdentifier("systemIntegration.restore")
            }

            if associations.isBusy {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for macOS to confirm the associations…")
                        .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                }
                .accessibilityIdentifier("systemIntegration.progress")
            }
            if let feedback = associations.feedback {
                Text(verbatim: feedback.message)
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(feedback.isFailure ? chrome.danger : chrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("systemIntegration.result")
            }

            line
            HStack(alignment: .top, spacing: Theme.Space.l) {
                Text("Finder services create new terminals and independent windows.")
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("About Finder Services", action: showFinderServices)
                    .buttonStyle(FamilyButtonStyle(kind: .secondary))
                    .accessibilityIdentifier("systemIntegration.services")
            }

            DisclosureGroup("Windows and Automation", isExpanded: $showsAutomation) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack {
                        Button("New Window") { TerminalAutomation.model?.newWindow() }
                    }
                    .buttonStyle(FamilyButtonStyle(kind: .secondary))
                    Toggle("Enable Terminal Automation", isOn: $automationEnabled)
                    Text("AppleScript and Shortcuts address windows and terminals by ID.")
                        .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                    if !TerminalAutomation.hasDeveloperTeamSignature {
                        Text("This local build supports AppleScript. Native Shortcuts actions require Apple developer signing.")
                            .font(Theme.Font.rowMeta).foregroundStyle(chrome.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                }
                .padding(.top, Theme.Space.m)
            }
        }
        .font(Theme.Font.body)
        .onAppear { associations.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            associations.refresh()
        }
    }

    private var defaultTerminal: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Default Terminal").font(Theme.Font.sectionTitle).foregroundStyle(chrome.text)
                Label {
                    Text(verbatim: associations.isDefaultTerminal
                         ? String(localized: "1Agent Is the Default Terminal")
                         : String(localized: "Not Set to 1Agent"))
                } icon: {
                    Image(systemName: associations.isDefaultTerminal ? "checkmark.circle.fill" : "circle.fill")
                        .font(.system(size: SettingsLayout.integrationStatusSize))
                }
                .foregroundStyle(associations.isDefaultTerminal ? chrome.accent : chrome.secondary)
                .accessibilityIdentifier("systemIntegration.defaultStatus")
                Text(verbatim: defaultApplicationDetail)
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Set as Default Terminal") {
                Task { await associations.setAsDefaultTerminal() }
            }
            .buttonStyle(FamilyButtonStyle(kind: .primary))
            .disabled(associations.isBusy || associations.isDefaultTerminal || !associations.backupIsReadable)
            .accessibilityIdentifier("systemIntegration.setDefault")
        }
        .padding(.vertical, Theme.Space.l)
        .overlay(alignment: .top) { line }
    }

    private var entries: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Text("Entry").frame(maxWidth: .infinity, alignment: .leading)
                Text("Current Application").frame(width: SettingsLayout.integrationAppColumn, alignment: .leading)
                Text("Open with 1Agent").frame(width: SettingsLayout.integrationChoiceColumn, alignment: .leading)
            }
            .font(Theme.Font.rowMeta)
            .foregroundStyle(chrome.secondary)
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: SettingsLayout.integrationHeaderHeight)
            .background(chrome.elevated)

            line
            entry(.executable)
            line
            entry(.command)
            line
            HStack(spacing: Theme.Space.m) {
                Text("Finder Directory Services").frame(maxWidth: .infinity, alignment: .leading)
                application(associations.target)
                Button("About Services", action: showFinderServices)
                    .buttonStyle(FamilyButtonStyle())
                    .foregroundStyle(chrome.accent)
                    .frame(width: SettingsLayout.integrationChoiceColumn, alignment: .leading)
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: SettingsLayout.integrationRowHeight)
        }
        .foregroundStyle(chrome.text)
        .background(chrome.background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(chrome.hairline, lineWidth: 1)
        }
    }

    private func entry(_ kind: TerminalEntryKind) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(verbatim: kind.title).frame(maxWidth: .infinity, alignment: .leading)
            application(associations.applications[kind])
            Toggle(isOn: Binding(
                get: { associations.isOwned(kind) || associations.selected.contains(kind) },
                set: { selected in
                    if selected { associations.selected.insert(kind) }
                    else { associations.selected.remove(kind) }
                }
            )) {
                Text(verbatim: kind.title)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(associations.isBusy || associations.isOwned(kind))
            .accessibilityIdentifier("systemIntegration.select.\(kind.rawValue)")
            .frame(width: SettingsLayout.integrationChoiceColumn, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(minHeight: SettingsLayout.integrationRowHeight)
    }

    private func application(_ application: TerminalEntryApplication?) -> some View {
        HStack(spacing: Theme.Space.s) {
            if let application {
                Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                    .resizable()
                    .frame(width: SettingsLayout.integrationIconSize, height: SettingsLayout.integrationIconSize)
                    .accessibilityHidden(true)
                Text(verbatim: application.name).lineLimit(1).truncationMode(.tail)
            } else {
                Text("No Default Application").foregroundStyle(chrome.secondary)
            }
        }
        .frame(width: SettingsLayout.integrationAppColumn, alignment: .leading)
    }

    private var line: some View { Rectangle().fill(chrome.hairline).frame(height: 1) }

    private var defaultApplicationDetail: String {
        guard let application = associations.applications[.executable] else {
            return String(localized: "Opens Unix executables. Other scripts can be selected below.")
        }
        return String(format: String(localized: "Unix executables currently open with %@."), application.name)
    }

    private func showFinderServices() {
        let alert = FamilyAlert()
        alert.messageText = String(localized: "Finder Directory Services")
        alert.informativeText = String(localized: "Select a file or folder in Finder, then open the Services menu.\n\nNew 1Agent Tab Here always creates a new terminal in the selected folder, or a file’s parent folder.\n\nNew 1Agent Window Here creates an independent window. Multiple folders share that new window.")
        alert.addButton(withTitle: String(localized: "OK"))
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) { _ in } }
        else { alert.runModal() }
    }
}
