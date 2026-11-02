import AppKit
import SwiftUI

/// Some responders belong to a selection that can change while a dialog is open.
protocol FamilyModalFocusRestoring {
    var canRestoreModalFocus: Bool { get }
}

/// 表单使用系统 sheet；独立展示时使用标准面板。
@MainActor
final class FamilyModalPresentation: NSObject {
    static let didCloseNotification = Notification.Name("FamilyModalPresentation.didClose")
    let window: FamilyModalWindow
    private weak var owner: NSWindow?
    private weak var previousResponder: NSResponder?
    private var finished = false
    private var ownerObserver: NSObjectProtocol?
    private static var retained: [ObjectIdentifier: FamilyModalPresentation] = [:]

    init(content: NSView, size: NSSize, owner: NSWindow?, onCancel: @escaping () -> Void) {
        window = FamilyModalWindow(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        self.owner = owner
        previousResponder = owner?.firstResponder
        super.init()
        window.isReleasedWhenClosed = false
        window.appearance = owner?.effectiveAppearance ?? NSApp.effectiveAppearance
        window.identifier = NSUserInterfaceItemIdentifier("family.dialog")
        window.onCancel = onCancel
        window.contentView = content
        window.setContentSize(size)
        if let owner {
            ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.window.onCancel?(); self?.close() }
            }
        }
    }

    func show(initialFirstResponder: NSView? = nil) {
        Self.retained[ObjectIdentifier(self)] = self
        if let initialFirstResponder { window.initialFirstResponder = initialFirstResponder }
        if let owner {
            owner.beginSheet(window) { [weak self] _ in self?.close() }
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        guard !finished else { return }
        finished = true
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }
        ownerObserver = nil
        window.onCancel = nil
        if window.sheetParent != nil { owner?.endSheet(window) }
        window.orderOut(nil)
        if let owner, owner.isVisible {
            if let previousResponder,
               (previousResponder as? FamilyModalFocusRestoring)?.canRestoreModalFocus != false {
                owner.makeFirstResponder(previousResponder)
            }
            NotificationCenter.default.post(name: Self.didCloseNotification, object: owner)
        }
        Self.retained.removeValue(forKey: ObjectIdentifier(self))
    }
}

final class FamilyModalWindow: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func close() { onCancel?() }
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
            .background(Color(nsColor: .windowBackgroundColor)))
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
