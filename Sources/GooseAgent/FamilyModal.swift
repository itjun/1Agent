import AppKit
import SwiftUI

/// App-owned modal chrome. No AppKit sheet animation, material, title bar or window shadow.
/// The full-window child panel keeps pointer input and keyboard focus inside the dialog.
@MainActor
final class FamilyModalPresentation: NSObject {
    let window = FamilyModalWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    let backdrop = FamilyModalBackdrop()
    private weak var owner: NSWindow?
    private weak var previousResponder: NSResponder?
    private var observers: [NSObjectProtocol] = []
    private var completion: (() -> Void)?
    private var finished = false
    private static var retained: [ObjectIdentifier: FamilyModalPresentation] = [:]

    init(content: NSView, size: NSSize, owner: NSWindow?, onCancel: @escaping () -> Void) {
        super.init()
        self.owner = owner
        previousResponder = owner?.firstResponder
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isMovable = false
        window.animationBehavior = .none
        window.appearance = owner?.effectiveAppearance ?? NSApp.effectiveAppearance
        window.identifier = NSUserInterfaceItemIdentifier("family.dialog")
        window.onCancel = onCancel
        backdrop.onCancel = onCancel
        backdrop.cardSize = size
        backdrop.install(content)
        window.contentView = backdrop
        completion = onCancel
        updateFrame()
        if let owner {
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateFrame() }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.completion?() }
            })
        }
    }

    func show(initialFirstResponder: NSView? = nil) {
        Self.retained[ObjectIdentifier(self)] = self
        if let owner { owner.addChildWindow(window, ordered: .above) }
        window.makeKeyAndOrderFront(nil)
        backdrop.layoutSubtreeIfNeeded()
        if let initialFirstResponder { window.makeFirstResponder(initialFirstResponder) }
        else { window.selectNextKeyView(nil) }
        NSAccessibility.post(element: window, notification: .created)
    }

    func close() {
        guard !finished else { return }
        finished = true
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        completion = nil
        window.onCancel = nil
        backdrop.onCancel = nil
        owner?.removeChildWindow(window)
        window.orderOut(nil)
        if let owner, owner.isVisible {
            owner.makeKeyAndOrderFront(nil)
            if let previousResponder { owner.makeFirstResponder(previousResponder) }
        }
        Self.retained.removeValue(forKey: ObjectIdentifier(self))
    }

    private func updateFrame() {
        let frame = owner?.frame ?? NSRect(x: 0, y: 0, width: backdrop.cardSize.width + 64, height: backdrop.cardSize.height + 64)
        window.setFrame(frame, display: true)
        if owner == nil { window.center() }
        backdrop.needsLayout = true
    }
}

final class FamilyModalWindow: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func close() { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

final class FamilyModalBackdrop: NSView {
    var card: NSView?
    private let scroll = NSScrollView()
    var cardSize = NSSize.zero
    var onCancel: (() -> Void)?
    override var isFlipped: Bool { true }
    func install(_ content: NSView) {
        card = content
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = Theme.Radius.card
        scroll.layer?.masksToBounds = true
        scroll.documentView = content
        addSubview(scroll)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.6).setFill()
        bounds.fill()
    }
    override func layout() {
        super.layout()
        let size = NSSize(width: min(cardSize.width, max(0, bounds.width - 32)), height: min(cardSize.height, max(0, bounds.height - 64)))
        scroll.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        card?.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: cardSize.height))
    }
    override func mouseDown(with event: NSEvent) { onCancel?() }
}

/// SwiftUI sheet content shares the same centered modal host as confirmations.
extension View {
    func familySheet<Sheet: View>(isPresented: Binding<Bool>, width: CGFloat, height: CGFloat, @ViewBuilder content: @escaping () -> Sheet) -> some View {
        background(FamilySheetAnchor(isPresented: isPresented, size: NSSize(width: width, height: height), sheet: content()))
    }
}

private struct FamilySheetAnchor<Sheet: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let size: NSSize
    let sheet: Sheet
    @Environment(\.windowChrome) private var chrome
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSView { FamilySheetAnchorView() }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        let presented = isPresented
        let binding = $isPresented
        let content = AnyView(sheet
            .environment(\.windowChrome, chrome).environment(\.colorScheme, colorScheme)
            .font(Theme.Font.body).tint(chrome.accent)
            .buttonStyle(FamilyButtonStyle(kind: .secondary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(chrome.background)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(chrome.hairline, lineWidth: 1)))
        // Updating the binding or making a key window inside a SwiftUI update is reentrant.
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let coordinator else { return }
            guard presented, let owner = view?.window else {
                coordinator.presentation?.close()
                coordinator.presentation = nil
                coordinator.host = nil
                return
            }
            if let host = coordinator.host { host.rootView = content; return }
            let host = NSHostingView(rootView: content)
            coordinator.host = host
            let presentation = FamilyModalPresentation(content: host, size: size, owner: owner) {
                binding.wrappedValue = false
                coordinator.presentation?.close()
                coordinator.presentation = nil
                coordinator.host = nil
            }
            coordinator.presentation = presentation
            presentation.show()
        }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.presentation?.close() }
    final class Coordinator {
        var presentation: FamilyModalPresentation?
        var host: NSHostingView<AnyView>?
    }
}
private final class FamilySheetAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
