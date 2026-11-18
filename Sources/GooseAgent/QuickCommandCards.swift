import SwiftUI

/// 把下一张卡放在当前最短的列。测量和摆放共用同一组位置。
struct QuickCommandCardLayout: Layout {
    private let minimumWidth: CGFloat = 192
    private let spacing = Theme.Space.m

    struct Cache {
        var width: CGFloat?
        var frames: [CGRect] = []
        var height: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    private func measure(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        guard cache.width != width else { return }
        let count = max(1, Int((width + spacing) / (minimumWidth + spacing)))
        let cardWidth = (width - CGFloat(count - 1) * spacing) / CGFloat(count)
        var bottoms = Array(repeating: CGFloat.zero, count: count)
        cache = Cache(width: width)
        for view in subviews {
            let column = bottoms.indices.min { bottoms[$0] < bottoms[$1] }!
            let height = view.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil)).height
            let frame = CGRect(x: CGFloat(column) * (cardWidth + spacing), y: bottoms[column],
                               width: cardWidth, height: height)
            cache.frames.append(frame)
            cache.height = max(cache.height, frame.maxY)
            bottoms[column] = frame.maxY + spacing
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimumWidth
        measure(width: width, subviews: subviews, cache: &cache)
        return CGSize(width: width, height: cache.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        measure(width: bounds.width, subviews: subviews, cache: &cache)
        for (view, frame) in zip(subviews, cache.frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

/// 颜色只取自窗口当前的主题。命令用自己的 ID 选色，搜索和调整顺序不会让卡片变色。
struct QuickCommandCardPalette {
    struct Ink {
        let fill: Color
        let title: Color
        let body: Color
        let outline: Color
    }

    private let inks: [Ink]
    let selected: Ink

    init(chrome: WindowChrome) {
        func rgb(_ color: Color) -> RGBColor {
            let color = NSColor(color).usingColorSpace(.sRGB)!
            return RGBColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
        }
        let base = rgb(chrome.background)
        let foreground = rgb(chrome.text)
        let accent = rgb(chrome.accent)
        func ink(tint: RGBColor) -> Ink {
            let surface = base.mixed(with: tint, amount: chrome.isDark ? 0.22 : 0.14)
            let target = surface.relativeLuminance > 0.179
                ? RGBColor(red: 0, green: 0, blue: 0) : RGBColor(red: 1, green: 1, blue: 1)
            func readable(_ color: RGBColor, minimum: Double = 4.5) -> Color {
                RGBColor.ensureContrast(color, against: surface, toward: target, minimum: minimum).color
            }
            return Ink(fill: surface.color, title: readable(foreground),
                       body: readable(foreground.mixed(with: surface, amount: 0.15)),
                       outline: readable(accent, minimum: 3))
        }
        let colors = chrome.syntaxPalette ?? AppTheme.colors(isDark: chrome.isDark).ansi
        inks = [6, 3, 5, 4, 2, 1].map { ink(tint: RGBColor(ghosttyHex: colors[$0])!) }
        selected = ink(tint: accent)
    }

    func ink(for id: UUID) -> Ink {
        let index = withUnsafeBytes(of: id.uuid) { $0.reduce(0) { $0 + Int($1) } }
        return inks[index % inks.count]
    }
}

extension QuickCommand {
    var cardPreview: String {
        // 简单管道分段显示；已有换行或含引号、转义、注释的脚本保留原排版。
        guard command.rangeOfCharacter(from: CharacterSet(charactersIn: "'\"\u{0060}\\#\n")) == nil else { return command }
        return command.replacingOccurrences(of: " | ", with: " |\n")
    }
}
