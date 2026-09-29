import Foundation

/// What another app (1Panel) asked for through `oneagent://open?…`.
///
/// Query parameters, all optional except that at least one `host` or a `group` must be present:
/// - `host=<alias>` (repeatable): SSH config aliases to open.
/// - `group=<name>`: every alias declared in `~/.ssh/config.d/<name>.conf`.
/// - `reuse=1`: an alias that is already open is focused instead of opened again.
/// - `layout=columns|rows|grid|leadingSide|leadingTop`: arrangement when two or more open together.
/// - `name=<title>`: sidebar title of the workspace created for two or more hosts.
/// - `window=new`: open in a fresh window instead of the key one.
struct ExternalOpenRequest: Equatable {
    var hosts: [String] = []
    var group: String?
    var reuse = false
    var layout: WorkspaceLayout?
    var name: String?
    var newWindow = false

    var isEmpty: Bool {
        hosts.isEmpty && (group?.isEmpty ?? true)
    }
}

enum ExternalOpen {
    /// Nil for any other scheme or path. Blank and multi-line aliases are dropped.
    static func request(from url: URL) -> ExternalOpenRequest? {
        guard url.scheme?.lowercased() == "oneagent" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let action = (components.host ?? "").lowercased()
        guard action == "open" else { return nil }
        var request = ExternalOpenRequest()
        for item in components.queryItems ?? [] {
            let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch item.name.lowercased() {
            case "host":
                if value.isEmpty || value.contains(where: \.isNewline) { continue }
                request.hosts.append(value)
            case "group":
                if !value.isEmpty {
                    request.group = value
                }
            case "reuse":
                request.reuse = ExternalOpen.isTrue(value)
            case "layout":
                request.layout = WorkspaceLayout(rawValue: value)
            case "name":
                if !value.isEmpty {
                    request.name = value
                }
            case "window":
                request.newWindow = value.lowercased() == "new"
            default:
                continue
            }
        }
        return request
    }

    /// Just the `host` aliases, for callers that do not care about the rest.
    static func hostAliases(from url: URL) -> [String] {
        ExternalOpen.request(from: url)?.hosts ?? []
    }

    private static func isTrue(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return lowered == "1" || lowered == "true" || lowered == "yes" || lowered.isEmpty
    }
}
