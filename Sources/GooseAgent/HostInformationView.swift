import SwiftUI

/// Shared by the workspace and native presentation tests so the complete binding is exercised.
struct HostInformationPresentation: ViewModifier {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState

    func body(content: Content) -> some View {
        content.familySheet(isPresented: optionalBinding($window.hostInformationTabID), width: SheetLayout.hostInformation, height: SheetLayout.hostInformationHeight) {
            if let tabID = window.hostInformationTabID {
                HostInformationView(model: model, tabID: tabID) { window.hostInformationTabID = nil }
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

    var body: some View {
        CommandDialog(title: "Host Information", close: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let tab = model.tabs.first(where: { $0.id == tabID && $0.hasTerminal }) {
                        CommandInfoRow(title: "Target Host", value: tab.isLocal ? String(localized: "This Mac") : tab.alias ?? String(localized: "Unknown"))
                        CommandInfoRow(title: "Connection", value: !tab.exited && !tab.reconnecting ? String(localized: "Connected") : String(localized: "Not connected"))
                        if !tab.isLocal {
                            let host = model.hosts.first { $0.alias == tab.alias }
                            CommandInfoRow(title: "Address", value: host?.hostName ?? String(localized: "Unknown"))
                            CommandInfoRow(title: "User", value: host?.user ?? String(localized: "Unknown"))
                            CommandInfoRow(title: "Port", value: host?.port ?? "22")
                        }
                        CommandInfoRow(title: "Working Directory", value: TerminalPaneActions.workingDirectory(of: tab) ?? String(localized: "Directory unknown"))
                        CommandInfoRow(title: "Shell", value: tab.isLocal ? LocalTerminal.shellExecutable : String(localized: "Unknown"))
                    } else {
                        Text("Not connected")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            Button("Close", action: onClose).buttonStyle(FamilyButtonStyle())
                .accessibilityIdentifier("hostInformation.close")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hostInformation.dialog")
    }
}
