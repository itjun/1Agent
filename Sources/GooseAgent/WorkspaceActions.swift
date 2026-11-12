import AppKit

/// Shared entry points for buttons, menus and keyboard commands.
extension AppModel {
    func toggleToolSidebar(in window: WindowState) {
        guard window.section == .terminals, let tab = selectedTab(in: window) else { return }
        toggleCommandSidebar(for: tab.id, in: window)
    }

    func toggleCommandSidebar(for tabID: UUID, in window: WindowState) {
        guard sidebarOrder(in: window).contains(tabID), tabs.contains(where: { $0.id == tabID && $0.hasTerminal }) else { return }
        commandSidebars[tabID, default: TerminalCommandSidebarState()].isExpanded.toggle()
        selectOnly(tabID, in: window, focusTerminal: true)
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

}
