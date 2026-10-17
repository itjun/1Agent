import SwiftUI

/// Shared with 1Panel. Loaded once; matching never reads local or remote file contents.
struct FileIconCatalog: Decodable {
    struct Pattern: Decodable {
        let prefix: String?
        let suffix: String?
        let icon: String
    }

    let names: [String: String]
    let patterns: [Pattern]
    let extensions: [String: String]

    static let bundled: FileIconCatalog = {
        guard let url = Bundle.main.url(forResource: "FileIconCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(FileIconCatalog.self, from: data) else {
            assertionFailure("Missing or invalid bundled FileIconCatalog.json")
            return FileIconCatalog(names: [:], patterns: [], extensions: [:])
        }
        return catalog
    }()

    func icon(for name: String) -> String {
        let lower = name.lowercased()
        if let exact = names[lower] { return exact }
        for pattern in patterns {
            if (pattern.prefix.map { lower.hasPrefix($0) } ?? true) &&
                (pattern.suffix.map { lower.hasSuffix($0) } ?? true) {
                return pattern.icon
            }
        }
        // Longest suffix first (.d.ts before .ts); ignore the hidden-file leading dot.
        for dot in lower.indices.dropFirst() where lower[dot] == "." {
            if let icon = extensions[String(lower[lower.index(after: dot)...])] {
                return icon
            }
        }
        return "file"
    }
}

/// Original brand artwork is bundled as vector assets, including light/dark variants.
struct FileTypeIcon: View {
    let name: String

    var body: some View {
        Image("FileIcon-\(FileIconCatalog.bundled.icon(for: name))")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }
}
