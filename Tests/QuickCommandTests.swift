import Foundation

@main
struct QuickCommandTests {
    @MainActor static func main() throws {
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--startup-command" {
            let item = QuickCommand(alias: "Fixture", command: CommandLine.arguments[4], scope: .local)
            let request = try QuickCommandRunRequest(item: item, context: QuickCommandContext(), directory: CommandLine.arguments[3])
            print(request.startupCommand(shell: CommandLine.arguments[2]))
            return
        }
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
        presentation.toolSidebarOpen = true; presentation.toolSidebarTab = "files"; presentation.toolSidebarWidth = 410
        let restored = try JSONDecoder().decode(WorkspacePresentation.self, from: JSONEncoder().encode(presentation))
        assert(restored == presentation)
        let old = try JSONDecoder().decode(WorkspacePresentation.self, from: Data("{\"presentationVersion\":4}".utf8))
        assert(!old.toolSidebarOpen && old.toolSidebarTab == "commands")
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
