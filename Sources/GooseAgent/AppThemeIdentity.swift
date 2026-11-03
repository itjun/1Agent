import SwiftUI

/// 图标属于完整外观预设，不提供脱离预设的单独选择。
struct AppThemeIdentity: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject private var icons = ApplicationIconManager.shared
    @AppStorage(AppTheme.storageKey) private var presetRaw = AppTheme.defaultPreset.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                if let image = icons.image(for: AppTheme.icon) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: SettingsLayout.appIconPreviewSize, height: SettingsLayout.appIconPreviewSize)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Picker("Preset Theme", selection: Binding(
                        get: { AppThemePreset(rawValue: presetRaw) ?? AppTheme.defaultPreset },
                        set: { AppearanceDriver.shared.selectPreset($0) }
                    )) {
                        ForEach(AppThemePreset.allCases) { preset in
                            Text(preset.icon.title).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityIdentifier("settings.preset.picker")
                    Text("The app icon follows the appearance preset.")
                        .font(Theme.Font.rowMeta)
                        .foregroundStyle(chrome.secondary)
                }
                Spacer(minLength: Theme.Space.s)
                Text(verbatim: AppTheme.id)
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.secondary)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.preset.identity")

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
