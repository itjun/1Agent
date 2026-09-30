import AppKit
import SwiftUI

/// Settings → Advanced: import from Ghostty's config files, the custom snippet, and the config
/// Ghostty is running with.
struct AdvancedSettingsPage: View {
    @Environment(\.windowChrome) private var chrome
    @ObservedObject private var diagnostics = TerminalConfigDiagnostics.shared
    @ObservedObject private var importRequests = GhosttyImportRequests.shared
    @State private var detectedFiles: [URL] = []
    @State private var hasBackup = false
    /// The plan shown in the preview sheet; nil closes the sheet.
    @State private var plan: GhosttyImportPlan?
    @State private var importStatus: LocalizedStringKey?
    @State private var importErrors: [String] = []
    @State private var snippetDraft = ""
    @State private var storedSnippet = ""
    @State private var showsRenderedConfig = false
    @State private var renderedConfig = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            importCard
            snippetCard
            renderedConfigCard
        }
        .onAppear {
            reloadState()
            snippetDraft = storedSnippet
            openPendingPreview()
        }
        .onChange(of: importRequests.previewPending) { _, _ in
            openPendingPreview()
        }
        .sheet(isPresented: Binding(
            get: { plan != nil },
            set: { presented in
                if !presented {
                    plan = nil
                }
            }
        )) {
            if let plan {
                GhosttyImportPreviewSheet(
                    plan: plan,
                    onCancel: { self.plan = nil },
                    onImport: { runImport(plan) }
                )
                .environment(\.windowChrome, chrome)
            }
        }
    }

    // MARK: Import

    private var importCard: some View {
        SettingsCard("Import from Ghostty") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if detectedFiles.isEmpty {
                    Text("No Ghostty config file was found. Ghostty reads ~/.config/ghostty/config.ghostty and ~/Library/Application Support/com.mitchellh.ghostty/config.ghostty.")
                        .font(Theme.Font.body)
                        .foregroundStyle(chrome.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Config files found:")
                        .font(Theme.Font.body)
                        .foregroundStyle(chrome.secondary)
                    ForEach(detectedFiles, id: \.self) { url in
                        Text(verbatim: (url.path as NSString).abbreviatingWithTildeInPath)
                            .font(Theme.Font.paneTitle)
                            .foregroundStyle(chrome.text)
                            .textSelection(.enabled)
                    }
                }
                HStack(spacing: Theme.Space.m) {
                    Button("Import Configuration from Ghostty…") {
                        importStatus = nil
                        importErrors = []
                        plan = GhosttyConfigImport.makePlan()
                    }
                    .disabled(detectedFiles.isEmpty)
                    if hasBackup {
                        Button("Undo Last Import") {
                            GhosttyConfigImport.undoLastImport()
                            importErrors = []
                            importStatus = "Last import undone"
                            reloadState()
                            snippetDraft = storedSnippet
                        }
                    }
                }
                if let importStatus {
                    Label(importStatus, systemImage: "checkmark.circle")
                        .font(Theme.Font.body)
                        .foregroundStyle(chrome.success)
                }
                ForEach(importErrors, id: \.self) { message in
                    Text(verbatim: message)
                        .font(Theme.Font.rowMeta)
                        .foregroundStyle(chrome.danger)
                }
            }
        }
    }

    private func openPendingPreview() {
        if !importRequests.previewPending {
            return
        }
        importRequests.previewPending = false
        if detectedFiles.isEmpty {
            return
        }
        plan = GhosttyConfigImport.makePlan()
    }

    private func runImport(_ plan: GhosttyImportPlan) {
        importErrors = GhosttyConfigImport.applyPlan(plan)
        importStatus = "Import complete"
        self.plan = nil
        reloadState()
        snippetDraft = storedSnippet
    }

    private func reloadState() {
        detectedFiles = GhosttyConfigImport.detectedFiles()
        hasBackup = GhosttyConfigImport.hasBackup()
        storedSnippet = TerminalSettings.load().customConfig
        renderedConfig = AdvancedSettingsPage.appGeneratedConfig()
    }

    /// Only the lines the app writes. The engine's full text starts with the package's built-in defaults
    /// (such as `font-thicken = true`), which every page overrides further down and would only mislead here.
    private static func appGeneratedConfig() -> String {
        GhosttyRuntime.controller.terminalConfiguration.rendered
    }

    // MARK: Snippet

    private var snippetCard: some View {
        SettingsCard("Custom Configuration Snippet") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("One Ghostty setting per line, as key = value. Settings that have their own control are changed on their page.")
                    .font(Theme.Font.body)
                    .foregroundStyle(chrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $snippetDraft)
                    .font(Theme.Font.paneTitle)
                    .foregroundStyle(chrome.text)
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Space.xs)
                    .frame(height: SettingsLayout.customConfigEditorHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(chrome.background)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .stroke(chrome.hairline, lineWidth: 1)
                    )
                HStack(spacing: Theme.Space.m) {
                    snippetDiagnostics
                    Spacer(minLength: Theme.Space.s)
                    Button("Apply") {
                        applySnippet()
                    }
                    .disabled(snippetDraft == storedSnippet)
                }
            }
        }
    }

    private func applySnippet() {
        var settings = TerminalSettings.load()
        settings.customConfig = snippetDraft
        settings.save()
        GhosttyRuntime.applyTerminalSettings()
        reloadState()
    }

    private var snippetDiagnostics: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            let clean = diagnostics.skippedLines.isEmpty
                && diagnostics.invalidLines.isEmpty
                && diagnostics.rejectedLines.isEmpty
                && diagnostics.engineIssue == nil
            if clean {
                Label("Configuration OK", systemImage: "checkmark.circle")
                    .foregroundStyle(chrome.success)
            }
            ForEach(diagnostics.skippedLines, id: \.self) { line in
                Text(String(format: String(localized: "Skipped, managed by the app: %@"), line))
                    .foregroundStyle(chrome.warning)
            }
            ForEach(diagnostics.invalidLines, id: \.self) { line in
                Text(String(format: String(localized: "Invalid line, needs key = value: %@"), line))
                    .foregroundStyle(chrome.danger)
            }
            ForEach(diagnostics.rejectedLines, id: \.self) { rejection in
                Text(String(format: String(localized: "Left out, Ghostty rejected it: %@ (%@)"), rejection.line, rejection.issue))
                    .foregroundStyle(chrome.danger)
                    .textSelection(.enabled)
            }
            if let issue = diagnostics.engineIssue {
                Text(String(format: String(localized: "Ghostty rejected the configuration: %@"), issue))
                    .foregroundStyle(chrome.danger)
                    .textSelection(.enabled)
            }
        }
        .font(Theme.Font.rowMeta)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Rendered config

    private var renderedConfigCard: some View {
        SettingsCard("Current Configuration") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("What Ghostty is running with: settings from every page, then the custom snippet. Theme colors are applied separately.")
                    .font(Theme.Font.body)
                    .foregroundStyle(chrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showsRenderedConfig {
                    ScrollView {
                        Text(verbatim: renderedConfig)
                            .font(Theme.Font.paneTitle)
                            .foregroundStyle(chrome.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.s)
                    }
                    .frame(height: SettingsLayout.renderedConfigHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(chrome.background)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .stroke(chrome.hairline, lineWidth: 1)
                    )
                }
            }
        } accessory: {
            Button {
                if !showsRenderedConfig {
                    renderedConfig = AdvancedSettingsPage.appGeneratedConfig()
                }
                showsRenderedConfig.toggle()
            } label: {
                if showsRenderedConfig {
                    Label("Hide", systemImage: "chevron.up")
                } else {
                    Label("Show", systemImage: "chevron.down")
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(chrome.accent)
            .buttonStyle(.plain)
        }
    }
}

/// Everything an import would do, grouped, before anything is written.
struct GhosttyImportPreviewSheet: View {
    @Environment(\.windowChrome) private var chrome
    let plan: GhosttyImportPlan
    let onCancel: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Import from Ghostty")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(chrome.text)
                ForEach(plan.files, id: \.self) { url in
                    Text(verbatim: (url.path as NSString).abbreviatingWithTildeInPath)
                        .font(Theme.Font.paneTitle)
                        .foregroundStyle(chrome.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.l)

            Rectangle().fill(chrome.hairline).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if plan.changesNothing {
                        Text("Nothing to change: the app already matches your Ghostty configuration.")
                            .font(Theme.Font.body)
                            .foregroundStyle(chrome.secondary)
                    }
                    settingsSection
                    themeSection
                    customSection
                    shortcutsSection
                    ignoredSection
                    unmigratedSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.l)
            }

            Rectangle().fill(chrome.hairline).frame(height: 1)

            HStack(spacing: Theme.Space.m) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: onImport)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(plan.changesNothing)
            }
            .padding(Theme.Space.l)
        }
        .frame(width: SheetLayout.importPreview, height: SheetLayout.importPreviewBodyHeight)
        .background(chrome.background)
    }

    @ViewBuilder
    private var settingsSection: some View {
        if !plan.settingsChanges.isEmpty {
            section("Settings to Apply") {
                ForEach(plan.settingsChanges, id: \.key) { change in
                    if change.isUnchanged {
                        row(
                            String(format: String(localized: "%@: %@ (unchanged)"), change.key, change.newValue),
                            color: chrome.secondary
                        )
                    } else {
                        row(String(format: String(localized: "%@: %@ → %@"), change.key, change.oldValue, change.newValue))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var themeSection: some View {
        if !plan.theme.isEmpty {
            section("Theme") {
                if let light = plan.theme.light {
                    themeRow(light, dark: false)
                }
                if let dark = plan.theme.dark {
                    themeRow(dark, dark: true)
                }
                ForEach(plan.theme.warnings, id: \.self) { warning in
                    row(warning, color: chrome.warning)
                }
            }
        }
    }

    private func themeRow(_ slot: GhosttyThemeSlotPlan, dark: Bool) -> some View {
        var text: String
        if slot.isUnchanged {
            if dark {
                text = String(format: String(localized: "Dark: %@ (unchanged)"), slot.name)
            } else {
                text = String(format: String(localized: "Light: %@ (unchanged)"), slot.name)
            }
        } else if dark {
            text = String(format: String(localized: "Dark: %@ (now %@)"), slot.name, slot.currentName)
        } else {
            text = String(format: String(localized: "Light: %@ (now %@)"), slot.name, slot.currentName)
        }
        if case .importFile = slot.source {
            text += " · " + String(localized: "theme file is copied into your themes folder")
        }
        if slot.isUnchanged {
            return row(text, color: chrome.secondary)
        }
        return row(text)
    }

    @ViewBuilder
    private var customSection: some View {
        if !plan.customLines.isEmpty {
            section("Add to Custom Snippet") {
                ForEach(plan.customLines, id: \.self) { line in
                    Text(verbatim: line)
                        .font(Theme.Font.paneTitle)
                        .foregroundStyle(chrome.text)
                }
            }
        }
    }

    @ViewBuilder
    private var shortcutsSection: some View {
        if !plan.shortcuts.isEmpty {
            section("Keyboard Shortcuts") {
                ForEach(plan.shortcuts, id: \.shortcutID) { shortcut in
                    if let id = AppShortcutID(rawValue: shortcut.shortcutID) {
                        let newChord = GhosttyConfigImport.chord(for: shortcut.trigger)
                        let oldChord = AppShortcuts.chord(for: id)
                        if newChord == oldChord {
                            row(
                                String(format: String(localized: "%@: %@ (unchanged)"), GhosttyConfigImport.shortcutTitle(id), newChord.display),
                                color: chrome.secondary
                            )
                        } else {
                            row(String(format: String(localized: "%@: %@ → %@"), GhosttyConfigImport.shortcutTitle(id), oldChord.display, newChord.display))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var ignoredSection: some View {
        if !plan.ignored.isEmpty {
            section("Ignored") {
                ForEach(plan.ignored, id: \.line) { item in
                    reasonRow(item.line, reason: item.reason.message)
                }
            }
        }
    }

    @ViewBuilder
    private var unmigratedSection: some View {
        if !plan.unmigrated.isEmpty || !plan.warnings.isEmpty {
            section("Not Migrated") {
                ForEach(plan.warnings, id: \.self) { warning in
                    row(warning, color: chrome.warning)
                }
                ForEach(plan.unmigrated, id: \.line) { item in
                    reasonRow(item.line, reason: item.reason)
                }
            }
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(chrome.secondary)
            content()
        }
    }

    private func row(_ text: String, color: Color? = nil) -> some View {
        Text(verbatim: text)
            .font(Theme.Font.body)
            .foregroundStyle(color ?? chrome.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func reasonRow(_ line: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: line)
                .font(Theme.Font.paneTitle)
                .foregroundStyle(chrome.text)
            Text(verbatim: reason)
                .font(Theme.Font.rowMeta)
                .foregroundStyle(chrome.secondary)
        }
    }
}
