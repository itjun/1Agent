import SwiftUI

/// 图标属于完整外观预设，不提供脱离预设的单独选择。
struct AppThemeIdentity: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject private var icons = ApplicationIconManager.shared
    @AppStorage(AppTheme.storageKey) private var presetRaw = AppTheme.defaultPreset.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Space.m) {
                        ForEach(AppThemePreset.allCases) { preset in
                            let isSelected = preset.rawValue == presetRaw
                            Button { AppearanceDriver.shared.selectPreset(preset) } label: {
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
                                    Spacer(minLength: 0)
                                }
                                .padding(Theme.Space.s)
                                .frame(width: SettingsLayout.appIconIdentityWidth)
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
                .padding(Theme.Space.xs)
            }
            .scrollIndicators(.automatic)
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
}
