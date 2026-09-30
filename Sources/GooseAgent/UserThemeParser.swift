import Foundation
import GhosttyTheme

/// Reads one Ghostty theme file: `key = value` lines, `#` comments, `palette = N=#hex`.
/// Kept apart from `UserThemeStore` so `make test` can compile it without AppKit.
enum UserThemeParser {
    /// Nil when `background` or `foreground` is missing or not a 6-digit hex color.
    static func parse(name: String, contents: String) -> GhosttyThemeDefinition? {
        var values: [String: String] = [:]
        var palette: [Int: String] = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = UserThemeParser.unquoted(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
            if key == "palette" {
                guard let inner = value.firstIndex(of: "="),
                      let index = Int(value[..<inner].trimmingCharacters(in: .whitespaces)) else { continue }
                let color = value[value.index(after: inner)...].trimmingCharacters(in: .whitespaces)
                palette[index] = UserThemeParser.normalizedColor(color)
            } else {
                values[key] = value
            }
        }
        guard let background = values["background"], let foreground = values["foreground"] else { return nil }
        let normalizedBackground = UserThemeParser.normalizedColor(background)
        let normalizedForeground = UserThemeParser.normalizedColor(foreground)
        if !UserThemeParser.isHexColor(normalizedBackground) || !UserThemeParser.isHexColor(normalizedForeground) {
            return nil
        }
        return GhosttyThemeDefinition(
            name: name,
            background: normalizedBackground,
            foreground: normalizedForeground,
            cursorColor: values["cursor-color"].map { UserThemeParser.normalizedColor($0) },
            cursorText: values["cursor-text"].map { UserThemeParser.normalizedColor($0) },
            selectionBackground: values["selection-background"].map { UserThemeParser.normalizedColor($0) },
            selectionForeground: values["selection-foreground"].map { UserThemeParser.normalizedColor($0) },
            palette: palette
        )
    }

    /// Ghostty accepts `F4F0E8` as well as `#F4F0E8`; the rest of the app expects the `#` form.
    static func normalizedColor(_ raw: String) -> String {
        if !raw.hasPrefix("#") && UserThemeParser.isHexColor("#" + raw) {
            return "#" + raw
        }
        return raw
    }

    static func isHexColor(_ raw: String) -> Bool {
        guard raw.hasPrefix("#") else { return false }
        let digits = raw.dropFirst()
        return digits.count == 6 && digits.allSatisfy(\.isHexDigit)
    }

    private static func unquoted(_ raw: String) -> String {
        if raw.count >= 2 && raw.hasPrefix("\"") && raw.hasSuffix("\"") {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }
}
