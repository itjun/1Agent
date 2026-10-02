import Foundation

/// Reading a file as text for the preview drawer: which encoding and line ending it uses, and
/// the UTF-8 + LF form it can be converted to.
enum TextFile {
    enum Encoding: Equatable {
        case utf8
        case utf8BOM
        case utf16LE
        case utf16BE
        case gb18030
        case latin1

        var label: String {
            switch self {
            case .utf8: return "UTF-8"
            case .utf8BOM: return "UTF-8 BOM"
            case .utf16LE: return "UTF-16 LE"
            case .utf16BE: return "UTF-16 BE"
            case .gb18030: return "GB18030"
            case .latin1: return "ISO-8859-1"
            }
        }
    }

    enum LineEnding: Equatable {
        case lf
        case crlf
        case cr
        case mixed
        case none

        var label: String {
            switch self {
            case .lf: return "LF"
            case .crlf: return "CRLF"
            case .cr: return "CR"
            case .mixed: return String(localized: "Mixed")
            case .none: return "—"
            }
        }
    }

    struct Decoded: Equatable {
        var text: String
        var encoding: Encoding
        var lineEnding: LineEnding

        var isUTF8LF: Bool {
            encoding == .utf8 && (lineEnding == .lf || lineEnding == .none)
        }
    }

    private static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "mdx", "rst", "log", "csv", "tsv",
        "json", "jsonc", "json5", "xml", "html", "htm", "css", "scss", "less", "sass",
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts", "vue", "svelte", "astro",
        "py", "pyi", "rb", "php", "go", "rs", "java", "kt", "kts", "scala", "groovy",
        "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm", "cs", "swift",
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "sql",
        "yml", "yaml", "toml", "ini", "cfg", "conf", "config", "properties", "env",
        "gitignore", "gitattributes", "dockerignore", "editorconfig", "npmrc", "nvmrc",
        "nginx", "service", "timer", "socket", "plist", "gradle", "mod", "sum",
        "svg", "tex", "r", "lua", "pl", "pm", "ex", "exs", "erl", "hs", "clj", "vim",
        "mk", "cmake", "tf", "hcl", "proto", "graphql", "gql", "htaccess",
        "diff", "patch", "reg", "desktop", "spec", "lock",
    ]
    private static let textNames: Set<String> = [
        "makefile", "dockerfile", "containerfile", "license", "readme", "changelog",
        "authors", "copying", "gemfile", "rakefile", "procfile", "vagrantfile",
        "jenkinsfile", "brewfile", "hosts", "crontab",
        ".gitignore", ".gitattributes", ".dockerignore", ".editorconfig",
        ".npmrc", ".yarnrc", ".nvmrc", ".bashrc", ".zshrc", ".profile",
        ".bash_profile", ".vimrc", ".gitconfig", ".env",
    ]

    /// Same list as 1Panel's `isTextFileName`: archives and images never open as text.
    static func isTextName(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lower.isEmpty, lower != ".", lower != ".." else { return false }
        if textNames.contains(lower) || lower.hasPrefix(".env") { return true }
        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex,
              lower.index(after: dot) != lower.endIndex else { return false }
        return textExtensions.contains(String(lower[lower.index(after: dot)...]))
    }

    /// Nil for binary data: a NUL byte outside UTF-16.
    static func decode(_ data: Data) -> Decoded? {
        let bytes = [UInt8](data.prefix(4))
        let encoding: Encoding
        let text: String?
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8BOM
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LE
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BE
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else {
            guard !data.contains(0) else { return nil }
            if let utf8 = String(data: data, encoding: .utf8) {
                encoding = .utf8
                text = utf8
            } else if let gb = String(data: data, encoding: gb18030) {
                encoding = .gb18030
                text = gb
            } else {
                encoding = .latin1
                text = String(data: data, encoding: .isoLatin1)
            }
        }
        guard let text else { return nil }
        return Decoded(text: text, encoding: encoding, lineEnding: lineEnding(of: text))
    }

    static func lineEnding(of text: String) -> LineEnding {
        var crlf = 0
        var lf = 0
        var cr = 0
        var previousCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if previousCR {
                    crlf += 1
                    cr -= 1
                } else {
                    lf += 1
                }
                previousCR = false
            } else {
                if scalar == "\r" { cr += 1 }
                previousCR = scalar == "\r"
            }
        }
        let kinds = [crlf, lf, cr].filter { $0 > 0 }.count
        if kinds == 0 { return .none }
        if kinds > 1 { return .mixed }
        if crlf > 0 { return .crlf }
        return lf > 0 ? .lf : .cr
    }

    /// Larger files are uploaded as they are, as in 1Panel.
    static let uploadConversionLimit = 8 * 1024 * 1024

    /// Worth reading before an upload: a known text name, or a name without an extension (scripts).
    static func mayConvertOnUpload(name: String) -> Bool {
        isTextName(name) || (name as NSString).pathExtension.isEmpty
    }

    /// The decoded text when `data` is text that is not yet UTF-8 + LF, else nil. Without a known
    /// text name, bytes that only decode as Latin-1 count as binary.
    static func uploadConversion(name: String, data: Data) -> Decoded? {
        guard !data.isEmpty, data.count <= uploadConversionLimit, mayConvertOnUpload(name: name),
              let decoded = decode(data), !decoded.isUTF8LF else { return nil }
        if decoded.encoding == .latin1, !isTextName(name) { return nil }
        return decoded
    }

    /// UTF-8 without a BOM, every line ending as LF.
    static func utf8LF(_ text: String) -> Data {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return Data(normalized.utf8)
    }

    private static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
    ))
}
