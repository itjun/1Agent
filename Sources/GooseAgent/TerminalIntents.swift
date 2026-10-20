import AppIntents
import Foundation

struct Open1AgentTerminalIntent: AppIntent {
    static var title: LocalizedStringResource = "Open 1Agent Terminal"
    static var description = IntentDescription("Open a new terminal in an explicit local directory.")
    static var openAppWhenRun = true
    @Parameter(title: "Working Directory", default: "") var directory: String
    @Parameter(title: "New Window", default: false) var newWindow: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard TerminalAutomation.isEnabled else { throw AutomationFailure.disabled }
        guard let model = TerminalAutomation.model else { throw AutomationFailure.unavailable }
        var config = try TerminalCreationConfiguration()
        config.directory = directory.isEmpty ? nil : directory
        let state = newWindow ? model.createWindow() : (model.keyWindow ?? model.createWindow())
        return .result(value: try await model.createScriptTerminal(configuration: config, in: state).uuidString)
    }
}

struct Focus1AgentTerminalIntent: AppIntent {
    static var title: LocalizedStringResource = "Focus 1Agent Terminal"
    static var openAppWhenRun = true
    @Parameter(title: "Terminal ID") var terminalID: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard TerminalAutomation.isEnabled else { throw AutomationFailure.disabled }
        guard let model = TerminalAutomation.model, let id = UUID(uuidString: terminalID), let state = model.window(containing: id) else { throw AutomationFailure.missingObject }
        MainWindowManager.shared.show(state, model: model)
        model.selectOnly(id, in: state)
        return .result()
    }
}

struct Input1AgentTerminalIntent: AppIntent {
    static var title: LocalizedStringResource = "Input Text to 1Agent Terminal"
    static var description = IntentDescription("Send text to the terminal with the specified ID. Execution requires an explicit newline.")
    static var openAppWhenRun = true
    @Parameter(title: "Terminal ID") var terminalID: String
    @Parameter(title: "Text") var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard TerminalAutomation.isEnabled else { throw AutomationFailure.disabled }
        guard let id = UUID(uuidString: terminalID), !text.contains("\0") else { throw AutomationFailure.invalidInput }
        let view = try await TerminalAutomation.readyView(id)
        guard view.attachedSurface?.paste(text: text) == true else { throw AutomationFailure.unavailable }
        return .result()
    }
}
