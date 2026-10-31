import SwiftUI

struct ApplicationIconSettingsPage: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject private var icons = ApplicationIconManager.shared
    @AppStorage(LocalPalette.storageKey) private var localPaletteRaw = LocalPalette.defaultPalette.rawValue
    @AppStorage(RemotePalette.storageKey) private var remotePaletteRaw = RemotePalette.defaultPalette.rawValue
    @State private var hoveredIcon: ApplicationIcon?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            Text("Choose the local app icon and remote accent independently. Each row previews selection and focus; terminal themes stay separate.")
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
                Button("Restore Default Icon") { selectLocalIcon(.defaultIcon) }
                    .disabled(defaultIsActive)
                    .accessibilityIdentifier("settings.appIcon.restoreDefault")
                Button("Restore Default Colors") { remotePaletteRaw = RemotePalette.defaultPalette.rawValue }
                    .disabled(remotePalette == RemotePalette.defaultPalette)
                    .accessibilityIdentifier("settings.remotePalette.restoreDefault")
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
            if remotePalette == LocalPalette.palette(raw: localPaletteRaw) {
                Text("Local and remote terminals use the same palette. Choose different colors to distinguish them.")
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.warning)
            }
        }
    }

    private var defaultIsActive: Bool {
        icons.selected == .defaultIcon && !icons.loadFailed && !icons.finderUpdateFailed
            && LocalPalette.palette(raw: localPaletteRaw) == LocalPalette.defaultPalette
    }

    private var remotePalette: ApplicationIcon { RemotePalette.palette(raw: remotePaletteRaw) }

    private var tableHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.l) {
                Text("Icon and Color").frame(width: SettingsLayout.appIconIdentityWidth, alignment: .leading)
                Text("Appearance Preview").frame(maxWidth: .infinity, alignment: .leading)
                choiceHeadings
            }
            .frame(minWidth: SettingsLayout.stackedRowBreakpoint)
            HStack(spacing: Theme.Space.l) {
                Text("Icon and Color").frame(maxWidth: .infinity, alignment: .leading)
                choiceHeadings
            }
        }
        .font(Theme.Font.rowMeta)
        .foregroundStyle(chrome.secondary)
        .padding(.horizontal, Theme.Space.m)
        .padding(.bottom, Theme.Space.s)
    }

    private var choiceHeadings: some View {
        HStack(spacing: Theme.Space.s) {
            Text("This Mac").frame(width: SettingsLayout.appIconChoiceWidth)
            Text("Remote").frame(width: SettingsLayout.appIconChoiceWidth)
        }
    }

    private func paletteRow(_ icon: ApplicationIcon) -> some View {
        let palette = WindowChrome(isDark: chrome.isDark, icon: icon == .original ? LocalPalette.defaultPalette : icon)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.l) {
                identity(icon, palette: palette).frame(width: SettingsLayout.appIconIdentityWidth, alignment: .leading)
                effectPreview(palette).frame(maxWidth: .infinity)
                choices(icon, palette: palette)
            }
            .frame(minWidth: SettingsLayout.stackedRowBreakpoint)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.l) {
                    identity(icon, palette: palette).frame(maxWidth: .infinity, alignment: .leading)
                    choices(icon, palette: palette)
                }
                effectPreview(palette)
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
                    Circle().fill(palette.accentFill)
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
                         label: String(format: String(localized: "Use %@ for the local app icon"), icon.title),
                         identifier: "settings.appIcon.\(icon.rawValue)") { selectLocalIcon(icon) }
            if icon != .original {
                choiceButton(isSelected: remotePalette == icon, palette: palette,
                             label: String(format: String(localized: "Use %@ for remote colors"), icon.title),
                             identifier: "settings.remotePalette.\(icon.rawValue)") { remotePaletteRaw = icon.rawValue }
            } else {
                Color.clear.frame(width: SettingsLayout.appIconChoiceWidth, height: SettingsLayout.rowMinimumHeight)
                    .accessibilityHidden(true)
            }
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

    private func effectPreview(_ palette: WindowChrome) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text("Selected Session")
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.s)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(palette.accentFill))
            Text("Focused Pane")
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.s)
                .background(chrome.background)
                .modifier(FloatingContentSurface(isSelected: true))
                .environment(\.windowChrome, palette)
        }
        .font(Theme.Font.rowMeta)
        .foregroundStyle(chrome.text)
        .accessibilityHidden(true)
    }

    private func selectLocalIcon(_ icon: ApplicationIcon) {
        icons.select(icon)
        guard icons.selected == icon, !icons.loadFailed else { return }
        localPaletteRaw = (icon == .original ? LocalPalette.defaultPalette : icon).rawValue
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
