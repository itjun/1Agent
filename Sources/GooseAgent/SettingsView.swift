import AppKit
import GhosttyTheme
import SwiftUI

enum SettingsLayout {
    static let windowMinimumSize = CGSize(width: SheetLayout.settings, height: SheetLayout.settingsBodyHeight)
    static let windowDefaultSize = CGSize(width: 1280, height: 820)
    static let sidebarWidthKey = "settings.sidebarWidth"
    static let appIconPreviewSize: CGFloat = 64
    static let appIconIdentityWidth: CGFloat = 200
    static let appIconChoiceWidth: CGFloat = 52
    static let appIconSwatchSize: CGFloat = 12
    static let appIconSelectionSize: CGFloat = 18
    static let pageHeaderHeight: CGFloat = 76
    static let pageTitleSize: CGFloat = 28
    static let contentMaxWidth: CGFloat = 960
    static let sectionSpacing: CGFloat = Theme.Space.xl
    static let cardRadius: CGFloat = Theme.Radius.card
    static let stackedRowBreakpoint: CGFloat = 560
    static let rowMinimumHeight: CGFloat = 44
    static let configurationHelpWidth: CGFloat = 320
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
    static let integrationTitleSize: CGFloat = 14
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

/// 设置分组共用轻灰底，只有外层内容面板投影。
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
        GroupBox {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                content().frame(maxWidth: .infinity, alignment: .leading)
            }.padding(Theme.Space.s)
        } label: {
            HStack { Text(title); Spacer(); accessory() }
        }
    }

}

extension SettingsCard where Accessory == EmptyView {
    init(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, content: content, accessory: { EmptyView() })
    }
}

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedPage: SettingsPage = .appearance
    @State private var pageContentBounds: [SettingsPage: CGRect] = [:]
    @FocusState private var focusedPage: SettingsPage?
    @AppStorage(SettingsLayout.sidebarWidthKey) private var savedSidebarWidth: Double = SidebarLayout.defaultWidth
    @AppStorage(TerminalAppearance.storageKey) private var appearanceRaw = TerminalAppearance.system.rawValue
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

    // 全局设置不继承最后一个会话的本机／远程配色。
    private var chrome: WindowChrome { WindowChrome(isDark: colorScheme == .dark, icon: .original) }
    private var sidebarChrome: WindowChrome { chrome }
    private let onRestart: () -> Void

    init(onRestart: @escaping () -> Void) {
        self.onRestart = onRestart
        _selectedPage = State(initialValue: GhosttyImportRequests.shared.previewPending ? .advanced : .appearance)
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
            isDividerHidden: false,
            width: CGFloat(savedSidebarWidth),
            minimumWidth: SidebarLayout.minWidth, maximumWidth: SidebarLayout.maxWidth,
            defaultWidth: SidebarLayout.defaultWidth,
            onWidthChange: { savedSidebarWidth = Double($0) }
        ) {
            VStack(spacing: 0) {
                settingsNavigation
            }

                .environment(\.windowChrome, sidebarChrome)
                .preferredColorScheme(colorScheme)
                    .tint(chrome.accent).font(Theme.Font.body)
        } detail: {
            VStack(spacing: 0) {
                Text(selectedPage.title)
                    .font(.system(size: SettingsLayout.pageTitleSize, weight: .semibold))
                    .foregroundStyle(chrome.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, pageContentBounds[selectedPage]?.minX ?? Theme.Space.xl)
                    .padding(.trailing, Theme.Space.xl)
                    .frame(height: SettingsLayout.pageHeaderHeight)
                    .background(WindowDragArea())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("settings.section.\(selectedPage.rawValue)")
                Rectangle().fill(chrome.hairline).frame(height: 0.5)
                settingsContent
                if preview.isActive {
                    previewActionBar
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: "settings.detail")
            .background(chrome.background)


            // 原生分栏各有独立的 hosting root，材质和配色须传给所有设置卡片。
            .environment(\.windowChrome, chrome)
            .preferredColorScheme(colorScheme)
                    .tint(chrome.accent).font(Theme.Font.body)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(chrome.background.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)

        .onAppear {
            TerminalThemeChoice.migrateIfNeeded()
            if !fontFamilies.contains(fontFamily) {
                fontFamily = TerminalDefaults.defaultFontFamily
            }
            GhosttyRuntime.applyTerminalSettings()
        }
        .onChange(of: importRequests.previewPending) { _, pending in
            if pending {
                selectedPage = .advanced
            }
        }
        .onChange(of: selectedPage) { old, new in
            themeSearchFocused = false
            if old == .shortcuts && new != .shortcuts {
                ShortcutRecorder.shared.stop()
            }
        }
    }

    private var settingsNavigation: some View {
        List(selection: $selectedPage) {
            ForEach(SettingsPage.allCases) { page in
                Button { selectedPage = page } label: { Text(page.title).frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain).tag(page)
                    .accessibilityIdentifier("settings.navigation.\(page.rawValue)")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(Text("Settings"))
    }

    private var settingsContent: some View {
        // 分类只显示当前页；稳定保留其他页，切换不会清空搜索、配置草稿或预览。
        ZStack(alignment: .topLeading) {
            ForEach(SettingsPage.allCases) { page in
                ScrollViewReader { proxy in
                    ScrollView {
                        settingsPage(page)
                            .frame(maxWidth: SettingsLayout.contentMaxWidth, alignment: .leading)
                            .onGeometryChange(for: CGRect.self) { geometry in
                                let frame = geometry.frame(in: .named("settings.detail"))
                                return CGRect(x: frame.minX, y: 0, width: frame.width, height: 0)
                            } action: { bounds in
                                // 常显滚动条会占宽；标题与操作栏跟随表单的真实边界。
                                pageContentBounds[page] = bounds
                            }
                            .padding(Theme.Space.xl)
                            .frame(maxWidth: .infinity)
                            .id(page)
                    }
                    .accessibilityIdentifier("settings.content.\(page.rawValue)")
                    .onChange(of: selectedPage) { _, selected in
                        if selected == page { proxy.scrollTo(page, anchor: .top) }
                    }
                }
                .opacity(selectedPage == page ? 1 : 0)
                .allowsHitTesting(selectedPage == page)
                .disabled(selectedPage != page)
                .accessibilityHidden(selectedPage != page)
                .zIndex(selectedPage == page ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func settingsPage(_ page: SettingsPage) -> some View {
        Group {
            switch page {
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
                AppUpdateSettingsPage(onRestart: onRestart)
            case .advanced:
                AdvancedSettingsPage(isActive: selectedPage == .advanced)
            }
        }
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
                SettingsRow("Font", showsSeparator: true) {
                    FamilyPicker(value: $fontFamily, options: fontFamilies.map { ($0, $0) })
                }

                SettingsRow("Size") {
                    HStack(spacing: Theme.Space.s) {
                        FamilySlider(
                            value: $fontSize,
                            range: TerminalDefaults.minFontSize...TerminalDefaults.maxFontSize,
                            step: 1
                        )
                        Text(String(format: String(localized: "%lld px"), Int(fontSize.rounded())))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(chrome.secondary)
                            .frame(width: SettingsLayout.valueLabelWidth, alignment: .trailing)
                    }
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
                SettingsRow("Thicken", detail: "Draw glyphs a little heavier, which helps thin fonts on some displays.", ghosttyKey: "font-thicken", showsSeparator: true) {
                    SettingsSwitch(isOn: $fontThicken.applyingTerminalSettings())
                }
                SettingsRow("Thicken Strength", detail: "How much heavier; only used while Thicken is on.", ghosttyKey: "font-thicken-strength", showsSeparator: true) {
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
                SettingsRow("Ligatures", detail: "Join character pairs such as -> and => into one glyph when the font supports it.", ghosttyKey: "font-feature", showsSeparator: true) {
                    SettingsSwitch(isOn: $fontLigatures.applyingTerminalSettings())
                }
                SettingsRow("Line Height", detail: "Add or remove space between lines, as a share of the font's own line height.", ghosttyKey: "adjust-cell-height", showsSeparator: true) {
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
                SettingsRow("Horizontal Padding", detail: "Space between the text and the left and right edges of the terminal.", ghosttyKey: "window-padding-x", showsSeparator: true) {
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
        Picker("Appearance", selection: $appearanceRaw) {
            ForEach(TerminalAppearance.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .onChange(of: appearanceRaw) { _, _ in AppearanceDriver.shared.reapply() }
    }

    /// Restores the shared light and dark themes through the preview transaction.
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
    /// The list opens on typing or on Dark / Light; previews apply to every terminal.
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
        TextField("Search themes", text: $themeQuery)
            .textFieldStyle(.roundedBorder)
            .focused($themeSearchFocused)
    }

    /// Same height and border as the search field, so the row reads as one control group.
    private var themeFilterBar: some View {
        Picker("Appearance", selection: $themeFilter) {
            ForEach(ThemeFilter.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    /// Clicking a current card lists every theme for that slot, so one can be picked and previewed.
    private func currentThemeCard(title: LocalizedStringKey, choice: TerminalThemeChoice, filter: ThemeFilter) -> some View {
        let hint: LocalizedStringKey = filter == .light ? "Show all light themes" : "Show all dark themes"
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(chrome.secondary)
            ThemePreviewCard(
                definition: choice.definition,
                selected: themeFilter == filter
            ) {
                themeQuery = ""
                themeFilter = filter
            }
            .help(hint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isInUse(_ definition: GhosttyThemeDefinition) -> Bool {
        definition.name == preview.effectiveLight().name
            || definition.name == preview.effectiveDark().name
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
            .accessibilityIdentifier("settings.appearance.preview.cancel")
            Button("Save") {
                preview.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(FamilyButtonStyle(kind: .primary))
            .accessibilityIdentifier("settings.appearance.preview.save")
        }
        .frame(width: pageContentBounds[selectedPage]?.width)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, pageContentBounds[selectedPage]?.minX ?? Theme.Space.xl)
        .padding(.trailing, Theme.Space.xl)
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

private struct SettingsWindowRoot: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var appearanceDriver = AppearanceDriver.shared
    @AppStorage(TerminalAppearance.storageKey) private var appearanceRaw = TerminalAppearance.system.rawValue

    var body: some View {
        SettingsView(onRestart: { model.requestRestart() })
            .preferredColorScheme(appearanceDriver.interfaceColorScheme)
            .frame(minWidth: SettingsLayout.windowMinimumSize.width, minHeight: SettingsLayout.windowMinimumSize.height)
            .background(Color(nsColor: .windowBackgroundColor))

            .onAppear { appearanceDriver.reapply() }
            .onChange(of: appearanceRaw) { _, _ in appearanceDriver.reapply() }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = SettingsWindowController()
    static let windowID = NSUserInterfaceItemIdentifier("settings")
    private(set) var window: NSWindow?
    private weak var model: AppModel?
    private weak var owner: NSWindow?
    private weak var columns: NSSplitView?
    private let columnSeparator = NSToolbarItem.Identifier("settings.sidebarSeparator")

    func show(model: AppModel) {
        self.model = model
        if NSApp.keyWindow?.identifier == MainWindowManager.windowID { owner = NSApp.keyWindow }
        if owner == nil { owner = MainWindowManager.shared.window(for: model.mainWindow) }
        let settings = window ?? makeWindow(model: model)
        window = settings
        MainWindowManager.bringToActiveSpace(settings)
        DispatchQueue.main.async { [weak self, weak settings] in
            guard let self, let settings, let root = settings.contentView,
                  let split = workspaceColumnSplit(in: root) else { return }
            self.columns = split
            if settings.toolbar == nil {
                let toolbar = NSToolbar(identifier: "settings.toolbar")
                toolbar.delegate = self
                toolbar.allowsUserCustomization = false
                settings.toolbarStyle = .unified
                settings.toolbar = toolbar
            }
        }
    }

    private func makeWindow(model: AppModel) -> NSWindow {
        let host = NSHostingController(rootView: SettingsWindowRoot(model: model))
        host.sizingOptions = [.minSize]
        let settings = NSWindow(contentViewController: host)
        settings.identifier = Self.windowID
        settings.title = String(localized: "Settings")
        settings.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        settings.titlebarAppearsTransparent = false
        settings.titleVisibility = .visible
        settings.titlebarSeparatorStyle = .automatic
        settings.tabbingMode = .disallowed
        settings.isRestorable = false
        settings.isReleasedWhenClosed = false
        settings.delegate = self
        settings.contentMinSize = SettingsLayout.windowMinimumSize
        settings.setContentSize(SettingsLayout.windowDefaultSize)
        if let visible = (owner?.screen ?? NSScreen.main)?.visibleFrame {
            let anchor = owner?.frame ?? visible
            var frame = settings.frame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(anchor.midX - frame.width / 2, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(anchor.midY - frame.height / 2, visible.minY), visible.maxY - frame.height)
            settings.setFrame(frame, display: false)
        }
        return settings
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [columnSeparator, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard identifier == columnSeparator, let columns else { return nil }
        return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: columns, dividerIndex: 0)
    }

    func windowWillClose(_ notification: Notification) {
        ThemePreview.shared.cancel()
        ShortcutRecorder.shared.stop()
        guard model?.isQuitting != true, let owner, owner.isVisible else { return }
        owner.makeKeyAndOrderFront(nil)
        FocusedTerminal.shared.refresh()
    }
}
