import Foundation

/// 在读取或下载前按名称筛选；未知类型不交给 Quick Look 自动探测。
enum FilePreviewPolicy {
    enum Kind { case text, html, markdown, quickLook }

    static func kind(for entry: FileEntry) -> Kind? {
        let ext = (entry.name as NSString).pathExtension.lowercased()
        if entry.isDirectory {
            return ["key", "pages", "numbers"].contains(ext) ? .quickLook : nil
        }
        return kind(for: entry.name)
    }

    private static let quickLookExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif", "avif", "ico", "icns",
        "pdf", "rtf", "doc", "docx", "docm", "xls", "xlsx", "xlsm", "xlsb", "ppt", "pptx", "pptm", "pps", "ppsx", "pages", "numbers", "key", "odt", "ods", "odp",
    ]
    private static let binaryExtensions: Set<String> = [
        "jar", "war", "ear", "exe", "bin", "dll", "so", "dylib", "class", "o", "a", "lib", "pyc", "wasm",
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "zst", "lz", "lz4", "z",
        "dmg", "iso", "img", "pkg", "deb", "rpm", "apk", "aab", "app", "appimage", "db", "sqlite", "sqlite3",
    ]

    static func kind(for name: String) -> Kind? {
        let ext = (name.trimmingCharacters(in: .whitespaces).lowercased() as NSString).pathExtension
        // .env 的文本名称规则较宽，先排除 .env.jar 这类明确的二进制后缀。
        guard !binaryExtensions.contains(ext) else { return nil }
        if quickLookExtensions.contains(ext) { return .quickLook }
        if ["html", "htm"].contains(ext) { return .html }
        if ["md", "markdown", "mdown", "mkd"].contains(ext) { return .markdown }
        return TextFile.isTextName(name) ? .text : nil
    }
}
