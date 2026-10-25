import GhosttyTheme
import SwiftUI

/// A small fake terminal drawn in one catalog theme: prompt, `ls` and `git status` output,
/// a selected row, all 16 ANSI colors, and the cursor. Falls back to foreground/background
/// wherever the theme leaves a color out.
struct ThemePreviewCard: View {
    let definition: GhosttyThemeDefinition
    let selected: Bool
    var isRemote = false
    let onSelect: () -> Void

    @Environment(\.windowChrome) private var chrome

    private var background: Color {
        Color(ghosttyHex: definition.background) ?? .black
    }

    private var foreground: Color {
        Color(ghosttyHex: definition.foreground) ?? .white
    }

    private func palette(_ index: Int) -> Color {
        guard let raw = definition.palette[index] else { return foreground }
        return Color(ghosttyHex: raw) ?? foreground
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 0) {
                titleBar
                terminalBody
                swatchStrip
                metaBar
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(selected ? chrome.accent : chrome.hairline, lineWidth: selected ? 2 : 1)
            )
            .contentShape(Rectangle())
            // The sample text inside would otherwise be read instead of the theme, leaving just "button".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: definition.name))
        }
        .buttonStyle(FamilyButtonStyle())
        .accessibilityLabel(Text(verbatim: definition.name))
        .accessibilityValue(Text(definition.isLightBackground ? "Light theme" : "Dark theme"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var titleBar: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(red: 1, green: 0.373, blue: 0.337)).frame(width: 9, height: 9)
            Circle().fill(Color(red: 1, green: 0.741, blue: 0.180)).frame(width: 9, height: 9)
            Circle().fill(Color(red: 0.153, green: 0.788, blue: 0.247)).frame(width: 9, height: 9)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(background)
        .overlay(foreground.opacity(0.06))
    }

    private var terminalBody: some View {
        let selectionBackground = definition.selectionBackground.flatMap { Color(ghosttyHex: $0) } ?? foreground
        let selectionForeground = definition.selectionForeground.flatMap { Color(ghosttyHex: $0) } ?? background
        let cursor = definition.cursorColor.flatMap { Color(ghosttyHex: $0) } ?? foreground

        return VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: isRemote ? "operator" : "developer").foregroundColor(palette(2))
                + Text(verbatim: "@").foregroundColor(foreground)
                + Text(verbatim: isRemote ? "server" : "mac").foregroundColor(palette(4))
                + Text(verbatim: isRemote ? " /srv/app" : " ~/workspace").foregroundColor(palette(6))
            Text(verbatim: "$ ").foregroundColor(palette(5))
                + Text(verbatim: "ls --color").foregroundColor(foreground)
            Text(verbatim: "src  ").foregroundColor(palette(4))
                + Text(verbatim: "README.md  ").foregroundColor(palette(2))
                + Text(verbatim: "error.log  ").foregroundColor(palette(1))
                + Text(verbatim: "build/").foregroundColor(palette(3))
            Text(verbatim: "$ ").foregroundColor(palette(5))
                + Text(verbatim: "git status").foregroundColor(foreground)
            Text(verbatim: "modified: app.js   ").foregroundColor(palette(1))
                + Text(verbatim: "new: util.js").foregroundColor(palette(2))
            Text(verbatim: "selected line")
                .foregroundColor(selectionForeground)
                .padding(.horizontal, 2)
                .background(selectionBackground)
            colorBlocks(0..<8)
            colorBlocks(8..<16)
            HStack(spacing: 0) {
                Text(verbatim: "normal text ").foregroundColor(foreground)
                Rectangle()
                    .fill(cursor)
                    .frame(width: 7, height: 13)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(background)
    }

    private func colorBlocks(_ range: Range<Int>) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(range), id: \.self) { index in
                Text(verbatim: "██").foregroundColor(palette(index))
            }
        }
    }

    private var swatchStrip: some View {
        HStack(spacing: 0) {
            ForEach(0..<16, id: \.self) { index in
                palette(index)
            }
        }
        .frame(height: 8)
    }

    private var metaBar: some View {
        HStack(spacing: 8) {
            Text(verbatim: definition.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(chrome.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: GhosttyThemeDefinition.ghosttyHex(definition.background).uppercased())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(chrome.secondary)
            Text(definition.isLightBackground ? "Light theme" : "Dark theme")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(chrome.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().stroke(chrome.hairline, lineWidth: 1))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(chrome.sidebarBackground)
    }
}

extension Color {
    init?(ghosttyHex raw: String) {
        guard let rgb = RGBColor(ghosttyHex: raw) else { return nil }
        self = rgb.color
    }
}
