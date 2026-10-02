import AppKit
import Combine
import SwiftUI

/// "Uploading 42%" at the top center of a window, below the tab strip. A child window, so it shows over terminals,
/// whose metal layer covers any SwiftUI view inside the window.
@MainActor
final class TransferToast: ObservableObject {
    static let shared = TransferToast()

    enum Phase: Equatable {
        case running(Double)
        case done
        case failed
    }

    @Published private(set) var text = ""
    @Published private(set) var phase: Phase = .done
    private var panel: NSPanel?
    private weak var parent: NSWindow?
    private var hideWork: DispatchWorkItem?
    private var lastReport = Date.distantPast
    private var current = 0

    /// Starts a transfer's toast. Later calls pass the returned number, so progress that arrives
    /// after the end, or from an older transfer, is dropped.
    func begin(_ text: String, in window: NSWindow?) -> Int {
        current += 1
        show(text, phase: .running(0), in: window)
        return current
    }

    /// Updates are coalesced to about ten per second.
    func progress(_ id: Int, _ text: String, fraction: Double) {
        guard id == current, case .running = phase else { return }
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.1 || fraction >= 1 else { return }
        lastReport = now
        show(text, phase: .running(fraction), in: nil)
    }

    func finish(_ id: Int, _ text: String) {
        guard id == current else { return }
        show(text, phase: .done, in: nil)
        hideLater()
    }

    /// `id` nil: an error before any transfer began.
    func fail(_ id: Int?, _ text: String, in window: NSWindow? = nil) {
        if let id {
            guard id == current else { return }
        } else {
            current += 1
        }
        show(text, phase: .failed, in: window)
        hideLater(FileBrowserLayout.toastLingerSeconds * 2)
    }

    private func show(_ text: String, phase: Phase, in window: NSWindow?) {
        hideWork?.cancel()
        self.text = text
        self.phase = phase
        guard let window = window ?? parent ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let panel = self.panel ?? makePanel()
        if parent !== window {
            parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            parent = window
        }
        let size = CGSize(width: FileBrowserLayout.toastWidth, height: FileBrowserLayout.toastHeight)
        let frame = window.frame
        panel.setFrame(CGRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - FileBrowserLayout.toastTopInset - size.height,
            width: size.width,
            height: size.height
        ), display: true)
        panel.orderFront(nil)
    }

    private func hideLater(_ delay: Double = FileBrowserLayout.toastLingerSeconds) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.parent = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = ToastPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: TransferToastView(toast: self))
        self.panel = panel
        return panel
    }
}

private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct TransferToastView: View {
    @ObservedObject var toast: TransferToast
    @ObservedObject private var appearance = AppearanceDriver.shared

    var body: some View {
        let chrome = WindowChrome.resolve(isDark: appearance.isDark)
        let failed = toast.phase == .failed
        VStack(spacing: Theme.Space.xs) {
            Text(verbatim: toast.text)
                .font(Theme.Font.rowMeta.weight(.medium))
                .foregroundStyle(failed ? chrome.danger : chrome.text)
                .lineLimit(1)
                .truncationMode(.middle)
            if case .running(let fraction) = toast.phase {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(chrome.accent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(chrome.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(failed ? chrome.danger : chrome.hairline, lineWidth: 1)
        )
    }
}
