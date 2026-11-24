import SwiftUI

/// Shared by the workspace and native presentation tests so the complete binding is exercised.
struct HostInformationPresentation: ViewModifier {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    var resolver = SSHConfigurationResolver.shared
    var configurationEnvironment: [String]? = nil

    func body(content: Content) -> some View {
        content.familySheet(isPresented: optionalBinding($window.hostInformationTabID), width: SheetLayout.hostInformation, height: SheetLayout.hostInformationHeight) {
            if let tabID = window.hostInformationTabID {
                HostInformationView(model: model, tabID: tabID, onClose: { window.hostInformationTabID = nil },
                                    resolver: resolver, configurationEnvironment: configurationEnvironment)
                    .id(tabID)
            }
        }
    }
}

/// Read-only information for the pane that opened the context menu.
struct HostInformationView: View {
    @ObservedObject var model: AppModel
    let tabID: UUID
    let onClose: () -> Void
    var resolver = SSHConfigurationResolver.shared
    var configurationEnvironment: [String]? = nil
    @State private var isConnectionInfoCopied = false
    @State private var configuration: ResolvedSSHConfiguration?
    @State private var isResolving = true

    private var tab: TerminalTab? {
        model.tabs.first { $0.id == tabID && $0.hasTerminal }
    }

    var body: some View {
        CommandDialog(title: "Host Information", close: onClose) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if let tab {
                        HostInformationRow(title: String(localized: "Target Host"), value: tab.isLocal ? String(localized: "This Mac") : tab.alias, identifier: "name")
                        CommandInfoRow(title: "Connection", value: !tab.exited && !tab.reconnecting ? String(localized: "Connected") : String(localized: "Not connected"))
                        if !tab.isLocal {
                            let placeholder = isResolving ? String(localized: "Loading…") : String(localized: "Could not resolve configuration")
                            HostInformationRow(title: String(localized: "Address"), value: configuration?.hostName, identifier: "address", placeholder: placeholder)
                            HostInformationRow(title: String(localized: "User"), value: configuration?.user, identifier: "user", placeholder: placeholder)
                            HostInformationRow(title: String(localized: "Port"), value: configuration?.port, identifier: "port", placeholder: placeholder)
                        }
                        HostInformationRow(title: String(localized: "Working Directory"), value: TerminalPaneActions.workingDirectory(of: tab),
                            identifier: "directory", placeholder: String(localized: "Directory unknown"))
                        if tab.isLocal {
                            HostInformationRow(title: String(localized: "Shell"), value: LocalTerminal.shellExecutable, identifier: "shell")
                        } else if let alias = tab.alias {
                            // 保留 SSH 配置中的端口、跳板机和认证方式。
                            HostInformationRow(title: String(localized: "SSH Command"),
                                value: "ssh -- '" + alias.replacingOccurrences(of: "'", with: "'\\''") + "'", identifier: "sshCommand")
                        }
                    } else {
                        Text("Not connected")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            if let tab, !tab.isLocal {
                Button(isConnectionInfoCopied ? String(localized: "Copied") : String(localized: "Copy All")) {
                    guard let configuration else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString([tab.alias ?? "", configuration.hostName, configuration.user].joined(separator: "\n"), forType: .string)
                    isConnectionInfoCopied = true
                }
                .buttonStyle(FamilyButtonStyle())
                .disabled(configuration == nil)
                .accessibilityIdentifier("hostInformation.copyConnectionInfo")
                .task(id: isConnectionInfoCopied) {
                    guard isConnectionInfoCopied else { return }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    isConnectionInfoCopied = false
                }
            }
            Button("Close", action: onClose).buttonStyle(FamilyButtonStyle())
                .accessibilityIdentifier("hostInformation.close")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hostInformation.dialog")
        .task(id: tab?.alias) {
            configuration = nil
            guard let tab, !tab.isLocal, let alias = tab.alias else { isResolving = false; return }
            isResolving = true
            let environment: [String]
            if let configurationEnvironment { environment = configurationEnvironment }
            else { environment = await SSHLaunchEnvironment.shared.get() }
            do {
                let result = try await resolver.resolve(alias: alias, environment: environment)
                try Task.checkCancellation()
                configuration = result
                isResolving = false
            } catch {
                if !Task.isCancelled { isResolving = false }
            }
        }
    }
}

private struct HostInformationRow: View {
    let title: String
    let value: String?
    let identifier: String
    var placeholder = String(localized: "Unknown")
    @State private var isCopied = false

    var body: some View {
        HStack(spacing: 12) {
            CommandInfoRow(title: LocalizedStringKey(title), value: value ?? placeholder)
            Button {
                guard let value, !value.isEmpty else { return }
                NSPasteboard.general.clearContents()
                isCopied = NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(FamilyButtonStyle())
            .disabled(value?.isEmpty != false)
            .help(isCopied ? String(localized: "Copied") : String(format: String(localized: "Copy %@"), title))
            .accessibilityLabel(String(format: String(localized: "Copy %@"), title))
            .accessibilityIdentifier("hostInformation.copy." + identifier)
            .task(id: isCopied) {
                guard isCopied else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                isCopied = false
            }
        }
    }
}
