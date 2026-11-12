import SwiftUI

private struct SettingsControlTitleKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingsControlTitle: String? {
        get { self[SettingsControlTitleKey.self] }
        set { self[SettingsControlTitleKey.self] = newValue }
    }
}

/// One setting inside a `SettingsCard`: title, a one-line explanation, the Ghostty key it maps to
/// (so the official docs can be looked up), and the control on the right.
struct SettingsRow<Control: View>: View {
    @Environment(\.windowChrome) private var chrome
    @State private var showsConfigurationHelp = false
    let title: String.LocalizationValue
    let detail: LocalizedStringKey?
    let ghosttyKey: String?
    /// Separators belong between options, never after the last option in a card.
    let showsSeparator: Bool
    @ViewBuilder let control: () -> Control

    init(
        _ title: String.LocalizationValue,
        detail: LocalizedStringKey? = nil,
        ghosttyKey: String? = nil,
        showsSeparator: Bool = false,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.ghosttyKey = ghosttyKey
        self.showsSeparator = showsSeparator
        self.control = control
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Space.l) {
                labels.frame(minWidth: SettingsLayout.stackedRowBreakpoint - SettingsLayout.rowControlWidth - Theme.Space.l,
                             idealWidth: SettingsLayout.stackedRowBreakpoint - SettingsLayout.rowControlWidth - Theme.Space.l,
                             maxWidth: .infinity, alignment: .leading)
                controls.frame(width: SettingsLayout.rowControlWidth, alignment: .trailing)
            }
            .frame(minWidth: SettingsLayout.stackedRowBreakpoint)
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                labels.frame(maxWidth: .infinity, alignment: .leading)
                controls.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: SettingsLayout.rowMinimumHeight)
        .padding(.bottom, showsSeparator ? Theme.Space.s : 0)
        .overlay(alignment: .bottom) {
            if showsSeparator { Rectangle().fill(chrome.hairline).frame(height: 0.5) }
        }
    }

    private var controls: some View {
        control()
            .environment(\.settingsControlTitle, String(localized: title))
            .help(Text(detail ?? ""))
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                Text(String(localized: title))
                    .font(Theme.Font.body).foregroundStyle(chrome.text)
                if let ghosttyKey {
                    Button { showsConfigurationHelp.toggle() } label: {
                        Image(systemName: "info.circle")
                            .font(Theme.Font.rowMeta)
                            .frame(width: Theme.Control.compactHeight, height: Theme.Control.compactHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(FamilyButtonStyle())
                    .focusable()
                    .onKeyPress(keys: [.space, .return]) { _ in
                        showsConfigurationHelp.toggle()
                        return .handled
                    }
                    .foregroundStyle(chrome.secondary)
                    .accessibilityLabel(Text(String(format: String(localized: "Configuration key for %@"), String(localized: title))))
                    .accessibilityIdentifier("settings.help.\(ghosttyKey)")
                    .popover(isPresented: $showsConfigurationHelp) {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            Text("Configuration Key").font(Theme.Font.sectionTitle)
                            Text(verbatim: ghosttyKey).font(Theme.Font.paneTitle).textSelection(.enabled)
                            if let detail { Text(detail).font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary) }
                            Button("Copy") {
                                copyConfigurationKey(ghosttyKey)
                            }
                            .buttonStyle(FamilyButtonStyle(kind: .secondary))
                            .focusable()
                            .onKeyPress(keys: [.space, .return]) { _ in
                                copyConfigurationKey(ghosttyKey)
                                return .handled
                            }
                            .accessibilityIdentifier("settings.help.copy.\(ghosttyKey)")
                        }
                        .padding(Theme.Space.l)
                        .frame(width: SettingsLayout.configurationHelpWidth, alignment: .leading)
                        .foregroundStyle(chrome.text)
                        .background(chrome.background)
                    }
                }
            }
            if let detail {
                Text(detail)
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func copyConfigurationKey(_ key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
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
            FamilySlider(value: snappedValue, range: range) { editing in
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
    @Environment(\.settingsControlTitle) private var title

    var body: some View {
        Toggle(isOn: $isOn) { Text(verbatim: title ?? "") }
            .labelsHidden()
            .toggleStyle(FamilyToggleStyle(showsLabel: false))
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
            .buttonStyle(FamilyButtonStyle())
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

/// 终端设置只保留鼠标与剪贴板选项。
/// Every control writes its own UserDefaults key and applies at once.
struct TerminalSettingsPage: View {
    @Environment(\.windowChrome) private var chrome
    @AppStorage(TerminalSettings.copyOnSelectKey) private var copyOnSelect = TerminalSettings.defaults.copyOnSelect
    @AppStorage(TerminalSettings.clipboardPasteProtectionKey) private var pasteProtection = TerminalSettings.defaults.clipboardPasteProtection

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            mouseCard
            Text("SSH sends a keepalive probe every 30 seconds; after 3 missed replies the connection counts as lost and reconnects automatically. This cannot be turned off.")
                .font(Theme.Font.rowMeta)
                .foregroundStyle(chrome.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            RestorePageDefaultsButton {
                restoreDefaults()
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

    private static func copyOnSelectTitle(_ mode: TerminalSettings.CopyOnSelect) -> String {
        switch mode {
        case .none: String(localized: "Off")
        case .clipboard: String(localized: "Copy to Clipboard")
        case .primary: String(localized: "Selection Clipboard Only (no effect on macOS)")
        case .both: String(localized: "Clipboard and Selection Clipboard")
        }
    }

    private var mouseCard: some View {
        SettingsCard("Mouse and Clipboard") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                SettingsRow("Copy on Select", detail: "Copy text to the clipboard as soon as it is selected.", ghosttyKey: "copy-on-select", showsSeparator: true) {
                    FamilyPicker(value: $copyOnSelect.applyingTerminalSettings(), options: copyOnSelectChoices.map { ($0, TerminalSettingsPage.copyOnSelectTitle($0)) })
                        .accessibilityLabel(Text("Copy on Select"))
                        .frame(width: SettingsLayout.rowControlWidth, alignment: .trailing)
                }
                SettingsRow("Paste Protection", detail: "Ask before pasting text with line breaks or other content that could run commands.", ghosttyKey: "clipboard-paste-protection") {
                    SettingsSwitch(isOn: $pasteProtection.applyingTerminalSettings())
                }

            }
        }
    }

    private func restoreDefaults() {
        let defaults = TerminalSettings.defaults
        copyOnSelect = defaults.copyOnSelect
        pasteProtection = defaults.clipboardPasteProtection
        GhosttyRuntime.applyTerminalSettings()
    }
}
