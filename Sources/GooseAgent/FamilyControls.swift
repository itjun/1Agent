import AppKit
import SwiftUI

struct FamilyToggleStyle: ToggleStyle {
    var checkbox = false
    var showsLabel = true
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if checkbox {
            control(configuration).toggleStyle(.checkbox)
        } else {
            control(configuration).toggleStyle(.switch)
        }
    }
    @ViewBuilder private func control(_ configuration: Configuration) -> some View {
        if showsLabel {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        } else {
            Toggle(isOn: configuration.$isOn) { configuration.label }.labelsHidden()
        }
    }
}

struct FamilySegments<Value: Hashable>: View {
    @Binding var value: Value
    var options: [(Value, String)]
    @Environment(\.settingsControlTitle) private var title
    var body: some View {
        Picker(selection: $value) {
            ForEach(options, id: \.0) { Text(verbatim: $0.1).tag($0.0) }
        } label: { Text(verbatim: title ?? "") }
        .pickerStyle(.segmented).labelsHidden()
    }
}

struct FamilySlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0
    var onEditingChanged: (Bool) -> Void = { _ in }
    @Environment(\.isEnabled) private var enabled
    @Environment(\.windowChrome) private var chrome
    @Environment(\.settingsControlTitle) private var settingsControlTitle
    func makeNSView(context: Context) -> FamilySliderControl {
        let slider = FamilySliderControl()
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.isContinuous = true
        slider.onEditingChanged = { [weak coordinator = context.coordinator] in coordinator?.parent.onEditingChanged($0) }
        return slider
    }
    func updateNSView(_ slider: FamilySliderControl, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.step = step
        slider.isEnabled = enabled
        slider.setAccessibilityLabel(settingsControlTitle)
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
struct FamilyNumberInput: View {
    @Environment(\.settingsControlTitle) private var title
    @Binding var value: Int
    var range: ClosedRange<Int>
    var body: some View {
        HStack {
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text(verbatim: title ?? ""))
                .frame(width: 60)
                .onChange(of: value) { _, number in
                    value = min(max(number, range.lowerBound), range.upperBound)
                }
            Stepper(value: $value, in: range) { Text(verbatim: title ?? "") }.labelsHidden()
        }
    }
}
