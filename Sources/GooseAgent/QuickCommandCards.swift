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

/// 终端代码块配色；底色较主面板微压一阶，并对各语法角色保证至少 4.5:1 的可读对比度。
struct QuickCommandCodePalette {
    let backgroundRGB: RGBColor
    let background: Color
    let plain: Color
    let command: Color
    let operatorColor: Color
    let flag: Color
    let flagValue: Color
    let stringOrVariable: Color
    let comment: Color

    init(chrome: WindowChrome) {
        func rgb(_ color: Color) -> RGBColor {
            let resolved = NSColor(color).usingColorSpace(.sRGB)!
            return RGBColor(red: resolved.redComponent, green: resolved.greenComponent, blue: resolved.blueComponent)
        }
        let pane = rgb(chrome.background)
        let sink = chrome.isDark ? RGBColor(red: 0.04, green: 0.05, blue: 0.08) : RGBColor(red: 0.88, green: 0.90, blue: 0.95)
        let surface = pane.mixed(with: sink, amount: chrome.isDark ? 0.36 : 0.34)
        let target = surface.relativeLuminance > 0.179
            ? RGBColor(red: 0, green: 0, blue: 0) : RGBColor(red: 1, green: 1, blue: 1)

        func readable(_ candidate: RGBColor, minimum: Double = 4.5) -> Color {
            RGBColor.ensureContrast(candidate, against: surface, toward: target, minimum: minimum).color
        }

        let ink = rgb(chrome.text)
        let accent = rgb(chrome.accent)
        let flagRaw = RGBColor(ghosttyHex: chrome.isDark ? "C7A4FF" : "6D28D9")!
        let valueRaw = RGBColor(ghosttyHex: chrome.isDark ? "6EE7B7" : "047857")!
        let stringRaw = RGBColor(ghosttyHex: chrome.isDark ? "FCD34D" : "B45309")!

        backgroundRGB = surface
        background = surface.color
        plain = readable(ink)
        command = readable(accent)
        operatorColor = readable(ink.mixed(with: surface, amount: 0.28))
        flag = readable(flagRaw)
        flagValue = readable(valueRaw)
        stringOrVariable = readable(stringRaw)
        comment = readable(ink.mixed(with: surface, amount: 0.36))
    }

    func color(for role: QuickCommandTokenRole) -> Color {
        switch role {
        case .plain: return plain
        case .command: return command
        case .operatorToken: return operatorColor
        case .flag: return flag
        case .flagValue: return flagValue
        case .stringOrVariable: return stringOrVariable
        case .comment: return comment
        }
    }

    static func attributedCommand(_ command: String, palette: QuickCommandCodePalette, fontSize: CGFloat = 13) -> AttributedString {
        let baseFont = Font.system(size: fontSize, design: .monospaced)
        guard command.utf8.count <= QuickCommandLexer.highlightByteLimit else {
            var plainText = AttributedString(command)
            plainText.font = baseFont
            plainText.foregroundColor = palette.plain
            return plainText
        }
        let lines = command.components(separatedBy: "\n")
        var result = AttributedString()
        for (lineIndex, line) in lines.enumerated() {
            if lineIndex > 0 {
                var newline = AttributedString("\n")
                newline.font = baseFont
                newline.foregroundColor = palette.plain
                result.append(newline)
            }
            for token in QuickCommandLexer.tokenizeLine(line) {
                var piece = AttributedString(token.text)
                if token.role == .command || token.role == .flagValue {
                    piece.font = Font.system(size: fontSize, weight: .medium, design: .monospaced)
                } else {
                    piece.font = baseFont
                }
                piece.foregroundColor = palette.color(for: token.role)
                result.append(piece)
            }
        }
        return result
    }
}

/// 代码块显示保存的原文，包含命令自身的变量和换行。
struct QuickCommandCodeBlock: View {
    let command: String
    @Environment(\.windowChrome) private var chrome

    var body: some View {
        let palette = QuickCommandCodePalette(chrome: chrome)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        Text(QuickCommandCodePalette.attributedCommand(command, palette: palette))
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("quickCommands.library.code")
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(palette.background, in: shape)
            .overlay(shape.strokeBorder(chrome.hairline, lineWidth: 1))
    }
}

/// 仅当命令包含 `--flag` 长选项时展示参数核对网格；简单短命令不展示。
struct QuickCommandParametersGrid: View {
    let parameters: [QuickCommandFlagParameter]
    @Environment(\.windowChrome) private var chrome

    var body: some View {
        let palette = QuickCommandCodePalette(chrome: chrome)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Parameters")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(chrome.secondary)
            ParameterCardLayout {
                ForEach(parameters) { parameter in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: parameter.flag)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(palette.flag)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: parameter.isFlagOnly ? String(localized: "Enabled") : parameter.value)
                            .font(parameter.isFlagOnly
                                  ? .system(size: 12, weight: .medium)
                                  : .system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(parameter.isFlagOnly ? chrome.secondary : chrome.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(chrome.elevated, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(chrome.hairline, lineWidth: 1))
                }
            }
        }
    }
}

/// 短参数保持紧凑，长参数按内容取宽；空间不足时整张卡换行。
private struct ParameterCardLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let cards = frames(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: cards.map(\.maxX).max() ?? 0, height: cards.last?.maxY ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let spacing = Theme.Space.s
        var cards: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowStart = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let cardWidth = min(width, max(144, view.sizeThatFits(.unspecified).width))
            if x > 0, x + cardWidth > width {
                for index in rowStart..<cards.count { cards[index].size.height = rowHeight }
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
                rowStart = cards.count
            }
            let size = view.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil))
            rowHeight = max(rowHeight, size.height)
            cards.append(CGRect(x: x, y: y, width: cardWidth, height: size.height))
            x += cardWidth + spacing
        }
        for index in rowStart..<cards.count { cards[index].size.height = rowHeight }
        return cards
    }
}
