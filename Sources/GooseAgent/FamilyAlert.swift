import AppKit

/// 保留调用方的返回值和串行确认队列，外观与交互由 NSAlert 负责。
@MainActor
final class FamilyAlert {
    private let alert = NSAlert()
    var window: NSWindow { alert.window }
    private var isRunningModal = false
    var messageText: String { get { alert.messageText } set { alert.messageText = newValue } }
    var informativeText: String { get { alert.informativeText } set { alert.informativeText = newValue } }
    var alertStyle: NSAlert.Style { get { alert.alertStyle } set { alert.alertStyle = newValue } }
    var accessoryView: NSView? { get { alert.accessoryView } set { alert.accessoryView = newValue } }
    var initialFirstResponder: NSView?
    var buttons: [NSButton] { alert.buttons }
    private static var queue: [(FamilyAlert, NSWindow, (NSApplication.ModalResponse) -> Void)] = []
    private static var active: FamilyAlert?

    @discardableResult func addButton(withTitle title: String) -> NSButton {
        let button = alert.addButton(withTitle: title)
        ClickableCursorView.attach(to: button)
        return button
    }

    func beginSheetModal(for window: NSWindow, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        Self.queue.append((self, window, completionHandler))
        Self.presentNext()
    }

    func beginSheetModal(for window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    private static func presentNext() {
        guard active == nil, !queue.isEmpty else { return }
        let (entry, owner, completion) = queue.removeFirst()
        guard owner.isVisible else { completion(.abort); presentNext(); return }
        active = entry
        if entry.alertStyle == .critical { entry.buttons.first?.hasDestructiveAction = true }
        entry.alert.window.initialFirstResponder = entry.initialFirstResponder
        entry.alert.beginSheetModal(for: owner) { response in
            Self.active = nil
            completion(response)
            Self.presentNext()
        }
    }

    @discardableResult func runModal() -> NSApplication.ModalResponse {
        alert.window.initialFirstResponder = initialFirstResponder
        isRunningModal = true
        defer { isRunningModal = false }
        return alert.runModal()
    }

    func cancel() {
        if let index = Self.queue.firstIndex(where: { $0.0 === self }) {
            let (_, _, completion) = Self.queue.remove(at: index)
            completion(.abort)
            return
        }
        if let owner = alert.window.sheetParent { owner.endSheet(alert.window, returnCode: .abort) }
        else if isRunningModal { NSApp.abortModal(); alert.window.orderOut(nil) }
    }
}

/// 上传检查使用原生复选框，保留现有调用接口。
final class FamilyNativeButton: NSButton {
    override var isEnabled: Bool {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addVisibleCursorRect(.pointingHand) }
    }

    enum Kind { case secondary, primary, danger, checkbox }
    var kind = Kind.secondary {
        didSet {
            setButtonType(kind == .checkbox ? .switch : .momentaryPushIn)
            bezelStyle = .rounded
            hasDestructiveAction = kind == .danger
        }
    }
}

final class FamilyNativeTextField: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBezeled = true
        bezelStyle = .roundedBezel
        isEditable = true
        isSelectable = true
        font = .systemFont(ofSize: NSFont.systemFontSize)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
