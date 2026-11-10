import AppKit
import SwiftUI

struct QuickCommandPreviewContent: View {
    let item: QuickCommand
    let context: QuickCommandContext
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @ObservedObject var execution: QuickCommandSidebarExecution
    let maximumWidth: CGFloat
    let onExecuted: () -> Void
    @Environment(\.windowChrome) private var chrome

    private var isCurrentTarget: Bool { model.quickCommandContext(in: window) == context }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: item.alias).font(Theme.Font.sectionTitle).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    model.runSidebarQuickCommand(item.id, in: window, expectedContext: context,
                                                 expectedItem: item, onSuccess: onExecuted)
                } label: {
                    Group {
                        if execution.isSubmitting { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "play.fill").font(.system(size: 12)) }
                    }
                    .frame(width: SidebarLayout.iconButtonSize, height: SidebarLayout.iconButtonSize)
                    .contentShape(Rectangle())
                }
                .buttonStyle(FamilyButtonStyle())
                .disabled(execution.isSubmitting || !isCurrentTarget || !context.isLive || window.quickCommandConfirmation != nil)
                .accessibilityLabel(Text("Run"))
                .help("Run in Current Terminal").accessibilityIdentifier("quickCommands.preview.run")
                .fixedSize()
            }
            .padding(.trailing, SheetLayout.commandPreviewCodeInset)
            HStack(alignment: .top, spacing: SheetLayout.commandPreviewCodeSpacing) {
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: item.command).font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                        .frame(minHeight: SidebarLayout.iconButtonSize, alignment: .leading)
                        .accessibilityIdentifier("quickCommands.preview.code")
                }.frame(width: textWidth, height: textHeight)
                SidebarIconButton(symbol: "doc.on.doc", help: String(localized: "Copy Preview Text"),
                                  accessibilityLabel: "Copy Preview Text", hoverFill: chrome.hairline) {
                    CommandClipboard.copy(item.command)
                }.accessibilityIdentifier("quickCommands.preview.copy")
            }
            .padding(SheetLayout.commandPreviewCodeInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(chrome.text.opacity(chrome.isDark ? 0.10 : 0.06))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Host").foregroundStyle(chrome.secondary)
                    Text(verbatim: context.host ?? String(localized: "This Mac"))
                }
                GridRow {
                    Text("Directory").foregroundStyle(chrome.secondary)
                    Text(verbatim: item.executionDirectory(in: context) ?? String(localized: "Directory unknown"))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }.font(Theme.Font.rowMeta).frame(maxWidth: .infinity, alignment: .leading)
            if let error = execution.error {
                Text(verbatim: error).font(Theme.Font.rowMeta).foregroundStyle(chrome.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("quickCommands.preview.error")
            }
        }
        .padding(SheetLayout.commandPreviewInset).frame(width: previewWidth)
        .foregroundStyle(chrome.text).background(chrome.background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(chrome.hairline))
        .accessibilityElement(children: .contain).accessibilityIdentifier("quickCommands.preview")
    }

    private var commandBounds: NSRect {
        (item.command as NSString).boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
    }

    private var previewWidth: CGFloat {
        let contentWidth = ceil(commandBounds.width) + SheetLayout.commandPreviewInset * 2
            + SheetLayout.commandPreviewCodeInset * 2 + SidebarLayout.iconButtonSize
            + SheetLayout.commandPreviewCodeSpacing + 4
        return min(maximumWidth, max(SheetLayout.commandSidebarPreviewWidth, contentWidth))
    }

    private var textHeight: CGFloat {
        min(SheetLayout.commandSidebarPreviewHeight, max(SidebarLayout.iconButtonSize, ceil(commandBounds.height) + 4))
    }

    private var textWidth: CGFloat {
        previewWidth - SheetLayout.commandPreviewInset * 2
            - SheetLayout.commandPreviewCodeInset * 2 - SidebarLayout.iconButtonSize - SheetLayout.commandPreviewCodeSpacing
    }
}

/// 点击打开的指令预览；点击外部时原事件继续传递，不吞掉终端或其他指令的点击。
struct QuickCommandPreview<Content: View>: NSViewRepresentable {
    let item: QuickCommand
    let context: QuickCommandContext
    let isPresented: Bool
    let onDismiss: () -> Void
    @ViewBuilder let content: (CGFloat) -> Content

    func makeNSView(context: Context) -> QuickCommandPreviewAnchorView { QuickCommandPreviewAnchorView() }
    func updateNSView(_ view: QuickCommandPreviewAnchorView, context: Context) {
        if view.commandContext != self.context || view.item != item { view.dismiss(notify: false) }
        view.item = item
        view.commandContext = self.context
        view.previewContent = AnyView(content(view.maximumPreviewWidth))
        view.onDismiss = onDismiss
        view.isPresented = isPresented
        if isPresented { view.showPreview() }
        else { view.dismiss(notify: false) }
    }
    static func dismantleNSView(_ view: QuickCommandPreviewAnchorView, coordinator: ()) { view.dismiss(notify: false) }
}

final class QuickCommandPreviewAnchorView: NSView {
    var item: QuickCommand?
    var commandContext = QuickCommandContext()
    var previewContent = AnyView(EmptyView())
    var onDismiss: () -> Void = {}
    var isPresented = false
    private(set) var previewPanel: NSPanel?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    var maximumPreviewWidth: CGFloat {
        guard let window, let screen = window.screen?.visibleFrame else { return SheetLayout.commandSidebarPreviewMaxWidth }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let roomOnLeft = anchor.minX - screen.minX - 20
        return min(SheetLayout.commandSidebarPreviewMaxWidth, screen.width - 16,
                   max(SheetLayout.commandSidebarPreviewWidth, roomOnLeft))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { dismiss(notify: false) }
        super.viewWillMove(toWindow: newWindow)
    }
    func showPreview() {
        guard isPresented, let window, window.isVisible,
              !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return }
        if let panel = previewPanel, let hosting = panel.contentView as? NSHostingView<AnyView> {
            hosting.layoutSubtreeIfNeeded()
            position(panel, size: hosting.fittingSize, in: window)
            return
        }
        let hosting = NSHostingView(rootView: previewContent)
        let size = hosting.fittingSize
        let panel = QuickCommandPreviewPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hosting
        position(panel, size: size, in: window)
        previewPanel = panel
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .scrollWheel, .keyDown]) { [weak self] event in
            guard let self, let panel = self.previewPanel else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.dismiss()
                return nil
            }
            if event.type == .keyDown, event.window !== panel { self.dismiss(); return event }
            if event.type == .leftMouseDragged, event.window !== panel { self.dismiss(); return event }
            if event.type == .scrollWheel, event.window !== panel { self.dismiss(); return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if event.window !== panel { self.dismiss() }
            }
            return event
        }
        for name in [NSWindow.willCloseNotification, NSWindow.willMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }

    private func position(_ panel: NSPanel, size: NSSize, in window: NSWindow) {
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? anchor
        let x = max(screen.minX + 8, anchor.minX - size.width - 12)
        let y = min(screen.maxY - size.height - 8, max(screen.minY + 8, anchor.midY - size.height / 2))
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }

    func dismiss(notify: Bool = true) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let panel = previewPanel {
            panel.parent?.removeChildWindow(panel)
            panel.close()
            previewPanel = nil
        }
        if notify, isPresented { isPresented = false; onDismiss() }
    }
}

private final class QuickCommandPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
