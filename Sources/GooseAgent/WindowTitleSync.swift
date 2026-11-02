import AppKit
import SwiftUI

/// 将工具栏分区绑定到原生分栏，标题和操作跟随各自的内容区域。
struct WindowTitleSync: NSViewRepresentable {
    var title: String
    var model: AppModel
    @ObservedObject var state: WindowState

    func makeCoordinator() -> Coordinator { Coordinator(model: model, state: state) }
    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        view.coordinator = context.coordinator
        return view
    }

    private final class AnchorView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { coordinator?.removeToolbar() }
        }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }
    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.title = title
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.titlebarSeparatorStyle = .automatic
            window.isMovableByWindowBackground = false
            coordinator.attach(to: window)
            coordinator.refresh(window.toolbar)
        }
    }

    @MainActor final class Coordinator: NSObject, NSToolbarDelegate {
        weak var model: AppModel?
        weak var state: WindowState?
        private let sidebar = NSToolbarItem.Identifier("workspace.toggleSidebar")
        private let sidebarSeparator = NSToolbarItem.Identifier("workspace.sidebarSeparator")
        private let inspectorSeparator = NSToolbarItem.Identifier("workspace.inspectorSeparator")
        private weak var splitView: NSSplitView?
        private weak var window: NSWindow?
        private var isDetached = false
        private let newTerminal = NSToolbarItem.Identifier("workspace.newLocalTerminal")
        private let tools = NSToolbarItem.Identifier("workspace.toggleToolSidebar")
        init(model: AppModel, state: WindowState) {
            self.model = model
            self.state = state
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(splitAttached(_:)),
                name: .workspaceSplitDidAttach, object: nil)
        }
        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func splitAttached(_ notification: Notification) {
            guard let split = notification.object as? NSSplitView, let window,
                  split.window === window else { return }
            attach(to: window)
        }

        func detach() {
            isDetached = true
            removeToolbar()
        }

        func removeToolbar() {
            if window?.toolbar?.delegate === self { window?.toolbar = nil }
            splitView = nil
        }

        func attach(to window: NSWindow) {
            guard !isDetached else { return }
            self.window = window
            guard let root = window.contentView, let split = workspaceColumnSplit(in: root) else { return }
            splitView = split
            if window.toolbar == nil {
                let toolbar = NSToolbar(identifier: "workspace.toolbar")
                toolbar.delegate = self
                toolbar.displayMode = .iconOnly
                toolbar.allowsUserCustomization = false
                window.toolbarStyle = .unified
                window.toolbar = toolbar
            }
            for case let separator as NSTrackingSeparatorToolbarItem in window.toolbar?.items ?? [] {
                if separator.splitView !== split { separator.splitView = split }
            }
            refresh(window.toolbar)
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [.flexibleSpace, sidebar, newTerminal, sidebarSeparator, .flexibleSpace, inspectorSeparator, tools]
        }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
            if id == sidebarSeparator || id == inspectorSeparator {
                guard let splitView else { return nil }
                return NSTrackingSeparatorToolbarItem(identifier: id, splitView: splitView,
                    dividerIndex: id == sidebarSeparator ? 0 : 1)
            }
            let item = NSToolbarItem(itemIdentifier: id)
            item.target = self
            if id == sidebar {
                item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
                item.action = #selector(toggleSidebar)
            } else if id == newTerminal {
                item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
                item.action = #selector(openTerminal)
            } else if id == tools {
                item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
                item.action = #selector(toggleTools)
            } else { return nil }
            return item
        }
        func refresh(_ toolbar: NSToolbar?) {
            guard let state else { return }
            for item in toolbar?.items ?? [] {
                let shortcut: AppShortcutID
                if item.itemIdentifier == sidebar {
                    item.label = state.presentation.sidebarCollapsed ? String(localized: "Show Session Sidebar") : String(localized: "Hide Session Sidebar")
                    shortcut = .toggleSidebar
                } else if item.itemIdentifier == newTerminal {
                    item.label = String(localized: "New Local Terminal")
                    shortcut = .newLocalTerminal
                } else if item.itemIdentifier == tools {
                    item.label = state.presentation.toolSidebarOpen ? String(localized: "Hide Tool Sidebar") : String(localized: "Show Tool Sidebar")
                    shortcut = .toggleToolSidebar
                    item.isEnabled = !state.presentation.fullFilesWorkspace
                } else { continue }
                let key = AppShortcuts.display(for: shortcut)
                item.toolTip = key.isEmpty ? item.label : item.label + " (" + key + ")"
            }
        }
        @objc private func toggleSidebar() { if let state { model?.toggleSidebar(in: state) } }
        @objc private func openTerminal() { if let state { model?.openLocalTerminal(in: state) } }
        @objc private func toggleTools() { if let state { model?.toggleToolSidebar(in: state) } }
    }
}
