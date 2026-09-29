import GhosttyTheme
import SwiftUI

enum SettingsLayout {
    static let sidebarWidth: CGFloat = 180
    static let separatorWidth: CGFloat = 1
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case appearance
    case font

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .appearance: "Appearance"
        case .font: "Font"
        }
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
    @ObservedObject private var preview = ThemePreview.shared
    @State private var themeQuery = ""
    @State private var themeFilter: ThemeFilter = .all

    private var appearance: TerminalAppearance {
        TerminalAppearance(rawValue: appearanceRaw) ?? .system
    }

    private var fontFamilies: [String] {
        TerminalFontSettings.availableFamilies()
    }

    private let themeColumns = [
        GridItem(.adaptive(minimum: 300), spacing: 12),
    ]

    private static let searchControlHeight: CGFloat = 38

    private var trimmedQuery: String {
        themeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The list opens once the user types or picks Dark / Light. All with an empty search stays closed.
    private var showsThemeList: Bool {
        !trimmedQuery.isEmpty || themeFilter != .all
    }

    /// Every name match (the whole catalog for an empty search), narrowed by the filter and sorted by name.
    /// The grid is lazy, so showing all ~485 cards costs no more than the visible rows.
    private var matchingThemes: [GhosttyThemeDefinition] {
        var themes = GhosttyThemeCatalog.allThemes
        if !trimmedQuery.isEmpty {
            themes = GhosttyThemeCatalog.search(trimmedQuery)
        }
        return themes
            .filter { themeFilter.includes($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsNavigation
            Rectangle()
                .fill(chrome.hairline)
                .frame(width: SettingsLayout.separatorWidth)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(chrome.background.ignoresSafeArea())
        .oneagentHideFocusRing()
        .onAppear {
            TerminalThemeChoice.migrateIfNeeded()
            lightThemeRaw = TerminalThemeChoice.storedLight().rawValue
            darkThemeRaw = TerminalThemeChoice.storedDark().rawValue
            if !fontFamilies.contains(fontFamily) {
                fontFamily = TerminalDefaults.defaultFontFamily
            }
            GhosttyRuntime.applyFontSettings()
        }
    }

    private var settingsNavigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(chrome.text)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 16)

            ForEach(SettingsPage.allCases) { page in
                let selected = selectedPage == page
                Button {
                    selectedPage = page
                } label: {
                    Text(page.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(chrome.text)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Rectangle().fill(selected ? chrome.accent.opacity(0.16) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(width: SettingsLayout.sidebarWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(chrome.elevated.opacity(0.58).ignoresSafeArea())
    }

    private var settingsContent: some View {
        Group {
            switch selectedPage {
            case .appearance:
                appearancePage
            case .font:
                fontPage
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SSH sends a keepalive probe every 30 seconds; after 3 missed replies the connection counts as lost and reconnects automatically. This cannot be turned off.")
                .font(Theme.sidebarRowMeta)
                .foregroundStyle(chrome.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Appearance Mode")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(chrome.text)
            HStack(spacing: 8) {
                ForEach(TerminalAppearance.allCases) { mode in
                    appearanceCard(mode)
                }
            }

            HStack(spacing: 8) {
                Text("Terminal Colors")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(chrome.text)
                Spacer(minLength: 8)
                restoreDefaultThemesButton
            }

            themePicker
        }
    }

    private var fontPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Terminal Font")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(chrome.text)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text("Font")
                        .font(.system(size: 13))
                        .foregroundStyle(chrome.text)
                        .frame(width: 56, alignment: .leading)
                    Picker("", selection: $fontFamily) {
                        ForEach(fontFamilies, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Text("Size")
                        .font(.system(size: 13))
                        .foregroundStyle(chrome.text)
                        .frame(width: 56, alignment: .leading)
                    Slider(
                        value: $fontSize,
                        in: TerminalDefaults.minFontSize...TerminalDefaults.maxFontSize,
                        step: 1
                    )
                    Text(String(format: String(localized: "%lld px"), Int(fontSize.rounded())))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(chrome.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                Text("1Agent 你好 abc 0123456789 -> =>")
                    .font(.custom(fontFamily, size: CGFloat(fontSize)))
                    .foregroundStyle(chrome.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(chrome.background)
                    )
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(chrome.elevated))
            .onChange(of: fontFamily) { _, _ in
                GhosttyRuntime.applyFontSettings()
            }
            .onChange(of: fontSize) { _, newValue in
                let clamped = min(max(newValue, TerminalDefaults.minFontSize), TerminalDefaults.maxFontSize)
                if clamped != newValue {
                    fontSize = clamped
                }
                GhosttyRuntime.applyFontSettings()
            }
        }
    }

    private func appearanceCard(_ mode: TerminalAppearance) -> some View {
        let selected = appearance == mode
        return Button {
            appearanceRaw = mode.rawValue
            AppearanceDriver.shared.reapply()
        } label: {
            Text(mode.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(chrome.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selected ? chrome.accent : chrome.hairline, lineWidth: selected ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Previews the GitHub light and dark defaults together; the action bar then saves or cancels them.
    private var restoreDefaultThemesButton: some View {
        let disabled = preview.showsDefaults
        return Button {
            preview.showDefaults()
        } label: {
            Text("Restore Default Themes")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(chrome.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    /// The two themes in use (or being previewed) stay on top; clicking one lists that slot's themes.
    /// The list opens on typing or on Dark / Light; clicking a card previews it in every window without saving.
    private var themePicker: some View {
        let results = matchingThemes
        return VStack(alignment: .leading, spacing: 14) {
            // 与下方结果网格共用列定义，两张卡占前两列并与结果卡对齐。
            LazyVGrid(columns: themeColumns, alignment: .leading, spacing: 12) {
                currentThemeCard(title: "Current light theme", choice: preview.effectiveLight(), filter: .light)
                currentThemeCard(title: "Current dark theme", choice: preview.effectiveDark(), filter: .dark)
            }

            HStack(spacing: 12) {
                themeSearchField
                themeFilterBar
            }

            if !showsThemeList {
                Text(String(format: String(localized: "Type to search %lld themes"), GhosttyThemeCatalog.allThemes.count))
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
                LazyVGrid(columns: themeColumns, spacing: 12) {
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
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: SettingsView.searchControlHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(chrome.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(chrome.hairline, lineWidth: 1)
        )
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
                        .font(.system(size: 14, weight: selected ? .semibold : .regular))
                        .foregroundStyle(chrome.text)
                        .padding(.horizontal, 14)
                        .frame(maxHeight: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selected ? chrome.accent.opacity(0.22) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(height: SettingsView.searchControlHeight)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(chrome.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
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
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(chrome.elevated)
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

    private var chrome: WindowChrome {
        let _ = lightThemeRaw
        let _ = darkThemeRaw
        return WindowChrome.resolve(isDark: appearanceDriver.isDark)
    }

    var body: some View {
        SettingsView()
            .environment(\.windowChrome, chrome)
            .preferredColorScheme(appearanceDriver.interfaceColorScheme)
            .oneagentHideFocusRing()
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

    private var window: NSWindow?
    private var model: AppModel?

    func toggle(model: AppModel) {
        self.model = model
        if let window, window.isVisible {
            window.close()
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
