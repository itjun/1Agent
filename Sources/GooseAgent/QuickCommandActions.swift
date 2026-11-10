import AppKit

extension AppModel {
    func confirmQuickCommand(_ item: QuickCommand, in window: WindowState) {
        guard window.quickCommandConfirmation == nil, !window.quickCommandSidebarExecution.isSubmitting else { return }
        window.quickCommandConfirmation = QuickCommandConfirmationTarget(item: item, context: quickCommandContext(in: window))
    }

    func commandForDrop(_ id: UUID, on tabID: UUID, in window: WindowState) -> QuickCommand? {
        guard window.quickCommandConfirmation == nil, !window.quickCommandSidebarExecution.isSubmitting,
              window.section == .terminals, !window.presentation.fullFilesWorkspace,
              let root = displayRoot(in: window), PaneLayout.contains(tabID, in: root),
              let tab = tabs.first(where: { $0.id == tabID && $0.hasTerminal }),
              let item = QuickCommandStore.shared.commands.first(where: { $0.id == id }),
              item.matches(quickCommandContext(for: tab)), (try? item.validated()) != nil else { return nil }
        return item
    }

    @discardableResult
    func runDroppedQuickCommand(_ id: UUID, on tabID: UUID, in window: WindowState) -> Bool {
        // Resolve again at mouse-up: the command, pane or its directory may have changed.
        guard let item = commandForDrop(id, on: tabID, in: window) else { return false }
        window.section = .terminals
        selectTab(tabID, in: window, focusTerminal: false)
        if item.scope == .all, let tab = tabs.first(where: { $0.id == tabID }) {
            return SSHTerminalRegistry.pasteLibraryText(item.command, into: tab.sessionID)
        }
        return runSidebarQuickCommand(item.id, in: window)
    }

    func copyLibraryCommand(_ id: UUID, to destination: QuickCommandCollection, in window: WindowState) {
        do {
            let copy = try QuickCommandStore.shared.copyCommand(id, to: destination)
            window.commandLibraryMessage = String(format: String(localized: "Copied to %@"), destination.title)
            if window.section == .commands {
                window.commandLibraryCollection = QuickCommandCollection.owner(of: copy)
                window.commandLibrarySelection = copy.id
            }
        } catch { window.commandLibraryMessage = error.localizedDescription }
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

    @discardableResult
    func runSidebarQuickCommand(_ id: UUID, in window: WindowState,
                                expectedContext: QuickCommandContext? = nil, expectedItem: QuickCommand? = nil,
                                onSuccess: @escaping () -> Void = {}) -> Bool {
        let execution = window.quickCommandSidebarExecution
        guard !execution.isSubmitting, window.quickCommandConfirmation == nil else { return false }
        do {
            // 点击时重新读取指令和目标；不使用预览打开时的旧内容。
            let context = quickCommandContext(in: window)
            guard context.sessionID != nil,
                  let item = QuickCommandStore.shared.commands.first(where: { $0.id == id }) else {
                throw QuickCommandError.changedTarget
            }
            if let expectedContext, context != expectedContext { throw QuickCommandError.changedTarget }
            if let expectedItem, item != expectedItem { throw QuickCommandError.changedTarget }
            guard let directory = item.executionDirectory(in: context) else { throw QuickCommandError.invalidDirectory }
            let request = try QuickCommandRunRequest(item: item, context: context, directory: directory)
            execution.run(request, perform: { [weak self, weak window] request in
                guard let self, let window else { throw QuickCommandError.changedTarget }
                if request.context.host == nil, ExternalOpen.validatedDirectory(request.directory) == nil {
                    throw QuickCommandError.invalidDirectory
                }
                try await self.executeQuickCommand(request, in: window, newTerminal: false)
                if let id = request.context.sessionID { SSHTerminalRegistry.focus(id) }
            }, onSuccess: onSuccess)
            return true
        } catch { execution.report(error); return false }
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
