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
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(maximum: SettingsLayout.themeMaximumWidth),
                                                                        spacing: SettingsLayout.themeGridSpacing), count: count),
                                      alignment: .leading, spacing: Theme.Space.xl) {
                                ForEach(themes) { theme in
                                    themeCard(theme)
                                        .id(theme.id)
                                }
                            }
                            .padding(SettingsLayout.themeGridFocusInset)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
        let colors = theme.colors(interfaceIsDark: appearance.interfaceIsDark)
        return Button {
            preferences.select(theme.id)
        } label: {
            TerminalThemePreview(colors: colors, title: theme.displayName, isSelected: selected)
                .contentShape(Rectangle())
        }
        .buttonStyle(FamilyPlainButtonStyle())
        .focusable()
        .focusEffectDisabled()
        .focused($focusedTheme, equals: theme.id)
        .overlay {
            RoundedRectangle(cornerRadius: SettingsLayout.cardRadius)
                .strokeBorder(focusedTheme == theme.id ? chrome.lineStrong : .clear, lineWidth: 1)
                .padding(-SettingsLayout.themeGridFocusInset).allowsHitTesting(false)
        }
        .onKeyPress(keys: [.space, .return]) { _ in
            preferences.select(theme.id)
            return .handled
        }
        .help(theme.displayName)
        .accessibilityLabel(Text(verbatim: theme.displayName))
        .accessibilityValue(selected ? Text("In Use") : Text(verbatim: ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("themes.card.\(theme.id)")
    }
}

struct TerminalThemePreview: View {
    @Environment(\.isShellTransparent) private var isShellTransparent
    private static let sampleRadius: CGFloat = 10
    private static let sampleInset: CGFloat = 5
    private static let outerRadius = sampleRadius + sampleInset
    private static let sampleFontSize = CGFloat(TerminalDefaults.defaultFontSize)
    let colors: TerminalThemeColors
    let title: String
    var isSelected = false

    private func color(_ hex: String) -> Color { RGBColor(ghosttyHex: hex)!.color }
    private func ansi(_ index: Int) -> Color { color(colors.ansi[index]) }

    var body: some View {
        let chrome = colors.workspaceChrome
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Text(verbatim: title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                if isSelected {
                    Label("In Use", systemImage: "checkmark")
                        .font(Theme.Font.rowMeta)
                        .foregroundStyle(chrome.accent)
                        .fixedSize()
                }
            }
            .foregroundStyle(chrome.text)
            .frame(height: 20)

            sample
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TerminalCardFill(color: chrome.readingBackground))
        .clipShape(RoundedRectangle(cornerRadius: Self.sampleRadius))
        .padding(Self.sampleInset)
        .background {
            ShellBackdrop(isTransparent: isShellTransparent, isDark: chrome.isDark,
                          usesTerminalBackground: true, showsTerminalCards: true, chrome: chrome)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.outerRadius))
        .aspectRatio(SettingsLayout.themePreviewAspectRatio, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var sample: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            VStack(alignment: .leading, spacing: 0) {
                line(("~/project ", 4), ("(main) ", 2), (" $ ls", nil))
                line(("src/  ", 4), ("README.md  ", nil), ("run.sh", 2))
            }
            line(("12  ", 7), ("def ", 5), ("greet", 4), ("(name: str):", nil))
            VStack(alignment: .leading, spacing: 0) {
                line(("CPU", 6), ("[", nil), ("|||||", 2), ("    12.5%]", nil))
                line(("  PID  CPU%  Command", 0))
                    .background(ansi(2))
                line(("  421   2.1  python", 0))
                    .background(ansi(6))
            }
        }
        .font(.system(size: Self.sampleFontSize, design: .monospaced))
        .foregroundStyle(color(colors.foreground))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func line(_ spans: (String, Int?)...) -> some View {
        let text = spans.reduce(into: AttributedString()) { line, span in
            var fragment = AttributedString(span.0)
            if let colorIndex = span.1 {
                fragment.foregroundColor = ansi(colorIndex)
            }
            line.append(fragment)
        }
        return Text(text)
            .frame(height: Self.sampleFontSize + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
