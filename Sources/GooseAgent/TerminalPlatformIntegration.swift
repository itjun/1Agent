import AppKit
import Carbon
import Combine

@MainActor
final class QuickTerminalController: ObservableObject {
    static let shared = QuickTerminalController()
    @Published private(set) var registrationError: String?
    private weak var model: AppModel?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var previousApplication: NSRunningApplication?

    func start(model: AppModel) {
        self.model = model
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var identity = EventHotKeyID()
            guard let event, GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &identity) == noErr,
                  identity.signature == 0x31416774, identity.id == 1 else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in
                guard !ShortcutRecorder.isRecording else { return }
                QuickTerminalController.shared.toggle()
            }
            return noErr
        }, 1, &type, nil, &handler)
        refreshRegistration()
        for state in model.windows where state.isQuickTerminal {
            configure(state)
            MainWindowManager.shared.window(for: state)?.orderOut(nil)
        }
    }

    func refreshRegistration() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        registrationError = nil
        let chord = AppShortcuts.chord(for: .quickTerminal)
        guard !chord.isUnbound else { return }
        guard let code = Self.keyCode(for: chord.key) else { registrationError = String(localized: "This global shortcut is unavailable for the current keyboard layout."); return }
        var modifiers: UInt32 = 0
        if chord.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if chord.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if chord.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        if chord.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let status = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x31416774, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { registrationError = String(localized: "The global shortcut is already in use or could not be registered. Choose another shortcut in Hotkeys.") }
    }

    func toggle() {
        guard let model, !model.isQuitting, !(NSApp.keyWindow is FamilyModalWindow) else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let existingState = model.windows.first(where: \.isQuickTerminal)
        let state: WindowState
        if let existing = existingState { state = existing }
        else {
            state = model.createWindow()
            state.isQuickTerminal = true
            model.openLocalTerminal(at: LocalTerminal.homeDirectory, in: state)
        }
        if existingState != nil, let native = MainWindowManager.shared.window(for: state), native.isVisible, native.isKeyWindow {
            native.orderOut(nil)
            model.persistSessionIfReady()
            previousApplication?.activate()
            return
        }
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = frontmost
        }
        configure(state)
        MainWindowManager.shared.show(state, model: model)
        if let tab = model.selectedTab(in: state) { SSHTerminalRegistry.focus(tab.sessionID) }
    }

    /// A floating quick terminal must not cover the settings window it opens.
    func hideForSettings() {
        guard let model, let state = model.windows.first(where: \.isQuickTerminal) else { return }
        MainWindowManager.shared.window(for: state)?.orderOut(nil)
        model.persistSessionIfReady()
    }

    private func configure(_ state: WindowState) {
        guard let native = MainWindowManager.shared.window(for: state) else { return }
        native.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        native.level = .floating
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let screen {
            let frame = screen.visibleFrame
            let width = max(min(frame.width, 1100), min(880, frame.width))
            let height = max(min(frame.height * 0.6, 720), min(520, frame.height))
            native.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height), display: true)
        }
    }

    static func keyCode(for key: String) -> UInt32? {
        let special: [String: UInt32] = ["\r": 36, "\t": 48, " ": 49, "\u{1b}": 53, "\u{7f}": 51,
                                           KeyChord.leftArrow: 123, KeyChord.rightArrow: 124, KeyChord.downArrow: 125, KeyChord.upArrow: 126,
                                           KeyChord.home: 115, KeyChord.end: 119, KeyChord.pageUp: 116, KeyChord.pageDown: 121,
                                           KeyChord.forwardDelete: 117]
        if let code = special[key] { return code }
        let functionCodes: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        if key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first {
            let index = Int(scalar.value) - Int(NSF1FunctionKey)
            if functionCodes.indices.contains(index) { return functionCodes[index] }
        }
        if key == "`" { return 50 }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for code in UInt16(0)...UInt16(127) {
            var dead: UInt32 = 0, length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            guard UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                 &dead, chars.count, &length, &chars) == noErr, length > 0 else { continue }
            if String(utf16CodeUnits: chars, count: length).lowercased() == key.lowercased() { return UInt32(code) }
        }
        return nil
    }
}
