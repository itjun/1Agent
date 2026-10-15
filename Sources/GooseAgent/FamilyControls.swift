import SwiftUI

/// 1Panel switch and checkbox drawings, using Toggle's binding and accessibility semantics.
struct FamilyToggleStyle: ToggleStyle {
    var checkbox = false
    @Environment(\.windowChrome) private var chrome
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                if checkbox {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.Radius.tag)
                            .fill(configuration.isOn ? chrome.accent : chrome.background)
                        RoundedRectangle(cornerRadius: Theme.Radius.tag)
                            .strokeBorder(configuration.isOn ? chrome.accent : chrome.lineStrong, lineWidth: 1)
                        if configuration.isOn { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white) }
                    }.frame(width: 16, height: 16)
                } else {
                    Capsule().fill(configuration.isOn ? chrome.accent : chrome.lineStrong)
                        .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                            Circle().fill(.white).frame(width: 16, height: 16).padding(2)
                        }
                        .frame(width: 36, height: 20)
                        .animation(reduceMotion ? nil : .timingCurve(0.38, 0, 0.24, 1, duration: 0.2), value: configuration.isOn)
                }
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focused($focused)
        .familyFocusRing(focused).opacity(enabled ? 1 : 0.45)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

struct FamilySegments<Value: Hashable>: View {
    @Binding var value: Value
    var options: [(Value, String)]
    @Environment(\.windowChrome) private var chrome
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Value?
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { item in
                Button { value = item.0 } label: {
                    Text(verbatim: item.1).font(.system(size: 14, weight: value == item.0 ? .semibold : .regular))
                        .foregroundStyle(value == item.0 ? chrome.accent : chrome.text)
                        .padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.tag).fill(value == item.0 ? chrome.background : .clear))
                }
                .buttonStyle(.plain).focused($focused, equals: item.0)
                .familyFocusRing(focused == item.0)
                .accessibilityAddTraits(value == item.0 ? [.isSelected] : [])
                .onMoveCommand { direction in
                    guard enabled, let index = options.firstIndex(where: { $0.0 == value }) else { return }
                    let next = direction == .left || direction == .up ? index - 1 : index + 1
                    if options.indices.contains(next) { value = options[next].0; focused = value }
                }
            }
        }.padding(2).background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(chrome.elevated))
        .opacity(enabled ? 1 : 0.45)
    }
}

/// A plain native slider supplies tracking and keyboard/VoiceOver, while its cell draws the
/// same 4px rail and 16px thumb in every app appearance.
struct FamilySlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0
    var onEditingChanged: (Bool) -> Void = { _ in }
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> FamilySliderControl {
        let slider = FamilySliderControl()
        slider.cell = FamilySliderCell()
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.isContinuous = true
        slider.focusRingType = .none
        slider.onEditingChanged = { [weak coordinator = context.coordinator] in coordinator?.parent.onEditingChanged($0) }
        return slider
    }
    func updateNSView(_ slider: FamilySliderControl, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.step = step
        slider.isEnabled = enabled
        slider.needsDisplay = true
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject {
        var parent: FamilySlider
        init(_ parent: FamilySlider) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) {
            let step = parent.step
            let number = step > 0 ? parent.range.lowerBound + ((slider.doubleValue - parent.range.lowerBound) / step).rounded() * step : slider.doubleValue
            parent.value = min(max(number, parent.range.lowerBound), parent.range.upperBound)
        }
    }
}

final class FamilySliderControl: NSSlider {
    var onEditingChanged: (Bool) -> Void = { _ in }
    var step: Double = 0
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 32) }
    override func mouseDown(with event: NSEvent) {
        onEditingChanged(true)
        super.mouseDown(with: event)
        onEditingChanged(false)
    }
    override func keyDown(with event: NSEvent) {
        let delta = step > 0 ? step : (maxValue - minValue) / 100
        switch event.keyCode {
        case 123, 125: doubleValue = max(minValue, doubleValue - delta)
        case 124, 126: doubleValue = min(maxValue, doubleValue + delta)
        case 116: doubleValue = min(maxValue, doubleValue + delta * 10)
        case 121: doubleValue = max(minValue, doubleValue - delta * 10)
        case 115: doubleValue = minValue
        case 119: doubleValue = maxValue
        default: super.keyDown(with: event); return
        }
        sendAction(action, to: target)
        needsDisplay = true
    }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
}
private final class FamilySliderCell: NSSliderCell {
    private var chrome: WindowChrome { WindowChrome(isDark: controlView?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) }
    override var knobThickness: CGFloat { 16 }
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSColor(chrome.hairline).setFill(); NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let fraction = (doubleValue - minValue) / max(0.00001, maxValue - minValue)
        let filled = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: 4)
        NSColor(chrome.accent).setFill(); NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }
    override func drawKnob(_ rect: NSRect) {
        let knob = NSRect(x: rect.midX - 7, y: rect.midY - 7, width: 14, height: 14)
        if controlView?.window?.firstResponder === controlView {
            NSColor(chrome.focus).setFill(); NSBezierPath(ovalIn: knob.insetBy(dx: -3, dy: -3)).fill()
        }
        NSColor(chrome.background).setFill(); NSBezierPath(ovalIn: knob).fill()
        NSColor(chrome.accent).setStroke(); let ring = NSBezierPath(ovalIn: knob); ring.lineWidth = 2; ring.stroke()
    }
}

struct FamilyNumberInput: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    @Environment(\.windowChrome) private var chrome
    @FocusState private var focused: Bool
    @State private var draft = ""
    var body: some View {
        HStack(spacing: 0) {
            Button { commit(value - 1) } label: { Image(systemName: "minus").frame(width: 28, height: 32) }
                .disabled(value <= range.lowerBound).accessibilityLabel(Text("Decrease"))
            TextField("", text: $draft).textFieldStyle(.plain).multilineTextAlignment(.center)
                .font(.system(size: 14, design: .monospaced)).frame(width: 40)
                .focused($focused).onSubmit { commitDraft() }
                .onMoveCommand { direction in commit(value + (direction == .up ? 1 : direction == .down ? -1 : 0)) }
            Button { commit(value + 1) } label: { Image(systemName: "plus").frame(width: 28, height: 32) }
                .disabled(value >= range.upperBound).accessibilityLabel(Text("Increase"))
        }
        .buttonStyle(FamilyButtonStyle()).foregroundStyle(chrome.text)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(focused ? chrome.background : chrome.elevated))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(focused ? chrome.accent : .clear, lineWidth: 1))
        .familyFocusRing(focused)
        .onAppear { draft = String(value) }.onChange(of: value) { _, number in draft = String(number) }
        .onChange(of: focused) { _, active in if !active { commitDraft() } }
    }
    private func commitDraft() { commit(Int(draft) ?? value) }
    private func commit(_ number: Int) { value = min(max(number, range.lowerBound), range.upperBound); draft = String(value) }
}
