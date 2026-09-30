import Foundation
import GhosttyTheme

@main
enum UserThemeParserTests {
    static func main() {
        let full = """
        # Claude Paper
        # comment line

        background = #F4F0E8
        foreground = #302E2B
        cursor-color = #C96F4A
        selection-background = #DDD6CA
        palette = 0=#3A3835
        palette = 15=#FAF7F1
        """
        let paper = UserThemeParser.parse(name: "Claude Paper", contents: full)
        expect(paper?.name == "Claude Paper", "name comes from the file name")
        expect(paper?.background == "#F4F0E8", "background with #")
        expect(paper?.foreground == "#302E2B", "foreground with #")
        expect(paper?.cursorColor == "#C96F4A", "cursor color")
        expect(paper?.cursorText == nil, "missing cursor text stays nil")
        expect(paper?.selectionBackground == "#DDD6CA", "selection background")
        expect(paper?.palette[0] == "#3A3835", "palette 0")
        expect(paper?.palette[15] == "#FAF7F1", "palette 15")
        expect(paper?.palette.count == 2, "only listed palette entries")

        let bare = """
        background=F4F0E8
        foreground = 302e2b
        palette = 1 = B95747
        cursor-color = C96F4A
        """
        let noHash = UserThemeParser.parse(name: "Bare", contents: bare)
        expect(noHash?.background == "#F4F0E8", "background without # gets one")
        expect(noHash?.foreground == "#302e2b", "foreground without # gets one")
        expect(noHash?.palette[1] == "#B95747", "palette without # gets one")
        expect(noHash?.cursorColor == "#C96F4A", "cursor without # gets one")

        let commentedBackground = """
        # background = #000000
        foreground = #FFFFFF
        """
        expect(UserThemeParser.parse(name: "X", contents: commentedBackground) == nil, "commented background does not count")
        expect(UserThemeParser.parse(name: "X", contents: "foreground = #FFFFFF") == nil, "missing background is nil")
        expect(UserThemeParser.parse(name: "X", contents: "background = #000000") == nil, "missing foreground is nil")
        expect(UserThemeParser.parse(name: "X", contents: "background = nope\nforeground = #FFFFFF") == nil, "non-hex background is nil")
        expect(UserThemeParser.parse(name: "X", contents: "") == nil, "empty file is nil")

        expect(UserThemeParser.normalizedColor("abcdef") == "#abcdef", "normalize bare hex")
        expect(UserThemeParser.normalizedColor("#abcdef") == "#abcdef", "keep # hex")
        expect(UserThemeParser.normalizedColor("black") == "black", "leave names alone")
        expect(!UserThemeParser.isHexColor("#+12345"), "sign is not a hex digit")

        print("UserThemeParserTests passed")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAIL: \(message)")
            exit(1)
        }
    }
}
