import Foundation

/// Window material is independent of the terminal's saved theme and Ghostty configuration.
struct WindowMaterialSettings: Equatable {
    enum Style: String, CaseIterable {
        case acrylic
        case mica
        case solid
    }

    static let styleKey = "appearance.windowMaterial"
    static let opacityKey = "appearance.acrylicOpacity"
    static let opacityRange: ClosedRange<Double> = 0.5 ... 0.95
    static let defaultOpacity = 0.78

    var style: Style = .acrylic
    var opacity: Double = defaultOpacity

    static func load(from defaults: UserDefaults = .standard) -> Self {
        let style = defaults.string(forKey: styleKey).flatMap(Style.init(rawValue:)) ?? .acrylic
        // Reuse a saved translucent background on upgrade, without rewriting that preference.
        let legacy = defaults.object(forKey: TerminalSettings.backgroundOpacityKey) as? Double
        let saved = defaults.object(forKey: opacityKey) as? Double
        let opacity = saved ?? legacy.flatMap { $0 < 1 ? $0 : nil } ?? defaultOpacity
        return Self(style: style, opacity: clampedOpacity(opacity))
    }

    static func clampedOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultOpacity }
        return min(max(value, opacityRange.lowerBound), opacityRange.upperBound)
    }

    func effectiveOpacity(reduceTransparency: Bool) -> Double {
        style == .acrylic && !reduceTransparency ? Self.clampedOpacity(opacity) : 1
    }

    /// Mica's terminal composites onto an opaque app-owned foundation. A clear terminal layer
    /// does not make the window transparent or reveal windows underneath it.
    func terminalOpacity(reduceTransparency: Bool) -> Double {
        if style == .mica && !reduceTransparency { return 0 }
        return effectiveOpacity(reduceTransparency: reduceTransparency)
    }

    /// Always write the effective opacity last. Solid mode and accessibility must also win over
    /// legacy settings or an advanced snippet, otherwise an opaque window can still have clear panes.
    func terminalEntries(settings: TerminalSettings, snippet: [TerminalConfigEntry], reduceTransparency: Bool) -> [TerminalConfigEntry] {
        (settings.configEntries() + snippet).filter { $0.key != "background-opacity" } + [
            TerminalConfigEntry(key: "background-opacity", value: TerminalSettings.literal(terminalOpacity(reduceTransparency: reduceTransparency), maximumFractionDigits: 3)),
        ]
    }
}
