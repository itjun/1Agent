import Foundation

@main enum TerminalOutputStoreTests {
    static func main() {
        let samples: [(String, String)] = [
            ("a\r\nb\rc\n\n", "a\nb\nc"),
            ("中文🙂\t\u{7F}\u{85}é", "中文🙂\té"),
            ("\u{1b}[38;2:1:2:3m红\u{1b}[0m", "\u{1b}[38;2:1:2:3m红\u{1b}[0m"),
            ("before\u{1b}[?25lafter", "beforeafter"),
            ("before\u{1b}]2;secret\u{07}after", "beforeafter"),
            ("before\u{1b}Ppayload\u{1b}\\after", "beforeafter"),
            ("before\u{1b}[12中after", "beforeafter"),
            ("before\u{1b}中after", "beforeafter"),
            ("before\u{1b}]unfinished", "before"),
            ("before\u{1b}[31", "before")
        ]
        for (input, expected) in samples {
            let actual = TerminalOutputStore.displayText(input)
            guard actual == expected else {
                fatalError("Unexpected sanitized output: \(actual.debugDescription), expected \(expected.debugDescription)")
            }
        }

        let lines = (0..<(TerminalOutputStore.lineLimit + 5)).map { "line_\($0)" }.joined(separator: "\n")
        let tail = TerminalOutputStore.displayText(lines)
        precondition(tail.hasPrefix("line_5\n") && tail.hasSuffix("line_20004"))
        precondition(tail.split(separator: "\n").count == TerminalOutputStore.lineLimit)

        let unicode = String(repeating: "中", count: TerminalOutputStore.byteLimit / 3 + 2) + "尾"
        let bounded = TerminalOutputStore.displayText(unicode)
        precondition(bounded.utf8.count <= TerminalOutputStore.byteLimit && bounded.hasSuffix("尾"))
        precondition(!bounded.contains("\u{FFFD}"), "Byte truncation must not split a Unicode scalar")
        print("TerminalOutputStoreTests passed")
    }
}
