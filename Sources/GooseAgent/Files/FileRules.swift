import Foundation

/// One row of a file pane, local or remote.
struct FileEntry: Identifiable, Hashable, Sendable {
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64
    /// `drwxr-xr-x` form, as `ls -l` prints it.
    var mode: String
    var modified: Date?

    var id: String { path }
    var isHidden: Bool { name.hasPrefix(".") }
}

enum FileError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// What to do when a transferred name already exists in the target folder.
enum ConflictChoice: Sendable {
    case rename
    case overwrite
}

/// Path rules shared by the local and remote file systems. Same rules as 1Panel's `sftp_browser.go`.
enum FileRules {
    private static let localTopLevel: Set<String> = [
        "System", "Applications", "Library", "Users", "Volumes", "private",
        "opt", "usr", "bin", "sbin", "etc", "var", "tmp", "dev", "cores", "home",
    ]
    private static let remoteTopLevel: Set<String> = [
        "bin", "boot", "dev", "etc", "lib", "lib64", "proc", "sbin",
        "sys", "usr", "run", "var", "opt", "tmp",
    ]

    /// Why `path` must not be deleted, or nil when it may be.
    static func deleteRefusal(_ path: String, remote: Bool, home: String?) -> String? {
        let clean = normalize(path)
        if clean == "/" || clean.isEmpty {
            return String(localized: "Refusing to delete the root folder")
        }
        if !remote, let home, normalize(home) == clean {
            return String(localized: "Refusing to delete the home folder")
        }
        let parent = (clean as NSString).deletingLastPathComponent
        let name = (clean as NSString).lastPathComponent
        if parent == "/", (remote ? remoteTopLevel : localTopLevel).contains(name) {
            return String(format: String(localized: "Refusing to delete system folder %@"), clean)
        }
        return nil
    }

    /// `/a//b/./c/` → `/a/b/c`. `..` is resolved too; nothing above `/`.
    static func normalize(_ path: String) -> String {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    static func parent(of path: String) -> String {
        let clean = normalize(path)
        guard clean != "/" else { return "/" }
        return (clean as NSString).deletingLastPathComponent
    }

    /// `name 1.ext`, `name 2.ext`…; a name without an extension gets the number at the end.
    static func numberedName(_ name: String, _ n: Int) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, name != "." + ext else { return "\(name) \(n)" }
        let base = (name as NSString).deletingPathExtension
        return "\(base) \(n).\(ext)"
    }

    /// The name each source lands as, and whether that replaces an existing item.
    /// `reserved` keeps two sources of the same batch from picking the same new name.
    /// Names in `keep` are never replaced, whatever the choice.
    static func targetNames(
        for names: [String], existing: Set<String>, choice: ConflictChoice, keep: Set<String> = []
    ) -> [(name: String, replace: Bool)] {
        var reserved: Set<String> = []
        return names.map { name in
            let taken = { (candidate: String) in reserved.contains(candidate) || existing.contains(candidate) }
            guard taken(name) else {
                reserved.insert(name)
                return (name, false)
            }
            if choice == .overwrite, !keep.contains(name) {
                reserved.insert(name)
                return (name, existing.contains(name))
            }
            var n = 1
            while taken(numberedName(name, n)) { n += 1 }
            let picked = numberedName(name, n)
            reserved.insert(picked)
            return (picked, false)
        }
    }

    /// True when `path` is `folder` itself or somewhere inside it.
    static func isSameOrInside(_ path: String, _ folder: String) -> Bool {
        let path = normalize(path)
        let folder = normalize(folder)
        return path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    /// Names that a copy on one side into `directory` must not replace: replacing one deletes a
    /// source, or a folder holding one, before it is copied. `sources` are full paths.
    static func protectedNames(_ names: [String], sources: [String], into directory: String) -> Set<String> {
        Set(names.filter { name in
            let target = join(directory, name)
            return sources.contains { isSameOrInside($0, target) }
        })
    }

    /// Why a copy on one side cannot run: an item copied into the folder it is already in, or a
    /// folder copied into itself.
    static func sameSideRefusal(sources: [(path: String, isDirectory: Bool)], into directory: String) -> String? {
        let target = normalize(directory)
        for source in sources {
            let name = (normalize(source.path) as NSString).lastPathComponent
            if parent(of: source.path) == target {
                return String(format: String(localized: "“%@” is already in this folder"), name)
            }
            if source.isDirectory, isSameOrInside(target, source.path) {
                return String(format: String(localized: "Cannot copy “%@” into itself"), name)
            }
        }
        return nil
    }

    /// POSIX single quotes, safe in any remote shell.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Remote listings

    /// `find <dir> -mindepth 1 -maxdepth 1 -printf '%y\t%Y\t%s\t%M\t%T@\t%f\0'`.
    /// `%Y` follows links, so a link to a folder opens like a folder.
    static func parseFind(_ output: String, in directory: String) -> [FileEntry] {
        output.split(separator: "\0", omittingEmptySubsequences: true).compactMap { record in
            let fields = record.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count == 6 else { return nil }
            let name = String(fields[5])
            guard !name.isEmpty, name != ".", name != ".." else { return nil }
            let seconds = Double(fields[4]).map { Date(timeIntervalSince1970: $0) }
            return FileEntry(
                name: name,
                path: join(directory, name),
                isDirectory: fields[1] == "d",
                size: Int64(fields[2]) ?? 0,
                mode: String(fields[3]),
                modified: seconds
            )
        }
    }

    /// `LC_ALL=C ls -lA <dir>` for hosts without GNU find: busybox, BSD, macOS.
    /// Times are `Mon dd HH:MM` (this year) or `Mon dd  yyyy`.
    static func parseLs(_ output: String, in directory: String, now: Date = Date()) -> [FileEntry] {
        output.split(separator: "\n").compactMap { line -> FileEntry? in
            let text = String(line)
            guard let first = text.first, "-dlcbps".contains(first) else { return nil }
            let fields = text.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 9 else { return nil }
            let mode = String(fields[0])
            let size = Int64(fields[4]) ?? 0
            let modified = lsDate(month: String(fields[5]), day: String(fields[6]), clock: String(fields[7]), now: now)
            guard let nameStart = rangeAfterFields(8, in: text) else { return nil }
            var name = String(text[nameStart...])
            var isDirectory = first == "d"
            if first == "l", let arrow = name.range(of: " -> ") {
                let target = String(name[arrow.upperBound...])
                name = String(name[..<arrow.lowerBound])
                isDirectory = target.hasSuffix("/")
            }
            guard name != ".", name != ".." else { return nil }
            return FileEntry(
                name: name,
                path: join(directory, name),
                isDirectory: isDirectory,
                size: size,
                mode: mode,
                modified: modified
            )
        }
    }

    /// Start of whatever follows the first `count` space-separated fields.
    private static func rangeAfterFields(_ count: Int, in text: String) -> String.Index? {
        var index = text.startIndex
        for _ in 0..<count {
            while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
            while index < text.endIndex, text[index] != " " { index = text.index(after: index) }
        }
        guard index < text.endIndex else { return nil }
        return text.index(after: index)
    }

    private static func lsDate(month: String, day: String, clock: String, now: Date) -> Date? {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard let monthIndex = months.firstIndex(of: month), let dayNumber = Int(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var parts = DateComponents()
        parts.month = monthIndex + 1
        parts.day = dayNumber
        if clock.contains(":") {
            let hm = clock.split(separator: ":")
            parts.hour = Int(hm.first ?? "0")
            parts.minute = Int(hm.last ?? "0")
            let year = calendar.component(.year, from: now)
            parts.year = year
            if let date = calendar.date(from: parts), date > now.addingTimeInterval(86_400) {
                parts.year = year - 1
            }
        } else {
            parts.year = Int(clock)
        }
        return calendar.date(from: parts)
    }
}
