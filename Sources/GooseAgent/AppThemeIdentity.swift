import SwiftUI

/// 图标属于完整外观预设，不提供脱离预设的单独选择。
struct AppThemeIdentity: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject private var icons = ApplicationIconManager.shared
    @AppStorage(AppTheme.storageKey) private var presetRaw = AppTheme.defaultPreset.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ViewThatFits(in: .horizontal) {
                presetGrid(columns: 4)
                presetGrid(columns: 3)
                presetGrid(columns: 2)
                presetGrid(columns: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private func presetGrid(columns: Int) -> some View {
        Grid(horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.m) {
            ForEach(0..<((AppThemePreset.allCases.count + columns - 1) / columns), id: \.self) { row in
                GridRow {
                    ForEach(Array(AppThemePreset.allCases.dropFirst(row * columns).prefix(columns))) { preset in
                        choice(for: preset)
                            .frame(width: SettingsLayout.presetChoiceWidth)
                    }
                }
            }
        }
    }

    private func choice(for preset: AppThemePreset) -> some View {
        let isSelected = preset.rawValue == presetRaw
        return Button { AppearanceDriver.shared.selectPreset(preset) } label: {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                identity(for: preset, isSelected: isSelected)
                previews(for: preset)
            }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? chrome.selection : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(isSelected ? chrome.accent : .clear, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(FamilyButtonStyle())
        .accessibilityLabel(Text(preset.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.preset.choice." + preset.id)
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
            Text(preset.title)
                .font(Theme.Font.body.weight(.medium))
                .foregroundStyle(isSelected && !chrome.isSystem ? chrome.accent : chrome.text)
        }
    }

    private func previews(for preset: AppThemePreset) -> some View {
        VStack(spacing: Theme.Space.s) {
            ThemePreviewCard(isDark: false, preset: preset, isCompact: true)
            ThemePreviewCard(isDark: true, preset: preset, isCompact: true)
        }
        .accessibilityHidden(true)
    }

}
