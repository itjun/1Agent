import SwiftUI

/// 图标属于完整外观预设，不提供脱离预设的单独选择。
struct AppThemeIdentity: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject private var icons = ApplicationIconManager.shared
    @AppStorage(AppTheme.storageKey) private var presetRaw = AppTheme.defaultPreset.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            VStack(spacing: Theme.Space.s) {
                ForEach(AppThemePreset.allCases) { preset in
                    let isSelected = preset.rawValue == presetRaw
                    Button { AppearanceDriver.shared.selectPreset(preset) } label: {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Theme.Space.m) {
                                identity(for: preset, isSelected: isSelected)
                                    .frame(width: SettingsLayout.appIconIdentityWidth, alignment: .leading)
                                previews(for: preset)
                                    .frame(minWidth: SettingsLayout.presetPreviewMinimumWidth * 2 + Theme.Space.s)
                            }
                            VStack(alignment: .leading, spacing: Theme.Space.s) {
                                identity(for: preset, isSelected: isSelected)
                                previews(for: preset)
                            }
                        }
                        .padding(Theme.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isSelected ? chrome.selection : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .strokeBorder(isSelected ? chrome.accent : .clear, lineWidth: 1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(FamilyButtonStyle())
                    .accessibilityLabel(Text(preset.icon.title))
                    .accessibilityValue(Text(verbatim: preset.id))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("settings.preset.choice." + preset.id)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.preset.identity")
            Text("The app icon follows the appearance preset.")
                .font(Theme.Font.rowMeta)
                .foregroundStyle(chrome.secondary)

            if icons.loadFailed || icons.finderUpdateFailed {
                Text("The preset icon could not be fully applied. Retry to sync the Dock and Finder icons.")
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.danger)
                Button("Retry Icon Sync") { icons.applyPresetIcon(AppTheme.icon) }
                    .buttonStyle(FamilyButtonStyle(kind: .secondary))
                    .accessibilityIdentifier("settings.preset.retryIcon")
            }
        }
    }

    private func identity(for preset: AppThemePreset, isSelected: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            if let image = icons.image(for: preset.icon) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: SettingsLayout.appIconPreviewSize, height: SettingsLayout.appIconPreviewSize)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(preset.icon.title)
                    .font(Theme.Font.body.weight(.medium))
                    .foregroundStyle(isSelected ? chrome.accent : chrome.text)
                Text(verbatim: preset.id)
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.secondary)
            }
        }
    }

    private func previews(for preset: AppThemePreset) -> some View {
        HStack(spacing: Theme.Space.s) {
            ThemePreviewCard(isDark: false, preset: preset, isCompact: true)
            ThemePreviewCard(isDark: true, preset: preset, isCompact: true)
        }
        .accessibilityHidden(true)
    }

}
