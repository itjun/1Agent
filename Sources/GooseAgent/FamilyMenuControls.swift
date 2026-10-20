import AppKit
import SwiftUI

/// SwiftUI owns the trigger; AppKit owns the popup and keyboard routing.
struct FamilyMenu<Label: View>: View {
    var items: () -> [FamilyMenuItem]
    var selection = false
    var onPresentationChange: (Bool) -> Void = { _ in }
    @ViewBuilder var label: () -> Label
    @StateObject private var anchor = FamilyMenuAnchor()

    var body: some View {
        Button {
            if let view = anchor.view {
                FamilyMenuPresenter.shared.show(items(), below: view, selection: selection, onDismiss: { onPresentationChange(false) })
                onPresentationChange(!FamilyMenuPresenter.shared.panels.isEmpty)
            }
        } label: { label() }
        .buttonStyle(FamilyButtonStyle())
        .background(FamilyMenuAnchorView(anchor: anchor))
    }
}

extension FamilyMenu where Label == FamilyMenuLabel {
    init(_ title: LocalizedStringKey, items: @escaping () -> [FamilyMenuItem]) {
        self.items = items
        self.label = { FamilyMenuLabel(title: title) }
    }
}

struct FamilyMenuLabel: View {
    var title: LocalizedStringKey
    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "chevron.down").font(.system(size: 10))
        }
        .frame(minHeight: Theme.Control.height)
    }
}

struct FamilyPicker<Value: Hashable>: View {
    @Binding var value: Value
    var options: [(Value, String)]
    @Environment(\.windowChrome) private var chrome
    @State private var presented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FamilyMenu(items: {
            options.map { option in
                FamilyMenuItem(title: option.1, checked: value == option.0, action: { value = option.0 })
            }
        }, selection: true, onPresentationChange: { presented = $0 }) {
            HStack(spacing: 8) {
                Text(verbatim: options.first { $0.0 == value }?.1 ?? "")
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 12))
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(presented ? 180 : 0))
            }
            .font(Theme.Font.body)
            .foregroundStyle(chrome.text)
            .padding(.horizontal, 8)
            .frame(height: Theme.Control.height)
            .background(RoundedRectangle(cornerRadius: 4).fill(presented ? chrome.background : chrome.elevated))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(presented ? chrome.accent : .clear, lineWidth: 1))
            .familyFocusRing(presented)
            .animation(reduceMotion ? nil : .timingCurve(0.38, 0, 0.24, 1, duration: 0.2), value: presented)
        }
        .accessibilityValue(Text(verbatim: options.first { $0.0 == value }?.1 ?? ""))
    }
}

private final class FamilyMenuAnchor: ObservableObject { weak var view: NSView? }

private struct FamilyMenuAnchorView: NSViewRepresentable {
    let anchor: FamilyMenuAnchor
    func makeNSView(context: Context) -> NSView {
        let view = FamilyContextAnchorView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

extension View {
    func familyContextMenu(_ items: @escaping () -> [FamilyMenuItem]) -> some View {
        background(FamilyContextAnchor(items: items))
    }
}

private struct FamilyContextAnchor: NSViewRepresentable {
    var items: () -> [FamilyMenuItem]
    func makeNSView(context: Context) -> FamilyContextAnchorView {
        let view = FamilyContextAnchorView()
        view.items = items
        return view
    }
    func updateNSView(_ view: FamilyContextAnchorView, context: Context) { view.items = items }
}

/// Transparent anchors do not steal selection, drag or scroll gestures. The most specific
/// visible anchor wins, so a file row takes precedence over the list's blank-area menu.
private final class FamilyContextAnchorView: NSView {
    var items: (() -> [FamilyMenuItem])?
    override var isFlipped: Bool { true }
    // SwiftUI's unclipped native hosts can report a visibleRect larger than this row.
    var hitBounds: NSRect { visibleRect.intersection(bounds) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        FamilyContextMenus.shared.register(self)
    }
}

@MainActor
private final class FamilyContextMenus {
    static let shared = FamilyContextMenus()
    private let anchors = NSHashTable<FamilyContextAnchorView>.weakObjects()
    private var monitor: Any?

    func register(_ view: FamilyContextAnchorView) {
        anchors.add(view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  let anchor = self?.anchors.allObjects.filter({ view in
                      view.items != nil && view.window === event.window && !view.isHiddenOrHasHiddenAncestor &&
                      view.hitBounds.contains(view.convert(event.locationInWindow, from: nil))
                  }).min(by: { $0.hitBounds.width * $0.hitBounds.height < $1.hitBounds.width * $1.hitBounds.height }),
                  let items = anchor.items else { return event }
            FamilyMenuPresenter.shared.show(items(), with: event, for: anchor)
            return nil
        }
    }
}
