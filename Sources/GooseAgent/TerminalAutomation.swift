import AppKit
import GhosttyTerminal
import GhosttyKit
import Security

struct TerminalCreationConfiguration {
    var directory: String?
    var command: String?
    var initialInput: String?
    var waitAfterCommand = false
    var environment: [String] = []
    var fontSize: Float?

    init(record: NSDictionary? = nil) throws {
        var fields: [String: Any] = [:]
        for (key, value) in record ?? [:] {
            if let key = key as? String { fields[key] = value }
            else if let key = key as? NSNumber { fields[Self.code(key.uint32Value)] = value }
        }
        func value(_ name: String, _ code: String) -> Any? { fields[name] ?? fields[code] }
        func text(_ name: String, _ code: String) throws -> String? {
            guard let value = value(name, code) else { return nil }
            guard let string = value as? String, !string.contains("\0") else { throw AutomationFailure.invalidConfiguration }
            return string
        }
        directory = try text("workingDirectory", "GScD").flatMap { $0.isEmpty ? nil : $0 }
        command = try text("command", "GScC").flatMap { $0.isEmpty ? nil : $0 }
        initialInput = try text("initialInput", "GScI").flatMap { $0.isEmpty ? nil : $0 }
        if let size = value("fontSize", "GScF") {
            guard let number = size as? NSNumber, number.doubleValue.isFinite,
                  number.doubleValue == 0 || (4...200).contains(number.doubleValue) else { throw AutomationFailure.invalidConfiguration }
            if number.doubleValue > 0 { fontSize = number.floatValue }
        }
        if let wait = value("waitAfterCommand", "GScW") {
            guard let wait = wait as? NSNumber else { throw AutomationFailure.invalidConfiguration }
            waitAfterCommand = wait.boolValue
        }
        if let variables = value("environmentVariables", "GScE") {
            guard let variables = variables as? [String], variables.allSatisfy({ entry in
                guard let equal = entry.firstIndex(of: "="), equal != entry.startIndex, !entry.contains("\0") else { return false }
                return entry[..<equal].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            }) else { throw AutomationFailure.invalidConfiguration }
            environment = variables
        }
    }

    static func code(_ number: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((number >> $0) & 255) }, encoding: .macOSRoman) ?? ""
    }

    var record: NSDictionary {
        ["fontSize": fontSize ?? 0, "workingDirectory": directory ?? "", "command": command ?? "",
         "initialInput": initialInput ?? "", "waitAfterCommand": waitAfterCommand, "environmentVariables": environment]
    }
}

enum AutomationFailure: LocalizedError {
    case missingObject, invalidDirectory, invalidConfiguration, invalidInput, unavailable, disabled
    var errorDescription: String? {
        switch self {
        case .missingObject: String(localized: "The requested window or terminal no longer exists.")
        case .invalidDirectory: String(localized: "The requested working directory is unavailable.")
        case .invalidConfiguration: String(localized: "The terminal creation configuration is invalid.")
        case .invalidInput: String(localized: "The requested key, modifier, or action is invalid.")
        case .unavailable: String(localized: "The terminal is not ready for this operation.")
        case .disabled: String(localized: "Terminal automation is disabled in System Integration settings.")
        }
    }
}

@MainActor
enum TerminalAutomation {
    static weak var model: AppModel?
    static let enabledKey = "app.systemIntegration.automationEnabled"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) == nil || UserDefaults.standard.bool(forKey: enabledKey) }
    static var hasDeveloperTeamSignature: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return false }
        return !team.isEmpty
    }

    static func specifier(key: String, id: String) -> NSScriptObjectSpecifier? {
        guard let description = NSScriptSuiteRegistry.shared().classDescription(withAppleEventCode: 0x63617070) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: nil, key: key, uniqueID: id)
    }

    static func window(_ id: UUID) -> ScriptTerminalWindow { ScriptTerminalWindow(id) }
    static func terminal(_ id: UUID) -> ScriptTerminal { ScriptTerminal(id) }
    static func tab(_ id: UUID) -> ScriptTerminalTab { ScriptTerminalTab(id) }

    static func resolve(_ value: Any?) -> Any? {
        if let specifier = value as? NSScriptObjectSpecifier { return specifier.objectsByEvaluatingSpecifier }
        return value
    }

    static func readyView(_ id: UUID) async throws -> SSHTerminalNSView {
        for _ in 0..<250 {
            guard let model, let tab = model.tabs.first(where: { $0.id == id }), tab.hasTerminal, !tab.exited else { throw AutomationFailure.missingObject }
            if let view = SSHTerminalRegistry.automationView(tab.sessionID), view.attachedSurface != nil,
               view.processHost?.process.shellPid ?? 0 > 0 { return view }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw AutomationFailure.unavailable
    }

    static func modifiers(_ text: String?) throws -> TerminalInputModifiers {
        var result: TerminalInputModifiers = []
        for part in (text ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            switch part {
            case "shift": result.insert(.shift)
            case "control", "ctrl": result.insert(.ctrl)
            case "option", "alt": result.insert(.alt)
            case "command", "super": result.insert(.super_)
            default: throw AutomationFailure.invalidInput
            }
        }
        return result
    }
}

@MainActor
extension NSApplication {
    @objc(handleOneAgentQuit:)
    func handleOneAgentQuit(_ command: NSScriptCommand) { terminate(nil) }
    @objc(valueInOneAgentWindowsWithUniqueID:)
    func oneAgentWindow(uniqueID: String) -> ScriptTerminalWindow? { oneAgentWindows.first { $0.id == uniqueID } }
    @objc(valueInOneAgentTerminalsWithUniqueID:)
    func oneAgentTerminal(uniqueID: String) -> ScriptTerminal? { oneAgentTerminals.first { $0.id == uniqueID } }
    @objc(valueInOneAgentTabsWithUniqueID:)
    func oneAgentTab(uniqueID: String) -> ScriptTerminalTab? { oneAgentTabs.first { $0.id == uniqueID } }
    @objc var oneAgentWindows: [ScriptTerminalWindow] {
        guard TerminalAutomation.isEnabled, let model = TerminalAutomation.model else { return [] }
        return model.windows.filter { MainWindowManager.shared.window(for: $0) != nil }.map { TerminalAutomation.window($0.id) }
    }
    @objc var oneAgentFrontWindow: ScriptTerminalWindow? { TerminalAutomation.isEnabled ? TerminalAutomation.model?.keyWindow.map { TerminalAutomation.window($0.id) } : nil }
    @objc var oneAgentTerminals: [ScriptTerminal] { TerminalAutomation.isEnabled ? (TerminalAutomation.model?.tabs.filter(\.hasTerminal).map { TerminalAutomation.terminal($0.id) } ?? []) : [] }
    @objc var oneAgentTabs: [ScriptTerminalTab] {
        guard TerminalAutomation.isEnabled, let model = TerminalAutomation.model else { return [] }
        return model.windows.flatMap { model.panelRows(in: $0).map { TerminalAutomation.tab($0.id) } }
    }
}

@objc(OneAgentScriptWindow)
@MainActor
final class ScriptTerminalWindow: NSObject {
    let uuid: UUID
    init(_ id: UUID) { uuid = id; super.init() }
    var state: WindowState? { TerminalAutomation.model?.window(for: uuid) }
    @objc var id: String { uuid.uuidString }
    @objc var title: String { state.flatMap { MainWindowManager.shared.window(for: $0)?.title } ?? "" }
    @objc var tabs: [ScriptTerminalTab] { guard let model = TerminalAutomation.model, let state else { return [] }; return model.panelRows(in: state).map { TerminalAutomation.tab($0.id) } }
    @objc var terminals: [ScriptTerminal] { guard let model = TerminalAutomation.model, let state else { return [] }; return model.sidebarOrder(in: state).map { TerminalAutomation.terminal($0) } }
    @objc var selectedTab: ScriptTerminalTab? { guard let model = TerminalAutomation.model, let state, let selected = state.selectedTabID, let row = model.panelRow(for: selected, in: state) else { return nil }; return TerminalAutomation.tab(row.id) }
    @objc(valueInTabsWithUniqueID:)
    func tab(uniqueID: String) -> ScriptTerminalTab? { tabs.first { $0.id == uniqueID } }
    @objc(valueInTerminalsWithUniqueID:)
    func terminal(uniqueID: String) -> ScriptTerminal? { terminals.first { $0.id == uniqueID } }
    override var objectSpecifier: NSScriptObjectSpecifier? { TerminalAutomation.specifier(key: "oneAgentWindows", id: id) }
}

@objc(OneAgentScriptTab)
@MainActor
final class ScriptTerminalTab: NSObject {
    let uuid: UUID
    init(_ id: UUID) { uuid = id; super.init() }
    var owner: WindowState? { guard let model = TerminalAutomation.model else { return nil }; return model.windows.first { model.panelRows(in: $0).contains { $0.id == uuid } } }
    var row: TerminalPanelRow? { guard let model = TerminalAutomation.model, let owner else { return nil }; return model.panelRows(in: owner).first { $0.id == uuid } }
    @objc var id: String { uuid.uuidString }
    @objc var title: String { row?.name ?? "" }
    @objc var index: Int { guard let model = TerminalAutomation.model, let owner else { return 0 }; return (model.panelRows(in: owner).firstIndex { $0.id == uuid } ?? -1) + 1 }
    @objc var selected: Bool { guard let owner, let current = owner.selectedTabID else { return false }; return row?.leafIDs.contains(current) == true }
    @objc var focusedTerminal: ScriptTerminal? { row.map { TerminalAutomation.terminal($0.focusedTabID) } }
    @objc var terminals: [ScriptTerminal] { row?.leafIDs.map { TerminalAutomation.terminal($0) } ?? [] }
    @objc(valueInTerminalsWithUniqueID:)
    func terminal(uniqueID: String) -> ScriptTerminal? { terminals.first { $0.id == uniqueID } }
    override var objectSpecifier: NSScriptObjectSpecifier? { TerminalAutomation.specifier(key: "oneAgentTabs", id: id) }
}

@objc(OneAgentScriptTerminal)
@MainActor
final class ScriptTerminal: NSObject {
    let uuid: UUID
    init(_ id: UUID) { uuid = id; super.init() }
    var tab: TerminalTab? { TerminalAutomation.model?.tabs.first { $0.id == uuid } }
    @objc var id: String { uuid.uuidString }
    @objc var title: String { guard let model = TerminalAutomation.model, let tab else { return "" }; return model.sessionTitle(tab) }
    @objc var workingDirectory: String { guard let tab else { return "" }; return tab.isLocal ? SSHTerminalRegistry.currentWorkingDirectory(for: tab.sessionID) ?? tab.directory ?? "" : tab.remoteDirectory ?? "" }
    override var objectSpecifier: NSScriptObjectSpecifier? { TerminalAutomation.specifier(key: "oneAgentTerminals", id: id) }
}

/// All mutating commands share one asynchronous dispatcher, including strict object validation.
@objc(OneAgentScriptCommand)
final class TerminalScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()
        Task { @MainActor in
            let result: Any?
            do {
                let value = try await execute()
                // Serialize object references before Cocoa Scripting processes the reply.
                // An absent/incomplete object specifier must be an ordinary script error.
                if let object = value as? ScriptTerminalWindow { try validateReply(object) }
                else if let object = value as? ScriptTerminalTab { try validateReply(object) }
                else if let object = value as? ScriptTerminal { try validateReply(object) }
                result = value
            } catch { scriptErrorNumber = -1708; scriptErrorString = error.localizedDescription; result = nil }
            OneAgentResumeScriptCommand(self, result, String(localized: "The automation reply could not be converted. The command was stopped safely."))
        }
        return nil
    }

    @MainActor private func validateReply(_ object: NSObject) throws {
        guard object.objectSpecifier?.descriptor != nil else { throw AutomationFailure.unavailable }
    }

    @MainActor
    private func execute() async throws -> Any? {
        guard TerminalAutomation.isEnabled else { throw AutomationFailure.disabled }
        guard let model = TerminalAutomation.model else { throw AutomationFailure.unavailable }
        let args = evaluatedArguments ?? [:]
        let name = commandDescription.commandName
        let direct = TerminalAutomation.resolve(directParameter)
        let configuration = try TerminalCreationConfiguration(record: args["configuration"] as? NSDictionary)
        func terminal(_ value: Any?) throws -> ScriptTerminal {
            guard let object = TerminalAutomation.resolve(value) as? ScriptTerminal, object.tab != nil else { throw AutomationFailure.missingObject }; return object
        }
        func window(_ value: Any?) throws -> WindowState {
            guard let object = TerminalAutomation.resolve(value) as? ScriptTerminalWindow, let state = object.state else { throw AutomationFailure.missingObject }; return state
        }
        switch name {
        case "new surface configuration": return configuration.record
        case "new window":
            let state = model.createWindow()
            do { _ = try await model.createScriptTerminal(configuration: configuration, in: state) }
            catch { MainWindowManager.shared.closeImmediately(state); throw error }
            return TerminalAutomation.window(state.id)
        case "new tab":
            let state = try args["window"].map { try window($0) } ?? model.keyWindow ?? model.createWindow()
            let id = try await model.createScriptTerminal(configuration: configuration, in: state)
            return TerminalAutomation.tab(id)
        case "split":
            let source = try terminal(direct)
            guard let state = model.window(containing: source.uuid) else { throw AutomationFailure.missingObject }
            let direction = (args["direction"] as? NSNumber).map { TerminalCreationConfiguration.code($0.uint32Value) } ?? "GSrt"
            let edge: SplitEdge
            switch direction { case "GSrt": edge = .right; case "GSlf": edge = .left; case "GSdn": edge = .bottom; case "GSup": edge = .top; default: throw AutomationFailure.invalidInput }
            return TerminalAutomation.terminal(try await model.createScriptTerminal(configuration: configuration, in: state, splitting: source.uuid, edge: edge))
        case "focus", "close":
            let object = try terminal(direct)
            if name == "close" { model.closeTab(object.uuid) }
            else if let state = model.window(containing: object.uuid) { MainWindowManager.shared.show(state, model: model); model.selectOnly(object.uuid, in: state) }
            return nil
        case "activate window": MainWindowManager.shared.show(try window(direct), model: model); return nil
        case "close window": MainWindowManager.shared.closeImmediately(try window(direct)); return nil
        case "select tab", "close tab":
            guard let object = direct as? ScriptTerminalTab, let state = object.owner, let row = object.row else { throw AutomationFailure.missingObject }
            if name == "close tab" { model.closePanel(row.id, in: state) }
            else { MainWindowManager.shared.show(state, model: model); model.selectPanel(row.id, in: state) }
            return nil
        case "input text":
            let object = try terminal(args["terminal"])
            guard let text = direct as? String, !text.contains("\0") else { throw AutomationFailure.invalidInput }
            let view = try await TerminalAutomation.readyView(object.uuid)
            guard view.attachedSurface?.paste(text: text) == true else { throw AutomationFailure.unavailable }
            return nil
        case "perform action":
            let object = try terminal(args["on"])
            guard let action = direct as? String else { throw AutomationFailure.invalidInput }
            if action == "new_window" {
                let directory = object.tab?.isLocal == true && !object.workingDirectory.isEmpty
                    ? object.workingDirectory : LocalTerminal.homeDirectory
                model.newWindow(at: directory)
                return true
            }
            if action == "new_tab", let state = model.window(containing: object.uuid) { model.duplicateAsTab(object.uuid, in: state); return true }
            if action.hasPrefix("set_tab_title:"), let state = model.window(containing: object.uuid), let row = model.panelRow(for: object.uuid, in: state) { model.renamePanel(row.id, to: String(action.dropFirst(14)), in: state); return true }
            return try await TerminalAutomation.readyView(object.uuid).performBindingAction(action)
        case "send key", "send mouse button", "send mouse position", "send mouse scroll":
            let object = try terminal(args["terminal"])
            let view = try await TerminalAutomation.readyView(object.uuid)
            let modifiers = try TerminalAutomation.modifiers(args["modifiers"] as? String)
            if name == "send key" {
                guard let text = direct as? String else { throw AutomationFailure.invalidInput }
                let named: [String: TerminalKey] = ["return": .enter, "up": .arrowUp, "down": .arrowDown, "left": .arrowLeft, "right": .arrowRight]
                let name = text.lowercased().replacingOccurrences(of: "_", with: "")
                let physical = named[name] ?? TerminalKey.allCases.first { String(describing: $0).lowercased() == name }
                let key = (text.count == 1 ? TerminalKeyPress(typing: text.first!, modifiers: modifiers) : nil)
                    ?? physical.map { TerminalKeyPress($0, modifiers: modifiers) }
                guard let key else { throw AutomationFailure.invalidInput }
                let release = (args["action"] as? NSNumber).map { TerminalCreationConfiguration.code($0.uint32Value) } == "GIrl"
                guard view.attachedSurface?.sendScriptKey(key, release: release) == true else { throw AutomationFailure.unavailable }
            } else if name == "send mouse position" {
                guard let x = args["x"] as? NSNumber, let y = args["y"] as? NSNumber, x.doubleValue.isFinite, y.doubleValue.isFinite else { throw AutomationFailure.invalidInput }
                view.sendMousePos(x: x.doubleValue, y: y.doubleValue, modifiers: modifiers)
            } else if name == "send mouse button" {
                let code = (direct as? NSNumber).map { TerminalCreationConfiguration.code($0.uint32Value) }
                let button: ghostty_input_mouse_button_e
                switch code { case "GMlf": button = GHOSTTY_MOUSE_LEFT; case "GMrt": button = GHOSTTY_MOUSE_RIGHT; case "GMmd": button = GHOSTTY_MOUSE_MIDDLE; default: throw AutomationFailure.invalidInput }
                let release = (args["action"] as? NSNumber).map { TerminalCreationConfiguration.code($0.uint32Value) } == "GIrl"
                _ = view.sendMouseButton(state: release ? GHOSTTY_MOUSE_RELEASE : GHOSTTY_MOUSE_PRESS, button: button, modifiers: modifiers)
            } else {
                guard let x = args["x"] as? NSNumber, let y = args["y"] as? NSNumber, x.doubleValue.isFinite, y.doubleValue.isFinite else { throw AutomationFailure.invalidInput }
                view.sendMouseScroll(x: x.doubleValue, y: y.doubleValue, mods: TerminalScrollModifiers(precision: (args["precision"] as? NSNumber)?.boolValue ?? false))
            }
            return nil
        default: throw AutomationFailure.invalidInput
        }
    }
}

@MainActor
extension ScriptTerminalWindow {
    @objc(handleOneAgentCommand:)
    func handleOneAgentCommand(_ command: TerminalScriptCommand) -> Any? { command.performDefaultImplementation() }
}
@MainActor
extension ScriptTerminalTab {
    @objc(handleOneAgentCommand:)
    func handleOneAgentCommand(_ command: TerminalScriptCommand) -> Any? { command.performDefaultImplementation() }
}
@MainActor
extension ScriptTerminal {
    @objc(handleOneAgentCommand:)
    func handleOneAgentCommand(_ command: TerminalScriptCommand) -> Any? { command.performDefaultImplementation() }
}
