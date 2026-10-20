import AppKit
import Combine
import SwiftUI

/// One real transfer's status, shown in the initiating window's file footer when open.
/// Without Files, a child panel remains visible over the terminal's metal layer.
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
    @Published private(set) var visible = false
    @Published private(set) var windowID: UUID?
    private var panel: NSPanel?
    private weak var parent: NSWindow?
    private weak var panelParent: NSWindow?
    private weak var ownerState: WindowState?
    private var presentationObservation: AnyCancellable?
    private var hideWork: DispatchWorkItem?
    private var lastReport = Date.distantPast
    private var current = 0

    /// Starts a transfer's toast. Later calls pass the returned number, so progress that arrives
    /// after the end, or from an older transfer, is dropped.
    func begin(_ text: String, in window: NSWindow?) -> Int {
        current += 1
        lastReport = .distantPast
        show(text, phase: .running(0), in: window ?? NSApp.keyWindow ?? NSApp.mainWindow)
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
        let source = id == nil ? window ?? NSApp.keyWindow ?? NSApp.mainWindow : window
        show(text, phase: .failed, in: source)
        hideLater(FileBrowserLayout.toastLingerSeconds * 2)
    }

    private func show(_ text: String, phase: Phase, in window: NSWindow?) {
        hideWork?.cancel()
        self.text = text
        self.phase = phase
        guard let window = window ?? parent ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        if parent !== window || ownerState == nil {
            hidePanel()
            presentationObservation = nil
            parent = window
            ownerState = MainWindowManager.shared.state(for: window)
            windowID = ownerState?.id
            presentationObservation = ownerState?.$presentation
                .map(\.filesVisible)
                .removeDuplicates()
                .sink { [weak self] filesVisible in
                    // @Published emits before storage changes; use its supplied value.
                    self?.updatePanel(filesVisible: filesVisible)
                }
        }
        visible = true
        updatePanel(filesVisible: ownerState?.presentation.filesVisible ?? false)
    }

    private func updatePanel(filesVisible: Bool) {
        guard visible, !filesVisible, let window = parent else {
            hidePanel()
            return
        }
        let panel = self.panel ?? makePanel()
        if panelParent !== window {
            panelParent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            panelParent = window
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

    private func hidePanel() {
        guard let panel else { return }
        panelParent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panelParent = nil
    }

    private func hideLater(_ delay: Double = FileBrowserLayout.toastLingerSeconds) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.visible = false
            self.hidePanel()
            self.presentationObservation = nil
            self.parent = nil
            self.ownerState = nil
            self.windowID = nil
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

/// Embedded below the file workspace. It takes no space when the transfer has expired,
/// belongs to another window, or is already being shown as the terminal's floating toast.
struct TransferStatusBar: View {
    @ObservedObject var window: WindowState
    @ObservedObject private var toast = TransferToast.shared
    @ObservedObject private var appearance = AppearanceDriver.shared

    var body: some View {
        if toast.visible, toast.windowID == window.id, window.presentation.filesVisible {
            let chrome = WindowChrome.resolve(isDark: appearance.isDark)
            VStack(spacing: 0) {
                Rectangle().fill(chrome.hairline).frame(height: 1)
                HStack(spacing: Theme.Space.s) {
                    if toast.phase == .done {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(chrome.success)
                            .accessibilityHidden(true)
                    } else if toast.phase == .failed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(chrome.danger)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: toast.text)
                        .font(Theme.Font.body.weight(.medium))
                        .foregroundStyle(toast.phase == .failed ? chrome.danger : chrome.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if case .running(let fraction) = toast.phase {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(chrome.accent)
                            .controlSize(.small)
                            .frame(width: 160)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.m)
                .frame(height: 31)
            }
            .background(chrome.background)
        }
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
