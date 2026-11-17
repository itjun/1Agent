import AppKit
import SwiftUI

/// 维护原生窗口标题与红绿灯位置；各页操作区由各自的岛承载。
struct WorkspaceToolbar: NSViewRepresentable {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WindowState
    @ObservedObject private var appearance = AppearanceDriver.shared

    func makeCoordinator() -> Coordinator { Coordinator(model: model, state: state) }

    func makeNSView(context: Context) -> ToolbarAttachmentView {
        let view = ToolbarAttachmentView()
        view.onWindow = { [weak coordinator = context.coordinator] in coordinator?.attach(to: $0) }
        return view
    }

    func updateNSView(_ view: ToolbarAttachmentView, context: Context) {
        context.coordinator.update()
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: AppModel
        let state: WindowState
        private weak var window: NSWindow?

        init(model: AppModel, state: WindowState) {
            self.model = model
            self.state = state
        }

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = true
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar = nil
            window.titlebarSeparatorStyle = .none
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize(_:)),
                name: NSWindow.didResizeNotification, object: window)
            update()
        }

        func update() {
            window?.backgroundColor = NSColor(WindowChrome.workspace(isDark: AppearanceDriver.shared.isDark).background)
            let tab = model.selectedTab(in: state)
            window?.title = state.section == .commands ? String(localized: "Command Library")
                : state.presentation.fullFilesWorkspace ? String(localized: "Files")
                : tab.map { model.sessionTitle($0) } ?? String(localized: "1Agent")
            // 各页标题与操作属于各自的岛，不再切换原生通栏或改变内容高度。
            window?.toolbar = nil
            DispatchQueue.main.async { [weak self] in self?.positionWindowButtons() }
            FocusedTerminal.shared.refreshSoon()
        }

        private func positionWindowButtons() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            // 原生红绿灯放在导航岛内部，与各岛的 32pt 标题共用中心线。
            // 使用窗口坐标，避免每次布局在已移动的位置上累计偏移。
            for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
                let center = parent.convert(NSPoint(x: ShellLayout.workspaceInset + 18 + CGFloat(index) * 20,
                    y: window.frame.height - ShellLayout.workspaceInset - ShellLayout.compactHeaderHeight / 2), from: nil)
                button.setFrameOrigin(NSPoint(x: center.x - button.frame.width / 2,
                                              y: center.y - button.frame.height / 2))
            }
        }

        @objc private func windowDidResize(_ notification: Notification) { update() }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

/// 左右侧栏共用扁平按钮，只在悬停和按下时显示底色。
struct WorkspaceSidebarToggle: View {
    let shortcut: AppShortcutID
    let systemImage: String
    let identifier: String
    let action: () -> Void
    @ObservedObject private var appearance = AppearanceDriver.shared

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Theme.Toolbar.iconFont)
                .frame(width: Theme.Toolbar.height, height: Theme.Toolbar.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(WorkspaceSidebarButtonStyle(chrome: WindowChrome.resolve(isDark: appearance.isDark)))
        .help(shortcut.title + " (" + AppShortcuts.display(for: shortcut) + ")")
        .accessibilityLabel(shortcut.title)
        .accessibilityIdentifier(identifier)
        .preferredColorScheme(appearance.interfaceColorScheme)
    }
}

private struct WorkspaceSidebarButtonStyle: ButtonStyle {
    let chrome: WindowChrome
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(chrome.text)
            .background(configuration.isPressed ? chrome.accentFill : isHovered ? chrome.hoverFill : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .onHover { isHovered = $0 }
            .clickableCursor()
    }
}

/// 文件和改动预览共用通栏标题及阅读操作。
struct WorkspacePreviewToolbar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WindowState
    var body: some View {
        HStack(spacing: 8) {
            if let request = state.toolGitPreview {
                FileTypeIcon(name: (request.change.path as NSString).lastPathComponent)
                Text(verbatim: (request.change.path as NSString).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle).help(request.change.path)
                if let stats = request.change.lineStats { GitLineStatsLabel(stats: stats).fixedSize() }
            } else if let column = state.toolPreviewColumn {
                WorkspacePreviewFileTitle(column: column)
            }
            Spacer(minLength: 4)
            Button {
                NSApp.keyWindow?.makeFirstResponder(nil)
                state.isToolPreviewExpanded.toggle()
            } label: {
                Image(systemName: state.isToolPreviewExpanded
                    ? "arrow.down.left.and.arrow.up.right" : "arrow.up.right.and.arrow.down.left")
                    .font(Theme.Toolbar.iconFont)
                    .frame(width: Theme.Toolbar.height, height: Theme.Toolbar.height).contentShape(Rectangle())
            }
            .help(state.isToolPreviewExpanded ? String(localized: "Collapse Reading") : String(localized: "Expand Reading"))
            .accessibilityLabel(state.isToolPreviewExpanded ? String(localized: "Collapse Reading") : String(localized: "Expand Reading"))
            .accessibilityIdentifier("workspace.preview.expand")
            Button { state.toolPreviewFindRequest += 1 } label: {
                Image(systemName: "magnifyingglass")
                    .font(Theme.Toolbar.iconFont)
                    .frame(width: Theme.Toolbar.height, height: Theme.Toolbar.height).contentShape(Rectangle())
            }
            .help(String(localized: "Find in Preview") + " (" + AppShortcuts.display(for: .find) + ")").accessibilityLabel(Text("Find in Preview"))
            .accessibilityIdentifier("workspace.preview.find")
            Button {
                state.closeToolPreview()

            } label: {
                Image(systemName: "xmark")
                    .font(Theme.Toolbar.iconFont)
                    .frame(width: Theme.Toolbar.height, height: Theme.Toolbar.height).contentShape(Rectangle())
            }
            .help("Close Preview").accessibilityLabel(Text("Close Preview"))
            .accessibilityIdentifier("workspace.preview.close")
        }
        .font(Theme.Font.paneTitle)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.preview.toolbar")
    }
}

private struct WorkspacePreviewFileTitle: View {
    @ObservedObject var column: FileColumn
    var body: some View {
        if let preview = column.preview {
            FileTypeIcon(name: preview.entry.name)
            Text(verbatim: preview.entry.name).lineLimit(1).truncationMode(.middle).help(preview.entry.path)
        }
    }
}

final class ToolbarAttachmentView: NSView {
    var onWindow: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.onWindow?(window)
            }
        }
    }
}
