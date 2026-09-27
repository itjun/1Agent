import AppKit
import GhosttyTheme
import SwiftUI

enum SettingsLayout {
    static let sidebarWidth: CGFloat = 180
    static let separatorWidth: CGFloat = 1
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case appearanceMode
    case terminalFont
    case terminalColors

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .appearanceMode: "Appearance Mode"
        case .terminalFont: "Terminal Font"
        case .terminalColors: "Terminal Colors"
        }
    }
}

struct SettingsView: View {
    @Environment(\.windowChrome) private var chrome
    @State private var selectedSection: SettingsSection = .appearanceMode
    @AppStorage(TerminalAppearance.storageKey) private var appearanceRaw = TerminalAppearance.system.rawValue
    @AppStorage(TerminalThemeFamily.storageKey) private var themeFamilyRaw = TerminalThemeFamily.claude.rawValue
    @AppStorage(TerminalFontSettings.familyKey) private var fontFamily = TerminalDefaults.defaultFontFamily
    @AppStorage(TerminalFontSettings.sizeKey) private var fontSize = TerminalDefaults.defaultFontSize

    private var appearance: TerminalAppearance {
        TerminalAppearance(rawValue: appearanceRaw) ?? .system
    }

    private var themeFamily: TerminalThemeFamily {
        TerminalThemeFamily.from(raw: themeFamilyRaw)
    }

    private var fontFamilies: [String] {
        TerminalFontSettings.availableFamilies()
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            HStack(spacing: 0) {
                settingsNavigation { section in
                    withAnimation(.easeInOut(duration: 0.18)) {
                        scrollProxy.scrollTo(section, anchor: .top)
                    }
                }
                Rectangle()
                    .fill(chrome.hairline)
                    .frame(width: SettingsLayout.separatorWidth)
                ScrollView {
                    settingsContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(chrome.background.ignoresSafeArea())
        .oneagentHideFocusRing()
        .onAppear {
            if !fontFamilies.contains(fontFamily) {
                fontFamily = TerminalDefaults.defaultFontFamily
            }
            GhosttyRuntime.applyFontSettings()
        }
    }

    private func settingsNavigation(onSelect: @escaping (SettingsSection) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(chrome.text)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 16)

            ForEach(SettingsSection.allCases) { section in
                let selected = selectedSection == section
                Button {
                    selectedSection = section
                    onSelect(section)
                } label: {
                    Text(section.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(chrome.text)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Rectangle().fill(selected ? chrome.accent.opacity(0.16) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(width: SettingsLayout.sidebarWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(chrome.elevated.opacity(0.58).ignoresSafeArea())
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Appearance Mode")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(chrome.text)
                .id(SettingsSection.appearanceMode)
            HStack(spacing: 8) {
                ForEach(TerminalAppearance.allCases) { mode in
                    appearanceCard(mode)
                }
            }

            Text("Terminal Font")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(chrome.text)
                .id(SettingsSection.terminalFont)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text("Font")
                        .font(.system(size: 13))
                        .foregroundStyle(chrome.text)
                        .frame(width: 56, alignment: .leading)
                    Picker("", selection: $fontFamily) {
                        ForEach(fontFamilies, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Text("Size")
                        .font(.system(size: 13))
                        .foregroundStyle(chrome.text)
                        .frame(width: 56, alignment: .leading)
                    Slider(
                        value: $fontSize,
                        in: TerminalDefaults.minFontSize...TerminalDefaults.maxFontSize,
                        step: 1
                    )
                    Text(String(format: String(localized: "%lld px"), Int(fontSize.rounded())))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(chrome.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                Text("1Agent 你好 abc 0123456789 -> =>")
                    .font(.custom(fontFamily, size: CGFloat(fontSize)))
                    .foregroundStyle(chrome.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(chrome.background)
                    )
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(chrome.elevated))
            .onChange(of: fontFamily) { _, _ in
                GhosttyRuntime.applyFontSettings()
            }
            .onChange(of: fontSize) { _, newValue in
                let clamped = min(max(newValue, TerminalDefaults.minFontSize), TerminalDefaults.maxFontSize)
                if clamped != newValue {
                    fontSize = clamped
                }
                GhosttyRuntime.applyFontSettings()
            }

            Text("Terminal Colors")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(chrome.text)
                .id(SettingsSection.terminalColors)
            Text("Light and night variants follow the appearance mode.")
                .font(.system(size: 12))
                .foregroundStyle(chrome.secondary)
            VStack(spacing: 4) {
                ForEach(TerminalThemeFamily.allCases) { family in
                    familyRow(family)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(chrome.elevated))
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func appearanceCard(_ mode: TerminalAppearance) -> some View {
        let selected = appearance == mode
        return Button {
            appearanceRaw = mode.rawValue
            AppearanceDriver.shared.reapply()
        } label: {
            Text(mode.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selected ? chrome.accent : Theme.hairline, lineWidth: selected ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func familyRow(_ family: TerminalThemeFamily) -> some View {
        let selected = themeFamily == family
        return Button {
            themeFamilyRaw = family.rawValue
            GhosttyRuntime.apply(family: family)
        } label: {
            HStack(spacing: 10) {
                if let light = family.lightPaint, let dark = family.darkPaint {
                    themeSwatch(surface: light.surface, ink: light.ink)
                    themeSwatch(surface: dark.surface, ink: dark.ink)
                } else if family == .claude {
                    themeSwatch(surface: ClaudeTerminalTheme.paper.surface, ink: ClaudeTerminalTheme.paper.ink)
                    themeSwatch(surface: ClaudeTerminalTheme.dark.surface, ink: ClaudeTerminalTheme.dark.ink)
                } else if family == .raycast {
                    themeSwatch(surface: RaycastTerminalTheme.light.surface, ink: RaycastTerminalTheme.light.ink)
                    themeSwatch(surface: RaycastTerminalTheme.dark.surface, ink: RaycastTerminalTheme.dark.ink)
                } else {
                    themeSwatch(named: family.lightName ?? "")
                    themeSwatch(named: family.darkName ?? "")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(family.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text(family.variantTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(chrome.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? chrome.accent : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func themeSwatch(surface: String, ink: String) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(ghosttyHex: surface) ?? .black)
            .frame(width: 36, height: 24)
            .overlay(
                Text("Aa")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(ghosttyHex: ink) ?? .white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
    }

    private func themeSwatch(named name: String) -> some View {
        let theme = GhosttyThemeCatalog.theme(named: name)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(ghosttyHex: theme?.background ?? "000000") ?? .black)
            .frame(width: 36, height: 24)
            .overlay(
                Text("Aa")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(ghosttyHex: theme?.foreground ?? "FFFFFF") ?? .white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
    }
}

/// Settings is its own window, with the standard traffic lights, like WeChat.
struct SettingsWindowRoot: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var appearanceDriver = AppearanceDriver.shared
    @AppStorage(TerminalAppearance.storageKey) private var appearanceRaw = TerminalAppearance.system.rawValue

    private var chrome: WindowChrome {
        WindowChrome.resolve(isDark: appearanceDriver.isDark)
    }

    var body: some View {
        SettingsView()
            .environment(\.windowChrome, chrome)
            .preferredColorScheme(appearanceDriver.interfaceColorScheme)
            .oneagentHideFocusRing()
            .frame(minWidth: SheetLayout.settings, minHeight: SheetLayout.settingsBodyHeight)
            .onAppear { appearanceDriver.reapply() }
            .onChange(of: appearanceRaw) { _, _ in
                appearanceDriver.reapply()
            }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    static let windowID = NSUserInterfaceItemIdentifier("settings")

    private var window: NSWindow?
    private var model: AppModel?

    func toggle(model: AppModel) {
        self.model = model
        if let window, window.isVisible {
            window.close()
            return
        }
        model.hostPickerPresented = false
        let window = self.window ?? makeWindow(model: model)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        model.showingSettings = true
    }

    private func makeWindow(model: AppModel) -> NSWindow {
        let controller = NSHostingController(rootView: SettingsWindowRoot(model: model))
        let window = NSWindow(contentViewController: controller)
        window.identifier = Self.windowID
        window.title = String(localized: "Settings")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = TerminalAppearance.appKitAppearance(isDark: TerminalAppearance.stored().resolvesDark())
        let size = NSSize(width: SheetLayout.settings, height: SheetLayout.settingsBodyHeight)
        window.setContentSize(size)
        window.minSize = size
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model?.showingSettings = false
    }
}

private extension Color {
    init?(ghosttyHex raw: String) {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
