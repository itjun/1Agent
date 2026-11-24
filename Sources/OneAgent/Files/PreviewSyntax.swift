import Foundation
import JavaScriptCore

struct PreviewSyntaxToken: Sendable {
    let range: NSRange
    let scope: String
    var isLiteral: Bool { scope == "comment" || scope == "quote" || scope == "string" || scope.hasPrefix("string.") }
}

/// A bundled tokenizer on a serial actor. File contents are data, never evaluated as JavaScript.
/// AppKit owns all layout, drawing, scrolling, selection and accessibility.
actor PreviewSyntax {
    static let shared = PreviewSyntax()
    static let maximumLength = 512 * 1024
    private let scriptURL: URL?
    private var context: JSContext?

    init(scriptURL: URL? = Bundle.main.url(forResource: "PreviewSyntax", withExtension: "js")) {
        self.scriptURL = scriptURL
    }

    func tokens(in text: String, path: String) -> [PreviewSyntaxToken] {
        guard text.utf16.count <= Self.maximumLength, let language = Self.language(path: path, text: text) else { return [] }
        if context == nil, let scriptURL, let source = try? String(contentsOf: scriptURL, encoding: .utf8) {
            let engine = JSContext()
            engine?.evaluateScript(source, withSourceURL: scriptURL)
            if engine?.exception == nil { context = engine }
        }
        guard let context else { return [] }
        context.exception = nil
        let values = context.objectForKeyedSubscript("previewSyntaxTokens")?.call(withArguments: [text, language])?.toArray()
        guard context.exception == nil, let values else { return [] }
        let length = (text as NSString).length
        return values.compactMap { value in
            guard let fields = value as? [Any], fields.count == 3,
                  let start = fields[0] as? Int, let count = fields[1] as? Int, let scope = fields[2] as? String,
                  start >= 0, count > 0, start <= length, count <= length - start else { return nil }
            return PreviewSyntaxToken(range: NSRange(location: start, length: count), scope: scope)
        }
    }

    static func language(path: String, text: String) -> String? {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        if lower.contains("/.ssh/") && name == "config" || ["ssh_config", "sshd_config"].contains(name) { return "ssh" }
        if lower.contains("nginx") && (name.hasSuffix(".conf") || name == "nginx") { return "nginx" }
        let names = ["dockerfile": "dockerfile", "makefile": "makefile", "gnumakefile": "makefile", "hosts": "hosts",
                     ".bashrc": "bash", ".zshrc": "bash", ".profile": "bash", ".gitignore": "ini", ".env": "ini"]
        if let language = names[name] { return language }
        let extensions = [
            "py": "python", "pyw": "python", "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
            "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "typescript", "json": "json", "jsonc": "json",
            "yml": "yaml", "yaml": "yaml", "xml": "xml", "html": "xml", "htm": "xml", "vue": "xml", "svg": "xml",
            "css": "css", "scss": "css", "less": "css", "sh": "bash", "bash": "bash", "zsh": "bash", "ksh": "bash",
            "sql": "sql", "go": "go", "java": "java", "rs": "rust", "rb": "ruby", "php": "php", "lua": "lua",
            "md": "markdown", "markdown": "markdown", "ini": "ini", "cfg": "ini", "conf": "ini", "cnf": "ini", "toml": "ini",
            "env": "ini", "properties": "properties", "diff": "diff", "patch": "diff", "proto": "protobuf", "c": "c", "h": "c",
            "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "service": "ini", "socket": "ini", "timer": "ini", "dockerfile": "dockerfile"
        ]
        if let language = extensions[(name as NSString).pathExtension] { return language }
        let first = String(text.prefix(256).split(whereSeparator: { $0.isNewline }).first ?? "").lowercased()
        guard first.hasPrefix("#!") else { return nil }
        for (marker, language) in [("python", "python"), ("node", "javascript"), ("bash", "bash"), ("/sh", "bash"),
                                   ("zsh", "bash"), ("ruby", "ruby"), ("perl", "bash"), ("lua", "lua")] {
            if first.contains(marker) { return language }
        }
        return nil
    }
}

/// UTF-16 indices match NSTextView, including Chinese, emoji and CRLF files.
struct PreviewTextIndex {
    let text: NSString
    let lineStarts: [Int]
    let bracketPairs: [Int: Int]

    init(_ string: String, tokens: [PreviewSyntaxToken] = []) {
        text = string as NSString
        let units = Array(string.utf16)
        var lines = [0], pairs: [Int: Int] = [:], stack: [(UInt16, Int)] = []
        let ignored = tokens.filter(\.isLiteral).map(\.range)
        var tokenIndex = 0
        for index in units.indices {
            let unit = units[index]
            if unit == 10 || unit == 13 && (index + 1 == units.count || units[index + 1] != 10) { lines.append(index + 1) }
            while tokenIndex < ignored.count && NSMaxRange(ignored[tokenIndex]) <= index { tokenIndex += 1 }
            if tokenIndex < ignored.count && NSLocationInRange(index, ignored[tokenIndex]) { continue }
            if [40, 91, 123].contains(unit) { stack.append((unit, index)) }
            else if let opening: UInt16 = [41: 40, 93: 91, 125: 123][unit] {
                if let last = stack.last, last.0 == opening {
                    stack.removeLast(); pairs[index] = last.1; pairs[last.1] = index
                } else { stack.removeAll() }
            }
        }
        lineStarts = lines
        bracketPairs = pairs
    }

    func line(at location: Int) -> Int {
        var low = 0, high = lineStarts.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= location { low = middle } else { high = middle }
        }
        return low
    }

    func matchingBrackets(at location: Int) -> [NSRange] {
        for position in [location, location - 1] {
            if let pair = bracketPairs[position] { return [NSRange(location: position, length: 1), NSRange(location: pair, length: 1)] }
        }
        return []
    }

    func occurrences(for selection: NSRange) -> [NSRange] {
        guard text.length <= PreviewSyntax.maximumLength, selection.location != NSNotFound,
              NSMaxRange(selection) <= text.length else { return [] }
        var target = selection
        let wholeWord = selection.length == 0
        if wholeWord {
            let line = text.lineRange(for: selection)
            let regex = try! NSRegularExpression(pattern: #"[\p{L}\p{N}_$]+"#)
            guard let word = regex.matches(in: text as String, range: line).first(where: {
                $0.range.location <= selection.location && NSMaxRange($0.range) >= selection.location
            }) else { return [] }
            target = word.range
        }
        guard target.length >= (wholeWord ? 1 : 2), target.length <= 200 else { return [] }
        let needle = text.substring(with: target)
        guard needle.rangeOfCharacter(from: .newlines) == nil, !needle.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let escaped = NSRegularExpression.escapedPattern(for: needle)
        let pattern = wholeWord ? #"(?<![\p{L}\p{N}_$])"# + escaped + #"(?![\p{L}\p{N}_$])"# : escaped
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var ranges: [NSRange] = []
        regex.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { match, _, stop in
            if let match { ranges.append(match.range) }
            if ranges.count >= 1000 { stop.pointee = true }
        }
        return ranges.count > 1 ? ranges : []
    }
}
