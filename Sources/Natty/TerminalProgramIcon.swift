import SwiftUI

@MainActor
final class TerminalProgramStatus: ObservableObject {
    static let shared = TerminalProgramStatus()
    @Published private(set) var programs: [String: TerminalProgram] = [:]

    func update(_ program: TerminalProgram?, sessionID: String) {
        if programs[sessionID] != program { programs[sessionID] = program }
    }
}

struct TerminalProgramIcon: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject private var shell = RemoteShellStatus.shared
    @ObservedObject private var local = TerminalProgramStatus.shared
    let tab: TerminalTab

    private var program: TerminalProgram {
        if tab.exited { return .init(kind: .shell, name: tab.isLocal ? (LocalTerminal.shellExecutable as NSString).lastPathComponent : "SSH") }
        if let state = shell.states[tab.sessionID], state.isRunning,
           let command = state.runningCommand, let identified = TerminalProgram.identify(command: command),
           identified.kind != .command { return identified }
        if let identified = local.programs[tab.sessionID] { return identified }
        if let state = shell.states[tab.sessionID], state.isRunning, let command = state.runningCommand,
           let identified = TerminalProgram.identify(command: command) { return identified }
        return .init(kind: .shell, name: tab.isLocal ? (LocalTerminal.shellExecutable as NSString).lastPathComponent : "SSH")
    }

    var body: some View {
        let current = program
        Group {
            switch current.kind {
            case .shell, .command: Image(systemName: "terminal")
            case .claude: Image(systemName: "asterisk")
            case .htop: Image(systemName: "chart.bar.xaxis")
            case .btop: Image(systemName: "gauge.with.dots.needle.33percent")
            default: Image("ProgramIcon-" + current.kind.rawValue).renderingMode(.template).resizable().scaledToFit()
            }
        }
        .font(.system(size: 16, weight: .regular))
        .frame(width: 18, height: 18)
        .foregroundStyle(chrome.secondary)
        .help(String(format: String(localized: "Current program: %@"), current.name))
        .accessibilityLabel(Text(verbatim: String(format: String(localized: "Current program: %@"), current.name)))
    }
}
