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
    static let contentInset: CGFloat = ShellLayout.workspaceInset
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
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Text(title)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(chrome.text)
                Spacer(minLength: Theme.Space.s)
                accessory()
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous)
                .fill(chrome.elevated)
        }
        .overlay {
            RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous)
                .strokeBorder(chrome.hairline.opacity(0.5), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}

extension SettingsCard where Accessory == EmptyView {
    init(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, content: content, accessory: { EmptyView() })
    }
}

struct SettingsView: View {
    @Environment(\.isShellTransparent) private var isShellTransparent
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
            isDividerHidden: isShellTransparent,
            width: CGFloat(savedSidebarWidth),
            minimumWidth: SidebarLayout.minWidth, maximumWidth: SidebarLayout.maxWidth,
            defaultWidth: SidebarLayout.defaultWidth,
            onWidthChange: { savedSidebarWidth = Double($0) }
        ) {
            VStack(spacing: 0) {
                WindowDragArea()
                    .frame(height: isShellTransparent ? ShellLayout.compactTitlebarHeight : Theme.PaneStyle.titlebarHeight)
                settingsNavigation
            }
                .ignoresSafeArea(edges: .top)
                .environment(\.windowChrome, sidebarChrome)
                .environment(\.isShellTransparent, isShellTransparent)
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
            .modifier(FloatingContentSurface())
            .padding(.vertical, isShellTransparent ? SettingsLayout.contentInset : 0)
            .padding(.trailing, isShellTransparent ? SettingsLayout.contentInset : 0)
            .ignoresSafeArea(edges: .top)
            // 原生分栏各有独立的 hosting root，材质和配色须传给所有设置卡片。
            .environment(\.windowChrome, chrome)
            .environment(\.isShellTransparent, isShellTransparent)
            .preferredColorScheme(colorScheme)
                    .tint(chrome.accent).font(Theme.Font.body)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background((isShellTransparent ? Color.clear : chrome.background).ignoresSafeArea())

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
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(sidebarChrome.text)
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, Theme.Space.xs)
                .padding(.bottom, Theme.Space.l)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsPage.allCases) { page in
                        let selected = selectedPage == page
                        Button {
                            // 鼠标选中使用圆角底色；键盘导航保留独立的焦点提示。
                            focusedPage = nil
                            selectedPage = page
                        } label: {
                            Text(page.title)
                                .font(Theme.Font.row.weight(selected ? .semibold : .regular))
                                .foregroundStyle(sidebarChrome.text)
                                .lineLimit(1)
                                .padding(.horizontal, Theme.Space.m)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: SettingsLayout.navRowHeight)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                                        .fill(selected ? sidebarChrome.hairline : Color.clear)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(FamilyButtonStyle(showsFocusRing: false))
                        .focusable()
                        .focusEffectDisabled()
                        .focused($focusedPage, equals: page)
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                                .strokeBorder(focusedPage == page ? sidebarChrome.lineStrong : .clear, lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                        .onKeyPress(keys: [.space, .return]) { _ in
                            selectedPage = page
                            return .handled
                        }
                        .accessibilityLabel(Text(page.title))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("settings.navigation.\(page.rawValue)")
                        .padding(.horizontal, Theme.Space.s)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background((isShellTransparent ? Color.clear : chrome.sidebarBackground).ignoresSafeArea())
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
            .environment(\.isShellTransparent, appearanceDriver.isShellTransparent)
            .preferredColorScheme(appearanceDriver.interfaceColorScheme)
            .frame(minWidth: SettingsLayout.windowMinimumSize.width, minHeight: SettingsLayout.windowMinimumSize.height)
            .background {
                ShellBackdrop(isTransparent: appearanceDriver.isShellTransparent, isDark: appearanceDriver.isDark)
                    .accessibilityHidden(true)
            }
            .ignoresSafeArea(edges: .top)
            .onAppear { appearanceDriver.reapply() }
            .onChange(of: appearanceRaw) { _, _ in appearanceDriver.reapply() }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    static let windowID = NSUserInterfaceItemIdentifier("settings")
    private(set) var window: NSWindow?
    private weak var model: AppModel?
    private weak var owner: NSWindow?

    func show(model: AppModel) {
        self.model = model
        if NSApp.keyWindow?.identifier == MainWindowManager.windowID { owner = NSApp.keyWindow }
        if owner == nil { owner = MainWindowManager.shared.window(for: model.mainWindow) }
        let settings = window ?? makeWindow(model: model)
        window = settings
        MainWindowManager.bringToActiveSpace(settings)
    }

    private func makeWindow(model: AppModel) -> NSWindow {
        let host = NSHostingController(rootView: SettingsWindowRoot(model: model))
        host.sizingOptions = [.minSize]
        let settings = NSWindow(contentViewController: host)
        settings.identifier = Self.windowID
        settings.title = String(localized: "Settings")
        settings.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        settings.titlebarAppearsTransparent = true
        settings.titleVisibility = .hidden
        settings.titlebarSeparatorStyle = .none
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

    func windowWillClose(_ notification: Notification) {
        ThemePreview.shared.cancel()
        ShortcutRecorder.shared.stop()
        guard model?.isQuitting != true, let owner, owner.isVisible else { return }
        owner.makeKeyAndOrderFront(nil)
        FocusedTerminal.shared.refresh()
    }
}
