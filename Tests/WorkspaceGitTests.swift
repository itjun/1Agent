import AppKit
@testable import GooseAgent

@main
struct WorkspaceGitTests {
    struct Failure: Error { var message: String }
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static func git(_ args: [String], _ directory: String) async throws {
        let result = try await WorkspaceGit.run(args, at: GitLocation(directory: directory))
        try check(result.status == 0, String(decoding: result.stderr, as: UTF8.self))
    }
    static func main() async throws {
        let treeChanges = [
            GitChange(path: "README.md", status: "M", lineStats: GitLineStats(additions: 1, deletions: 1)),
            GitChange(path: "src/a.swift", status: "D", lineStats: GitLineStats(deletions: 3)),
            GitChange(path: "src/nested/a.swift", status: "??", lineStats: GitLineStats(additions: 2)),
            GitChange(path: "src/.hidden", status: "M"),
            GitChange(path: "src-other/a.swift", status: "A"),
            GitChange(path: "replace", status: "D"),
            GitChange(path: "replace/inside.txt", status: "??")
        ]
        let tree = GitChangeTree.build(treeChanges)
        try check(tree == GitChangeTree.build(Array(treeChanges.reversed())), "directory ordering is stable across refresh order")
        try check(tree.compactMap(\.change).count == treeChanges.count
                  && Set(tree.map(\.id)).count == tree.count, "tree keeps every changed file with unique identities, including file-to-directory replacement")
        try check(tree.first { $0.path == "src/nested/a.swift" }?.depth == 2
                  && tree.first { $0.path == "src/nested/a.swift" }?.change?.lineStats == GitLineStats(additions: 2), "nested leaf retains path, depth and counts")
        try check(tree.last?.path == "replace", "root files follow directory groups")
        let collapsed = GitChangeTree.visibleRows(tree, collapsed: ["src", "replace"])
        try check(!collapsed.contains { $0.path.hasPrefix("src/") || $0.path == "replace/inside.txt" }
                  && collapsed.contains { $0.path == "src-other/a.swift" }
                  && collapsed.contains { $0.path == "replace" && $0.change != nil }, "collapse hides only directory descendants")
        let nested = GitChangeTree.visibleRows(tree, collapsed: ["src/nested"])
        try check(nested.contains { $0.path == "src/a.swift" }
                  && nested.contains { $0.path == "src/.hidden" }
                  && !nested.contains { $0.path == "src/nested/a.swift" }, "nested collapse preserves siblings and hidden changed files")
        try check(GitChangeTree.visibleRows(tree, collapsed: []) == tree
                  && GitChangeTree.build([]).isEmpty, "expand restores files and empty repositories stay empty")
        let compactChanges = [
            GitChange(path: "Sources/GooseAgent/Core/Model.swift", status: "M", lineStats: GitLineStats(additions: 4, deletions: 2)),
            GitChange(path: "Sources/GooseAgent/Core/View.swift", status: "A"),
            GitChange(path: "docs/README.md", status: "M")
        ]
        let compact = GitChangeTree.build(compactChanges)
        let chain = compact.first { $0.name == "Sources/GooseAgent/Core" }!
        try check(chain.path == "Sources/GooseAgent/Core" && chain.depth == 0
                  && chain.directoryPaths == ["Sources", "Sources/GooseAgent", "Sources/GooseAgent/Core"], "single directory chains merge with their original paths")
        try check(compact.first { $0.path.hasSuffix("Model.swift") }?.depth == 1
                  && compact.first { $0.path.hasSuffix("Model.swift") }?.change == compactChanges[0], "compressed tree reduces indentation without changing file metadata")
        let compactCollapsed = GitChangeTree.visibleRows(compact, collapsed: [chain.path])
        try check(!compactCollapsed.contains { $0.change?.path.hasPrefix("Sources/") == true }
                  && compactCollapsed.contains { $0.path == "docs/README.md" }, "collapsed merged directory hides its files only")
        try check(GitChangeTree.visibleRows(compact, collapsed: ["Sources"]) == compactCollapsed,
                  "merging keeps a previously collapsed parent closed")
        var remembered: Set<String> = ["Sources", "Sources/GooseAgent"]
        remembered.subtract(chain.directoryPaths)
        try check(GitChangeTree.visibleRows(compact, collapsed: remembered) == compact, "expanding merged directory clears old collapsed ancestors")
        let withDirectFile = compactChanges + [GitChange(path: "Sources/root.swift", status: "M")]
        let unmerged = GitChangeTree.build(withDirectFile)
        try check(unmerged.contains { $0.path == "Sources" && $0.name == "Sources" }
                  && unmerged.contains { $0.name == "GooseAgent/Core" && $0.depth == 1 }, "direct files stop chain compression")
        let withSibling = compactChanges + [GitChange(path: "Sources/Other/Other.swift", status: "D")]
        try check(GitChangeTree.build(withSibling).contains { $0.path == "Sources" && $0.name == "Sources" }, "multiple child directories remain separate")
        let patch = GitDiffDocument("diff --git a/test b/test\n--- a/test\n+++ b/test\n@@ -10,4 +10,3 @@\n keep\n-old a\n-old b\n+new a\n end\n")
        try check(patch.isPatch && patch.pairs.count == 5, "replacement blocks align with empty cells")
        try check(patch.pairs[2].left?.text == "old a" && patch.pairs[2].right?.text == "new a", "paired replacement")
        try check(patch.pairs[3].left?.oldNumber == 12 && patch.pairs[3].right == nil, "unequal deletion padding")
        try check(patch.pairs[4].left?.oldNumber == 13 && patch.pairs[4].right?.newNumber == 12, "context line numbers after replacement")
        try check(patch.unified.filter { $0.kind == .removed }.count == 2, "unified preserves all removals")
        let added = GitDiffDocument("@@ -0,0 +1,2 @@\n+one\n+two\n")
        try check(added.pairs[1].left == nil && added.pairs[2].right?.newNumber == 2, "new file empty original")
        let marker = GitDiffDocument("@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n")
        try check(marker.pairs.count == 2 && marker.pairs[1].right?.newNumber == 1, "newline marker preserves pairing")
        let plain = GitDiffDocument("Untracked preview\n--- heading\n@@ - + @@\n+literal")
        try check(!plain.isPatch && plain.unified.count == 4 && plain.unified[1].text == "--- heading", "plain file preserves diff-like content")
        let malformed = GitDiffDocument("@@ - + @@")
        try check(!malformed.isPatch, "malformed hunk does not crash")
        let binary = GitDiffDocument("Binary files a/icon.png and b/icon.png differ")
        try check(!binary.isPatch && binary.unified.count == 1, "binary fallback")
        try check(!GitDiffDocument.isSideBySide(width: 759) && GitDiffDocument.isSideBySide(width: 760), "adaptive layout boundary")
        let newFile = GitDiffDocument(WorkspaceGit.addedFilePatch("one\n\n+literal\n@@ literal"))
        try check(newFile.unified.filter { $0.kind == .added }.count == 4, "all new file content is added, including blank and diff-like lines")
        try check(newFile.pairs.dropFirst().allSatisfy { $0.left == nil && $0.right?.kind == .added }, "new file has no original-side content")
        try check(GitDiffDocument(WorkspaceGit.addedFilePatch("one\n")).unified.filter { $0.kind == .added }.count == 1, "terminal newline is not an extra line")
        try check(WorkspaceGit.addedFilePatch("").isEmpty, "empty file has no added content lines")
        let numstat = WorkspaceGit.parseNumstat("3\t2\tname\twith-tab\0-\t-\tbinary\0" + "4\t0\t\0/dev/null\0new\tfile\0")
        try check(numstat == GitLineStats(additions: 7, deletions: 2), "numstat handles binary and NUL-separated paths")
        let fileStats = WorkspaceGit.parseFileNumstat("3\t2\tname\twith-tab\0-\t-\tbinary\0" + "4\t0\t\0/dev/null\0new\tfile\0")
        try check(fileStats["name\twith-tab"] == GitLineStats(additions: 3, deletions: 2)
                  && fileStats["new\tfile"] == GitLineStats(additions: 4, deletions: 0), "counts retain exact file paths")
        try check(GitChange(path: "new", status: "??").displayStatus == "A"
                  && GitChange(path: "new", status: "AM").displayStatus == "A", "untracked and staged new files display A")
        try check(GitChange(path: "changed", status: "MM").displayStatus == "M"
                  && GitChange(path: "deleted", status: "D").displayStatus == "D"
                  && GitChange(path: "conflict", status: "UU").displayStatus == "UU", "status labels preserve modified, deleted and conflicts")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneagent-git-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = GitLocation(directory: root.path)
        try check(try await WorkspaceGit.snapshot(at: location) == nil, "non-repository")
        try await git(["init", "-b", "main"], root.path)
        let unborn = try await WorkspaceGit.snapshot(at: location)!
        try check(unborn.branch == "main" && !unborn.hasHead, "unborn branch")
        let file = root.appendingPathComponent("a file.txt")
        try "first\n".write(to: file, atomically: true, encoding: .utf8)
        try await git(["add", "."], root.path)
        try "first\nsecond\n".write(to: file, atomically: true, encoding: .utf8)
        let unbornChanges = try await WorkspaceGit.changes(at: location, base: nil)
        let unbornStats = try await WorkspaceGit.lineStats(at: location, snapshot: unborn, base: nil, changes: unbornChanges)
        try check(unbornStats == GitLineStats(additions: 2, deletions: 0), "unborn stats compare complete worktree with empty tree")
        let unbornDiff = GitDiffDocument(try await WorkspaceGit.diff(unbornChanges[0], snapshot: unborn, at: location, base: nil))
        try check(unbornDiff.unified.filter { $0.kind == .added }.count == 2
                  && !unbornDiff.unified.contains { $0.kind == .removed }, "new staged file with later edits stays entirely green in an unborn repository")
        try "first\n".write(to: file, atomically: true, encoding: .utf8)
        try await git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base"], root.path)
        try await git(["checkout", "-b", "feature/check"], root.path)
        try "first\nbranch addition\n".write(to: file, atomically: true, encoding: .utf8)
        try await git(["add", "."], root.path)
        try await git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "feature"], root.path)
        let snapshot = try await WorkspaceGit.snapshot(at: location)!
        try check(snapshot.branch == "feature/check" && snapshot.defaultBase == "main", "branch/base")
        let branchChanges = try await WorkspaceGit.changes(at: location, base: "main")
        try check(branchChanges.count == 1 && branchChanges[0].path == "a file.txt", "branch changes")
        let branchDiff = try await WorkspaceGit.diff(branchChanges[0], snapshot: snapshot, at: location, base: "main")
        try check(branchDiff.contains("+branch addition"), "branch diff")
        let branchStats = try await WorkspaceGit.lineStats(at: location, snapshot: snapshot, base: "main", changes: branchChanges)
        try check(branchStats == GitLineStats(additions: 1, deletions: 0), "branch totals match branch diff")
        let branchRows = try await WorkspaceGit.changesWithLineStats(at: location, snapshot: snapshot, base: "main", changes: branchChanges)
        try check(branchRows[0].lineStats == GitLineStats(additions: 1, deletions: 0), "per-file branch counts match comparison")
        try "first\nbranch addition\nstaged\n".write(to: file, atomically: true, encoding: .utf8)
        try await git(["add", "."], root.path)
        try "first\nbranch addition\nstaged\nunstaged\n".write(to: file, atomically: true, encoding: .utf8)
        let tricky = "quote'\n$(touch should-not-exist).txt"
        try "untracked\n".write(to: root.appendingPathComponent(tricky), atomically: true, encoding: .utf8)
        let changes = try await WorkspaceGit.changes(at: location, base: nil)
        try check(changes.contains { $0.path == tricky && $0.status == "??" }, "literal newline/quote filename")
        let tracked = changes.first { $0.path == "a file.txt" }!
        let diff = try await WorkspaceGit.diff(tracked, snapshot: snapshot, at: location, base: nil)
        try check(diff.contains("+staged") && diff.contains("+unstaged"), "combined staged and unstaged")
        let untracked = try await WorkspaceGit.diff(changes.first { $0.path == tricky }!, snapshot: snapshot, at: location, base: nil)
        let untrackedDocument = GitDiffDocument(untracked)
        try check(untrackedDocument.isPatch && untrackedDocument.unified.last?.kind == .added
                  && untrackedDocument.unified.last?.newNumber == 1, "untracked preview uses green added lines and line numbers")
        let totals = try await WorkspaceGit.lineStats(at: location, snapshot: snapshot, base: nil, changes: changes)
        try check(totals == GitLineStats(additions: 3, deletions: 0), "uncommitted totals combine staged, unstaged and untracked")
        let countedRows = try await WorkspaceGit.changesWithLineStats(at: location, snapshot: snapshot, base: nil, changes: changes)
        try check(countedRows.first { $0.path == "a file.txt" }?.lineStats == GitLineStats(additions: 2, deletions: 0)
                  && countedRows.first { $0.path == tricky }?.lineStats == GitLineStats(additions: 1, deletions: 0), "per-file tracked and untracked counts do not mix")
        try check(WorkspaceGit.totalLineStats(countedRows) == totals, "file counts sum to repository totals")
        try Data([0, 1, 2, 0, 255]).write(to: root.appendingPathComponent("binary.dat"))
        try "tail".write(to: root.appendingPathComponent("tab\tname.txt"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("empty.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: file)
        let removedChanges = try await WorkspaceGit.changes(at: location, base: nil)
        let removedStats = try await WorkspaceGit.lineStats(at: location, snapshot: snapshot, base: nil, changes: removedChanges)
        try check(removedStats == GitLineStats(additions: 2, deletions: 2), "deleted tracked file and new files, binary excluded, final line without newline counted")
        let removedRows = try await WorkspaceGit.changesWithLineStats(at: location, snapshot: snapshot, base: nil, changes: removedChanges)
        try check(removedRows.first { $0.path == "a file.txt" }?.lineStats == GitLineStats(additions: 0, deletions: 2)
                  && removedRows.first { $0.path == "binary.dat" }?.lineStats == GitLineStats()
                  && removedRows.first { $0.path == "empty.txt" }?.lineStats == GitLineStats(), "deleted, binary and empty files have correct per-file counts")
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-exist").path), "no shell interpolation")
        try await git(["config", "diff.external", "touch should-not-exist"], root.path)
        _ = try await WorkspaceGit.diff(tracked, snapshot: snapshot, at: location, base: nil)
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-exist").path), "external diff disabled")
        let parsed = WorkspaceGit.parseStatus("R  new name\0old name\0 D gone\0?? new\nfile\0")
        try check(parsed.map(\.path) == ["new name", "gone", "new\nfile"], "rename/delete parsing")
        try await git(["checkout", "--detach"], root.path)
        let detached = try await WorkspaceGit.snapshot(at: location)!
        try check(detached.hasHead && detached.branch.count == 8, "detached head")
        try await git(["restore", "--source=HEAD", "--staged", "--worktree", "--", "a file.txt"], root.path)
        try await git(["mv", "a file.txt", "renamed.txt"], root.path)
        let movedChanges = try await WorkspaceGit.changes(at: location, base: nil)
        let movedRows = try await WorkspaceGit.changesWithLineStats(at: location, snapshot: detached, base: nil, changes: movedChanges)
        let moved = movedRows.first { $0.path == "renamed.txt" }!
        try check(moved.originalPath == "a file.txt" && moved.lineStats == GitLineStats(additions: 2, deletions: 2), "rename row includes original and new paths under no-renames diff")
        let movedDiff = GitDiffDocument(try await WorkspaceGit.diff(moved, snapshot: detached, at: location, base: nil))
        try check(movedDiff.unified.filter { $0.kind == .added }.count == 2
                  && movedDiff.unified.filter { $0.kind == .removed }.count == 2, "rename preview and file counts agree")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        let cancellation = FileOperationCancellation()
        do {
            _ = try await FileOperationContext.$cancellation.withValue(cancellation) {
                try await ProcessRunner.run(process, outputLimit: 1024)
            }
            throw Failure(message: "output limit did not stop process")
        } catch is FileError { }
        try check(!process.isRunning, "bounded process stopped")
        print("WorkspaceGitTests passed: branches, unborn/detached HEAD, branch diff, staged/unstaged, untracked, literal filenames, renames, external diff disabled, bounded output")
    }
}
