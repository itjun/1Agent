import Foundation

/// `gooseagent://open?host=<alias>&host=<alias>` from another app, such as 1Pannel.
enum ExternalOpen {
    static func hostAliases(from url: URL) -> [String] {
        guard url.scheme?.lowercased() == "gooseagent" else { return [] }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return []
        }
        var aliases: [String] = []
        for item in items where item.name == "host" {
            let alias = item.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if alias.isEmpty || alias.contains(where: \.isNewline) { continue }
            aliases.append(alias)
        }
        return aliases
    }
}
