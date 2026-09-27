import Darwin
import Foundation

/// One concrete `Host` alias from the user's OpenSSH config.
struct SSHHost: Identifiable, Equatable, Hashable {
    var alias: String
    var hostName: String?
    var user: String?
    var port: String?

    var id: String { alias }

    /// `user@hostname:port` when the config says more than the alias.
    var subtitle: String {
        let target = (hostName?.isEmpty == false) ? hostName! : alias
        let at = (user?.isEmpty == false) ? "\(user!)@" : ""
        let withPort = (port?.isEmpty == false && port != "22") ? "\(at)\(target):\(port!)" : "\(at)\(target)"
        if withPort == alias { return "" }
        return withPort
    }

    /// Compact label for the terminal, like `root@demo-data · 192.0.2.20`.
    var sessionBadge: String {
        let endpoint = hostName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = user?.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointText = (endpoint?.isEmpty == false) ? endpoint : nil
        let accountText = (account?.isEmpty == false) ? account : nil
        let portSuffix = (port?.isEmpty == false && port != "22") ? ":\(port!)" : ""
        if let endpointText, endpointText != alias {
            let named = accountText.map { "\($0)@\(alias)" } ?? alias
            return "\(named) · \(endpointText)\(portSuffix)"
        }
        let target = endpointText ?? alias
        let login = accountText.map { "\($0)@\(target)" } ?? target
        return login + portSuffix
    }

    /// HostName. Hidden when it repeats the alias.
    var infoAddress: String? {
        let value = hostName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty || value == alias {
            return nil
        }
        return value
    }

    var infoUser: String? {
        let value = user?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty {
            return nil
        }
        return value
    }

    /// Alias, address, then user. Empty lines are left out. Port is never included.
    var connectionCopyText: String {
        var lines: [String] = []
        let name = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            lines.append(name)
        }
        if let infoAddress {
            lines.append(infoAddress)
        }
        if let infoUser {
            lines.append(infoUser)
        }
        return lines.joined(separator: "\n")
    }
}

struct SSHConfigLoadResult: Equatable {
    var hosts: [SSHHost]
    /// The user config file itself could not be read. A missing `Include` is not a failure.
    var failed: Bool
}

/// Reads `~/.ssh/config` the way OpenSSH lists hosts: `Include` (with `~` and globs)
/// is spliced in place, and only concrete `Host` aliases become rows.
/// Wildcard and `Match` blocks still supply the first `HostName` / `User` / `Port`
/// for those aliases. Connecting later is plain `ssh <alias>`, so OpenSSH applies
/// the rest of the file itself.
enum SSHConfig {
    static var userConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    }

    static func load(from url: URL = userConfigURL) -> SSHConfigLoadResult {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return SSHConfigLoadResult(hosts: [], failed: true)
        }
        var sections: [HostSection] = []
        var order: [String] = []
        var seen = Set<String>()
        var stack = Set<String>()
        parse(
            url: url,
            sections: &sections,
            order: &order,
            seen: &seen,
            stack: &stack,
            current: nil
        )
        let hosts = order.map { resolve($0, sections: sections) }
        return SSHConfigLoadResult(hosts: hosts, failed: false)
    }

    // MARK: - Parse

    private struct HostSection {
        var patterns: [String]
        var hostName: String?
        var user: String?
        var port: String?

        func applies(to alias: String) -> Bool {
            for pattern in patterns where pattern.hasPrefix("!") && pattern.count > 1 {
                if fnmatch(String(pattern.dropFirst()), alias) { return false }
            }
            return patterns.contains { pattern in
                !pattern.hasPrefix("!") && fnmatch(pattern, alias)
            }
        }
    }

    private final class ParseCursor {
        var section: Int?
        /// Set once a `Host` or `Match` has been seen. Keywords before that apply to every host.
        var sawBlock = false
    }

    private static func parse(
        url: URL,
        sections: inout [HostSection],
        order: inout [String],
        seen: inout Set<String>,
        stack: inout Set<String>,
        current: ParseCursor?
    ) {
        let path = url.resolvingSymlinksInPath().path
        guard stack.insert(path).inserted else { return }
        defer { stack.remove(path) }

        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }

        let cursor = current ?? ParseCursor()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let tokens = tokens(in: String(rawLine))
            guard let keyword = tokens.first?.lowercased() else { continue }
            let args = Array(tokens.dropFirst())
            switch keyword {
            case "host":
                guard !args.isEmpty else { continue }
                cursor.sawBlock = true
                sections.append(HostSection(patterns: args, hostName: nil, user: nil, port: nil))
                cursor.section = sections.count - 1
                for alias in args where isConcreteAlias(alias) {
                    if seen.insert(alias).inserted {
                        order.append(alias)
                    }
                }
            case "match":
                cursor.sawBlock = true
                cursor.section = nil
            case "include":
                for pattern in args {
                    for file in expandInclude(pattern) {
                        parse(
                            url: file,
                            sections: &sections,
                            order: &order,
                            seen: &seen,
                            stack: &stack,
                            current: cursor
                        )
                    }
                }
            case "hostname":
                assignIfEmpty(\.hostName, args.first, cursor: cursor, sections: &sections)
            case "user":
                assignIfEmpty(\.user, args.first, cursor: cursor, sections: &sections)
            case "port":
                assignIfEmpty(\.port, args.first, cursor: cursor, sections: &sections)
            default:
                break
            }
        }
    }

    private static func assignIfEmpty(
        _ keyPath: WritableKeyPath<HostSection, String?>,
        _ value: String?,
        cursor: ParseCursor,
        sections: inout [HostSection]
    ) {
        guard let value, !value.isEmpty else { return }
        if cursor.section == nil {
            guard !cursor.sawBlock else { return }
            sections.append(HostSection(patterns: ["*"], hostName: nil, user: nil, port: nil))
            cursor.section = sections.count - 1
        }
        guard let index = cursor.section, sections.indices.contains(index) else { return }
        if sections[index][keyPath: keyPath] == nil {
            sections[index][keyPath: keyPath] = value
        }
    }

    /// `Host *` and `Host *.example.com` are patterns, not destinations you can `ssh` to.
    private static func isConcreteAlias(_ token: String) -> Bool {
        !token.isEmpty && !token.hasPrefix("!") && !token.contains(where: { $0 == "*" || $0 == "?" })
    }

    private static func resolve(_ alias: String, sections: [HostSection]) -> SSHHost {
        var hostName: String?
        var user: String?
        var port: String?
        for section in sections where section.applies(to: alias) {
            if hostName == nil { hostName = section.hostName }
            if user == nil { user = section.user }
            if port == nil { port = section.port }
        }
        return SSHHost(alias: alias, hostName: hostName, user: user, port: port)
    }

    /// Relative include paths are read from `~/.ssh`, matching OpenSSH's user config.
    private static func expandInclude(_ token: String) -> [URL] {
        let pattern: String
        if token.hasPrefix("/") || token.hasPrefix("~") {
            pattern = token
        } else {
            pattern = "~/.ssh/\(token)"
        }
        var paths = glob_t()
        let status = pattern.withCString { glob($0, GLOB_TILDE, nil, &paths) }
        defer { if status == 0 { globfree(&paths) } }
        guard status == 0 else { return [] }
        var files: [URL] = []
        for index in 0..<Int(paths.gl_pathc) {
            guard let cString = paths.gl_pathv[index] else { continue }
            let path = String(cString: cString)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { continue }
            files.append(URL(fileURLWithPath: path))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Splits an ssh_config line. `#` starts a comment. `Keyword=value` is one assignment.
    private static func tokens(in line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for character in line {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "#" { break }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character == "=", result.isEmpty, !current.isEmpty {
                result.append(current)
                current = ""
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

private func fnmatch(_ pattern: String, _ value: String) -> Bool {
    pattern.withCString { pattern in
        value.withCString { value in
            Darwin.fnmatch(pattern, value, FNM_NOESCAPE) == 0
        }
    }
}
