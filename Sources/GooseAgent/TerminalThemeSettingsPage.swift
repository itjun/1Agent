import SwiftUI

/// 所有终端共用浅深色主题；缩略图不创建 Ghostty surface。
struct TerminalThemeSettingsPage: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject private var preferences = TerminalThemePreferences.shared
    @ObservedObject private var appearance = AppearanceDriver.shared
    @State private var search = ""
    @FocusState private var focusedTheme: String?

    private var themes: [TerminalThemeDescriptor] {
        TerminalThemeCatalog.shared.filtered(search: search, isDark: appearance.interfaceIsDark)
    }

    var body: some View {
        GeometryReader { geometry in
            let count = SettingsLayout.themeColumnCount(width: geometry.size.width)
            VStack(spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(alignment: .top, spacing: Theme.Space.xl) {
                        themeSummary(isDark: false)
                        themeSummary(isDark: true)
                    }
                    Text("Only matching themes are shown. Each appearance remembers its own theme.")
                        .font(Theme.Font.rowMeta).foregroundStyle(chrome.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                NativeSearchField(text: $search, placeholder: String(localized: "Search Ghostty Themes"),
                                  identifier: "themes.search", textColor: NSColor(chrome.text),
                                  backgroundColor: NSColor(chrome.elevated))
                    .frame(height: SettingsLayout.shortcutSearchHeight)
                if let issue = preferences.error ?? TerminalThemeCatalog.shared.issue {
                    Text(verbatim: issue)
                        .foregroundStyle(chrome.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("themes.error")
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        if themes.isEmpty {
                            VStack(spacing: Theme.Space.m) {
                                Text("No matching themes")
                                    .foregroundStyle(chrome.secondary)
                                Button("Clear Search") { search = "" }
                                    .buttonStyle(FamilyButtonStyle())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, Theme.Space.xl * 2)
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SettingsLayout.themeGridSpacing), count: count),
                                      alignment: .leading, spacing: Theme.Space.xl) {
                                ForEach(themes) { theme in
                                    themeCard(theme)
                                        .id(theme.id)
                                }
                            }
                            .padding(3) // 选中和键盘焦点轮廓不被滚动区域裁切。
                        }
                    }
                    .onMoveCommand { direction in
                        guard let current = focusedTheme, let index = themes.firstIndex(where: { $0.id == current }) else { return }
                        let offset: Int
                        switch direction {
                        case .left: offset = -1
                        case .right: offset = 1
                        case .up: offset = -count
                        case .down: offset = count
                        default: return
                        }
                        let next = min(max(index + offset, 0), themes.count - 1)
                        focusedTheme = themes[next].id
                        proxy.scrollTo(themes[next].id)
                    }
                    .onChange(of: search) { _, _ in
                        focusedTheme = nil
                        if let first = themes.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                    .onChange(of: appearance.interfaceIsDark) { _, _ in
                        focusedTheme = nil
                        if let first = themes.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
            }
            .padding(Theme.Space.xl)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("themes.catalog")
    }

    private func themeSummary(isDark: Bool) -> some View {
        let theme = TerminalThemePreferences.selected(isDark: isDark)
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Text(isDark ? "Theme for Dark Appearance" : "Theme for Light Appearance")
                    .foregroundStyle(chrome.secondary)
                if appearance.interfaceIsDark == isDark {
                    Text("In Use").foregroundStyle(chrome.accent)
                }
            }
            .font(Theme.Font.rowMeta)
            Text(verbatim: theme.displayName)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(chrome.text)
                .lineLimit(2).help(theme.displayName)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("themes.summary.\(isDark ? "dark" : "light")")
    }

    private func themeCard(_ theme: TerminalThemeDescriptor) -> some View {
        let selected = TerminalThemePreferences.selected(isDark: appearance.interfaceIsDark).id == theme.id
        let selectedLabel: LocalizedStringKey = "In Use"
        return Button {
            preferences.select(theme.id)
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TerminalThemePreview(colors: theme.colors(interfaceIsDark: appearance.interfaceIsDark))
                    .overlay {
                        RoundedRectangle(cornerRadius: TerminalThemePreview.outerRadius)
                            .strokeBorder(selected ? chrome.accent : chrome.hairline, lineWidth: selected ? 2 : 1)
                    }
                HStack(spacing: Theme.Space.xs) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(chrome.accent)
                    }
                    Text(verbatim: theme.displayName)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(chrome.text)
                    if selected {
                        Text(selectedLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(chrome.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(chrome.hairline, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(FamilyButtonStyle(showsFocusRing: false))
        .focusable()
        .focusEffectDisabled()
        .focused($focusedTheme, equals: theme.id)
        .overlay {
            RoundedRectangle(cornerRadius: SettingsLayout.cardRadius)
                .strokeBorder(focusedTheme == theme.id ? chrome.lineStrong : .clear, lineWidth: 1)
                .padding(-3).allowsHitTesting(false)
        }
        .onKeyPress(keys: [.space, .return]) { _ in
            preferences.select(theme.id)
            return .handled
        }
        .help(theme.displayName)
        .accessibilityLabel(Text(verbatim: theme.displayName))
        .accessibilityValue(selected ? Text(selectedLabel) : Text(verbatim: ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("themes.card.\(theme.id)")
    }
}

struct TerminalThemePreview: View {
    @Environment(\.isShellTransparent) private var isShellTransparent
    static let outerRadius = ShellLayout.contentRadius + ShellLayout.workspaceInset
    let colors: TerminalThemeColors
    private func color(_ hex: String) -> Color { RGBColor(ghosttyHex: hex)!.color }

    var body: some View {
        let chrome = colors.workspaceChrome
        VStack(alignment: .leading, spacing: 5) {
            (Text(verbatim: "~/project").foregroundColor(color(colors.ansi[4]))
             + Text(verbatim: " on ").foregroundColor(color(colors.foreground))
             + Text(verbatim: "main").foregroundColor(color(colors.ansi[2])))
            (Text(verbatim: "$ ").foregroundColor(color(colors.ansi[2]))
             + Text(verbatim: "git status").foregroundColor(color(colors.foreground)))
            Text(verbatim: "working tree clean").foregroundStyle(color(colors.foreground))
            Spacer(minLength: Theme.Space.s)
            HStack(spacing: 5) {
                ForEach(0..<8, id: \.self) { index in
                    VStack(spacing: 0) {
                        color(colors.ansi[index])
                        color(colors.ansi[index + 8])
                    }
                    .frame(maxWidth: 14).frame(height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(chrome.background, in: RoundedRectangle(cornerRadius: ShellLayout.contentRadius))
        .padding(ShellLayout.workspaceInset)
        .frame(height: SettingsLayout.themePreviewHeight)
        .background {
            ShellBackdrop(isTransparent: isShellTransparent, isDark: chrome.isDark,
                          usesTerminalBackground: true, chrome: chrome)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.outerRadius))
        .accessibilityHidden(true)
    }
}
