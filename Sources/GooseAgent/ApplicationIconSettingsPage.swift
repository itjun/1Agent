import SwiftUI

struct ApplicationIconSettingsPage: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject private var icons = ApplicationIconManager.shared
    @AppStorage(LocalPalette.storageKey) private var localPaletteRaw = LocalPalette.defaultPalette.rawValue
    @AppStorage(RemotePalette.storageKey) private var remotePaletteRaw = RemotePalette.defaultPalette.rawValue
    private let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Space.s), count: SettingsLayout.appIconColumns)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            SettingsCard("Local Colors and App Icon") {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    Text("Choose the local appearance colors and app icon. Terminal themes are configured independently. Dark, Clear, and Tinted icons follow the system appearance.")
                        .font(Theme.Font.rowMeta)
                        .foregroundStyle(chrome.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    iconButton(.original)

                    Text("Macaron Alternatives")
                        .font(Theme.Font.rowMeta)
                        .foregroundStyle(chrome.secondary)

                    LazyVGrid(columns: columns, spacing: Theme.Space.m) {
                        ForEach(ApplicationIcon.macaronIcons) { icon in
                            iconButton(icon)
                        }
                    }

                    Text("Your saved icon is reapplied when 1Agent starts, including after updating or reinstalling the app.")
                        .font(Theme.Font.rowMeta)
                        .foregroundStyle(chrome.secondary)

                    if icons.loadFailed {
                        Text("The selected app icon couldn’t be loaded. Your previous choice has been kept.")
                            .font(Theme.Font.rowMeta)
                            .foregroundStyle(chrome.danger)
                    }
                    if icons.finderUpdateFailed {
                        Text("The Finder icon couldn’t be updated. Make sure the app is writable, then select the icon again to retry.")
                            .font(Theme.Font.rowMeta)
                            .foregroundStyle(chrome.danger)
                    }
                }
            } accessory: {
                Button("Restore Default Icon") {
                    selectLocalIcon(.defaultIcon)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(defaultIsActive ? chrome.tertiary : chrome.accent)
                .buttonStyle(FamilyButtonStyle())
                .disabled(defaultIsActive)
                .accessibilityIdentifier("settings.appIcon.restoreDefault")
            }

            SettingsCard("Remote Appearance Colors") {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    Text("Choose the remote appearance colors. Terminal themes are configured independently.")
                        .font(Theme.Font.rowMeta)
                        .foregroundStyle(chrome.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(columns: columns, spacing: Theme.Space.m) {
                        ForEach(ApplicationIcon.macaronIcons) { icon in
                            paletteTile(icon, selected: remotePalette == icon, identifier: "settings.remotePalette.\(icon.rawValue)") {
                                remotePaletteRaw = icon.rawValue
                            }
                        }
                    }

                    if remotePalette == LocalPalette.palette(raw: localPaletteRaw) {
                        Text("Local and remote terminals use the same palette. Choose different colors to distinguish them.")
                            .font(Theme.Font.rowMeta)
                            .foregroundStyle(chrome.warning)
                    }
                }
            } accessory: {
                Button("Restore Default Colors") {
                    remotePaletteRaw = RemotePalette.defaultPalette.rawValue
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(remoteDefaultIsActive ? chrome.tertiary : chrome.accent)
                .buttonStyle(FamilyButtonStyle())
                .disabled(remoteDefaultIsActive)
                .accessibilityIdentifier("settings.remotePalette.restoreDefault")
            }
        }
    }

    private var defaultIsActive: Bool {
        icons.selected == .defaultIcon && !icons.loadFailed && !icons.finderUpdateFailed
            && LocalPalette.palette(raw: localPaletteRaw) == LocalPalette.defaultPalette
    }

    private var remoteDefaultIsActive: Bool {
        remotePalette == RemotePalette.defaultPalette
    }

    private var remotePalette: ApplicationIcon {
        RemotePalette.palette(raw: remotePaletteRaw)
    }

    private func iconButton(_ icon: ApplicationIcon) -> some View {
        paletteTile(icon, selected: icons.selected == icon, identifier: "settings.appIcon.\(icon.rawValue)") {
            selectLocalIcon(icon)
        }
    }

    private func selectLocalIcon(_ icon: ApplicationIcon) {
        icons.select(icon)
        guard icons.selected == icon, !icons.loadFailed else { return }
        localPaletteRaw = (icon == .original ? LocalPalette.defaultPalette : icon).rawValue
    }

    /// One icon tile; the app icon grid and the remote palette grid share it.
    private func paletteTile(_ icon: ApplicationIcon, selected: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            iconLabel(icon)
            .frame(maxWidth: .infinity)
            .padding(Theme.Space.s)
            .background(selected ? chrome.accentFill : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .stroke(selected ? chrome.accent : chrome.hairline, lineWidth: selected ? 2 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(chrome.accent)
                        .padding(Theme.Space.xs)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(FamilyButtonStyle())
        .accessibilityLabel(Text(verbatim: icon == .original ? icon.title : "\(icon.rawValue) · \(icon.title)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func iconLabel(_ icon: ApplicationIcon) -> some View {
        if icon == .original {
            HStack(spacing: Theme.Space.m) {
                iconPreview(icon)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.s) {
                        Text(verbatim: icon.title)
                            .foregroundStyle(chrome.text)
                        Text("Default Icon")
                            .foregroundStyle(chrome.secondary)
                    }
                    Text("White background, blue icon")
                        .foregroundStyle(chrome.secondary)
                }
                .font(Theme.Font.rowMeta)
                Spacer(minLength: 0)
            }
        } else {
            VStack(spacing: Theme.Space.xs) {
                iconPreview(icon)
                Text(verbatim: icon.title)
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(verbatim: icon.rawValue)
                    .font(.system(size: 10))
                    .foregroundStyle(chrome.secondary)
            }
        }
    }

    @ViewBuilder
    private func iconPreview(_ icon: ApplicationIcon) -> some View {
        if let image = icons.image(for: icon) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: SettingsLayout.appIconPreviewSize, height: SettingsLayout.appIconPreviewSize)
                .accessibilityHidden(true)
        }
    }
}
