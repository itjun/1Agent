import AppKit

extension AppModel {
    func confirmQuickCommand(_ item: QuickCommand, in window: WindowState) {
        guard window.quickCommandConfirmation == nil else { return }
        window.quickCommandConfirmation = QuickCommandConfirmationTarget(item: item, context: quickCommandContext(in: window))
    }

    func commandForDrop(_ id: UUID, on tabID: UUID, in window: WindowState) -> QuickCommand? {
        guard window.quickCommandConfirmation == nil, !window.presentation.fullFilesWorkspace,
              let root = displayRoot(in: window), PaneLayout.contains(tabID, in: root),
              let tab = tabs.first(where: { $0.id == tabID && $0.hasTerminal }),
              let item = QuickCommandStore.shared.commands.first(where: { $0.id == id }),
              item.matches(quickCommandContext(for: tab)), (try? item.validated()) != nil else { return nil }
        return item
    }

    @discardableResult
    func confirmDroppedQuickCommand(_ id: UUID, on tabID: UUID, in window: WindowState) -> Bool {
        // Resolve again at mouse-up: the command, pane or its directory may have changed.
        guard let item = commandForDrop(id, on: tabID, in: window) else { return false }
        window.section = .terminals
        selectTab(tabID, in: window, focusTerminal: false)
        confirmQuickCommand(item, in: window)
        return true
    }

    func executeQuickCommand(_ request: QuickCommandRunRequest, in window: WindowState, newTerminal: Bool) async throws {
        guard quickCommandContext(in: window) == request.context else { throw QuickCommandError.changedTarget }
        try QuickCommandExecution.claim(request.id)
        if newTerminal {
            try await launchQuickCommand(request, in: window)
        } else {
            try await SSHTerminalRegistry.runQuickCommand(request) {
                self.quickCommandContext(in: window) == request.context
            }
        }
    }

    func quickCommandContext(in window: WindowState) -> QuickCommandContext {
        guard let tab = selectedTab(in: window), tab.hasTerminal else { return QuickCommandContext() }
        return quickCommandContext(for: tab)
    }

    private func quickCommandContext(for tab: TerminalTab) -> QuickCommandContext {
        let local = tab.alias == nil || tab.alias?.isEmpty == true
        let directory = local ? SSHTerminalRegistry.currentWorkingDirectory(for: tab.sessionID) ?? tab.directory : tab.remoteDirectory
        return QuickCommandContext(sessionID: tab.sessionID, processID: SSHTerminalRegistry.processIdentity(for: tab.sessionID), host: local ? nil : tab.alias,
                                   directory: directory, isLive: !tab.exited && !tab.reconnecting)
    }
}
