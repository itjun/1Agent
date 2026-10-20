import AppKit
import SwiftUI

@main
struct PreviewSyntaxTests {
    @MainActor
    static func main() async {
        let syntax = PreviewSyntax(scriptURL: URL(fileURLWithPath: "Resources/PreviewSyntax.js"))
        let samples: [(String, String, String)] = [
            ("test.py", "import os\ndef hello(name):\n    return \"中文😀 #not a comment\" # comment\n", "keyword"),
            ("test.js", "const value = {answer: 42}; // note", "keyword"),
            ("test.ts", "interface User { name: string }", "keyword"),
            ("test.json", "{\"name\": \"中文\", \"enabled\": true}", "attr"),
            ("test.yaml", "name: agent\nenabled: true\n", "attr"),
            ("test.html", "<div class=\"test\">hello</div>", "name"),
            ("test.css", "body { color: red; }", "attribute"),
            ("test.sh", "#!/bin/bash\necho \"hello $USER\"", "built_in"),
            ("test.sql", "SELECT id FROM users WHERE id = 1;", "keyword"),
            ("test.go", "package main\nfunc main() { println(42) }", "keyword"),
            ("Test.java", "public class Test { int value = 42; }", "keyword"),
            ("test.rs", "fn main() { let value = 42; }", "keyword"),
            ("test.rb", "def hello\n puts 'hello'\nend", "keyword"),
            ("test.php", "<?php echo 'hello'; ?>", "keyword"),
            ("test.lua", "local value = 42 -- comment", "keyword"),
            ("test.md", "# Heading\n**bold**", "section"),
            ("test.ini", "[server]\nport=8080", "section"),
            ("test.properties", "name=agent", "attr"),
            ("test.diff", "--- a\n+++ b\n+added\n-removed", "addition"),
            ("test.proto", "syntax = \"proto3\";\nmessage Test { string name = 1; }", "keyword"),
            ("test.c", "int main() { return 0; }", "type"),
            ("test.cpp", "class Test { public: int value; };", "keyword"),
            ("Dockerfile", "FROM alpine\nRUN echo hello", "keyword"),
            ("Makefile", "all:\n\techo hello", "section"),
            ("/etc/nginx/nginx.conf", "server { listen 80; }", "attribute"),
            ("/etc/hosts", "127.0.0.1 localhost # note", "number"),
            ("/home/demo/.ssh/config", "Host demo\n  HostName example.test\n  Port 22", "keyword"),
        ]
        for (path, content, scope) in samples {
            let tokens = await syntax.tokens(in: content, path: path)
            expect(tokens.contains { $0.scope == scope }, "\(path) must contain \(scope) tokens")
            expect(tokens.allSatisfy { NSMaxRange($0.range) <= (content as NSString).length }, "UTF-16 ranges are bounded")
        }
        expect(PreviewSyntax.language(path: "script", text: "#!/usr/bin/env python3\nprint(42)") == "python", "shebang detection")
        let unknown = await syntax.tokens(in: "# ordinary text", path: "notes.txt")
        let large = await syntax.tokens(in: String(repeating: "x", count: PreviewSyntax.maximumLength + 1), path: "test.py")
        expect(unknown.isEmpty && large.isEmpty, "unknown and oversized files retain plain text")

        let source = "# 中文😀 (ignored)\r\nvalue = call(\"(quoted) # safe\", [42])\r\nprint(value)\r\n"
        let tokens = await syntax.tokens(in: source, path: "test.py")
        let ns = source as NSString
        let index = PreviewTextIndex(source, tokens: tokens)
        expect(index.lineStarts.count == 4, "CRLF counts as one line, including trailing empty line")
        let open = ns.range(of: "call(").location + 4
        expect(index.matchingBrackets(at: open).count == 2, "nested code brackets pair")
        expect(index.matchingBrackets(at: ns.range(of: "(quoted)").location).isEmpty, "brackets inside strings do not pair")
        expect(index.matchingBrackets(at: ns.range(of: "(ignored)").location).isEmpty, "brackets inside comments do not pair")
        let stringSpan = tokens.first { $0.scope == "string" && NSLocationInRange(ns.range(of: "# safe").location, $0.range) }
        expect(stringSpan != nil, "hash in a quoted string is not a comment")
        expect(index.occurrences(for: NSRange(location: ns.range(of: "value").location + 2, length: 0)).count == 2, "caret symbol matches whole words")
        expect(index.occurrences(for: ns.range(of: "value")).count == 2, "selected text matches")
        expect(PreviewTextIndex("value values value").occurrences(for: NSRange(location: 2, length: 0)).count == 2, "symbol matching rejects prefixes")
        expect(PreviewTextIndex("中文😀中文").occurrences(for: NSRange(location: 0, length: 2)).count == 2, "Unicode selection matches after surrogate pairs")
        expect(PreviewTextIndex("a\rb\r").lineStarts == [0, 2, 4], "legacy CR line endings")

        _ = NSApplication.shared
        let view = PreviewTextView()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = view
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        view.load(source)
        view.apply(tokens: tokens)
        let keywordSource = "import os\nprint(os)\n"
        let keywordTokens = await syntax.tokens(in: keywordSource, path: "test.py")
        view.load(keywordSource)
        view.apply(tokens: keywordTokens)
        expect(view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == PreviewCodeStyle.color(0xF92672), "native storage paints Python keywords")
        view.setSelectedRange(NSRange(location: 8, length: 0))
        expect(view.occurrenceRanges.count == 2, "native selection notification updates symbol occurrences")
        let selected = NSRange(location: 7, length: 2)
        view.setSelectedRange(selected)
        expect(view.selectedTextAttributes[.backgroundColor] as? NSColor == PreviewCodeStyle.selection, "native selected text uses visible blue")
        let board = NSPasteboard(name: NSPasteboard.Name("oneagent.preview-test.\(UUID())"))
        expect(view.selectedRange() == selected, "selection is established before native copy")
        expect(view.writeSelection(to: board, types: view.writablePasteboardTypes), "native copy writes selected text")
        expect(board.string(forType: .string) == "os", "copy contains original text without gutters or markup")
        board.releaseGlobally()
        view.apply(tokens: keywordTokens)
        expect(view.selectedRange() == selected && !view.isEditable, "asynchronous syntax styling preserves selection and read-only state")
        view.load(source)
        view.apply(tokens: tokens)
        view.setSelectedRange(NSRange(location: open, length: 0))
        expect(view.activeLine == 1 && view.matchedBrackets.count == 2, "native caret drives active line and brackets")
        let character = view.matchedBrackets.last!.location
        expect(view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: character, effectiveRange: nil) as? NSColor == PreviewCodeStyle.bracket,
               "matched bracket decoration reaches TextKit")
        view.load("x")
        expect(view.string == "x" && view.occurrenceRanges.isEmpty && view.matchedBrackets.isEmpty,
               "switching from a selected long document to a short one clears stale decoration ranges")
        let container = PreviewCodeContainer()
        container.frame = NSRect(x: 0, y: 0, width: 340, height: 180)
        container.code.load(String(repeating: "long_line ", count: 200) + "\n" + String(repeating: "line\n", count: 100))
        container.layoutSubtreeIfNeeded()
        expect(container.scroll.frame.minX >= container.code.lineGutter!.frame.maxX && container.scroll.contentView.bounds.minX == 0,
               "the native gutter stays outside the initially unscrolled code")
        container.scroll.contentView.scroll(to: NSPoint(x: 100, y: 60))
        let offset = container.scroll.contentView.bounds.origin
        container.code.apply(tokens: [])
        expect(container.scroll.contentView.bounds.origin == offset, "late highlighting preserves horizontal and vertical scroll offsets")
        var closed = false
        view.onClose = { closed = true }
        view.cancelOperation(nil)
        expect(closed, "Escape remains connected to the drawer")
        window.contentView = nil
        print("PreviewSyntaxTests passed: 27 grammars, UTF-16, native colors/selection/copy, symbol/bracket matching, plain-text fallback")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
