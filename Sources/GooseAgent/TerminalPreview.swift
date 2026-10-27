import AppKit
import GhosttyTerminal
import SwiftUI

/// 独立的只读终端画布，复用真实终端的字体、主题和 Powerline 字形渲染。
struct TerminalPreview: NSViewRepresentable {
    let sessionID: String
    let fallback: String

    func makeNSView(context: Context) -> TerminalPreviewView {
        let content = SSHTerminalRegistry.previewContent(for: sessionID)
        return TerminalPreviewView(output: content?.output ?? fallback,
                                   controller: content?.controller ?? GhosttyRuntime.controller)
    }

    func updateNSView(_ view: TerminalPreviewView, context: Context) {}

    static func dismantleNSView(_ view: TerminalPreviewView, coordinator: ()) {
        view.controller = nil
    }
}

final class TerminalPreviewView: AppTerminalView {
    // 没有进程或 SSH 连接；预览的输入与尺寸变化不会传给原会话。
    let previewSession = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
    private let output: String
    private var renderedSize: NSSize = .zero
    private var scheduledSize: NSSize = .zero
    private var pendingReplay: DispatchWorkItem?

    init(output: String, controller: TerminalController) {
        // 导出包含原网格行尾的带色空白；在更窄的预览中会折成多余色条。
        // 只裁掉行尾空白及样式收尾，保留文字间的空格和所有有效颜色。
        var lines = TerminalOutputStore.displayText(output).components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "(?:\u{1b}\\[[0-9;:]*m|[ \\t])+$", with: "", options: .regularExpression)
        }
        while lines.last == "" { lines.removeLast() }
        self.output = lines.joined(separator: "\u{1b}[0m\r\n")
        super.init(frame: .zero)
        configuration = TerminalSurfaceOptions(backend: .inMemory(previewSession),
                                                fontSize: Float(SwitcherLayout.previewFontSize))
        self.controller = controller
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {}

    override func layout() {
        super.layout()
        // SwiftUI 会经过多个中间尺寸；稳定后再回放，避免重排带色空白。
        let size = bounds.size
        guard size.width > 0, size.height > 0, window != nil,
              previewSession.hasAttachedSurface, size != renderedSize,
              size != scheduledSize else { return }
        pendingReplay?.cancel()
        scheduledSize = size
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window != nil, self.bounds.size == size else { return }
            self.pendingReplay = nil
            self.scheduledSize = .zero
            self.renderedSize = size
            self.previewSession.receive("\u{1b}[0m\u{1b}[3J\u{1b}[2J\u{1b}[H" + self.output + "\u{1b}[0m\u{1b}[?25l")
        }
        pendingReplay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            pendingReplay?.cancel()
            pendingReplay = nil
            scheduledSize = .zero
        } else {
            needsLayout = true
        }
    }
}
