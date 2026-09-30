import SwiftUI

/// One setting inside a `SettingsCard`: title, a one-line explanation, the Ghostty key it maps to
/// (so the official docs can be looked up), and the control on the right.
struct SettingsRow<Control: View>: View {
    @Environment(\.windowChrome) private var chrome
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let ghosttyKey: String?
    @ViewBuilder let control: () -> Control

    init(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        ghosttyKey: String? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.ghosttyKey = ghosttyKey
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Font.body)
                    .foregroundStyle(chrome.text)
                Text(detail)
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let ghosttyKey {
                    Text(verbatim: ghosttyKey)
                        .font(Theme.Font.rowMeta.monospaced())
                        .foregroundStyle(chrome.tertiary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
    }
}

/// A slider with its current value printed next to it, sized like every other row control.
struct SettingsSlider: View {
    @Environment(\.windowChrome) private var chrome
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    /// Called once a mouse drag ends, so Ghostty is not reconfigured on every frame. Changes made
    /// without a drag (keyboard, VoiceOver) commit right away.
    let onCommit: () -> Void
    @State private var isDragging = false

    /// Snaps to `step` by rounding instead of `Slider(step:)`, which would draw a tick per step.
    private var snappedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { newValue in
                let steps = ((newValue - range.lowerBound) / step).rounded()
                // Rounded to 4 decimals so 0.2 + 12 × 0.05 is stored as 0.8, not 0.8000000000000002.
                let snapped = ((range.lowerBound + steps * step) * 10_000).rounded() / 10_000
                let clamped = min(max(snapped, range.lowerBound), range.upperBound)
                if clamped == value {
                    return
                }
                value = clamped
                if !isDragging {
                    onCommit()
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Slider(value: snappedValue, in: range) { editing in
                isDragging = editing
                if !editing {
                    onCommit()
                }
            }
            Text(verbatim: label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(chrome.secondary)
                .frame(width: SettingsLayout.valueLabelWidth, alignment: .trailing)
        }
        .frame(width: SettingsLayout.rowControlWidth)
    }
}

/// A switch on the right of a `SettingsRow`.
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

/// Short note in a card for a setting that is saved but not acted on yet.
struct SettingsPendingNote: View {
    @Environment(\.windowChrome) private var chrome
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(Theme.Font.rowMeta)
            .foregroundStyle(chrome.warning)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Restore Page Defaults" at the bottom right of a settings page.
struct RestorePageDefaultsButton: View {
    @Environment(\.windowChrome) private var chrome
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: action) {
                Text("Restore Page Defaults")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(chrome.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

extension Binding {
    /// Writes the value, then hands the new configuration to every terminal. For discrete controls;
    /// sliders commit through `SettingsSlider.onCommit` instead.
    @MainActor
    func applyingTerminalSettings() -> Binding<Value> {
        Binding(
            get: { self.wrappedValue },
            set: { newValue in
                self.wrappedValue = newValue
                GhosttyRuntime.applyTerminalSettings()
            }
        )
    }
}

/// Settings → Terminal: cursor, scrollback, mouse and clipboard, Option key, bell, shell integration.
/// Every control writes its own UserDefaults key and applies at once.
struct TerminalSettingsPage: View {
    @Environment(\.windowChrome) private var chrome
    @AppStorage(TerminalSettings.cursorStyleKey) private var cursorStyle = TerminalSettings.defaults.cursorStyle
    @AppStorage(TerminalSettings.cursorBlinkKey) private var cursorBlink = TerminalSettings.defaults.cursorBlink
    @AppStorage(TerminalSettings.cursorOpacityKey) private var cursorOpacity = TerminalSettings.defaults.cursorOpacity
    @AppStorage(TerminalSettings.scrollbackLimitMBKey) private var scrollbackLimitMB = TerminalSettings.defaults.scrollbackLimitMB
    @AppStorage(TerminalSettings.copyOnSelectKey) private var copyOnSelect = TerminalSettings.defaults.copyOnSelect
    @AppStorage(TerminalSettings.clipboardPasteProtectionKey) private var pasteProtection = TerminalSettings.defaults.clipboardPasteProtection
    @AppStorage(TerminalSettings.mouseHideWhileTypingKey) private var mouseHideWhileTyping = TerminalSettings.defaults.mouseHideWhileTyping
    @AppStorage(TerminalSettings.linkURLKey) private var linkURL = TerminalSettings.defaults.linkURL
    @AppStorage(TerminalSettings.optionAsAltKey) private var optionAsAlt = TerminalSettings.defaults.optionAsAlt
    @AppStorage(TerminalSettings.bellFeaturesKey) private var bellFeatures = TerminalSettingsPage.defaultBellFeatures
    @AppStorage(TerminalSettings.shellIntegrationKey) private var shellIntegration = TerminalSettings.defaults.shellIntegration
    @AppStorage(TerminalSettings.shellIntegrationFeaturesKey) private var shellFeatures = TerminalSettingsPage.defaultShellFeatures

    /// Stored form of the default feature sets, as `TerminalSettings.save` writes them.
    private static let defaultBellFeatures = TerminalSettings.bellFeatureNames
        .filter { TerminalSettings.ghosttyDefaultBellFeatures.contains($0) }
        .joined(separator: ",")
    private static let defaultShellFeatures = TerminalSettings.shellIntegrationFeatureNames
        .filter { TerminalSettings.ghosttyDefaultShellIntegrationFeatures.contains($0) }
        .joined(separator: ",")

    private let featureColumns = [
        GridItem(.flexible(), spacing: Theme.Space.l, alignment: .topLeading),
        GridItem(.flexible(), spacing: Theme.Space.l, alignment: .topLeading),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            cursorCard
            scrollbackCard
            mouseCard
            keyboardCard
            bellCard
            shellIntegrationCard
            Text("SSH sends a keepalive probe every 30 seconds; after 3 missed replies the connection counts as lost and reconnects automatically. This cannot be turned off.")
                .font(Theme.Font.rowMeta)
                .foregroundStyle(chrome.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            RestorePageDefaultsButton {
                restoreDefaults()
            }
        }
    }

    // MARK: Cursor

    private var cursorCard: some View {
        SettingsCard("Cursor") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                SettingsRow("Style", detail: "Shape of the cursor. Some programs, such as vim, set their own.", ghosttyKey: "cursor-style") {
                    Picker("", selection: $cursorStyle.applyingTerminalSettings()) {
                        Text("Block").tag(TerminalSettings.CursorStyle.block)
                        Text("Bar").tag(TerminalSettings.CursorStyle.bar)
                        Text("Underline").tag(TerminalSettings.CursorStyle.underline)
                        Text("Hollow Block").tag(TerminalSettings.CursorStyle.blockHollow)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: SettingsLayout.rowControlWidth)
                }
                SettingsRow("Blink", detail: "Blink the cursor while the terminal has focus.", ghosttyKey: "cursor-style-blink") {
                    SettingsSwitch(isOn: $cursorBlink.applyingTerminalSettings())
                }
                SettingsRow("Opacity", detail: "Lower values let the character under the cursor show through.", ghosttyKey: "cursor-opacity") {
                    SettingsSlider(
                        value: $cursorOpacity,
                        range: TerminalSettings.cursorOpacityRange,
                        step: 0.05,
                        label: TerminalSettingsPage.percent(cursorOpacity),
                        onCommit: { GhosttyRuntime.applyTerminalSettings() }
                    )
                }
            }
        }
    }

    // MARK: Scrollback

    private var scrollbackCard: some View {
        SettingsCard("Scrollback") {
            SettingsRow("Scrollback Size", detail: "Memory each terminal keeps for history. Applies to terminals opened after the change.", ghosttyKey: "scrollback-limit-bytes") {
                SettingsSlider(
                    value: Binding(
                        get: { Double(scrollbackLimitMB) },
                        set: { scrollbackLimitMB = Int($0.rounded()) }
                    ),
                    range: TerminalSettings.scrollbackLimitMBRange,
                    step: 10,
                    label: String(format: String(localized: "%lld MB"), scrollbackLimitMB),
                    onCommit: { GhosttyRuntime.applyTerminalSettings() }
                )
            }
        }
    }

    // MARK: Mouse and clipboard

    /// macOS has no primary selection, so only Off and Clipboard mean anything. A value imported
    /// from another system stays listed so the menu never shows blank.
    private var copyOnSelectChoices: [TerminalSettings.CopyOnSelect] {
        var choices: [TerminalSettings.CopyOnSelect] = [.none, .clipboard]
        if !choices.contains(copyOnSelect) {
            choices.append(copyOnSelect)
        }
        return choices
    }

    private static func copyOnSelectTitle(_ mode: TerminalSettings.CopyOnSelect) -> LocalizedStringKey {
        switch mode {
        case .none: "Off"
        case .clipboard: "Copy to Clipboard"
        case .primary: "Selection Clipboard Only (no effect on macOS)"
        case .both: "Clipboard and Selection Clipboard"
        }
    }

    private var mouseCard: some View {
        SettingsCard("Mouse and Clipboard") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                SettingsRow("Copy on Select", detail: "Copy text to the clipboard as soon as it is selected.", ghosttyKey: "copy-on-select") {
                    Picker("", selection: $copyOnSelect.applyingTerminalSettings()) {
                        ForEach(copyOnSelectChoices, id: \.self) { mode in
                            Text(TerminalSettingsPage.copyOnSelectTitle(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: SettingsLayout.rowControlWidth, alignment: .trailing)
                }
                SettingsRow("Paste Protection", detail: "Ask before pasting text with line breaks or other content that could run commands.", ghosttyKey: "clipboard-paste-protection") {
                    SettingsSwitch(isOn: $pasteProtection.applyingTerminalSettings())
                }
                SettingsRow("Hide Pointer While Typing", detail: "Hide the mouse pointer while typing; it comes back when the mouse moves.", ghosttyKey: "mouse-hide-while-typing") {
                    SettingsSwitch(isOn: $mouseHideWhileTyping.applyingTerminalSettings())
                }
                SettingsRow("Detect Links", detail: "Underline links under the pointer while ⌘ is held; ⌘-click opens them.", ghosttyKey: "link-url") {
                    SettingsSwitch(isOn: $linkURL.applyingTerminalSettings())
                }
            }
        }
    }

    // MARK: Keyboard

    private var keyboardCard: some View {
        SettingsCard("Keyboard") {
            SettingsRow("Option as Alt", detail: "When on, Option combinations reach programs as Alt (Emacs, word jumps in the shell). When off, Option types special characters.", ghosttyKey: "macos-option-as-alt") {
                Picker("", selection: $optionAsAlt.applyingTerminalSettings()) {
                    Text("Off").tag(TerminalSettings.OptionAsAlt.off)
                    Text("Both Sides").tag(TerminalSettings.OptionAsAlt.on)
                    Text("Left Only").tag(TerminalSettings.OptionAsAlt.left)
                    Text("Right Only").tag(TerminalSettings.OptionAsAlt.right)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: SettingsLayout.rowControlWidth)
            }
        }
    }

    // MARK: Bell

    private static func bellTitle(_ name: String) -> LocalizedStringKey {
        switch name {
        case "system": "System Alert Sound"
        case "audio": "Play Sound"
        case "attention": "Bounce Dock Icon"
        case "title": "Mark the Title"
        case "border": "Flash the Border"
        default: LocalizedStringKey(name)
        }
    }

    private static func bellDetail(_ name: String) -> LocalizedStringKey {
        switch name {
        case "system": "Play the macOS alert sound."
        case "audio": "Not supported yet: needs a sound file setting."
        case "attention": "Bounce the Dock icon while the app is in the background."
        case "title": "Show a bell on the session's sidebar row until you open it."
        case "border": "Flash a border around the terminal."
        default: ""
        }
    }

    private var bellCard: some View {
        SettingsCard("Bell") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                SettingsRow("Bell Effects", detail: "What happens when a program rings the bell (for example, a finished command or Tab with no match).", ghosttyKey: "bell-features") {
                    EmptyView()
                }
                LazyVGrid(columns: featureColumns, alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(TerminalSettings.bellFeatureNames, id: \.self) { name in
                        featureToggle(
                            title: TerminalSettingsPage.bellTitle(name),
                            detail: TerminalSettingsPage.bellDetail(name),
                            isOn: featureBinding($bellFeatures, name: name, known: TerminalSettings.bellFeatureNames)
                        )
                    }
                }
                SettingsPendingNote("Play Sound does nothing yet: the app has no setting for the sound file. The other effects apply right away; one bell per session is handled every half second at most.")
            }
        }
    }

    // MARK: Shell integration

    private static func shellIntegrationTitle(_ mode: TerminalSettings.ShellIntegration) -> LocalizedStringKey {
        switch mode {
        case .detect: "Detect Automatically"
        case .none: "Off"
        case .zsh: "zsh"
        case .bash: "bash"
        case .fish: "fish"
        case .elvish: "elvish"
        case .nushell: "nushell"
        }
    }

    private static let shellIntegrationChoices: [TerminalSettings.ShellIntegration] = [
        .detect, .none, .zsh, .bash, .fish, .elvish, .nushell,
    ]

    private static func shellFeatureTitle(_ name: String) -> LocalizedStringKey {
        switch name {
        case "cursor": "Bar Cursor at the Prompt"
        case "sudo": "Keep Terminal Info for sudo"
        case "title": "Set the Title Automatically"
        case "ssh-env": "Compatible TERM over SSH"
        case "ssh-terminfo": "Install terminfo over SSH"
        case "path": "Add Ghostty to PATH"
        default: LocalizedStringKey(name)
        }
    }

    private static func shellFeatureDetail(_ name: String) -> LocalizedStringKey {
        switch name {
        case "cursor": "Show a bar cursor while typing at the prompt."
        case "sudo": "Let sudo keep the terminal's terminfo."
        case "title": "Show the running command or folder in the title."
        case "ssh-env": "Send a TERM value the remote host understands."
        case "ssh-terminfo": "Copy Ghostty's terminfo to the remote host on first connect."
        case "path": "Put Ghostty's command-line tool on PATH."
        default: ""
        }
    }

    private var shellIntegrationCard: some View {
        SettingsCard("Shell Integration") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                SettingsRow("Integration", detail: "Applies to local terminals; SSH sessions are not affected.", ghosttyKey: "shell-integration") {
                    Picker("", selection: $shellIntegration.applyingTerminalSettings()) {
                        ForEach(TerminalSettingsPage.shellIntegrationChoices, id: \.self) { mode in
                            Text(TerminalSettingsPage.shellIntegrationTitle(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: SettingsLayout.rowControlWidth, alignment: .trailing)
                }
                SettingsRow("Features", detail: "What the integration does in the shell.", ghosttyKey: "shell-integration-features") {
                    EmptyView()
                }
                LazyVGrid(columns: featureColumns, alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(TerminalSettings.shellIntegrationFeatureNames, id: \.self) { name in
                        featureToggle(
                            title: TerminalSettingsPage.shellFeatureTitle(name),
                            detail: TerminalSettingsPage.shellFeatureDetail(name),
                            isOn: featureBinding($shellFeatures, name: name, known: TerminalSettings.shellIntegrationFeatureNames)
                        )
                        .disabled(shellIntegration == .none)
                    }
                }
                SettingsPendingNote("Applies to local zsh only, in terminals opened after a change. Other shells and SSH sessions do not load it. The two SSH features are not used, because they need Ghostty's command-line tool.")
            }
        }
    }

    // MARK: Helpers

    private func featureToggle(title: LocalizedStringKey, detail: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Font.body)
                    .foregroundStyle(chrome.text)
                Text(detail)
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }

    /// One feature of a stored comma list as a checkbox; each change applies at once.
    private func featureBinding(_ stored: Binding<String>, name: String, known: [String]) -> Binding<Bool> {
        Binding(
            get: { TerminalSettings.storedFeatureListContains(stored.wrappedValue, name, known: known) },
            set: { enabled in
                stored.wrappedValue = TerminalSettings.storedFeatureList(
                    stored.wrappedValue,
                    setting: name,
                    enabled: enabled,
                    known: known
                )
                GhosttyRuntime.applyTerminalSettings()
            }
        )
    }

    static func percent(_ value: Double) -> String {
        String(format: String(localized: "%lld%%"), Int((value * 100).rounded()))
    }

    private func restoreDefaults() {
        let defaults = TerminalSettings.defaults
        cursorStyle = defaults.cursorStyle
        cursorBlink = defaults.cursorBlink
        cursorOpacity = defaults.cursorOpacity
        scrollbackLimitMB = defaults.scrollbackLimitMB
        copyOnSelect = defaults.copyOnSelect
        pasteProtection = defaults.clipboardPasteProtection
        mouseHideWhileTyping = defaults.mouseHideWhileTyping
        linkURL = defaults.linkURL
        optionAsAlt = defaults.optionAsAlt
        bellFeatures = TerminalSettingsPage.defaultBellFeatures
        shellIntegration = defaults.shellIntegration
        shellFeatures = TerminalSettingsPage.defaultShellFeatures
        GhosttyRuntime.applyTerminalSettings()
    }
}
