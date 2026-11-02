import SwiftUI

struct ApplicationIconSettingsPage: View {
    @ObservedObject private var icons = ApplicationIconManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            Picker("Icon", selection: Binding(get: { icons.selected }, set: { icons.select($0) })) {
                ForEach(ApplicationIcon.allCases) { icon in
                    HStack {
                        if let image = icons.image(for: icon) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 32, height: 32)
                        }
                        Text(verbatim: icon.title)
                    }.tag(icon)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("settings.appIcon.picker")

            Button("Restore Default Icon") { icons.select(.defaultIcon) }
                .disabled(icons.selected == .defaultIcon && !icons.loadFailed && !icons.finderUpdateFailed)
                .accessibilityIdentifier("settings.appIcon.restoreDefault")

            Text("Your saved icon is reapplied when 1Agent starts, including after updating or reinstalling the app.")
                .font(.callout).foregroundStyle(.secondary)
            if icons.loadFailed {
                Text("The selected app icon couldn’t be loaded. Your previous choice has been kept.").foregroundStyle(.red)
            }
            if icons.finderUpdateFailed {
                Text("The Finder icon couldn’t be updated. Make sure the app is writable, then select the icon again to retry.").foregroundStyle(.red)
            }
        }
    }
}
