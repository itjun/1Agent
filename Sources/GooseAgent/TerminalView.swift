import AppKit
import CoreText
import GhosttyTerminal
import GhosttyTheme
import SwiftUI

enum TerminalDefaults {
    static let defaultFontSize: Double = 13
    static let defaultFontWeight: Double = 0
    static let defaultLineSpacing: Double = 1
    static let darkBackgroundHex = "#101012"
    static let darkForegroundHex = "#D6D6D6"
    static let lightBackgroundHex = "#FFFFFF"
    static let lightForegroundHex = "#3A3A3A"
    static let symbolFallbackFamily = "Symbols Nerd Font Mono"

    static let darkPalette: [(red: Int, green: Int, blue: Int)] = [
        (0, 0, 0), (194, 54, 33), (37, 188, 36), (173, 173, 39),
        (73, 46, 225), (211, 56, 211), (51, 187, 200), (203, 204, 205),
        (129, 131, 131), (252, 57, 31), (49, 231, 34), (234, 236, 35),
        (88, 51, 255), (249, 53, 248), (20, 240, 240), (233, 235, 235),
    ]

    static let lightPalette: [(red: Int, green: Int, blue: Int)] = darkPalette.map { color in
        let flipped = LightTerminalANSIAdapter.lightRGB(
            red: color.red,
            green: color.green,
            blue: color.blue
        )
        let originalContrast = LightTerminalANSIAdapter.contrastOnWhite(
            red: color.red, green: color.green, blue: color.blue
        )
        let flippedContrast = LightTerminalANSIAdapter.contrastOnWhite(
            red: flipped.red, green: flipped.green, blue: flipped.blue
        )
        return originalContrast >= flippedContrast ? color : flipped
    }

    static func registerBundledFonts() {
        guard let url = Bundle.main.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

@MainActor
enum GhosttyRuntime {
    static let controller = TerminalController(
        configSource: appearanceConfigSource,
        theme: builtinTheme()
    )

    static var appearanceConfigSource: TerminalController.ConfigSource {
        guard let light = Bundle.main.url(forResource: "TerminalLight", withExtension: "ghostty"),
              let dark = Bundle.main.url(forResource: "TerminalDark", withExtension: "ghostty") else {
            preconditionFailure("Missing bundled terminal appearance markers")
        }
        return .generated(TerminalConfiguration.default.rendered
            + "\ntheme = light:\(light.path),dark:\(dark.path)\n")
    }

    static func applyFontSettings() {
        controller.setTerminalConfiguration(fontConfiguration())
    }

    /// Each family supplies a light and a night palette. Ghostty switches with the appearance.
    static func apply(family: TerminalThemeFamily) {
        let builtin = builtinTheme()
        let light = family.lightConfiguration() ?? builtin.light
        let dark = family.darkConfiguration() ?? builtin.dark
        controller.setTheme(TerminalTheme(light: light, dark: dark))
    }

    private static func fontConfiguration() -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withFontSize(Float(TerminalDefaults.defaultFontSize))
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(true)
            builder.withFontThicken(false)
            builder.withFontFamily("SF Mono")
            builder.withCustom("macos-option-as-alt", "true")
            builder.withCustom("keybind", "super+c=unbind")
            builder.withCustom("clipboard-write", "allow")
            builder.withCustom("mouse-shift-capture", "never")
            builder.withCustom("font-codepoint-map", "U+E000-U+F8FF=\(TerminalDefaults.symbolFallbackFamily)")
            builder.withCustom("font-codepoint-map", "U+F0000-U+FFFFD=\(TerminalDefaults.symbolFallbackFamily)")
            builder.withCustom("font-codepoint-map", "U+100000-U+10FFFD=\(TerminalDefaults.symbolFallbackFamily)")
        }
    }

    private static func builtinTheme() -> TerminalTheme {
        let dark = TerminalConfiguration { builder in
            builder.withBackground(TerminalDefaults.darkBackgroundHex)
            builder.withForeground(TerminalDefaults.darkForegroundHex)
            builder.withSelectionBackground(Theme.accentHex(dark: true))
            builder.withSelectionForeground(TerminalDefaults.darkBackgroundHex)
            for (index, color) in TerminalDefaults.darkPalette.enumerated() {
                builder.withPalette(index, color: hex(color))
            }
        }
        let light = TerminalConfiguration { builder in
            builder.withBackground(TerminalDefaults.lightBackgroundHex)
            builder.withForeground(TerminalDefaults.lightForegroundHex)
            builder.withSelectionBackground(Theme.accentHex(dark: false))
            builder.withSelectionForeground(TerminalDefaults.lightBackgroundHex)
            for (index, color) in TerminalDefaults.lightPalette.enumerated() {
                builder.withPalette(index, color: hex(color))
            }
        }
        return TerminalTheme(light: light, dark: dark)
    }

    private static func hex(_ color: (red: Int, green: Int, blue: Int)) -> String {
        String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
    }
}

extension GhosttyThemeDefinition {
    func terminalConfiguration() -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withBackground(Self.ghosttyHex(background))
            builder.withForeground(Self.ghosttyHex(foreground))
            if let cursorColor { builder.withCursorColor(Self.ghosttyHex(cursorColor)) }
            if let cursorText { builder.withCursorText(Self.ghosttyHex(cursorText)) }
            if let selectionBackground { builder.withSelectionBackground(Self.ghosttyHex(selectionBackground)) }
            if let selectionForeground { builder.withSelectionForeground(Self.ghosttyHex(selectionForeground)) }
            for (index, color) in palette.sorted(by: { $0.key < $1.key }) {
                builder.withPalette(index, color: Self.ghosttyHex(color))
            }
        }
    }

    static func ghosttyHex(_ raw: String) -> String {
        raw.hasPrefix("#") ? raw : "#\(raw)"
    }

    /// Light backgrounds belong in the white-theme list. Night themes stay in the other list.
    var isLightBackground: Bool {
        Self.relativeLuminance(of: background) >= 0.45
    }

    private static func relativeLuminance(of raw: String) -> Double {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return 0 }
        func channel(_ component: Int) -> Double {
            let s = Double(component) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let red = channel((value >> 16) & 0xFF)
        let green = channel((value >> 8) & 0xFF)
        let blue = channel(value & 0xFF)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}

enum TerminalAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearance.colorScheme"
    static let lightThemeKey = "appearance.terminalTheme.light"
    static let darkThemeKey = "appearance.terminalTheme.dark"
    /// Previous single-theme choice, copied into the matching light or dark slot once.
    static let legacyThemeKey = "appearance.terminalTheme"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "Follow System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    func isDark(system: ColorScheme) -> Bool {
        switch self {
        case .system: system == .dark
        case .light: false
        case .dark: true
        }
    }

    static func migrateLegacyThemeIfNeeded() {
        let defaults = UserDefaults.standard
        let legacy = defaults.string(forKey: legacyThemeKey) ?? ""
        guard !legacy.isEmpty, let theme = GhosttyThemeCatalog.theme(named: legacy) else { return }
        let key = theme.isLightBackground ? lightThemeKey : darkThemeKey
        if (defaults.string(forKey: key) ?? "").isEmpty {
            defaults.set(legacy, forKey: key)
        }
        defaults.removeObject(forKey: legacyThemeKey)
    }
}

/// Codex Absolutely colors. `surface` is the window, `ink` is the text, `accent` is the highlight.
struct AbsolutelyTheme {
    var surface: String
    var ink: String
    var accent: String
    var added: String
    var removed: String

    static let light = AbsolutelyTheme(
        surface: "#f9f9f7",
        ink: "#2d2d2b",
        accent: "#cc7d5e",
        added: "#00c853",
        removed: "#ff5f38"
    )

    static let dark = AbsolutelyTheme(
        surface: "#2d2d2b",
        ink: "#f9f9f7",
        accent: "#cc7d5e",
        added: "#00c853",
        removed: "#ff5f38"
    )

    func terminalConfiguration() -> TerminalConfiguration {
        let warm = "#8a7064"
        let brightWarm = "#d49278"
        return TerminalConfiguration { builder in
            builder.withBackground(surface)
            builder.withForeground(ink)
            builder.withCursorColor(accent)
            builder.withCursorText("#2d2d2b")
            builder.withSelectionBackground(accent)
            builder.withSelectionForeground(surface)
            let colors = [
                ink, removed, added, accent, warm, removed, added, ink,
                warm, removed, added, brightWarm, warm, removed, added, surface,
            ]
            for (index, color) in colors.enumerated() {
                builder.withPalette(index, color: color)
            }
        }
    }

    func chrome() -> WindowChrome {
        WindowChrome(theme: GhosttyThemeDefinition(
            name: "Absolutely",
            background: surface,
            foreground: ink,
            cursorColor: accent,
            palette: [1: removed, 2: added, 4: accent]
        ))
    }
}

/// A small set of light/night pairs. Appearance mode chooses which half is on screen.
enum TerminalThemeFamily: String, CaseIterable, Identifiable {
    case absolutely
    case github
    case ayu
    case oneHalf

    static let storageKey = "appearance.themeFamily"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .absolutely: "Absolutely"
        case .github: "GitHub"
        case .ayu: "Ayu"
        case .oneHalf: "One Half"
        }
    }

    var lightName: String? {
        switch self {
        case .absolutely: nil
        case .github: "GitHub Light Default"
        case .ayu: "Ayu Light"
        case .oneHalf: "One Half Light"
        }
    }

    var darkName: String? {
        switch self {
        case .absolutely: nil
        case .github: "GitHub Dark Default"
        case .ayu: "Ayu"
        case .oneHalf: "One Half Dark"
        }
    }

    var lightPaint: AbsolutelyTheme? {
        self == .absolutely ? .light : nil
    }

    var darkPaint: AbsolutelyTheme? {
        self == .absolutely ? .dark : nil
    }

    func lightConfiguration() -> TerminalConfiguration? {
        if let lightPaint { return lightPaint.terminalConfiguration() }
        return lightName.flatMap { GhosttyThemeCatalog.theme(named: $0)?.terminalConfiguration() }
    }

    func darkConfiguration() -> TerminalConfiguration? {
        if let darkPaint { return darkPaint.terminalConfiguration() }
        return darkName.flatMap { GhosttyThemeCatalog.theme(named: $0)?.terminalConfiguration() }
    }

    static func from(raw: String) -> TerminalThemeFamily {
        if raw == "atomOne" || raw == "absolutely" { return .absolutely }
        return TerminalThemeFamily(rawValue: raw) ?? .github
    }

    static func current(defaults: UserDefaults = .standard) -> TerminalThemeFamily {
        if let raw = defaults.string(forKey: storageKey) {
            return from(raw: raw)
        }
        let hint = [
            defaults.string(forKey: TerminalAppearance.lightThemeKey),
            defaults.string(forKey: TerminalAppearance.darkThemeKey),
            defaults.string(forKey: TerminalAppearance.legacyThemeKey),
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        if hint.contains("Ayu") { return .ayu }
        if hint.contains("One Half") { return .oneHalf }
        if hint.contains("Atom One") || hint.localizedCaseInsensitiveContains("absolutely") { return .absolutely }
        return .github
    }

    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: storageKey) == nil else { return }
        defaults.set(current(defaults: defaults).rawValue, forKey: storageKey)
    }
}

/// `ssh` copies `TERM` from its own environment onto the remote pty.
/// Keep that value at `xterm-256color` even if a caller passed something else.
private func sshChildEnvironment(_ commandEnvironment: [String]) -> [String] {
    var environment = commandEnvironment.filter {
        let key = $0.prefix(while: { $0 != "=" })
        return key != "TERM" && key != "COLORTERM" && key != "COLORFGBG"
            && !key.hasPrefix("TERM_PROGRAM") && key != "GHOSTTY_RESOURCES_DIR"
    }
    environment.append("TERM=xterm-256color")
    return environment
}

final class TerminalProcessHost {
    let session: InMemoryTerminalSession
    let process = TerminalProcess()
    private let adapterLock = NSLock()
    private var lightAdapter: LightTerminalANSIAdapter?
    private var processEnded = false
    private var outputDrained = false
    private var ghosttyNotified = false
    private var processExitCode: Int32?
    private var startedAt: TimeInterval = 0

    var onExit: ((Int32?) -> Void)?

    init() {
        let process = self.process
        session = InMemoryTerminalSession(
            write: { data in process.write(data) },
            resize: { viewport in
                process.resize(
                    columns: viewport.columns,
                    rows: viewport.rows,
                    widthPixels: viewport.widthPixels,
                    heightPixels: viewport.heightPixels
                )
            },
            suppressesPixelOnlyResizes: true
        )
        process.onOutput = { [weak self] data in self?.receiveOutput(data) }
        process.onOutputEnd = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.outputDrained = true
                self?.finishGhosttyIfReady()
            }
        }
        process.onExit = { [weak self] code in
            guard let self else { return }
            self.processExitCode = code
            self.processEnded = true
            self.finishGhosttyIfReady()
            self.onExit?(code)
        }
    }

    func start(executable: String, args: [String], environment: [String]) {
        startedAt = ProcessInfo.processInfo.systemUptime
        process.start(
            executable: executable,
            args: args,
            environment: sshChildEnvironment(environment)
        )
    }

    func terminate() {
        ghosttyNotified = true
        process.terminate()
    }

    private func finishGhosttyIfReady() {
        guard processEnded, outputDrained, !ghosttyNotified else { return }
        ghosttyNotified = true
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        session.finish(
            exitCode: UInt32(processExitCode ?? 1),
            runtimeMilliseconds: UInt64(max(0, elapsed * 1_000))
        )
    }

    func setLightColorsEnabled(_ enabled: Bool) {
        adapterLock.lock()
        lightAdapter = enabled ? LightTerminalANSIAdapter() : nil
        adapterLock.unlock()
    }

    private func receiveOutput(_ data: Data) {
        adapterLock.lock()
        if var adapter = lightAdapter {
            let transformed = adapter.transform([UInt8](data)[...])
            lightAdapter = adapter
            adapterLock.unlock()
            if !transformed.isEmpty { session.receive(Data(transformed)) }
        } else {
            adapterLock.unlock()
            session.receive(data)
        }
    }
}

@MainActor
enum SSHTerminalRegistry {
    private struct WeakView { weak var view: SSHTerminalNSView? }
    private static var views: [String: WeakView] = [:]

    static func register(_ view: SSHTerminalNSView, for id: String) {
        views[id] = WeakView(view: view)
    }

    static func unregister(_ id: String) {
        views[id] = nil
    }

    static func focus(_ id: String) {
        DispatchQueue.main.async {
            guard let view = views[id]?.view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }
}

final class SSHTerminalNSView: AppTerminalView {
    var onFocus: (() -> Void)?
    var appliedDarkAppearance: Int?
    weak var attachedSurface: TerminalSurface?
    weak var processHost: TerminalProcessHost?
    private var gestureIsLocal = false
    private var locallyConsumedKeyCode: UInt16?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        locallyConsumedKeyCode = nil
        if hasMarkedText() {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.command) || modifiers.contains(.control) { return }
            super.keyDown(with: event)
            return
        }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option, .shift])
        if !modifiers.isEmpty,
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            locallyConsumedKeyCode = event.keyCode
            return
        }
        if let payload = Self.ptyBytes(forMacEditingKey: event) {
            processHost?.session.sendInput(Data(payload.utf8))
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if locallyConsumedKeyCode == event.keyCode {
            locallyConsumedKeyCode = nil
            return
        }
        super.keyUp(with: event)
    }

    private static func ptyBytes(forMacEditingKey event: NSEvent) -> String? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let commandOnly = modifiers.contains(.command)
            && modifiers.isDisjoint(with: [.option, .control])
        let optionOnly = modifiers.contains(.option)
            && modifiers.isDisjoint(with: [.command, .control])
        if commandOnly {
            switch event.keyCode {
            case 51: return "\u{15}"
            case 123: return "\u{01}"
            case 124: return "\u{05}"
            case 117: return "\u{0b}"
            default: break
            }
        }
        if optionOnly {
            switch event.keyCode {
            case 51: return "\u{1b}\u{7f}"
            case 123: return "\u{1b}b"
            case 124: return "\u{1b}f"
            case 117: return "\u{1b}d"
            default: break
            }
        }
        return nil
    }

    private func isSelectionGesture(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
    }

    private func routedMouseEvent(_ event: NSEvent) -> NSEvent {
        guard isMouseCaptured else { return event }
        return gestureIsLocal ? event.addingShiftModifier() : event.removingShiftModifier()
    }

    override func mouseDown(with event: NSEvent) {
        gestureIsLocal = isSelectionGesture(event) || !isMouseCaptured
        super.mouseDown(with: routedMouseEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: routedMouseEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        defer { gestureIsLocal = false }
        super.mouseUp(with: routedMouseEvent(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func rightMouseUp(with event: NSEvent) {
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }

    override func menu(for _: NSEvent) -> NSMenu? {
        contextMenu()
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        if attachedSurface?.hasSelection() == true,
           let selection = attachedSurface?.readSelection(),
           !selection.isEmpty {
            menu.addItem(makeItem(String(localized: "Copy"), #selector(copySelectionFromMenu(_:))))
            if let url = Self.firstURL(in: selection) {
                menu.addItem(.separator())
                let open = makeItem(String(localized: "Open Link"), #selector(openLinkFromMenu(_:)))
                open.representedObject = url
                menu.addItem(open)
                let copyLink = makeItem(String(localized: "Copy Link Address"), #selector(copyLinkFromMenu(_:)))
                copyLink.representedObject = url
                menu.addItem(copyLink)
            }
            menu.addItem(.separator())
        }
        menu.addItem(makeItem(String(localized: "Paste"), #selector(performPaste(_:))))
        menu.addItem(makeItem(String(localized: "Select All"), #selector(selectAll(_:))))
        return menu
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openLinkFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyLinkFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func copySelectionFromMenu(_: Any?) {
        copyLocalSelection()
    }

    @discardableResult
    private func copyLocalSelection() -> Bool {
        guard let selection = attachedSurface?.readSelection(), !selection.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(selection, forType: .string)
    }

    static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector?.firstMatch(in: text, range: range),
              let url = match.url,
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            if attachedSurface?.hasSelection() == true {
                locallyConsumedKeyCode = event.keyCode
                copyLocalSelection()
            } else {
                keyDown(with: event)
            }
            return true
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
            pastePlainText()
            return true
        }
        if !modifiers.isDisjoint(with: [.command, .control, .option, .shift]),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            locallyConsumedKeyCode = event.keyCode
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc private func performPaste(_: Any?) {
        pastePlainText()
    }

    private func pastePlainText() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        paste(text: text)
    }
}

private extension NSEvent {
    func addingShiftModifier() -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: locationInWindow,
            modifierFlags: modifierFlags.union(.shift),
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: pressure
        ) ?? self
    }

    func removingShiftModifier() -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: locationInWindow,
            modifierFlags: modifierFlags.subtracting(.shift),
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: pressure
        ) ?? self
    }
}

struct SSHTerminalView: NSViewRepresentable {
    var sessionID: String
    var alias: String
    var environment: [String]
    var dark: Bool
    /// Catalog themes already include their own palette, so the light-color rewrite stays off.
    var usesCatalogTheme: Bool = false
    var onExit: () -> Void
    var onFocus: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SSHTerminalNSView {
        let host = TerminalProcessHost()
        let view = SSHTerminalNSView(frame: .zero)
        view.processHost = host
        context.coordinator.view = view
        context.coordinator.host = host
        context.coordinator.sessionID = sessionID
        context.coordinator.onExit = onExit
        context.coordinator.onFocus = onFocus
        view.onFocus = { [weak coordinator = context.coordinator] in
            coordinator?.onFocus?()
        }
        host.onExit = { [weak coordinator = context.coordinator] _ in
            coordinator?.processDidExit()
        }
        view.delegate = context.coordinator
        view.controller = GhosttyRuntime.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(host.session))
        applyAppearance(view, dark: dark, usesCatalogTheme: usesCatalogTheme)
        host.setLightColorsEnabled(!usesCatalogTheme && !dark)
        host.start(
            executable: "/usr/bin/ssh",
            args: ["-tt", "--", alias],
            environment: environment
        )
        SSHTerminalRegistry.register(view, for: sessionID)
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: SSHTerminalNSView, context: Context) {
        context.coordinator.onExit = onExit
        context.coordinator.onFocus = onFocus
        applyAppearance(nsView, dark: dark, usesCatalogTheme: usesCatalogTheme)
    }

    static func dismantleNSView(_ nsView: SSHTerminalNSView, coordinator: Coordinator) {
        coordinator.onExit = nil
        if let sessionID = coordinator.sessionID {
            SSHTerminalRegistry.unregister(sessionID)
        }
        coordinator.host?.terminate()
    }

    private func applyAppearance(_ view: SSHTerminalNSView, dark: Bool, usesCatalogTheme: Bool) {
        GhosttyRuntime.applyFontSettings()
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        GhosttyRuntime.controller.setColorScheme(dark ? .dark : .light)
        let signature = usesCatalogTheme ? (dark ? 2 : 3) : (dark ? 1 : 0)
        guard view.appliedDarkAppearance != signature else { return }
        view.appliedDarkAppearance = signature
        view.processHost?.setLightColorsEnabled(!usesCatalogTheme && !dark)
    }

    final class Coordinator: NSObject, TerminalSurfaceLifecycleDelegate {
        var sessionID: String?
        var onExit: (() -> Void)?
        var onFocus: (() -> Void)?
        weak var view: SSHTerminalNSView?
        var host: TerminalProcessHost?

        func terminalDidAttachSurface(_ surface: TerminalSurface) {
            view?.attachedSurface = surface
        }

        func terminalDidDetachSurface() {
            view?.attachedSurface = nil
        }

        func processDidExit() {
            let callback = onExit
            onExit = nil
            callback?()
        }
    }
}
