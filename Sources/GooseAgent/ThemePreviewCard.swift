import SwiftUI

/// 同一预设的浅／深色示意，使用实际窗口和终端色值，不提供额外主题选择。
struct ThemePreviewCard: View {
    let isDark: Bool
    var preset: AppThemePreset = AppTheme.stored()

    var body: some View {
        let colors = AppTheme.colors(isDark: isDark, preset: preset)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(isDark ? "Dark" : "Light")
                .font(Theme.Font.rowMeta.weight(.medium))
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text("Aa").font(.system(size: 20, weight: .medium))
                    Spacer()
                    Text(verbatim: "~/")
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(colors.color(colors.selection), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    Rectangle().fill(colors.color(colors.accent)).frame(width: 6, height: 15)
                }
                Text(verbatim: "$ git status")
                    .font(.system(size: 12, design: .monospaced))
                HStack(spacing: 3) {
                    ForEach(0..<16, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(colors.color(colors.ansi[index]))
                            .frame(height: 10)
                    }
                }
                .accessibilityHidden(true)
            }
            .foregroundStyle(colors.color(colors.foreground))
            .padding(Theme.Space.m)
            .background(colors.color(colors.background), in: RoundedRectangle(cornerRadius: Theme.Radius.row))
            .padding(Theme.Space.m)
            .background {
                LinearGradient(colors: colors.gradientColors, startPoint: .top, endPoint: .bottom)
                    .overlay {
                        LinearGradient(colors: [colors.color(colors.glow).opacity(isDark ? ShellLayout.darkGlowOpacity : ShellLayout.lightGlowOpacity), .clear],
                                       startPoint: .topTrailing, endPoint: .center)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(isDark ? "Dark" : "Light"))
        .accessibilityValue(Text(preset.icon.title))
        .accessibilityIdentifier(isDark ? "settings.preset.dark" : "settings.preset.light")
    }
}

extension Color {
    init?(ghosttyHex raw: String) {
        guard let rgb = RGBColor(ghosttyHex: raw) else { return nil }
        self = rgb.color
    }
}
