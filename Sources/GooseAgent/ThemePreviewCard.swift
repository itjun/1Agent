import SwiftUI

/// 同一预设的浅／深色示意，使用实际窗口和终端色值，不提供额外主题选择。
struct ThemePreviewCard: View {
    let isDark: Bool
    var preset: AppThemePreset = AppTheme.stored()
    var isCompact = false

    var body: some View {
        let colors = AppTheme.colors(isDark: isDark, preset: preset)
        VStack(alignment: .leading, spacing: isCompact ? Theme.Space.xs : Theme.Space.s) {
            VStack(alignment: .leading, spacing: isCompact ? Theme.Space.xs : Theme.Space.s) {
                HStack {
                    Text("Aa").font(.system(size: isCompact ? 16 : 20, weight: .medium))
                    Spacer()
                    Text(verbatim: "~/")
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(colors.color(colors.selection), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    Rectangle().fill(colors.color(colors.accent)).frame(width: 6, height: 15)
                }
                if !isCompact {
                    Text(verbatim: "$ git status")
                        .font(.system(size: 12, design: .monospaced))
                }
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
            .padding(isCompact ? Theme.Space.xs + 2 : Theme.Space.m)
            .background(colors.color(colors.background), in: RoundedRectangle(cornerRadius: Theme.Radius.row))
            .padding(isCompact ? Theme.Space.xs + 2 : Theme.Space.m)
            .background {
                LinearGradient(stops: zip(colors.gradientColors, ShellLayout.backdropLocations).map {
                    Gradient.Stop(color: $0.0, location: $0.1)
                }, startPoint: .top, endPoint: .bottom)
                    .overlay {
                        LinearGradient(colors: [colors.color(colors.glow).opacity(isDark ? ShellLayout.darkGlowOpacity : ShellLayout.lightGlowOpacity), .clear],
                                       startPoint: .top, endPoint: UnitPoint(x: 0.5, y: ShellLayout.glowEndY))
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(isDark ? "Dark" : "Light"))
        .accessibilityValue(Text(preset.icon.title))
        .accessibilityIdentifier("settings.preset." + (isDark ? "dark." : "light.") + preset.id)
    }
}

extension Color {
    init?(ghosttyHex raw: String) {
        guard let rgb = RGBColor(ghosttyHex: raw) else { return nil }
        self = rgb.color
    }
}
