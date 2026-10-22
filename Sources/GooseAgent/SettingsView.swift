import AppKit
import GhosttyTheme
import SwiftUI

enum SettingsLayout {
    static let appIconColumns = 5
    static let appIconPreviewSize: CGFloat = 88
    static let sidebarWidth: CGFloat = 180
    /// One page row in the left navigation.
    static let navRowHeight: CGFloat = 40
    /// One segment of the appearance-mode control.
    static let segmentHeight: CGFloat = 28
    /// Font preview box; fixed so the card does not jump while the size slider moves.
    static let fontPreviewHeight: CGFloat = 96
    /// Advanced snippet editor.
    static let customConfigEditorHeight: CGFloat = 160
    /// Read-only view of the configuration Ghostty is running with.
    static let renderedConfigHeight: CGFloat = 260
    /// Control column on the right of a `SettingsRow`: sliders, segmented pickers, menus.
    static let rowControlWidth: CGFloat = 320
    /// Current value printed after a slider, e.g. "80%".
    static let valueLabelWidth: CGFloat = 64
    /// Key-combination field on the Shortcuts page; wide enough for "⌃⌥⇧⌘←" and "按下快捷键…".
    static let shortcutRecorderWidth: CGFloat = 150
    static let shortcutRecorderHeight: CGFloat = 26
    /// Per-row "restore default" button, kept in place even when hidden so the fields stay aligned.
    static let shortcutResetButtonSize: CGFloat = 22
    /// Search field above the shortcut cards, the height of a regular push button row.
    static let shortcutSearchHeight: CGFloat = 32
    static let integrationTitleSize: CGFloat = 26
    static let integrationStatusSize: CGFloat = 10
    static let integrationAppColumn: CGFloat = 150
    static let integrationChoiceColumn: CGFloat = 112
    static let integrationHeaderHeight: CGFloat = 38
    static let integrationRowHeight: CGFloat = 58
    static let integrationIconSize: CGFloat = 22
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case appearance
    case appIcon
    case font
    case terminal
    case shortcuts
    case systemIntegration
    case advanced
    case about

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .appearance: "Appearance"
        case .appIcon: "Icon"
        case .font: "Font"
        case .terminal: "Terminal"
        case .shortcuts: "Hotkeys"
        case .systemIntegration: "System Integration"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }
}

/// One settings group, like System Settings: a headline (plus an optional trailing control)
/// above a bordered card that holds the content.
struct SettingsCard<Content: View, Accessory: View>: View {
    @Environment(\.windowChrome) private var chrome
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content
    @ViewBuilder let accessory: () -> Accessory

    init(
        _ title: LocalizedStringKey,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.content = content
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text(title)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(chrome.text)
                Spacer(minLength: Theme.Space.s)
                accessory()
            }
            content()
                .padding(.vertical, Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(chrome.hairline).frame(height: 1)
                }
        }
    }
}

extension SettingsCard where Accessory == EmptyView {
    init(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, content: content, accessory: { EmptyView() })
    }
}

struct SettingsView: View {
    @Environment(\.windowChrome) private var chrome
    @State private var selectedPage: SettingsPage = .appearance
    @AppStorage(TerminalAppearance.storageKey) private var appearanceRaw = TerminalAppearance.system.rawValue
    @AppStorage(TerminalAppearance.lightThemeKey) private var lightThemeRaw = TerminalThemeChoice.defaultLightName
    @AppStorage(TerminalAppearance.darkThemeKey) private var darkThemeRaw = TerminalThemeChoice.defaultDarkName
    @AppStorage(TerminalFontSettings.familyKey) private var fontFamily = TerminalDefaults.defaultFontFamily
    @AppStorage(TerminalFontSettings.sizeKey) private var fontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalSettings.fontThickenKey) private var fontThicken = TerminalSettings.defaults.fontThicken
    @AppStorage(TerminalSettings.fontThickenStrengthKey) private var fontThickenStrength = TerminalSettings.defaults.fontThickenStrength
    @AppStorage(TerminalSettings.fontLigaturesKey) private var fontLigatures = TerminalSettings.defaults.fontLigatures
    @AppStorage(TerminalSettings.cellHeightAdjustKey) private var cellHeightAdjust = TerminalSettings.defaults.cellHeightAdjust
    @AppStorage(TerminalSettings.paddingXKey) private var paddingX = TerminalSettings.defaults.paddingX
    @AppStorage(TerminalSettings.paddingYKey) private var paddingY = TerminalSettings.defaults.paddingY
    @AppStorage(TerminalSettings.minimumContrastKey) private var minimumContrast = TerminalSettings.defaults.minimumContrast
    @ObservedObject private var preview = ThemePreview.shared
    @ObservedObject private var importRequests = GhosttyImportRequests.shared
    @State private var themeQuery = ""
    @FocusState private var themeSearchFocused: Bool
    @State private var themeFilter: ThemeFilter = .all
    /// User theme waiting for the Move to Trash confirmation.

    private var sidebarChrome: WindowChrome { chrome }
    private let onRestart: () -> Void

    init(onRestart: @escaping () -> Void) {
        self.onRestart = onRestart
    }

    private var appearance: TerminalAppearance {
        TerminalAppearance(rawValue: appearanceRaw) ?? .system
    }

    private var fontFamilies: [String] {
        TerminalFontSettings.availableFamilies()
    }

    private let themeColumns = [
        GridItem(.adaptive(minimum: 300), spacing: Theme.Space.m),
    ]

    private static let searchControlHeight: CGFloat = 32

    private var trimmedQuery: String {
        themeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The list opens once the user types or picks Dark / Light. All with an empty search stays closed.
    private var showsThemeList: Bool {
        !trimmedQuery.isEmpty || themeFilter != .all
    }

    /// Search only Ghostty's official bundled catalog.
    private var matchingThemes: [GhosttyThemeDefinition] {
        let themes = trimmedQuery.isEmpty ? GhosttyThemeCatalog.allThemes : GhosttyThemeCatalog.search(trimmedQuery)
        return themes
            .filter { themeFilter.includes($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NativeSidebarSplit(
            width: SettingsLayout.sidebarWidth,
            minimumWidth: SettingsLayout.sidebarWidth, maximumWidth: SettingsLayout.sidebarWidth,
            defaultWidth: SettingsLayout.sidebarWidth
        ) {
            settingsNavigation
                .environment(\.windowChrome, sidebarChrome)
                    .tint(chrome.accent).font(Theme.Font.body)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    settingsContent
                }
                // 按页区分身份：换页时滚动位置回到顶部，而不是沿用上一页的偏移。
                .id(selectedPage)
                if preview.isActive {
                    previewActionBar
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.windowChrome, chrome)
                    .tint(chrome.accent).font(Theme.Font.body)
            .background(chrome.background.ignoresSafeArea())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(chrome.background.ignoresSafeArea())
        // Extend the native columns themselves into the titlebar. Each hosting root still
        // respects its safe area, keeping navigation and settings below the traffic lights.
        .ignoresSafeArea(edges: .top)

        .onAppear {
            TerminalThemeChoice.migrateIfNeeded()
            if !fontFamilies.contains(fontFamily) {
                fontFamily = TerminalDefaults.defaultFontFamily
            }
            GhosttyRuntime.applyTerminalSettings()
            if importRequests.previewPending {
                selectedPage = .advanced
            }
        }
        .onChange(of: importRequests.previewPending) { _, pending in
            if pending {
                selectedPage = .advanced
            }
        }
    }

    private var settingsNavigation: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(sidebarChrome.text)
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, Theme.Space.xs)
                .padding(.bottom, Theme.Space.l)

            ForEach(SettingsPage.allCases) { page in
                let selected = selectedPage == page
                Button {
                    selectedPage = page
                } label: {
                    Text(page.title)
                        .font(Theme.Font.row.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? sidebarChrome.accent : sidebarChrome.text)
                        .lineLimit(1)
                        .padding(.horizontal, Theme.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: SettingsLayout.navRowHeight)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                                .fill(selected ? sidebarChrome.accentFill : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(FamilyButtonStyle())
                .accessibilityIdentifier("settings.navigation.\(page.rawValue)")
                .padding(.horizontal, Theme.Space.s)
            }
            Spacer(minLength: 0)
            Button(action: onRestart) {
                Label("Restart 1Agent", systemImage: "arrow.clockwise")
                    .font(Theme.Font.row)
                    .foregroundStyle(sidebarChrome.secondary)
                    .padding(.horizontal, Theme.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: SettingsLayout.navRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FamilyButtonStyle())
            .help(String(localized: "Terminal sessions are saved and restored after the restart. Running commands will be interrupted."))
            .accessibilityIdentifier("settings.restart")
            .padding(.horizontal, Theme.Space.s)
            .padding(.bottom, Theme.Space.m)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(chrome.sidebarBackground.ignoresSafeArea())
    }

    private var settingsContent: some View {
        Group {
            switch selectedPage {
            case .appearance:
                appearancePage
            case .appIcon:
                ApplicationIconSettingsPage()
            case .font:
                fontPage
            case .terminal:
                TerminalSettingsPage()
            case .shortcuts:
                ShortcutsSettingsPage()
            case .systemIntegration:
                SystemIntegrationSettingsPage()
            case .about:
                AppUpdateSettingsPage()
            case .advanced:
                AdvancedSettingsPage()
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingsCard("Appearance Mode") {
                appearanceModeControl
            }

            SettingsCard("Terminal Colors") {
                themePicker
            } accessory: {
                restoreDefaultThemesButton
            }

            contrastCard

            RestorePageDefaultsButton {
                restoreAppearancePageDefaults()
            }
        }
    }

    private var minimumContrastLabel: String {
        if minimumContrast <= 1 {
            return String(localized: "Off")
        }
        return String(format: "%.1f", minimumContrast)
    }

    private var contrastCard: some View {
        SettingsCard("Contrast") {
            SettingsRow("Minimum Contrast", detail: "Brighten or darken text that is hard to read on its background. 1 turns it off; 4.5 is the usual readability bar.", ghosttyKey: "minimum-contrast") {
                SettingsSlider(
                    value: $minimumContrast,
                    range: TerminalSettings.minimumContrastRange,
                    step: 0.5,
                    label: minimumContrastLabel,
                    onCommit: { GhosttyRuntime.applyTerminalSettings() }
                )
            }
        }
    }

    /// Mode and contrast apply at once; the default themes are previewed first, like the
    /// card's own restore button, and saved from the action bar.
    private func restoreAppearancePageDefaults() {
        appearanceRaw = TerminalAppearance.system.rawValue
        AppearanceDriver.shared.reapply()
        minimumContrast = TerminalSettings.defaults.minimumContrast
        GhosttyRuntime.applyTerminalSettings()
        if !preview.showsDefaults {
            preview.showDefaults()
        }
    }

    private var fontPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            fontFamilyCard
            fontRenderingCard
            RestorePageDefaultsButton {
                restoreFontPageDefaults()
            }
        }
    }

    private var fontFamilyCard: some View {
        SettingsCard("Terminal Font") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack(spacing: Theme.Space.m) {
                    Text("Font")
                        .font(Theme.Font.body)
                        .foregroundStyle(chrome.text)
                        .frame(width: 56, alignment: .leading)
                    FamilyPicker(value: $fontFamily, options: fontFamilies.map { ($0, $0) })
                        .accessibilityLabel(Text("Font"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: Theme.Space.m) {
                    Text("Size")
                        .font(Theme.Font.body)
                        .foregroundStyle(chrome.text)
                        .frame(width: 56, alignment: .leading)
                    FamilySlider(
                        value: $fontSize,
                        range: TerminalDefaults.minFontSize...TerminalDefaults.maxFontSize,
                        step: 1
                    )
                    Text(String(format: String(localized: "%lld px"), Int(fontSize.rounded())))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(chrome.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                fontPreview
                Text("The preview follows Thicken and Line Height roughly; the terminal shows the exact result.")
                    .font(Theme.Font.rowMeta)
                    .foregroundStyle(chrome.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onChange(of: fontFamily) { _, _ in
                GhosttyRuntime.applyTerminalSettings()
            }
            .onChange(of: fontSize) { _, newValue in
                let clamped = min(max(newValue, TerminalDefaults.minFontSize), TerminalDefaults.maxFontSize)
                if clamped != newValue {
                    fontSize = clamped
                }
                GhosttyRuntime.applyTerminalSettings()
            }
        }
    }

    private var cellHeightLabel: String {
        if cellHeightAdjust > 0 {
            return "+\(cellHeightAdjust)%"
        }
        return "\(cellHeightAdjust)%"
    }

    private var fontRenderingCard: some View {
        SettingsCard("Glyphs and Spacing") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                SettingsRow("Thicken", detail: "Draw glyphs a little heavier, which helps thin fonts on some displays.", ghosttyKey: "font-thicken") {
                    SettingsSwitch(isOn: $fontThicken.applyingTerminalSettings())
                }
                SettingsRow("Thicken Strength", detail: "How much heavier; only used while Thicken is on.", ghosttyKey: "font-thicken-strength") {
                    SettingsSlider(
                        value: Binding(
                            get: { Double(fontThickenStrength) },
                            set: { fontThickenStrength = Int($0.rounded()) }
                        ),
                        range: TerminalSettings.fontThickenStrengthRange,
                        step: 5,
                        label: String(fontThickenStrength),
                        onCommit: { GhosttyRuntime.applyTerminalSettings() }
                    )
                    .disabled(!fontThicken)
                }
                SettingsRow("Ligatures", detail: "Join character pairs such as -> and => into one glyph when the font supports it.", ghosttyKey: "font-feature") {
                    SettingsSwitch(isOn: $fontLigatures.applyingTerminalSettings())
                }
                SettingsRow("Line Height", detail: "Add or remove space between lines, as a share of the font's own line height.", ghosttyKey: "adjust-cell-height") {
                    SettingsSlider(
                        value: Binding(
                            get: { Double(cellHeightAdjust) },
                            set: { cellHeightAdjust = Int($0.rounded()) }
                        ),
                        range: TerminalSettings.cellHeightAdjustRange,
                        step: 5,
                        label: cellHeightLabel,
                        onCommit: { GhosttyRuntime.applyTerminalSettings() }
                    )
                }
                SettingsRow("Horizontal Padding", detail: "Space between the text and the left and right edges of the terminal.", ghosttyKey: "window-padding-x") {
                    paddingStepper($paddingX)
                }
                SettingsRow("Vertical Padding", detail: "Space between the text and the bottom edge of the terminal. The top stays close under the title.", ghosttyKey: "window-padding-y") {
                    paddingStepper($paddingY)
                }
            }
        }
    }

    private func paddingStepper(_ value: Binding<Int>) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(String(format: String(localized: "%lld pt"), value.wrappedValue))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(chrome.secondary)
            FamilyNumberInput(value: value.applyingTerminalSettings(), range: TerminalSettings.paddingRange)
        }
    }

    private func restoreFontPageDefaults() {
        let defaults = TerminalSettings.defaults
        fontFamily = defaults.fontFamily
        fontSize = defaults.fontSize
        fontThicken = defaults.fontThicken
        fontThickenStrength = defaults.fontThickenStrength
        fontLigatures = defaults.fontLigatures
        cellHeightAdjust = defaults.cellHeightAdjust
        paddingX = defaults.paddingX
        paddingY = defaults.paddingY
        GhosttyRuntime.applyTerminalSettings()
    }

    /// Thicken has no SwiftUI equivalent; a heavier weight is the closest the preview can get.
    private var previewWeight: Font.Weight {
        if !fontThicken {
            return .regular
        }
        if fontThickenStrength >= 128 {
            return .semibold
        }
        return .medium
    }

    /// Extra space between the preview lines, following Line Height.
    private var previewLineGap: CGFloat {
        let extra = CGFloat(fontSize) * CGFloat(cellHeightAdjust) / 100
        return max(0, Theme.Space.xs + extra)
    }

    /// Sample text in the chosen font, drawn with the terminal's own colors: plain text, then
    /// prompt-like tokens in accent / success / warning / danger.
    private var fontPreview: some View {
        VStack(alignment: .leading, spacing: previewLineGap) {
            Text("Ghostty 你好 abc 0123456789 -> =>")
                .foregroundStyle(chrome.text)
            HStack(spacing: 0) {
                Text(verbatim: "developer@mac ~").foregroundStyle(chrome.accent)
                Text(verbatim: "  ✔ 200").foregroundStyle(chrome.success)
                Text(verbatim: "  ⚠ 302").foregroundStyle(chrome.warning)
                Text(verbatim: "  ✘ 500").foregroundStyle(chrome.danger)
            }
        }
        .font(.custom(fontFamily, size: CGFloat(fontSize)))
        .fontWeight(previewWeight)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SettingsLayout.fontPreviewHeight, alignment: .leading)
        .padding(.horizontal, Theme.Space.m)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(chrome.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .stroke(chrome.hairline, lineWidth: 1)
        )
    }

    /// Follow System / Light / Dark as one segmented control. Picking a segment applies at once, as before.
    private var appearanceModeControl: some View {
        HStack(spacing: 2) {
            ForEach(TerminalAppearance.allCases) { mode in
                appearanceSegment(mode)
            }
        }
        .padding(3)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(chrome.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .stroke(chrome.hairline, lineWidth: 1)
        )
    }

    private func appearanceSegment(_ mode: TerminalAppearance) -> some View {
        let selected = appearance == mode
        return Button {
            appearanceRaw = mode.rawValue
            AppearanceDriver.shared.reapply()
        } label: {
            HStack(spacing: Theme.Space.xs + 2) {
                Image(systemName: SettingsView.appearanceSymbol(mode))
                    .font(.system(size: 12))
                Text(mode.title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(selected ? chrome.accent : chrome.text)
            .padding(.horizontal, Theme.Space.m)
            .frame(height: SettingsLayout.segmentHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(selected ? chrome.accentFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(FamilyButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private static func appearanceSymbol(_ mode: TerminalAppearance) -> String {
        switch mode {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// Previews the GitHub light and dark defaults together; the action bar then saves or cancels them.
    private var restoreDefaultThemesButton: some View {
        let disabled = preview.showsDefaults
        return Button {
            preview.showDefaults()
        } label: {
            Text("Restore Default Themes")
                .font(.system(size: 13, weight: .medium))
                // Accent while clickable; the muted tertiary alone reads as disabled.
                .foregroundStyle(disabled ? chrome.tertiary : chrome.accent)
                .contentShape(Rectangle())
        }
        .buttonStyle(FamilyButtonStyle())
        .disabled(disabled)
    }

    /// The two themes in use (or being previewed) stay on top; clicking one lists that slot's themes.
    /// The list opens on typing or on Dark / Light; clicking a card previews it in every window without saving.
    private var themePicker: some View {
        let results = matchingThemes
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            // 与下方结果网格共用列定义，两张卡占前两列并与结果卡对齐。
            LazyVGrid(columns: themeColumns, alignment: .leading, spacing: Theme.Space.m) {
                currentThemeCard(title: "Current light theme", choice: preview.effectiveLight(), filter: .light)
                currentThemeCard(title: "Current dark theme", choice: preview.effectiveDark(), filter: .dark)
            }

            HStack(spacing: Theme.Space.m) {
                themeSearchField
                themeFilterBar
            }

            if !showsThemeList {
                Text(String(format: String(localized: "Type to search %lld themes"), results.count))
                    .font(Theme.sidebarRowMeta)
                    .foregroundStyle(chrome.secondary)
            } else if results.isEmpty {
                Text("No matching themes")
                    .font(Theme.sidebarRowMeta)
                    .foregroundStyle(chrome.secondary)
            } else {
                Text(String(format: String(localized: "Showing %lld themes"), results.count))
                    .font(Theme.sidebarRowMeta)
                    .foregroundStyle(chrome.secondary)
                LazyVGrid(columns: themeColumns, spacing: Theme.Space.m) {
                    ForEach(results) { definition in
                        ThemePreviewCard(
                            definition: definition,
                            selected: isInUse(definition)
                        ) {
                            preview.show(definition)
                        }
                    }
                }
            }
        }
    }

    private var themeSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(chrome.secondary)
            TextField("Search themes", text: $themeQuery)
                .focused($themeSearchFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(chrome.text)
            if !themeQuery.isEmpty {
                Button {
                    themeQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(chrome.secondary)
                }
                .buttonStyle(FamilyButtonStyle())
                .help("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity)
        .frame(height: SettingsView.searchControlHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(themeSearchFocused ? chrome.background : chrome.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .stroke(themeSearchFocused ? chrome.accent : chrome.hairline, lineWidth: 1)
        )
        .familyFocusRing(themeSearchFocused)
    }

    /// Same height and border as the search field, so the row reads as one control group.
    private var themeFilterBar: some View {
        HStack(spacing: 2) {
            ForEach(ThemeFilter.allCases) { filter in
                let selected = themeFilter == filter
                Button {
                    themeFilter = filter
                } label: {
                    Text(filter.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? chrome.accent : chrome.text)
                        .padding(.horizontal, Theme.Space.m)
                        .frame(maxHeight: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                                .fill(selected ? chrome.accentFill : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(FamilyButtonStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(height: SettingsView.searchControlHeight)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(chrome.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .stroke(chrome.hairline, lineWidth: 1)
        )
    }

    /// Clicking a current card lists every theme for that slot, so one can be picked and previewed.
    private func currentThemeCard(title: LocalizedStringKey, choice: TerminalThemeChoice, filter: ThemeFilter) -> some View {
        let hint: LocalizedStringKey = filter == .light ? "Show all light themes" : "Show all dark themes"
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(chrome.secondary)
            ThemePreviewCard(definition: choice.definition, selected: themeFilter == filter) {
                themeQuery = ""
                themeFilter = filter
            }
            .help(hint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isInUse(_ definition: GhosttyThemeDefinition) -> Bool {
        definition.name == preview.effectiveLight().name || definition.name == preview.effectiveDark().name
    }

    private var previewActionBar: some View {
        HStack(spacing: 10) {
            Text(String(format: String(localized: "Previewing: %@"), preview.previewedNames.joined(separator: " · ")))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(chrome.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Cancel") {
                preview.cancel()
            }
            Button("Save") {
                preview.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(FamilyButtonStyle(kind: .primary))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(chrome.sidebarBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(chrome.hairline).frame(height: 1)
        }
    }
}

private enum ThemeFilter: String, CaseIterable, Identifiable {
    case all
    case light
    case dark

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .all: "Filter: All"
        case .light: "Filter: Light"
        case .dark: "Filter: Dark"
        }
    }

    func includes(_ definition: GhosttyThemeDefinition) -> Bool {
        switch self {
        case .all: return true
        case .light: return definition.isLightBackground
        case .dark: return !definition.isLightBackground
        }
    }
}

/// Settings is its own window, with the standard traffic lights, like WeChat.
struct SettingsWindowRoot: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var appearanceDriver = AppearanceDriver.shared
    @AppStorage(TerminalAppearance.storageKey) private var appearanceRaw = TerminalAppearance.system.rawValue
    @AppStorage(TerminalAppearance.lightThemeKey) private var lightThemeRaw = TerminalThemeChoice.defaultLightName
    @AppStorage(TerminalAppearance.darkThemeKey) private var darkThemeRaw = TerminalThemeChoice.defaultDarkName
    @ObservedObject private var preview = ThemePreview.shared
    @ObservedObject private var applicationIcons = ApplicationIconManager.shared

    private var chrome: WindowChrome {
        let _ = lightThemeRaw
        let _ = darkThemeRaw
        return WindowChrome.resolve(isDark: appearanceDriver.isDark, icon: applicationIcons.selected)
    }

    var body: some View {
        SettingsView(onRestart: { model.requestRestart() })
            .environment(\.windowChrome, chrome)
                    .tint(chrome.accent).font(Theme.Font.body)
            .preferredColorScheme(appearanceDriver.interfaceColorScheme)

            .frame(minWidth: SheetLayout.settings, minHeight: SheetLayout.settingsBodyHeight)
            .onAppear { appearanceDriver.reapply() }
            .onChange(of: appearanceRaw) { _, _ in
                appearanceDriver.reapply()
            }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    static let windowID = NSUserInterfaceItemIdentifier("settings")

    private(set) var window: NSWindow?
    private var model: AppModel?

    func toggle(model: AppModel) {
        self.model = model
        if let window, window.isVisible {
            window.close()
            return
        }
        show(model: model)
    }

    /// Opens Settings, or brings it to the front when it is already open.
    func show(model: AppModel) {
        self.model = model
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        model.keyWindow?.hostPickerPresented = false
        let source = sourceWindow()
        let window = self.window ?? makeWindow(model: model)
        self.window = window
        placeWindow(window, over: source)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        model.showingSettings = true
    }

    private func makeWindow(model: AppModel) -> NSWindow {
        let controller = NSHostingController(rootView: SettingsWindowRoot(model: model))
        // 只让 SwiftUI 约束最小尺寸，否则它会按内容理想尺寸改写我们设定的 50% 窗口大小。
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        window.identifier = Self.windowID
        window.title = String(localized: "Settings")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = TerminalAppearance.appKitAppearance(isDark: TerminalAppearance.stored().resolvesDark())
        let size = NSSize(width: SheetLayout.settings, height: SheetLayout.settingsBodyHeight)
        window.setContentSize(size)
        window.minSize = size
        return window
    }

    /// The main window Settings was opened from: the key/main window, never Settings itself.
    private func sourceWindow() -> NSWindow? {
        for candidate in [NSApp.keyWindow, NSApp.mainWindow] {
            if let candidate, candidate.isVisible, candidate.identifier != Self.windowID {
                return candidate
            }
        }
        return nil
    }

    /// Re-applied on every open so the window never keeps an older size.
    private func placeWindow(_ window: NSWindow, over source: NSWindow?) {
        guard let screen = source?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = SettingsWindowFrame.frame(
            anchor: source?.frame ?? visible,
            visible: visible,
            minSize: window.minSize
        )
        window.setFrame(frame, display: false)
    }

    func windowWillClose(_ notification: Notification) {
        ThemePreview.shared.cancel()
        model?.showingSettings = false
    }
}
