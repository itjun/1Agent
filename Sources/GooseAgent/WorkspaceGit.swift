import AppKit
import SwiftUI

struct GitLocation: Hashable, Sendable {
    var host: String?
    var directory: String
}

struct GitChange: Identifiable, Equatable, Sendable {
    var path: String
    var status: String
    var originalPath: String?
    var lineStats: GitLineStats?
    var id: String { path }
    var displayStatus: String {
        if status == "??" { return "A" }
        if status.contains("U") || status == "AA" || status == "DD" { return status }
        if status.contains("D") { return "D" }
        if status.contains("A") { return "A" }
        if status.contains("R") { return "R" }
        if status.contains("C") { return "C" }
        if status.contains("M") { return "M" }
        return status
    }
}

/// 按路径构建一次有序目录行；展开/收起只筛选可见行，不读取文件系统。
enum GitChangeTree {
    struct Row: Identifiable, Equatable {
        var path: String
        var name: String
        var depth = 0
        var change: GitChange?
        var directoryPaths: [String] = []
        var id: String { (change == nil ? "directory:" : "file:") + path }
        func isCollapsed(in collapsed: Set<String>) -> Bool {
            directoryPaths.contains { collapsed.contains($0) }
        }
    }

    static func build(_ changes: [GitChange]) -> [Row] {
        var children: [String: [Row]] = [:]
        var directories = Set<String>()
        for change in changes {
            let components = change.path.split(separator: "/").map(String.init)
            guard let name = components.last else { continue }
            var parent = ""
            for component in components.dropLast() {
                let path = parent.isEmpty ? component : parent + "/" + component
                if directories.insert(path).inserted {
                    children[parent, default: []].append(Row(path: path, name: component))
                }
                parent = path
            }
            children[parent, default: []].append(Row(path: change.path, name: name, change: change))
        }
        var rows: [Row] = []
        func appendChildren(of parent: String, depth: Int) {
            let siblings = (children[parent] ?? []).sorted {
                if ($0.change == nil) != ($1.change == nil) { return $0.change == nil }
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
            }
            for var row in siblings {
                if row.change == nil {
                    row.directoryPaths = [row.path]
                    while let descendants = children[row.path], descendants.count == 1,
                          let child = descendants.first, child.change == nil {
                        row.name += "/" + child.name
                        row.path = child.path
                        row.directoryPaths.append(child.path)
                    }
                }
                row.depth = depth
                rows.append(row)
                if row.change == nil { appendChildren(of: row.path, depth: depth + 1) }
            }
        }
        appendChildren(of: "", depth: 0)
        return rows
    }

    static func visibleRows(_ rows: [Row], collapsed: Set<String>) -> [Row] {
        var hiddenBelow: Int?
        return rows.filter { row in
            if let depth = hiddenBelow, row.depth > depth { return false }
            hiddenBelow = row.isCollapsed(in: collapsed) ? row.depth : nil
            return true
        }
    }
}

struct GitSnapshot: Equatable, Sendable {
    var root: String
    var branch: String
    var hasHead: Bool
    var branches: [String]
    var defaultBase: String?
}

struct GitLineStats: Equatable, Sendable {
    var additions = 0
    var deletions = 0
}

/// 独立只读进程；不进入终端 stdin，不运行外部 diff、textconv 或刷新 Git 索引。
enum WorkspaceGit {
    static func run(_ arguments: [String], at location: GitLocation) async throws -> ProcessResult {
        let args = ["--no-optional-locks", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-C", location.directory] + arguments
        let process: Process
        if let host = location.host {
            process = await RemoteShell.process(alias: host, command: "LC_ALL=C GIT_TERMINAL_PROMPT=0 git " + args.map(FileRules.shellQuote).joined(separator: " "))
        } else {
            process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"
            environment["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = environment
        }
        let cancellation = FileOperationCancellation()
        let timeout = Task {
            try await Task.sleep(for: .seconds(12))
            cancellation.cancel()
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            do {
                return try await FileOperationContext.$cancellation.withValue(cancellation) {
                    try await ProcessRunner.run(process, outputLimit: 2 * 1024 * 1024)
                }
            } catch is CancellationError {
                if Task.isCancelled { throw CancellationError() }
                throw FileError.message(String(localized: "Git query timed out. Try refreshing."))
            }
        } onCancel: { cancellation.cancel() }
    }

    static func checked(_ arguments: [String], at location: GitLocation) async throws -> String {
        let result = try await run(arguments, at: location)
        guard result.status == 0 else { throw ProcessRunner.failure(result) }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    static func snapshot(at location: GitLocation) async throws -> GitSnapshot? {
        let rootResult = try await run(["rev-parse", "--show-toplevel"], at: location)
        guard rootResult.status == 0 else {
            if String(decoding: rootResult.stderr, as: UTF8.self).contains("not a git repository") { return nil }
            throw ProcessRunner.failure(rootResult)
        }
        let root = String(decoding: rootResult.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let head = try await run(["rev-parse", "--verify", "HEAD"], at: location)
        let symbolic = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"], at: location)
        let branch = symbolic.status == 0
            ? String(decoding: symbolic.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
            : String(String(decoding: head.stdout, as: UTF8.self).prefix(8))
        let names = try await checked(["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"], at: location)
        let branches = names.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
        let base = ["origin/main", "origin/master", "main", "master"].first { branches.contains($0) && $0 != branch }
            ?? branches.first { $0 != branch }
        return GitSnapshot(root: root, branch: branch, hasHead: head.status == 0, branches: branches, defaultBase: base)
    }

    static func changes(at location: GitLocation, base: String?) async throws -> [GitChange] {
        if let base {
            let comparison = try await comparisonRevision(base, at: location)
            let data = try await checked(["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-status", "-z", comparison, "--"], at: location)
            let fields = data.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
            return stride(from: 0, to: max(0, fields.count - 1), by: 2).map { GitChange(path: fields[$0 + 1], status: fields[$0]) }
        }
        let data = try await checked(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: location)
        return parseStatus(data)
    }

    static func lineStats(at location: GitLocation, snapshot: GitSnapshot, base: String?, changes: [GitChange]) async throws -> GitLineStats {
        let rows = try await WorkspaceGit.changesWithLineStats(at: location, snapshot: snapshot, base: base, changes: changes)
        return WorkspaceGit.totalLineStats(rows)
    }

    static func totalLineStats(_ changes: [GitChange]) -> GitLineStats {
        changes.reduce(into: GitLineStats()) { total, change in
            total.additions += change.lineStats?.additions ?? 0
            total.deletions += change.lineStats?.deletions ?? 0
        }
    }

    static func changesWithLineStats(at location: GitLocation, snapshot: GitSnapshot, base: String?, changes: [GitChange]) async throws -> [GitChange] {
        let revision: String
        if let base {
            revision = try await WorkspaceGit.comparisonRevision(base, at: location)
        } else if snapshot.hasHead {
            revision = "HEAD"
        } else {
            // 空仓库以空树对比工作区，避免暂存和未暂存的同一行重复计数。
            revision = try await WorkspaceGit.checked(["hash-object", "-t", "tree", "/dev/null"], at: location)
                .trimmingCharacters(in: .newlines)
        }
        let flags = ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--numstat", "-z"]
        let data = try await WorkspaceGit.checked(flags + [revision, "--"], at: location)
        let files = WorkspaceGit.parseFileNumstat(data)
        var rows = changes
        for index in rows.indices {
            try Task.checkCancellation()
            let change = rows[index]
            var stats = files[change.path] ?? GitLineStats()
            if change.status.contains("R"), let originalPath = change.originalPath, originalPath != change.path,
               let original = files[originalPath] {
                stats.additions += original.additions
                stats.deletions += original.deletions
            }
            if base == nil && change.status == "??" {
                // no-index 的退出码 1 表示存在差异；Git 自身处理二进制和末行无换行。
                let result = try await WorkspaceGit.run(flags + ["--no-index", "--", "/dev/null", change.path], at: location)
                guard result.status == 0 || result.status == 1 else { throw ProcessRunner.failure(result) }
                stats = WorkspaceGit.parseNumstat(String(decoding: result.stdout, as: UTF8.self))
            }
            rows[index].lineStats = stats
        }
        return rows
    }

    static func parseNumstat(_ data: String) -> GitLineStats {
        WorkspaceGit.parseFileNumstat(data).values.reduce(into: GitLineStats()) { total, stats in
            total.additions += stats.additions
            total.deletions += stats.deletions
        }
    }

    static func parseFileNumstat(_ data: String) -> [String: GitLineStats] {
        let records = data.split(separator: "\0", omittingEmptySubsequences: false)
        var files: [String: GitLineStats] = [:]
        var index = 0
        while index < records.count {
            let fields = records[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            if fields.count == 3 {
                var path = String(fields[2])
                if path.isEmpty {
                    // -z 的双路径记录（包括 no-index），使用目标文件名。
                    guard index + 2 < records.count else { break }
                    path = String(records[index + 2])
                    index += 2
                }
                // 二进制文件使用 “-”，不伪造文本行数。
                files[path] = GitLineStats(additions: Int(fields[0]) ?? 0, deletions: Int(fields[1]) ?? 0)
            }
            index += 1
        }
        return files
    }

    static func addedFilePatch(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        return "@@ -0,0 +1,\(lines.count) @@\n" + lines.map { "+" + $0 }.joined(separator: "\n") + "\n"
    }

    static func parseStatus(_ data: String) -> [GitChange] {
        let records = data.split(separator: "\0", omittingEmptySubsequences: true)
        var changes: [GitChange] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            if record.count >= 4 {
                let status = String(record.prefix(2))
                let isMoved = status.contains("R") || status.contains("C")
                let originalPath = isMoved && index + 1 < records.count ? String(records[index + 1]) : nil
                changes.append(GitChange(path: String(record.dropFirst(3)), status: status.trimmingCharacters(in: .whitespaces), originalPath: originalPath))
                if isMoved { index += 1 }
            }
            index += 1
        }
        return changes
    }

    private static func comparisonRevision(_ base: String, at location: GitLocation) async throws -> String {
        // 先解析到提交 ID，避免分支名被解释成选项或 revision 表达式。
        let result = try await checked(["rev-parse", "--verify", "--end-of-options", base + "^{commit}"], at: location)
        return result.trimmingCharacters(in: .newlines) + "...HEAD"
    }

    static func diff(_ change: GitChange, snapshot: GitSnapshot, at location: GitLocation, base: String?) async throws -> String {
        if change.status == "??" {
            let data = try await fileSystem(for: location.host).read(FileRules.join(snapshot.root, change.path), limit: 256 * 1024)
            guard let text = TextFile.decodePreview(data, using: nil, truncated: data.count >= 256 * 1024) else {
                return String(localized: "Binary file. Open it from Files to preview.")
            }
            let patch = WorkspaceGit.addedFilePatch(text.text)
            return data.count >= 256 * 1024
                ? patch + String(localized: "Untracked file (preview limited to 256 KiB)") : patch
        }
        let flags = ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--no-color", "--unified=3"]
        let paths = [change.path] + (change.status.contains("R") ? (change.originalPath.map { [$0] } ?? []) : [])
        if let base {
            return try await checked(flags + [try await comparisonRevision(base, at: location), "--"] + paths, at: location)
        }
        if snapshot.hasHead { return try await checked(flags + ["HEAD", "--"] + paths, at: location) }
        let emptyTree = try await WorkspaceGit.checked(["hash-object", "-t", "tree", "/dev/null"], at: location)
            .trimmingCharacters(in: .newlines)
        return try await WorkspaceGit.checked(flags + [emptyTree, "--"] + paths, at: location)
    }
}

struct GitLineStatsLabel: View {
    var stats: GitLineStats
    @Environment(\.windowChrome) private var chrome
    var body: some View {
        if stats.additions > 0 || stats.deletions > 0 {
            HStack(spacing: 4) {
                if stats.additions > 0 {
                    Text(verbatim: "+\(stats.additions)").foregroundStyle(chrome.success)
                }
                if stats.deletions > 0 {
                    Text(verbatim: "−\(stats.deletions)").foregroundStyle(chrome.danger)
                }
            }.monospacedDigit()
        }
    }
}

struct TerminalGitBadge: View {
    var tab: TerminalTab
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @Environment(\.windowChrome) private var chrome
    @State private var branch: String?
    @State private var stats: GitLineStats?
    @State private var statsError: String?
    private var location: GitLocation? {
        TerminalPaneActions.workingDirectory(of: tab).map { GitLocation(host: tab.isLocal ? nil : tab.alias, directory: $0) }
    }
    var body: some View {
        ZStack {
            Color.clear.frame(width: 1, height: 1)
            if let branch, !branch.isEmpty {
                Button {
                    model.selectOnly(tab.id, in: window)
                    window.toolGitBranchComparison = false
                    window.toolSidebarTab = .changes
                    model.updatePresentation(in: window) { $0.toolSidebarOpen = true }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                        Text(verbatim: branch).lineLimit(1).truncationMode(.middle)
                        if let stats { GitLineStatsLabel(stats: stats).fixedSize() }
                    }.font(Theme.Font.rowMeta).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(chrome.accentFill, in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).help(statsError ?? String(localized: "Show Branch Changes"))
                    .accessibilityIdentifier("workspace.branch." + tab.id.uuidString)
            }
        }
        .task(id: location) {
            branch = nil
            stats = nil
            statsError = nil
            guard let location else { return }
            while !Task.isCancelled {
                do {
                    let snapshot = try await WorkspaceGit.snapshot(at: location)
                    try Task.checkCancellation()
                    branch = snapshot?.branch
                    if snapshot == nil { stats = nil }
                    if let snapshot {
                        let root = GitLocation(host: location.host, directory: snapshot.root)
                        let changes = try await WorkspaceGit.changes(at: root, base: nil)
                        let next = try await WorkspaceGit.lineStats(at: root, snapshot: snapshot, base: nil, changes: changes)
                        try Task.checkCancellation()
                        stats = next
                    }
                    statsError = nil
                } catch {
                    if Task.isCancelled { return }
                    stats = nil
                    statsError = error.localizedDescription
                }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }
}

struct GitPreviewRequest: Equatable {
    var location: GitLocation
    var snapshot: GitSnapshot
    var change: GitChange
    var base: String?
    var revision: Int
}

/// 同一份补丁提供单栏与对齐双栏，拖动时无需再次读取 Git。
struct GitDiffDocument {
    let id = UUID()
    enum Kind { case context, added, removed, heading }
    struct Line {
        var text: String
        var oldNumber: Int?
        var newNumber: Int?
        var kind: Kind
    }
    struct Pair {
        var left: Line?
        var right: Line?
    }
    var unified: [Line] = []
    var pairs: [Pair] = []
    var isPatch = false

    init(_ text: String) {
        guard text.hasPrefix("diff --git ") || text.hasPrefix("@@ ") else {
            if !text.isEmpty {
                unified = text.components(separatedBy: "\n").map { Line(text: $0, kind: .context) }
            }
            return
        }
        var oldNumber = 0
        var newNumber = 0
        var isInHunk = false
        var removed: [Line] = []
        var added: [Line] = []
        func flush() {
            for index in 0..<max(removed.count, added.count) {
                pairs.append(Pair(left: index < removed.count ? removed[index] : nil,
                                  right: index < added.count ? added[index] : nil))
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("@@ ") {
                flush()
                let fields = raw.split(separator: " ")
                guard fields.count >= 3,
                      let oldStart = fields[1].dropFirst().split(separator: ",").first,
                      let newStart = fields[2].dropFirst().split(separator: ",").first,
                      let old = Int(oldStart), let new = Int(newStart) else { continue }
                oldNumber = old; newNumber = new
                isInHunk = true; isPatch = true
                let line = Line(text: raw, kind: .heading)
                unified.append(line); pairs.append(Pair(left: line, right: line))
            } else if isInHunk, raw.hasPrefix("-") {
                let line = Line(text: String(raw.dropFirst()), oldNumber: oldNumber, kind: .removed)
                oldNumber += 1; unified.append(line); removed.append(line)
            } else if isInHunk, raw.hasPrefix("+") {
                let line = Line(text: String(raw.dropFirst()), newNumber: newNumber, kind: .added)
                newNumber += 1; unified.append(line); added.append(line)
            } else if isInHunk, raw.hasPrefix(" ") {
                flush()
                let line = Line(text: String(raw.dropFirst()), oldNumber: oldNumber, newNumber: newNumber, kind: .context)
                oldNumber += 1; newNumber += 1
                unified.append(line); pairs.append(Pair(left: line, right: line))
            } else if raw.hasPrefix("\\ No newline") {
                // 补丁标记不消耗源文件行号，也不能拆开同一组增删行。
                continue
            } else {
                flush()
                if raw.hasPrefix("diff --git ") { isInHunk = false }
                if raw.hasPrefix("diff --git ") || raw.hasPrefix("index ") || raw.hasPrefix("--- ") || raw.hasPrefix("+++ ") { continue }
                if !raw.isEmpty {
                    let line = Line(text: raw, kind: .heading)
                    unified.append(line); pairs.append(Pair(left: line, right: line))
                }
            }
        }
        flush()
    }
    static func isSideBySide(width: CGFloat) -> Bool { width >= 760 }
}
