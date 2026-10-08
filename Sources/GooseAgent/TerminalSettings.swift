import Foundation

/// One `key = value` line handed to Ghostty.
struct TerminalConfigEntry: Equatable {
    let key: String
    let value: String
}

/// The advanced snippet split into lines Ghostty gets and lines left out, for the settings page.
struct TerminalCustomConfigParse: Equatable {
    var entries: [TerminalConfigEntry] = []
    /// Lines whose key the app owns, e.g. `font-size = 30`.
    var skippedLines: [String] = []
    /// Lines without `=` or without a key.
    var invalidLines: [String] = []
}

/// A snippet line Ghostty refused, with the engine's message.
struct TerminalConfigRejection: Equatable, Hashable {
    let line: String
    let issue: String
}

/// Which snippet entries go into the configuration when Ghostty rejects the whole of it.
struct TerminalSnippetFit: Equatable {
    var accepted: [TerminalConfigEntry] = []
    var rejected: [TerminalConfigRejection] = []
    /// Ghostty rejected the settings alone, so no snippet line is to blame.
    var baseIssue: String?

    /// `tryApply` applies the settings plus the given snippet entries and returns nil when Ghostty
    /// accepted them, or its message. Each accepted call is committed, so the last accepted call is
    /// what stays applied. Line by line only after the whole snippet failed.
    static func fit(
        _ entries: [TerminalConfigEntry],
        tryApply: ([TerminalConfigEntry]) -> String?
    ) -> TerminalSnippetFit {
        var result = TerminalSnippetFit()
        if tryApply(entries) == nil {
            result.accepted = entries
            return result
        }
        if let issue = tryApply([]) {
            result.baseIssue = issue
            return result
        }
        for entry in entries {
            if let issue = tryApply(result.accepted + [entry]) {
                let line = "\(entry.key) = \(entry.value)"
                result.rejected.append(TerminalConfigRejection(line: line, issue: issue))
            } else {
                result.accepted.append(entry)
            }
        }
        return result
    }
}

/// Every terminal preference in one place. Each field has its own UserDefaults key and maps to
/// one Ghostty config key, so a Ghostty config file can be imported field by field.
/// Defaults reproduce what the app rendered before these settings existed.
struct TerminalSettings: Equatable {
    enum CursorStyle: String, CaseIterable {
        case block
        case bar
        case underline
        case blockHollow = "block_hollow"
    }

    /// Ghostty 1.4 values. `true` / `false` from older configs map to `clipboard` / `none` on macOS.
    enum CopyOnSelect: String, CaseIterable {
        case none
        case primary
        case clipboard
        case both
    }

    enum OptionAsAlt: String, CaseIterable {
        case off = "false"
        case on = "true"
        case left
        case right
    }

    enum ShellIntegration: String, CaseIterable {
        case none
        case detect
        case bash
        case elvish
        case fish
        case nushell
        case zsh
    }

    // Font
    var fontFamily: String
    var fontSize: Double
    var fontThicken: Bool
    var fontThickenStrength: Int
    var fontLigatures: Bool
    /// Percent, rendered as `adjust-cell-height = N%`.
    var cellHeightAdjust: Int

    // Cursor
    var cursorStyle: CursorStyle
    var cursorBlink: Bool
    var cursorOpacity: Double

    // Window
    var paddingX: Int
    var paddingY: Int
    var backgroundOpacity: Double
    var minimumContrast: Double

    // Scrollback
    var scrollbackLimitMB: Int

    // Mouse and clipboard
    var copyOnSelect: CopyOnSelect
    var clipboardPasteProtection: Bool
    var mouseHideWhileTyping: Bool
    var linkURL: Bool

    // Keyboard
    var optionAsAlt: OptionAsAlt

    // Shell integration
    var shellIntegration: ShellIntegration
    /// Enabled feature names; anything in `shellIntegrationFeatureNames` not listed is off.
    var shellIntegrationFeatures: Set<String>

    // Bell
    /// Enabled feature names; anything in `bellFeatureNames` not listed is off.
    var bellFeatures: Set<String>

    // Advanced
    /// Extra `key = value` lines appended after everything else.
    var customConfig: String

    // MARK: - Limits and fixed values

    static let minFontSize: Double = 10
    static let maxFontSize: Double = 28
    static let symbolFallbackFamily = "Symbols Nerd Font Mono"

    /// Ranges the settings controls offer. Loaded values outside them are kept as they are.
    static let cursorOpacityRange: ClosedRange<Double> = 0.2 ... 1
    static let scrollbackLimitMBRange: ClosedRange<Double> = 10 ... 1000
    static let fontThickenStrengthRange: ClosedRange<Double> = 0 ... 255
    static let cellHeightAdjustRange: ClosedRange<Double> = -20 ... 50
    static let paddingRange: ClosedRange<Int> = 0 ... 40
    static let backgroundOpacityRange: ClosedRange<Double> = 0.5 ... 1
    static let minimumContrastRange: ClosedRange<Double> = 1 ... 21

    /// Order matters: Ghostty's feature list is rendered in this order.
    static let shellIntegrationFeatureNames = ["cursor", "sudo", "title", "ssh-env", "ssh-terminfo", "path"]
    static let bellFeatureNames = ["system", "audio", "attention", "title", "border"]

    /// Engine defaults (libghostty's Config.zig). A value equal to these is not rendered.
    static let ghosttyDefaultShellIntegrationFeatures: Set<String> = ["cursor", "title", "path"]
    static let ghosttyDefaultBellFeatures: Set<String> = ["attention", "title"]
    static let ghosttyDefaultFontThickenStrength = 255
    static let ghosttyDefaultScrollbackLimitMB = 50

    static let defaults = TerminalSettings(
        fontFamily: "SF Mono",
        fontSize: 14,
        fontThicken: false,
        fontThickenStrength: TerminalSettings.ghosttyDefaultFontThickenStrength,
        fontLigatures: true,
        cellHeightAdjust: 0,
        cursorStyle: .block,
        cursorBlink: true,
        cursorOpacity: 1,
        paddingX: 8,
        paddingY: 6,
        backgroundOpacity: 1,
        minimumContrast: 1,
        scrollbackLimitMB: TerminalSettings.ghosttyDefaultScrollbackLimitMB,
        copyOnSelect: .none,
        clipboardPasteProtection: true,
        mouseHideWhileTyping: false,
        linkURL: true,
        optionAsAlt: .on,
        shellIntegration: .detect,
        shellIntegrationFeatures: TerminalSettings.ghosttyDefaultShellIntegrationFeatures,
        bellFeatures: TerminalSettings.ghosttyDefaultBellFeatures,
        customConfig: ""
    )

    /// Keys the advanced snippet may not set: the app drives them itself, or they would
    /// make Ghostty read files outside the app. `keybind` is allowed, see `keybindConflictsWithApp`.
    static let managedKeys: Set<String> = [
        "font-family",
        "font-size",
        "background-opacity",
        "theme",
        "clipboard-write",
        "mouse-shift-capture",
        "config-file",
        "config-default-files",
    ]

    /// Ghostty's macOS default triggers for the actions in the app's Terminal menu and Edit → Find
    /// (Config.zig). Unbound so only the app's shortcuts run them, even after the user rebinds one elsewhere.
    /// `=`, `+`, `-`, `0`, `k`, `a`, `f`, `g` and `e` are unicode triggers; a named key like `equal`
    /// would be a different, physical trigger and leave the default in place.
    static let appOwnedGhosttyTriggers = [
        "super+=",
        "super+plus",
        "super+-",
        "super+0",
        "super+k",
        "super+a",
        "super+home",
        "super+end",
        "super+page_up",
        "super+page_down",
        "super+arrow_up",
        "super+arrow_down",
        "super+shift+arrow_up",
        "super+shift+arrow_down",
        "super+f",
        "super+g",
        "super+shift+g",
        "super+e",
        // `toggle_split_zoom`; Config.zig binds the physical enter key.
        "super+shift+enter",
        // `toggle_fullscreen`, `previous_tab` / `next_tab`.
        "super+enter",
        "super+ctrl+f",
        "super+shift+[",
        "super+shift+]",
        // `goto_tab` binds both the digit and the physical key; `last_tab` only the digit.
        "super+1", "super+digit_1",
        "super+2", "super+digit_2",
        "super+3", "super+digit_3",
        "super+4", "super+digit_4",
        "super+5", "super+digit_5",
        "super+6", "super+digit_6",
        "super+7", "super+digit_7",
        "super+8", "super+digit_8",
        "super+9",
    ]

    // MARK: - UserDefaults keys

    static let fontFamilyKey = "appearance.terminalFontFamily"
    static let fontSizeKey = "appearance.terminalFontSize"
    static let fontThickenKey = "terminal.fontThicken"
    static let fontThickenStrengthKey = "terminal.fontThickenStrength"
    static let fontLigaturesKey = "terminal.fontLigatures"
    static let cellHeightAdjustKey = "terminal.cellHeightAdjust"
    static let cursorStyleKey = "terminal.cursorStyle"
    static let cursorBlinkKey = "terminal.cursorBlink"
    static let cursorOpacityKey = "terminal.cursorOpacity"
    static let paddingXKey = "terminal.paddingX"
    static let paddingYKey = "terminal.paddingY"
    /// Space above the first line, in points; the vertical padding setting only moves the bottom.
    static let topPadding = 2
    static let backgroundOpacityKey = "terminal.backgroundOpacity"
    static let minimumContrastKey = "terminal.minimumContrast"
    static let scrollbackLimitMBKey = "terminal.scrollbackLimitMB"
    static let copyOnSelectKey = "terminal.copyOnSelect"
    static let clipboardPasteProtectionKey = "terminal.clipboardPasteProtection"
    static let mouseHideWhileTypingKey = "terminal.mouseHideWhileTyping"
    static let linkURLKey = "terminal.linkURL"
    static let optionAsAltKey = "terminal.optionAsAlt"
    static let shellIntegrationKey = "terminal.shellIntegration"
    static let shellIntegrationFeaturesKey = "terminal.shellIntegrationFeatures"
    static let bellFeaturesKey = "terminal.bellFeatures"
    static let customConfigKey = "terminal.customConfig"

    /// Every key `save` writes.
    static let storageKeys = [
        TerminalSettings.fontFamilyKey,
        TerminalSettings.fontSizeKey,
        TerminalSettings.fontThickenKey,
        TerminalSettings.fontThickenStrengthKey,
        TerminalSettings.fontLigaturesKey,
        TerminalSettings.cellHeightAdjustKey,
        TerminalSettings.cursorStyleKey,
        TerminalSettings.cursorBlinkKey,
        TerminalSettings.cursorOpacityKey,
        TerminalSettings.paddingXKey,
        TerminalSettings.paddingYKey,
        TerminalSettings.backgroundOpacityKey,
        TerminalSettings.minimumContrastKey,
        TerminalSettings.scrollbackLimitMBKey,
        TerminalSettings.copyOnSelectKey,
        TerminalSettings.clipboardPasteProtectionKey,
        TerminalSettings.mouseHideWhileTypingKey,
        TerminalSettings.linkURLKey,
        TerminalSettings.optionAsAltKey,
        TerminalSettings.shellIntegrationKey,
        TerminalSettings.shellIntegrationFeaturesKey,
        TerminalSettings.bellFeaturesKey,
        TerminalSettings.customConfigKey,
    ]

    // MARK: - Load / save

    /// Missing or unreadable values fall back to `defaults`, one field at a time.
    static func load(from defaults: UserDefaults = .standard) -> TerminalSettings {
        let fallback = TerminalSettings.defaults
        var settings = fallback

        let family = defaults.string(forKey: TerminalSettings.fontFamilyKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !family.isEmpty {
            settings.fontFamily = family
        }
        if let size = defaults.object(forKey: TerminalSettings.fontSizeKey) as? Double {
            settings.fontSize = TerminalSettings.clampedFontSize(size)
        }
        if let value = defaults.object(forKey: TerminalSettings.fontThickenKey) as? Bool {
            settings.fontThicken = value
        }
        if let value = defaults.object(forKey: TerminalSettings.fontThickenStrengthKey) as? Int {
            settings.fontThickenStrength = min(max(value, 0), 255)
        }
        if let value = defaults.object(forKey: TerminalSettings.fontLigaturesKey) as? Bool {
            settings.fontLigatures = value
        }
        if let value = defaults.object(forKey: TerminalSettings.cellHeightAdjustKey) as? Int {
            settings.cellHeightAdjust = value
        }
        if let raw = defaults.string(forKey: TerminalSettings.cursorStyleKey),
           let value = CursorStyle(rawValue: raw) {
            settings.cursorStyle = value
        }
        if let value = defaults.object(forKey: TerminalSettings.cursorBlinkKey) as? Bool {
            settings.cursorBlink = value
        }
        if let value = defaults.object(forKey: TerminalSettings.cursorOpacityKey) as? Double {
            settings.cursorOpacity = min(max(value, 0), 1)
        }
        if let value = defaults.object(forKey: TerminalSettings.paddingXKey) as? Int {
            settings.paddingX = max(value, 0)
        }
        if let value = defaults.object(forKey: TerminalSettings.paddingYKey) as? Int {
            settings.paddingY = max(value, 0)
        }
        if let value = defaults.object(forKey: TerminalSettings.backgroundOpacityKey) as? Double {
            settings.backgroundOpacity = min(max(value, 0), 1)
        }
        if let value = defaults.object(forKey: TerminalSettings.minimumContrastKey) as? Double {
            settings.minimumContrast = min(max(value, 1), 21)
        }
        if let value = defaults.object(forKey: TerminalSettings.scrollbackLimitMBKey) as? Int {
            settings.scrollbackLimitMB = max(value, 0)
        }
        if let raw = defaults.string(forKey: TerminalSettings.copyOnSelectKey),
           let value = CopyOnSelect(rawValue: raw) {
            settings.copyOnSelect = value
        }
        if let value = defaults.object(forKey: TerminalSettings.clipboardPasteProtectionKey) as? Bool {
            settings.clipboardPasteProtection = value
        }
        if let value = defaults.object(forKey: TerminalSettings.mouseHideWhileTypingKey) as? Bool {
            settings.mouseHideWhileTyping = value
        }
        if let value = defaults.object(forKey: TerminalSettings.linkURLKey) as? Bool {
            settings.linkURL = value
        }
        if let raw = defaults.string(forKey: TerminalSettings.optionAsAltKey),
           let value = OptionAsAlt(rawValue: raw) {
            settings.optionAsAlt = value
        }
        if let raw = defaults.string(forKey: TerminalSettings.shellIntegrationKey),
           let value = ShellIntegration(rawValue: raw) {
            settings.shellIntegration = value
        }
        if let raw = defaults.string(forKey: TerminalSettings.shellIntegrationFeaturesKey) {
            settings.shellIntegrationFeatures = TerminalSettings.storedFeatureSet(
                raw,
                known: TerminalSettings.shellIntegrationFeatureNames
            )
        }
        if let raw = defaults.string(forKey: TerminalSettings.bellFeaturesKey) {
            settings.bellFeatures = TerminalSettings.storedFeatureSet(raw, known: TerminalSettings.bellFeatureNames)
        }
        if let value = defaults.string(forKey: TerminalSettings.customConfigKey) {
            settings.customConfig = value
        }
        return settings
    }

    /// Feature sets are stored as the enabled names, comma separated in Ghostty's order.
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(fontFamily, forKey: TerminalSettings.fontFamilyKey)
        defaults.set(fontSize, forKey: TerminalSettings.fontSizeKey)
        defaults.set(fontThicken, forKey: TerminalSettings.fontThickenKey)
        defaults.set(fontThickenStrength, forKey: TerminalSettings.fontThickenStrengthKey)
        defaults.set(fontLigatures, forKey: TerminalSettings.fontLigaturesKey)
        defaults.set(cellHeightAdjust, forKey: TerminalSettings.cellHeightAdjustKey)
        defaults.set(cursorStyle.rawValue, forKey: TerminalSettings.cursorStyleKey)
        defaults.set(cursorBlink, forKey: TerminalSettings.cursorBlinkKey)
        defaults.set(cursorOpacity, forKey: TerminalSettings.cursorOpacityKey)
        defaults.set(paddingX, forKey: TerminalSettings.paddingXKey)
        defaults.set(paddingY, forKey: TerminalSettings.paddingYKey)
        defaults.set(backgroundOpacity, forKey: TerminalSettings.backgroundOpacityKey)
        defaults.set(minimumContrast, forKey: TerminalSettings.minimumContrastKey)
        defaults.set(scrollbackLimitMB, forKey: TerminalSettings.scrollbackLimitMBKey)
        defaults.set(copyOnSelect.rawValue, forKey: TerminalSettings.copyOnSelectKey)
        defaults.set(clipboardPasteProtection, forKey: TerminalSettings.clipboardPasteProtectionKey)
        defaults.set(mouseHideWhileTyping, forKey: TerminalSettings.mouseHideWhileTypingKey)
        defaults.set(linkURL, forKey: TerminalSettings.linkURLKey)
        defaults.set(optionAsAlt.rawValue, forKey: TerminalSettings.optionAsAltKey)
        defaults.set(shellIntegration.rawValue, forKey: TerminalSettings.shellIntegrationKey)
        let shellFeatures = TerminalSettings.shellIntegrationFeatureNames.filter { shellIntegrationFeatures.contains($0) }
        defaults.set(shellFeatures.joined(separator: ","), forKey: TerminalSettings.shellIntegrationFeaturesKey)
        let bell = TerminalSettings.bellFeatureNames.filter { bellFeatures.contains($0) }
        defaults.set(bell.joined(separator: ","), forKey: TerminalSettings.bellFeaturesKey)
        defaults.set(customConfig, forKey: TerminalSettings.customConfigKey)
    }

    static func clampedFontSize(_ size: Double) -> Double {
        min(max(size, TerminalSettings.minFontSize), TerminalSettings.maxFontSize)
    }

    /// A stored feature list with one name switched on or off, in the same format `save` writes.
    static func storedFeatureList(_ raw: String, setting name: String, enabled: Bool, known: [String]) -> String {
        var features = TerminalSettings.storedFeatureSet(raw, known: known)
        if enabled {
            features.insert(name)
        } else {
            features.remove(name)
        }
        return known.filter { features.contains($0) }.joined(separator: ",")
    }

    static func storedFeatureListContains(_ raw: String, _ name: String, known: [String]) -> Bool {
        TerminalSettings.storedFeatureSet(raw, known: known).contains(name)
    }

    private static func storedFeatureSet(_ raw: String, known: [String]) -> Set<String> {
        var result = Set<String>()
        for part in raw.split(separator: ",") {
            let name = part.trimmingCharacters(in: .whitespaces)
            if known.contains(name) {
                result.insert(name)
            }
        }
        return result
    }

    // MARK: - Rendering

    /// Settings plus the fixed lines the app always needs. The advanced snippet is not included.
    func configEntries() -> [TerminalConfigEntry] {
        var entries: [TerminalConfigEntry] = []
        func add(_ key: String, _ value: String) {
            entries.append(TerminalConfigEntry(key: key, value: value))
        }

        add("font-size", TerminalSettings.literal(fontSize, maximumFractionDigits: 2))
        add("window-padding-x", String(paddingX))
        // Top, bottom. The title strip already sits above the text, so the top stays tight.
        add("window-padding-y", "\(min(paddingY, TerminalSettings.topPadding)),\(paddingY)")
        // Balancing would push half of the leftover space above the first line.
        add("window-padding-balance", "false")
        add("cursor-style", cursorStyle.rawValue)
        add("cursor-style-blink", String(cursorBlink))
        add("font-thicken", String(fontThicken))
        if fontThickenStrength != TerminalSettings.ghosttyDefaultFontThickenStrength {
            add("font-thicken-strength", String(fontThickenStrength))
        }
        add("font-family", fontFamily)
        add("macos-option-as-alt", optionAsAlt.rawValue)
        // ⌘C is handled by the view: copy with a selection, otherwise sent to the shell.
        add("keybind", "super+c=unbind")
        for trigger in TerminalSettings.appOwnedGhosttyTriggers {
            add("keybind", "\(trigger)=unbind")
        }
        add("clipboard-write", "allow")
        // The view decides who gets shift-drags; the remote app must not claim them.
        add("mouse-shift-capture", "never")
        let symbols = TerminalSettings.symbolFallbackFamily
        add("font-codepoint-map", "U+E000-U+F8FF=\(symbols)")
        add("font-codepoint-map", "U+F0000-U+FFFFD=\(symbols)")
        add("font-codepoint-map", "U+100000-U+10FFFD=\(symbols)")

        if !fontLigatures {
            add("font-feature", "-calt")
            add("font-feature", "-liga")
        }
        if cellHeightAdjust != 0 {
            add("adjust-cell-height", "\(cellHeightAdjust)%")
        }
        if cursorOpacity != 1 {
            add("cursor-opacity", TerminalSettings.literal(cursorOpacity, maximumFractionDigits: 3))
        }
        if backgroundOpacity != 1 {
            add("background-opacity", TerminalSettings.literal(backgroundOpacity, maximumFractionDigits: 3))
        }
        if minimumContrast != 1 {
            add("minimum-contrast", TerminalSettings.literal(minimumContrast, maximumFractionDigits: 2))
        }
        if scrollbackLimitMB != TerminalSettings.ghosttyDefaultScrollbackLimitMB {
            add("scrollback-limit-bytes", String(scrollbackLimitMB * 1_000_000))
        }
        if copyOnSelect != .none {
            add("copy-on-select", copyOnSelect.rawValue)
        }
        if !clipboardPasteProtection {
            add("clipboard-paste-protection", "false")
        }
        if mouseHideWhileTyping {
            add("mouse-hide-while-typing", "true")
        }
        if !linkURL {
            add("link-url", "false")
        }
        if shellIntegration != .detect {
            add("shell-integration", shellIntegration.rawValue)
        }
        if shellIntegrationFeatures != TerminalSettings.ghosttyDefaultShellIntegrationFeatures {
            add("shell-integration-features", TerminalSettings.featureList(
                shellIntegrationFeatures,
                known: TerminalSettings.shellIntegrationFeatureNames
            ))
        }
        if bellFeatures != TerminalSettings.ghosttyDefaultBellFeatures {
            add("bell-features", TerminalSettings.featureList(bellFeatures, known: TerminalSettings.bellFeatureNames))
        }
        return entries
    }

    /// Ghostty's float parser only takes `.` and ASCII digits, whatever the user's region.
    static func literal(_ value: Double, maximumFractionDigits: Int) -> String {
        value.formatted(
            FloatingPointFormatStyle<Double>(locale: Locale(identifier: "en_US_POSIX"))
                .precision(.fractionLength(0 ... maximumFractionDigits))
                .grouping(.never)
        )
    }

    /// Every known feature spelled out, e.g. `cursor,no-sudo,title`, so nothing depends on engine defaults.
    static func featureList(_ enabled: Set<String>, known: [String]) -> String {
        var parts: [String] = []
        for name in known {
            if enabled.contains(name) {
                parts.append(name)
            } else {
                parts.append("no-\(name)")
            }
        }
        return parts.joined(separator: ",")
    }

    /// Splits the advanced snippet. Keys in `managedKeys` are skipped so the snippet cannot break the app.
    static func parseCustomConfig(_ text: String) -> TerminalCustomConfigParse {
        var result = TerminalCustomConfigParse()
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            guard let equals = line.firstIndex(of: "=") else {
                result.invalidLines.append(line)
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if key.isEmpty {
                result.invalidLines.append(line)
                continue
            }
            if TerminalSettings.managedKeys.contains(key) {
                result.skippedLines.append(line)
                continue
            }
            if key == "keybind" && TerminalSettings.keybindConflictsWithApp(value) {
                result.skippedLines.append(line)
                continue
            }
            result.entries.append(TerminalConfigEntry(key: key, value: value))
        }
        return result
    }

    /// Snippet keybinds come after the fixed `keybind = super+c=unbind`, and keybinds accumulate,
    /// so only these would undo it: an empty value or `clear` (both reset every binding) and any
    /// binding whose trigger, or the first step of a sequence, is ⌘C.
    static func keybindConflictsWithApp(_ rawValue: String) -> Bool {
        let value = TerminalSettings.unquoted(rawValue.trimmingCharacters(in: .whitespaces))
        if value.isEmpty || value == "clear" {
            return true
        }
        guard let equals = value.firstIndex(of: "=") else { return false }
        var trigger = String(value[..<equals]).lowercased()
        var stripped = true
        while stripped {
            stripped = false
            for prefix in ["global:", "all:", "unconsumed:", "performable:"] where trigger.hasPrefix(prefix) {
                trigger.removeFirst(prefix.count)
                stripped = true
            }
        }
        if let sequenceStart = trigger.firstIndex(of: ">") {
            trigger = String(trigger[..<sequenceStart])
        }
        var hasSuper = false
        var otherModifier = false
        var key = ""
        for rawPart in trigger.split(separator: "+") {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            switch part {
            case "super", "cmd", "command":
                hasSuper = true
            case "alt", "opt", "option", "ctrl", "control", "shift":
                otherModifier = true
            default:
                key = part
            }
        }
        return hasSuper && !otherModifier && (key == "c" || key == "key_c")
    }

    // MARK: - Import

    /// Writes one Ghostty config line into the matching field. False when no field owns the key
    /// or the value is outside what the field can hold; the importer keeps such lines elsewhere.
    mutating func apply(ghosttyKey key: String, value rawValue: String) -> Bool {
        let value = TerminalSettings.unquoted(rawValue.trimmingCharacters(in: .whitespaces))
        switch key {
        case "font-family":
            if value.isEmpty {
                return false
            }
            fontFamily = value
            return true
        case "font-size":
            guard let size = Double(value) else { return false }
            fontSize = TerminalSettings.clampedFontSize(size)
            return true
        case "font-thicken":
            guard let flag = TerminalSettings.bool(value) else { return false }
            fontThicken = flag
            return true
        case "font-thicken-strength":
            guard let strength = Int(value), strength >= 0, strength <= 255 else { return false }
            fontThickenStrength = strength
            return true
        case "font-feature":
            return applyFontFeature(value)
        case "adjust-cell-height":
            guard value.hasSuffix("%"), let percent = Int(value.dropLast()) else { return false }
            cellHeightAdjust = percent
            return true
        case "cursor-style":
            guard let style = CursorStyle(rawValue: value) else { return false }
            cursorStyle = style
            return true
        case "cursor-style-blink":
            guard let flag = TerminalSettings.bool(value) else { return false }
            cursorBlink = flag
            return true
        case "cursor-opacity":
            guard let opacity = Double(value), opacity >= 0, opacity <= 1 else { return false }
            cursorOpacity = opacity
            return true
        case "window-padding-x":
            guard let padding = Int(value), padding >= 0 else { return false }
            paddingX = padding
            return true
        case "window-padding-y":
            guard let padding = Int(value), padding >= 0 else { return false }
            paddingY = padding
            return true
        case "background-opacity":
            guard let opacity = Double(value), opacity >= 0, opacity <= 1 else { return false }
            backgroundOpacity = opacity
            return true
        case "minimum-contrast":
            guard let contrast = Double(value), contrast >= 1, contrast <= 21 else { return false }
            minimumContrast = contrast
            return true
        case "scrollback-limit", "scrollback-limit-bytes":
            guard let bytes = Int(value), bytes >= 0 else { return false }
            scrollbackLimitMB = Int((Double(bytes) / 1_000_000).rounded())
            return true
        case "copy-on-select":
            return applyCopyOnSelect(value)
        case "clipboard-paste-protection":
            guard let flag = TerminalSettings.bool(value) else { return false }
            clipboardPasteProtection = flag
            return true
        case "mouse-hide-while-typing":
            guard let flag = TerminalSettings.bool(value) else { return false }
            mouseHideWhileTyping = flag
            return true
        case "link-url":
            guard let flag = TerminalSettings.bool(value) else { return false }
            linkURL = flag
            return true
        case "macos-option-as-alt":
            guard let option = OptionAsAlt(rawValue: value) else { return false }
            optionAsAlt = option
            return true
        case "shell-integration":
            guard let integration = ShellIntegration(rawValue: value) else { return false }
            shellIntegration = integration
            return true
        case "shell-integration-features":
            guard let features = TerminalSettings.parseFeatureList(
                value,
                known: TerminalSettings.shellIntegrationFeatureNames,
                engineDefault: TerminalSettings.ghosttyDefaultShellIntegrationFeatures
            ) else { return false }
            shellIntegrationFeatures = features
            return true
        case "bell-features":
            guard let features = TerminalSettings.parseFeatureList(
                value,
                known: TerminalSettings.bellFeatureNames,
                engineDefault: TerminalSettings.ghosttyDefaultBellFeatures
            ) else { return false }
            bellFeatures = features
            return true
        default:
            return false
        }
    }

    /// Only the ligature switch is modeled: a list made of `-calt` / `-liga` turns ligatures off.
    private mutating func applyFontFeature(_ value: String) -> Bool {
        var sawLigatureFeature = false
        for part in value.split(separator: ",") {
            let feature = part.trimmingCharacters(in: .whitespaces)
            if feature == "-calt" || feature == "-liga" {
                sawLigatureFeature = true
            } else {
                return false
            }
        }
        if !sawLigatureFeature {
            return false
        }
        fontLigatures = false
        return true
    }

    private mutating func applyCopyOnSelect(_ value: String) -> Bool {
        if value == "true" {
            copyOnSelect = .clipboard
            return true
        }
        if value == "false" {
            copyOnSelect = .none
            return true
        }
        guard let mode = CopyOnSelect(rawValue: value) else { return false }
        copyOnSelect = mode
        return true
    }

    /// Ghostty's packed-struct syntax: `a,no-b` turns `a` on and `b` off, omitted names take
    /// the engine default, `true` / `false` switch everything. Nil when a name is unknown.
    static func parseFeatureList(_ value: String, known: [String], engineDefault: Set<String>) -> Set<String>? {
        if value == "true" {
            return Set(known)
        }
        if value == "false" {
            return []
        }
        var result = engineDefault
        for part in value.split(separator: ",") {
            let token = part.trimmingCharacters(in: .whitespaces)
            if known.contains(token) {
                result.insert(token)
            } else if token.hasPrefix("no-"), known.contains(String(token.dropFirst(3))) {
                result.remove(String(token.dropFirst(3)))
            } else {
                return nil
            }
        }
        return result
    }

    private static func bool(_ value: String) -> Bool? {
        if value == "true" {
            return true
        }
        if value == "false" {
            return false
        }
        return nil
    }

    private static func unquoted(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
