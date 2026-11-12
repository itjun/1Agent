import AppKit
import SwiftUI

@MainActor
final class NativeFolderPicker: ObservableObject {
    weak var owner: NSWindow?
    private(set) var panel: NSOpenPanel?
    private var closeObserver: NSObjectProtocol?

    func present(directory: String, onChoose: @escaping ([URL]) -> Void) {
        guard panel == nil, let owner, owner.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        panel.prompt = String(localized: "Pin Folder")
        self.panel = panel
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
        panel.beginSheetModal(for: owner) { [weak self, weak panel] response in
            guard let self, let panel, self.panel === panel else { return }
            self.panel = nil
            self.removeObserver()
            if response == .OK { onChoose(panel.urls) }
        }
    }

    func cancel() {
        let current = panel
        panel = nil
        removeObserver()
        current?.cancel(nil)
    }

    private func removeObserver() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }
}

struct NativeFolderPickerAnchor: NSViewRepresentable {
    let picker: NativeFolderPicker

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.picker = picker
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) { picker.owner = view.window }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        view.picker?.cancel()
        view.picker?.owner = nil
    }

    final class Anchor: NSView {
        weak var picker: NativeFolderPicker?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            picker?.owner = window
        }
    }
}
