import AppKit

/// Shared entry points for buttons, menus and keyboard commands.
extension AppModel {
    func toggleToolSidebar(in window: WindowState) {
        guard window.section == .terminals else { return }
        updatePresentation(in: window) { $0.toolSidebarOpen.toggle() }
        if let tab = selectedTab(in: window) { SSHTerminalRegistry.focus(tab.sessionID) }
    }

    func sidebarIsCollapsed(in window: WindowState, totalWidth: CGFloat? = nil) -> Bool {
        let width = totalWidth ?? MainWindowManager.shared.window(for: window)?.contentView?.bounds.width ?? 1100
        let savedWidth = UserDefaults.standard.object(forKey: SidebarLayout.widthKey) as? Double
            ?? SidebarLayout.defaultWidth
        return window.presentation.sidebarCollapsed || (!window.sidebarRevealed &&
            WorkspaceChromeLayout.temporarilyCollapseSidebar(
                totalWidth: width, sidebarWidth: savedWidth,
                filesVisible: window.presentation.filesVisible, filesWorkspace: true))
    }

    func toggleSidebar(in window: WindowState) {
        let reveal = sidebarIsCollapsed(in: window)
        window.sidebarRevealed = reveal
        updatePresentation(in: window) { $0.sidebarCollapsed = !reveal }
        // Layout only: the selected session, PTY and terminal surface retain their identity.
        if !window.presentation.fullFilesWorkspace, let tab = selectedTab(in: window) {
            SSHTerminalRegistry.focus(tab.sessionID)
        }
    }

    func openCommandPalette(in window: WindowState) {
        guard !window.hostPickerPresented else { return }
        window.commandPalettePresented = true
    }
}
