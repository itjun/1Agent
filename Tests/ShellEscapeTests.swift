import Foundation

@main
enum ShellEscapeTests {
    static func main() {
        expect(ShellEscape.escape("/tmp/plain.txt") == "/tmp/plain.txt", "nothing to escape")
        expect(ShellEscape.escape("/tmp/a b.txt") == "/tmp/a\\ b.txt", "space")
        expect(ShellEscape.escape("it's (1).txt") == "it\\'s\\ \\(1\\).txt", "quote and parentheses")
        expect(ShellEscape.escape("a\\b") == "a\\\\b", "a backslash is escaped once")
        expect(ShellEscape.escape("$HOME&x;y|z") == "\\$HOME\\&x\\;y\\|z", "expansion and control characters")
        expect(ShellEscape.escape("*?[a]{b}<c>`d`!#\"") == "\\*\\?\\[a\\]\\{b\\}\\<c\\>\\`d\\`\\!\\#\\\"", "globs and the rest")
        expect(ShellEscape.escape("tab\there") == "tab\\\there", "tab")
        expect(ShellEscape.escape("中文 文件.md") == "中文\\ 文件.md", "non-ASCII stays as it is")
        expect(
            ShellEscape.dropText(paths: ["/tmp/a b", "/tmp/c"]) == "/tmp/a\\ b /tmp/c",
            "several files are separated by one space"
        )
        expect(ShellEscape.dropText(paths: []) == "", "no files")
        print("ok")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    static func fail(_ message: String) -> Never {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}
