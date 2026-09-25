import GhosttyTheme
import SwiftUI

enum TabPlacement: String, CaseIterable, Identifiable {
    case vertical
    case top
    case bottom

    static let storageKey = "appearance.tabLayout"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .vertical: "Vertical Tabs"
        case .top: "Top Tabs"
        case .bottom: "Bottom Tabs"
        }
    }
}

enum SettingsLayout {
    static let contentWidth: CGFloat = 720
}

struct SettingsView: View {
    @Environment(\.windowChrome) private var chrome
    @AppStorage(TabPlacement.storageKey) private var tabLayoutRaw = TabPlacement.vertical.rawValue
    @AppStorage(TerminalAppearance.storageKey) private var appearanceRaw = TerminalAppearance.system.rawValue
    @AppStorage(TerminalThemeFamily.storageKey) private var themeFamilyRaw = TerminalThemeFamily.github.rawValue

    private var tabLayout: TabPlacement {
        TabPlacement(rawValue: tabLayoutRaw) ?? .vertical
    }

    private var appearance: TerminalAppearance {
        TerminalAppearance(rawValue: appearanceRaw) ?? .system
    }

    private var themeFamily: TerminalThemeFamily {
        TerminalThemeFamily.from(raw: themeFamilyRaw)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(chrome.text)
                Text("Appearance")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(chrome.secondary)
                Text("Layout")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(chrome.text)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(TabPlacement.allCases) { placement in
                        layoutCard(placement)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(chrome.elevated))

                Text("Appearance Mode")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(chrome.text)
                HStack(spacing: 8) {
                    ForEach(TerminalAppearance.allCases) { mode in
                        appearanceCard(mode)
                    }
                }

                Text("Terminal Colors")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(chrome.text)
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
            .frame(maxWidth: SettingsLayout.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(chrome.background)
        .gooseagentHideFocusRing()
    }

    private func appearanceCard(_ mode: TerminalAppearance) -> some View {
        let selected = appearance == mode
        return Button {
            appearanceRaw = mode.rawValue
        } label: {
            Text(mode.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selected ? Color.accentColor : Theme.hairline, lineWidth: selected ? 2 : 1)
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
                } else {
                    themeSwatch(named: family.lightName ?? "")
                    themeSwatch(named: family.darkName ?? "")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(family.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text("Light / Night")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
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

    private func layoutCard(_ placement: TabPlacement) -> some View {
        let selected = tabLayout == placement
        return Button {
            tabLayoutRaw = placement.rawValue
        } label: {
            VStack(spacing: 8) {
                layoutPreview(placement)
                    .frame(width: 118, height: 76)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    )
                Text(placement.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func layoutPreview(_ placement: TabPlacement) -> some View {
        let bar = Color(white: 0.78)
        return ZStack {
            Color(white: 0.97)
            switch placement {
            case .vertical:
                HStack(spacing: 0) {
                    bar.frame(width: 26)
                    Spacer(minLength: 0)
                }
            case .top:
                VStack(spacing: 0) {
                    bar.frame(height: 16)
                    Spacer(minLength: 0)
                }
            case .bottom:
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    bar.frame(height: 12)
                }
            }
        }
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
