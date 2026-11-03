import SwiftUI

struct ApplicationIconSettingsPage: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject private var icons = ApplicationIconManager.shared
    @State private var hoveredIcon: ApplicationIcon?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            Text("Choose the app icon. Window and terminal colors stay on the selected preset.")
                .font(Theme.Font.rowMeta)
                .foregroundStyle(chrome.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: Theme.Space.xs) {
                tableHeader
                ForEach(ApplicationIcon.allCases) { icon in
                    paletteRow(icon)
                }
            }

            HStack(spacing: Theme.Space.l) {
                Button("Restore Default Icon") { selectIcon(.defaultIcon) }
                    .disabled(defaultIsActive)
                    .accessibilityIdentifier("settings.appIcon.restoreDefault")
            }
            .font(Theme.Font.rowMeta)
            .foregroundStyle(chrome.text)
            .buttonStyle(FamilyButtonStyle(kind: .secondary))

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
    }

    private var defaultIsActive: Bool {
        icons.selected == .defaultIcon && !icons.loadFailed && !icons.finderUpdateFailed
    }

    private var tableHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.l) {
                Text("Icon").frame(width: SettingsLayout.appIconIdentityWidth, alignment: .leading)
                Spacer(minLength: Theme.Space.m)
                choiceHeadings
            }
            .frame(minWidth: SettingsLayout.stackedRowBreakpoint)
            HStack(spacing: Theme.Space.l) {
                Text("Icon").frame(maxWidth: .infinity, alignment: .leading)
                choiceHeadings
            }
        }
        .font(Theme.Font.rowMeta)
        .foregroundStyle(chrome.secondary)
        .padding(.horizontal, Theme.Space.m)
        .padding(.bottom, Theme.Space.s)
    }

    private var choiceHeadings: some View {
        Text("Icon").frame(width: SettingsLayout.appIconChoiceWidth)
    }

    private func paletteRow(_ icon: ApplicationIcon) -> some View {
        let palette = chrome
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.l) {
                identity(icon, palette: palette).frame(width: SettingsLayout.appIconIdentityWidth, alignment: .leading)
                Spacer(minLength: Theme.Space.m)
                choices(icon, palette: palette)
            }
            .frame(minWidth: SettingsLayout.stackedRowBreakpoint)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.l) {
                    identity(icon, palette: palette).frame(maxWidth: .infinity, alignment: .leading)
                    choices(icon, palette: palette)
                }
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
            .fill(hoveredIcon == icon ? chrome.elevated : .clear))
        .onHover { hoveredIcon = $0 ? icon : nil }
        .accessibilityElement(children: .contain)
    }

    private func identity(_ icon: ApplicationIcon, palette: WindowChrome) -> some View {
        HStack(spacing: Theme.Space.m) {
            iconPreview(icon)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(verbatim: icon.title).font(Theme.Font.body).foregroundStyle(chrome.text)
                HStack(spacing: Theme.Space.xs) {
                    Circle().fill(icon.palette.map { RGBColor(ghosttyHex: $0.fill)!.color } ?? palette.accentFill)
                        .overlay(Circle().strokeBorder(palette.accent, lineWidth: 1))
                        .frame(width: SettingsLayout.appIconSwatchSize, height: SettingsLayout.appIconSwatchSize)
                        .accessibilityHidden(true)
                    if icon == .original { Text("Default Icon") }
                    else { Text(verbatim: icon.rawValue) }
                }
                .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
            }
        }
    }

    private func choices(_ icon: ApplicationIcon, palette: WindowChrome) -> some View {
        HStack(spacing: Theme.Space.s) {
            choiceButton(isSelected: icons.selected == icon, palette: palette,
                         label: String(format: String(localized: "Use %@ for the app icon"), icon.title),
                         identifier: "settings.appIcon.\(icon.rawValue)") { selectIcon(icon) }
        }
    }

    private func choiceButton(isSelected: Bool, palette: WindowChrome, label: String,
                              identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: SettingsLayout.appIconSelectionSize))
                .foregroundStyle(isSelected ? palette.accent : chrome.lineStrong)
                .frame(width: SettingsLayout.appIconChoiceWidth, height: SettingsLayout.rowMinimumHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(FamilyButtonStyle())
        .focusable()
        .onKeyPress(keys: [.space, .return]) { _ in action(); return .handled }
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private func selectIcon(_ icon: ApplicationIcon) {
        icons.select(icon)
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
