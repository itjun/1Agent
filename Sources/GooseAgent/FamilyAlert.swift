import AppKit

/// 保留异步队列和取消契约，确认框由系统 NSAlert 呈现。
@MainActor
final class FamilyAlert {
    let native = NSAlert()
    var messageText: String { get { native.messageText } set { native.messageText = newValue } }
    var informativeText: String { get { native.informativeText } set { native.informativeText = newValue } }
    var alertStyle: NSAlert.Style { get { native.alertStyle } set { native.alertStyle = newValue } }
    var accessoryView: NSView? { get { native.accessoryView } set { native.accessoryView = newValue } }
    var initialFirstResponder: NSView?
    var buttons: [NSButton] { native.buttons }
    private var completion: ((NSApplication.ModalResponse) -> Void)?
    private weak var owner: NSWindow?
    private var finished = false
    private var runningModal = false
    private static var queue: [FamilyAlert] = []
    private static var active: FamilyAlert?

    @discardableResult func addButton(withTitle title: String) -> NSButton { native.addButton(withTitle: title) }

    func beginSheetModal(for window: NSWindow, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        owner = window
        completion = completionHandler
        Self.queue.append(self)
        Self.presentNext()
    }

    func beginSheetModal(for window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    private static func presentNext() {
        guard active == nil, !queue.isEmpty else { return }
        let alert = queue.removeFirst()
        active = alert
        guard let owner = alert.owner, owner.isVisible else { alert.finish(.abort); return }
        alert.native.window.appearance = owner.effectiveAppearance
        if let field = alert.initialFirstResponder { alert.native.window.initialFirstResponder = field }
        alert.native.beginSheetModal(for: owner) { response in alert.finish(response) }
    }

    func runModal() -> NSApplication.ModalResponse {
        runningModal = true
        if let field = initialFirstResponder { native.window.initialFirstResponder = field }
        let response = native.runModal()
        runningModal = false
        return response
    }

    func cancel() {
        guard !finished else { return }
        if native.window.sheetParent != nil { owner?.endSheet(native.window, returnCode: .abort) }
        if runningModal { NSApp.abortModal(); native.window.orderOut(nil) }
        finish(.abort)
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        guard !finished else { return }
        finished = true
        Self.queue.removeAll { $0 === self }
        if Self.active === self { Self.active = nil }
        let handler = completion
        completion = nil
        handler?(response)
        Self.presentNext()
    }
}

final class FamilyNativeButton: NSButton {
    enum Kind { case secondary, primary, danger, checkbox }
    var kind: Kind = .secondary {
        didSet {
            bezelStyle = .rounded
            if kind == .checkbox { setButtonType(.switch) }
            hasDestructiveAction = kind == .danger
        }
    }
}

typealias FamilyNativeTextField = NSTextField
