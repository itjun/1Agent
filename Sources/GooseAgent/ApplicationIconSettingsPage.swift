import SwiftUI

struct ApplicationIconSettingsPage: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject private var icons = ApplicationIconManager.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Space.s), count: SettingsLayout.appIconColumns)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            SettingsCard("App Icon") {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    Text("Choose an app icon. Finder, the Dock and the app switcher update together, the app’s accent colors follow the icon, and your choice is remembered after restarting.")
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
                    icons.select(.defaultIcon)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(defaultIsActive ? chrome.tertiary : chrome.accent)
                .buttonStyle(FamilyButtonStyle())
                .disabled(defaultIsActive)
                .accessibilityIdentifier("settings.appIcon.restoreDefault")
            }
        }
    }

    private var defaultIsActive: Bool {
        icons.selected == .defaultIcon && !icons.loadFailed && !icons.finderUpdateFailed
    }

    private func iconButton(_ icon: ApplicationIcon) -> some View {
        let selected = icons.selected == icon
        return Button {
            icons.select(icon)
        } label: {
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
        .accessibilityIdentifier("settings.appIcon.\(icon.rawValue)")
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
