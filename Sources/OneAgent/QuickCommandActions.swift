import AppKit

extension AppModel {
    func confirmQuickCommand(_ item: QuickCommand, in window: WindowState) {
        guard window.quickCommandConfirmation == nil, !window.quickCommandSidebarExecution.isSubmitting else { return }
        window.quickCommandConfirmation = QuickCommandConfirmationTarget(item: item, context: quickCommandContext(in: window))
    }

    func commandForDrop(_ id: UUID, on tabID: UUID, in window: WindowState) -> QuickCommand? {
        guard window.quickCommandConfirmation == nil, !commandExecution(for: tabID).isSubmitting,
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
        return runSidebarQuickCommand(item.id, in: window, targetTabID: tabID)
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

    func executeQuickCommand(_ request: QuickCommandRunRequest, in window: WindowState, newTerminal: Bool, targetTabID: UUID? = nil) async throws {
        guard commandContext(in: window, targetTabID: targetTabID) == request.context else { throw QuickCommandError.changedTarget }
        try QuickCommandExecution.claim(request.id)
        if newTerminal {
            try await launchQuickCommand(request, in: window)
        } else {
            try await SSHTerminalRegistry.runQuickCommand(request) {
                self.commandContext(in: window, targetTabID: targetTabID) == request.context
            }
        }
    }

    @discardableResult
    func runSidebarQuickCommand(_ id: UUID, in window: WindowState,
                                expectedContext: QuickCommandContext? = nil, expectedItem: QuickCommand? = nil,
                                targetTabID: UUID? = nil,
                                onSuccess: @escaping () -> Void = {}) -> Bool {
        let execution = targetTabID.map { commandExecution(for: $0) } ?? window.quickCommandSidebarExecution
        guard !execution.isSubmitting, window.quickCommandConfirmation == nil else { return false }
        do {
            // 点击时重新读取指令和目标；不使用预览打开时的旧内容。
            let context = commandContext(in: window, targetTabID: targetTabID)
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
                try await self.executeQuickCommand(request, in: window, newTerminal: false, targetTabID: targetTabID)
                if let tab = self.tabs.first(where: { $0.sessionID == request.context.sessionID }),
                   let owner = self.windows.first(where: { self.sidebarOrder(in: $0).contains(tab.id) }) {
                    self.selectOnly(tab.id, in: owner, focusTerminal: false)
                    MainWindowManager.shared.window(for: owner)?.makeKeyAndOrderFront(nil)
                    SSHTerminalRegistry.focus(tab.sessionID)
                }
            }, onSuccess: onSuccess)
            return true
        } catch { execution.report(error); return false }
    }

    func quickCommandContext(in window: WindowState) -> QuickCommandContext {
        currentTerminalContext(in: window)
    }

    func currentTerminalContext(in window: WindowState) -> QuickCommandContext {
        guard let tab = selectedTab(in: window), tab.hasTerminal else { return QuickCommandContext() }
        return quickCommandContext(for: tab)
    }

    func commandContext(in window: WindowState, targetTabID: UUID?) -> QuickCommandContext {
        guard let targetTabID else { return quickCommandContext(in: window) }
        guard sidebarOrder(in: window).contains(targetTabID),
              let tab = tabs.first(where: { $0.id == targetTabID && $0.hasTerminal }) else { return QuickCommandContext() }
        return quickCommandContext(for: tab)
    }

    /// 和这个终端同在一个分屏的终端（含自己）。它们共用右侧一列命令栏。
    func commandSidebarGroup(of tabID: UUID) -> [UUID] {
        let panel = WorkspaceBoard.index(containing: tabID, in: workspaces).flatMap { workspaces[$0].panel(containing: tabID) }
        let leaves = panel.map { WorkspaceBoard.leafIDs($0.layout) } ?? [tabID]
        return leaves.filter { id in tabs.contains { $0.id == id && $0.hasTerminal } }
    }

    /// 分屏里任一终端展开就显示命令栏，宽度取第一个展开的终端，切换焦点时布局不跳动。
    func sharedCommandSidebar(for tabID: UUID) -> TerminalCommandSidebarState? {
        commandSidebarGroup(of: tabID).compactMap { commandSidebars[$0] }.first { $0.isExpanded }
    }

    /// 展开、收起和宽度对整个分屏生效；选中的命令仍按终端各自保存。
    func updateSharedCommandSidebar(for tabID: UUID, _ change: (inout TerminalCommandSidebarState) -> Void) {
        // 旧存档里各终端宽度可能不同，先对齐到正在显示的宽度，收起再展开不会变宽变窄。
        let width = sharedCommandSidebar(for: tabID)?.width
        var states = commandSidebars
        for id in commandSidebarGroup(of: tabID) {
            if let width { states[id, default: TerminalCommandSidebarState()].width = width }
            change(&states[id, default: TerminalCommandSidebarState()])
        }
        commandSidebars = states
    }

    /// 命令栏跟着当前终端走；选中的是预览面板时，显示分屏里第一个终端的命令。
    func commandSidebarTab(in window: WindowState) -> TerminalTab? {
        guard let selected = window.selectedTabID else { return nil }
        let group = commandSidebarGroup(of: selected)
        guard let id = group.contains(selected) ? selected : group.first else { return nil }
        return tabs.first { $0.id == id }
    }

    func expandCommandSidebarIfNeeded(for tab: TerminalTab) {
        guard tab.hasTerminal, commandSidebars[tab.id] == nil else { return }
        // 新终端分进已有分屏时，沿用这个分屏的展开状态和宽度，不再自己判断。
        let siblings = commandSidebarGroup(of: tab.id).compactMap { commandSidebars[$0] }
        if let sibling = siblings.first(where: { $0.isExpanded }) ?? siblings.first {
            commandSidebars[tab.id] = TerminalCommandSidebarState(isExpanded: sibling.isExpanded, width: sibling.width)
            return
        }
        let context = quickCommandContext(for: tab)
        if QuickCommandStore.shared.commands.contains(where: { $0.appearsInSidebar(for: context) }) {
            commandSidebars[tab.id] = TerminalCommandSidebarState(isExpanded: true)
        }
    }

    private func quickCommandContext(for tab: TerminalTab) -> QuickCommandContext {
        let local = tab.alias == nil || tab.alias?.isEmpty == true
        let directory = local ? SSHTerminalRegistry.currentWorkingDirectory(for: tab.sessionID) ?? tab.directory : tab.remoteDirectory
        return QuickCommandContext(sessionID: tab.sessionID, processID: SSHTerminalRegistry.processIdentity(for: tab.sessionID), host: local ? nil : tab.alias,
                                   directory: directory, isLive: !tab.exited && !tab.reconnecting)
    }
}
