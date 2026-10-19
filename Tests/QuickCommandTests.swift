import Foundation
import AppKit

@main
struct QuickCommandTests {
    @MainActor static func main() throws {
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--startup-command" {
            let item = QuickCommand(alias: "Fixture", command: CommandLine.arguments[4], scope: .local)
            let request = try QuickCommandRunRequest(item: item, context: QuickCommandContext(), directory: CommandLine.arguments[3])
            print(request.startupCommand(shell: CommandLine.arguments[2]))
            return
        }
        try transferTests()
        try orderingTests()
        let local = QuickCommandContext(sessionID: "a#0", directory: "/work/project", isLive: true)
        var item = QuickCommand(alias: "Pull", command: "python project.py git pull", directory: "/work/project")
        assert(item.matches(local))
        assert(!item.matches(QuickCommandContext(host: "dev", directory: "/work/project")))
        assert(!item.matches(QuickCommandContext(directory: "/work/project-two")))
        assert(!item.matches(QuickCommandContext(directory: "/work/project/child")))
        item.includesSubdirectories = true
        assert(item.matches(QuickCommandContext(directory: "/work/project/child")))
        assert(!item.matches(QuickCommandContext(directory: "/work/project-two")))
        assert(!item.matches(QuickCommandContext()))
        assert(item.executionDirectory(in: QuickCommandContext(directory: "/work/project/child")) == "/work/project")
        item.needsRepair = true
        assert(!item.matches(local))
        item.needsRepair = false
        let encoded = try QuickCommandLibrary(commands: [item]).encoded()
        let decoded = try QuickCommandLibrary.decode(encoded)
        assert(decoded.commands == [item])
        var newer = QuickCommandLibrary(commands: [item]); newer.version = 99
        do { _ = try QuickCommandLibrary.decode(newer.encoded()); fatalError("unknown version accepted") } catch {}
        do { _ = try QuickCommandLibrary.decode(QuickCommandLibrary(commands: [item, item]).encoded()); fatalError("duplicate ids accepted") } catch {}
        assert(QuickCommandMerge.merge(existing: [item], incoming: [item], choices: [:]) == [item])
        var changed = item; changed.command = "pwd"
        assert(QuickCommandMerge.merge(existing: [item], incoming: [changed], choices: [:]) == [item])
        assert(QuickCommandMerge.merge(existing: [item], incoming: [changed], choices: [item.id: .replace]) == [changed])
        let copies = QuickCommandMerge.merge(existing: [item], incoming: [changed], choices: [item.id: .copy])
        assert(copies.count == 2 && copies[1].id != item.id)
        var invalid = item; invalid.command = "echo hi\u{1b}[31m"
        do { _ = try invalid.validated(); fatalError("control accepted") } catch {}
        let zsh = CommandHistoryParser.parse(Data(": 1700000000:0;git status\n: 1700000001:0;git status\n: 1700000002:0;echo one\\\necho two\n".utf8), format: .zsh, truncated: false)
        assert(zsh.parsedCount == 3 && zsh.candidates.count == 2)
        assert(zsh.candidates.first?.count == 2)
        assert(zsh.candidates.contains { $0.command == "echo one\necho two" })
        let bash = CommandHistoryParser.parse(Data("#1700000000\necho one\necho two\n#1700000001\npwd\n".utf8), format: .bash, truncated: false)
        assert(bash.candidates.count == 2)
        assert(bash.candidates.contains { $0.command == "echo one\necho two" })
        let fish = CommandHistoryParser.parse(Data("- cmd: echo one\\necho two\n  when: 1700000000\n  paths:\n    - /not/a/cwd\n".utf8), format: .fish, truncated: false)
        assert(fish.candidates.count == 1 && fish.candidates[0].command == "echo one\necho two")
        let partial = CommandHistoryParser.parse(Data("broken record\ncontinuation\n- cmd: pwd\n  when: 1700000000\n".utf8), format: .fish, truncated: true)
        assert(partial.candidates.count == 1 && partial.truncated)
        let large = (0..<6000).map { "echo \($0)" }.joined(separator: "\n")
        assert(CommandHistoryParser.parse(Data(large.utf8), format: .bash, truncated: false).parsedCount == 5000)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("quick-command-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = QuickCommandStore(url: temp.appendingPathComponent("commands.json"))
        try store.save(item)
        assert(QuickCommandStore(url: store.url).commands.first?.command == item.command)
        try Data("bad".utf8).write(to: store.url)
        let broken = QuickCommandStore(url: store.url)
        do { try broken.save(item); fatalError("corrupt library overwritten") } catch {}
        let preserved = try Data(contentsOf: store.url)
        assert(String(data: preserved, encoding: .utf8) == "bad")
        var presentation = WorkspacePresentation()
        assert(!presentation.toolSidebarOpen && presentation.toolSidebarWidth == 350)
        presentation.toolSidebarOpen = true; presentation.toolSidebarWidth = 410
        let restored = try JSONDecoder().decode(WorkspacePresentation.self, from: JSONEncoder().encode(presentation))
        assert(restored == presentation)
        for removedTab in ["files", "info"] {
            var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(presentation)) as! [String: Any]
            payload["toolSidebarTab"] = removedTab
            let migrated = try JSONDecoder().decode(WorkspacePresentation.self, from: JSONSerialization.data(withJSONObject: payload))
            assert(migrated == presentation, "removed tabs must not change sidebar visibility, sizing or file layout")
            let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as! [String: Any]
            assert(saved["toolSidebarTab"] == nil, "obsolete tab selection is no longer persisted")
        }
        let old = try JSONDecoder().decode(WorkspacePresentation.self, from: Data("{\"presentationVersion\":4}".utf8))
        assert(!old.toolSidebarOpen)
        assert(ToolSidebarLayout.visibleWidth(detailWidth: 650, open: true, filesMode: false, preferred: 350) == 0)
        assert(ToolSidebarLayout.visibleWidth(detailWidth: 750, open: true, filesMode: false, preferred: 350) == 349)
        assert(ToolSidebarLayout.visibleWidth(detailWidth: 900, open: true, filesMode: true, preferred: 350) == 0)
        let scriptItem = QuickCommand(alias: "Script", command: "printf '%s\\n' '你好'; exit 7", scope: .local)
        let request = try QuickCommandRunRequest(item: scriptItem, context: local, directory: "/tmp")
        assert(request.currentShellCommand.contains("builtin cd -- '/tmp'"))
        assert(request.startupCommand(shell: "/bin/zsh").contains("exec /bin/sh -c"))
        try QuickCommandExecution.claim(request.id)
        do { try QuickCommandExecution.claim(request.id); fatalError("duplicate delivery accepted") } catch {}
        var remoteItem = item; remoteItem.host = "remote"
        do { _ = try QuickCommandRunRequest(item: remoteItem, context: local, directory: "/tmp"); fatalError("wrong host accepted") } catch {}
        print("Quick command model, migration, history, storage and layout tests passed")
    }
}

extension QuickCommandTests {
    @MainActor static func orderingTests() throws {
        func check(_ condition: Bool, _ message: String = "Unexpected command order") { precondition(condition, message) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("command-order-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QuickCommandStore(url: root.appendingPathComponent("commands.json"))
        let first = QuickCommand(alias: "A", command: "printf a", scope: .host, host: "dev", order: 5)
        let hidden = QuickCommand(alias: "Hidden", command: "printf hidden", scope: .host, host: "other", order: 8)
        let second = QuickCommand(alias: "B", command: "printf b", scope: .host, host: "dev", order: 10)
        let last = QuickCommand(alias: "C", command: "printf c", scope: .host, host: "dev", order: 10)
        let common = QuickCommand(alias: "Common", command: "pwd", scope: .all, order: 2)
        let originals = [common, last, second, hidden, first] // Storage order differs from display order.
        try store.replace(originals)
        func ids() -> [UUID] { store.commands.sorted(by: QuickCommand.displayOrder).map(\.id) }
        check(try store.move(last.id, relativeTo: first.id, after: false))
        check(ids() == [last.id, first.id, hidden.id, second.id, common.id])
        check(try store.move(last.id, relativeTo: second.id, after: true))
        check(ids() == [first.id, hidden.id, second.id, last.id, common.id])
        check(QuickCommandStore(url: store.url).commands.sorted(by: QuickCommand.displayOrder).map(\.id) == ids())
        for original in originals {
            var saved = store.commands.first { $0.id == original.id }!
            saved.order = original.order
            check(saved == original, "Only ordering may change; preserve scripts and host/folder bindings")
        }
        let snapshot = try Data(contentsOf: store.url)
        check(try !store.move(first.id, relativeTo: first.id, after: true))
        check(try !store.move(last.id, relativeTo: second.id, after: true))
        check(try !store.move(first.id, relativeTo: common.id, after: false))
        check(try !store.move(UUID(), relativeTo: first.id, after: false))
        check(try Data(contentsOf: store.url) == snapshot, "No-op or stale/cross-group drops must not rewrite storage")
        print("Quick command ordering: upward/downward moves, hidden rows, ties, persistence, unchanged bindings and no-op drops passed")
    }

    @MainActor static func transferTests() throws {
        func rejects(_ action: () throws -> Void) {
            do { try action(); fatalError("invalid transfer accepted") } catch {}
        }
        let original = QuickCommand(alias: "查看仓库", command: "source ./init.sh && python project.py\nprintf '%s\\n' hello",
                                    group: "sample-project", directory: "/Users/source/sample-project", includesSubdirectories: true)
        var second = original; second.id = UUID(); second.alias = "拉取代码"
        let transfer = try QuickCommandTransfer(commands: [original, second])
        let encoded = try transfer.encoded()
        assert(!String(decoding: encoded, as: UTF8.self).contains("/Users/source"))
        let decodedTransfer = try QuickCommandTransfer.decode(encoded)
        assert(decodedTransfer == transfer)
        let target = QuickCommandContext(host: "fixture-build") // Unknown remote cwd, as in the screenshot.
        let request = try QuickCommandPasteRequest(transfer: transfer, context: target)
        let copies = try request.copies(existing: [original, second])
        assert(copies.count == 2 && copies[0].id != original.id && copies[1].id != second.id)
        assert(copies[0].command == original.command && copies[0].group == original.group)
        assert(copies.map(\.alias) == [original.alias, second.alias])
        assert(copies.allSatisfy { $0.scope == .host && $0.host == target.host && $0.directory == nil && !$0.includesSubdirectories })
        assert(copies.allSatisfy { $0.matches(target) && !$0.matches(QuickCommandContext(host: "demo-raven")) })
        assert(copies[1].order == copies[0].order + 1)
        assert(original.directory == "/Users/source/sample-project" && original.host == nil)
        let repeated = try request.copies(existing: [original, second] + copies)
        assert(repeated[0].alias == original.alias + String(localized: " (Copy)"))
        assert(repeated[0].id == copies[0].id) // Stable identities within one open dialog.
        let nextRequest = try QuickCommandPasteRequest(transfer: transfer, context: target)
        let again = try nextRequest.copies(existing: copies + repeated)
        assert(again[0].id != copies[0].id)
        assert(again[0].alias == original.alias + String(format: String(localized: " (Copy %lld)"), Int64(2)))
        let folder = try request.copies(existing: copies, directory: "/root/sample-project/", includesSubdirectories: true)
        assert(folder[0].alias == original.alias && folder[0].directory == "/root/sample-project")
        assert(!folder[0].matches(target))
        assert(folder[0].matches(QuickCommandContext(host: "fixture-build", directory: "/root/sample-project/sub")))
        let sameFolder = try request.copies(existing: folder, directory: "/root/sample-project")
        assert(sameFolder[0].alias != original.alias && !sameFolder[0].includesSubdirectories)
        let localRequest = try QuickCommandPasteRequest(transfer: QuickCommandTransfer(commands: copies), context: QuickCommandContext())
        let back = try localRequest.copies(existing: [])
        assert(back.allSatisfy { $0.scope == .local && $0.host == nil && $0.directory == nil })
        let other = try QuickCommandPasteRequest(transfer: QuickCommandTransfer(commands: copies), context: QuickCommandContext(host: "other"))
        let otherCopies = try other.copies(existing: [])
        assert(otherCopies[0].host == "other")
        rejects { _ = try request.copies(existing: [], directory: "~/unresolved") }
        rejects { _ = try QuickCommandTransfer(commands: []) }
        var version = transfer; version.version = 2
        rejects { _ = try QuickCommandTransfer.decode(JSONEncoder().encode(version)) }
        rejects { _ = try QuickCommandTransfer.decode(Data("hello".utf8)) }
        var bad = original; bad.command += "\u{1b}"
        rejects { _ = try QuickCommandTransfer(commands: [bad]) }
        var long = original; long.alias = String(repeating: "长", count: 200)
        let longRequest = try QuickCommandPasteRequest(transfer: QuickCommandTransfer(commands: [long, long, long]), context: target)
        let longCopies = try longRequest.copies(existing: [])
        assert(Set(longCopies.map(\.alias)).count == 3 && longCopies.allSatisfy { $0.alias.count <= 200 })
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("1agent-transfer-test-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        try QuickCommandClipboard.copy([original, second], to: pasteboard)
        assert(pasteboard.string(forType: .string) == transfer.plainText)
        let snapshot = try QuickCommandClipboard.read(from: pasteboard)
        pasteboard.clearContents(); pasteboard.setString("plain text", forType: .string)
        rejects { _ = try QuickCommandClipboard.read(from: pasteboard) }
        assert(snapshot == transfer) // Opening the dialog pins content even if clipboard changes.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("command-transfer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QuickCommandStore(url: root.appendingPathComponent("commands.json"))
        try store.replace([original, second])
        let before = try Data(contentsOf: store.url)
        _ = try request.copies(existing: store.commands) // Preview/cancel performs no writes.
        let afterPreview = try Data(contentsOf: store.url)
        assert(afterPreview == before)
        try store.replace(store.commands + copies)
        assert(QuickCommandStore(url: store.url).commands == store.commands)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        assert((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let committed = store.commands
        // Invalid batch is rejected before touching the existing file.
        rejects { try store.replace(committed + [bad]) }
        assert(store.commands == committed && QuickCommandStore(url: store.url).commands == committed)
        // Force failure at the atomic rename, after successfully writing the private temp file.
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        rejects { try store.replace(committed + again) }
        assert(store.commands == committed)
        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
        assert(remainingFiles == ["commands.json"])
        print("Quick command transfer: clipboard, rebinding, conflicts, cancellation and atomic storage passed")
    }
}
