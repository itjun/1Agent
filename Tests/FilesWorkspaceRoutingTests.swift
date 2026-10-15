import AppKit
import Foundation
import ObjectiveC
import SwiftUI
@testable import GooseAgent

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

/// SwiftUI's unclipped AppKit backgrounds can report visibility outside their own bounds.
private final class UnclippedFileAnchor: NSView {
    override var isFlipped: Bool { true }
    override var visibleRect: NSRect { bounds.insetBy(dx: -2000, dy: -2000) }
}

/// Use a missing, isolated home to exercise a first-list failure without SSH or user data.
private struct FolderLoadFixture: FileSystem {
    let folder: String
    var host: String? { nil }
    func home() async throws -> String { folder }
    func list(_ directory: String) async throws -> [FileEntry] { try await LocalFileSystem().list(directory) }
    func existingNames(in directory: String, among names: [String]) async throws -> Set<String> { try await LocalFileSystem().existingNames(in: directory, among: names) }
    func makeDirectory(_ path: String) async throws { try await LocalFileSystem().makeDirectory(path) }
    func createFile(_ path: String) async throws { try await LocalFileSystem().createFile(path) }
    func delete(_ paths: [String]) async throws { try await LocalFileSystem().delete(paths) }
    func read(_ path: String, limit: Int) async throws -> Data { try await LocalFileSystem().read(path, limit: limit) }
    func write(_ data: Data, to path: String) async throws { try await LocalFileSystem().write(data, to: path) }
    func copy(_ path: String, to target: String) async throws { try await LocalFileSystem().copy(path, to: target) }
    func resolveFolders(_ paths: [String]) async -> [String] { await LocalFileSystem().resolveFolders(paths) }
}

@main
private struct FilesWorkspaceRoutingTests {
    @MainActor
    static func main() async {
        do {
            try await run()
            print("FilesWorkspaceRoutingTests passed")
        } catch {
            fputs("FilesWorkspaceRoutingTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let home = environment["ONEAGENT_TEST_HOME"],
              home.hasPrefix("/private/tmp/oneagent-files-routing."),
              URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
                == URL(fileURLWithPath: home).resolvingSymlinksInPath(),
              FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
                == URL(fileURLWithPath: home).resolvingSymlinksInPath() else {
            throw TestFailure(description: "A temporary isolated home is required")
        }
        let suiteName = "oneagent.files-routing.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName),
              let getter = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults")) else {
            throw TestFailure(description: "Could not install isolated defaults")
        }
        let getterBlock: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(getter, imp_implementationWithBlock(getterBlock))
        try require(UserDefaults.standard === defaults, "UserDefaults.standard must use the isolated suite")
        try require(defaults.data(forKey: "session.openTabs") == nil, "The test must not read a real saved session")
        try require(defaults.data(forKey: FileBrowserStore.tabsKey) == nil, "The file store must start isolated")

        // Check the guard before creating any production model that could request remote work.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        probe.arguments = ["--", "fixture-a", "pwd"]
        let probeOutput = Pipe()
        probe.standardOutput = probeOutput
        try probe.run()
        probe.waitUntilExit()
        try require(probe.terminationStatus == 0, "Remote fixture probe must succeed")
        let probeText = String(decoding: probeOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try require(probeText == "/fixture-startup-directory\n", "SSH must be intercepted before launch")

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let model = AppModel()
        let state = model.mainWindow
        try require(MainWindowManager.shared.window(for: state) == nil, "The test must not mount the production window")

        // Exercise the real RootView: a passing model-only test cannot catch missing chrome.
        let chromeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                    styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        chromeWindow.contentView = NSHostingView(rootView: RootView(model: model, window: state))
        chromeWindow.orderFront(nil)
        try await settle()
        chromeWindow.contentView?.layoutSubtreeIfNeeded()
        let labels = accessibilityLabels(chromeWindow.contentView!)
        try require(labels.contains(String(localized: "Terminal")) && labels.contains(String(localized: "Files")),
                    "The real SwiftUI toolbar must be reachable through the fixture's accessibility tree")
        try verifySingleFilesEntry(chromeWindow, visible: false)
        try await verifyFamilyFolderPicker(window: chromeWindow, home: home)
        for layout in [FileWorkspaceLayout.belowTerminal, .sideBySide, .belowTerminal] {
            model.selectFilesLayout(layout, in: state)
            try await settle()
            chromeWindow.contentView?.layoutSubtreeIfNeeded()
            try verifySingleFilesEntry(chromeWindow, visible: true)
            try require(!state.presentation.filesDockVisible && state.presentation.fullFilesWorkspace,
                        "Every legacy layout request must open the one independent file page")
        }
        // The real file view must retain its scroll target when the page is removed and remounted.
        let initialFiles = model.fileWorkspace(for: state)
        let initialLocal = initialFiles.localColumn
        for number in 0..<60 {
            let path = home + String(format: "/scroll-fixture-%02d.txt", number)
            try Data().write(to: URL(fileURLWithPath: path))
        }
        initialLocal.refresh()
        try await eventually("list isolated scroll fixtures") { initialLocal.entries.filter { $0.name.hasPrefix("scroll-fixture-") }.count == 60 }
        initialLocal.filter = "scroll-fixture-"
        initialLocal.sortKey = .name
        initialLocal.ascending = true
        initialLocal.showHidden = true
        initialLocal.scrollAnchor = home + "/scroll-fixture-30.txt"
        try await settle()
        let savedScrollAnchor = initialLocal.scrollAnchor
        try require(savedScrollAnchor != nil, "The real ScrollView must retain a visible-row anchor")
        model.hideFiles(in: state)
        try await settle()
        try verifySingleFilesEntry(chromeWindow, visible: false)
        model.selectFilesLayout(.sideBySide, in: state)
        try await settle()
        try require(initialFiles.localColumn === initialLocal && initialLocal.filter == "scroll-fixture-"
                    && initialLocal.showHidden && initialLocal.sortKey == .name && initialLocal.ascending,
                    "Ordinary page switches must retain filter, sort and visibility")
        try require(initialLocal.scrollAnchor == savedScrollAnchor, "Remounting the file page must retain its scroll anchor")
        model.hideFiles(in: state)
        try await settle()
        try await verifyFolderLoadStates(window: chromeWindow, workspace: initialFiles, folder: home + "/retry-empty-folder")
        chromeWindow.orderOut(nil)
        chromeWindow.contentView = nil

        model.openRemoteTerminal("fixture-a", at: "/remote/a-terminal", placement: .newTab, beside: UUID(), in: state)
        try await eventually("create host A") { model.tabs.count == 1 }
        let hostA = model.tabs[0]
        model.noteWorkingDirectory("/remote/a-terminal", forSession: hostA.sessionID)
        model.openRemoteTerminal("fixture-b", at: "/remote/b-terminal", placement: .newTab, beside: hostA.id, in: state)
        try await eventually("create host B") { model.tabs.count == 2 }
        let hostB = model.tabs.first { $0.alias == "fixture-b" }!
        model.noteWorkingDirectory("/remote/b-terminal", forSession: hostB.sessionID)
        let localA = home + "/local-a"
        let localB = home + "/local-b"
        model.openLocalTerminal(at: localA, placement: .newTab, beside: hostB.id, in: state)
        try await eventually("create local A") { model.tabs.count == 3 }
        let local = model.tabs.first { $0.isLocal }!

        model.selectOnly(hostA.id, in: state)
        model.selectFilesLayout(.sideBySide, in: state)
        let workspace = model.fileWorkspace(for: state)
        try require(workspace.remoteColumn == nil,
                    "Ordinary Files navigation must not bind to the selected terminal")
        model.showFiles(for: hostA.id, in: state)
        try await eventually("explicitly reveal host A cwd") {
            workspace.remoteColumn?.fileSystem.host == "fixture-a" && workspace.remoteColumn?.directory == "/remote/a-terminal"
        }
        let remoteA = workspace.remoteColumn!
        remoteA.open("/remote/a-browsed")
        try await eventually("browse host A") { remoteA.directory == "/remote/a-browsed" }

        model.hideFiles(in: state)
        model.selectOnly(hostB.id, in: state)
        model.selectFilesLayout(.sideBySide, in: state)
        try require(workspace.remoteColumn === remoteA && remoteA.directory == "/remote/a-browsed",
                    "Ordinary Files navigation must retain the chosen server and browsed directory")
        model.showFiles(for: hostB.id, in: state)
        try await eventually("explicitly reveal host B cwd") {
            workspace.remoteColumn?.fileSystem.host == "fixture-b" && workspace.remoteColumn?.directory == "/remote/b-terminal"
        }
        let remoteB = workspace.remoteColumn!
        try require(workspace.remoteTabs.contains { $0 === remoteA }, "Explicit navigation must retain other server locations")
        try await verifyFilePanePointerFocus(model: model, state: state, workspace: workspace, window: chromeWindow)

        let oldLocalDirectory = workspace.localColumn.directory
        model.hideFiles(in: state)
        model.selectOnly(local.id, in: state)
        model.noteWorkingDirectory(localB, forSession: local.sessionID)
        model.selectFilesLayout(.sideBySide, in: state)
        try require(workspace.remoteColumn === remoteB && workspace.localColumn.directory == oldLocalDirectory,
                    "Selecting a local terminal must not change either file endpoint")
        model.showFiles(for: local.id, in: state)
        try await eventually("explicitly reveal local terminal cwd") {
            workspace.focusedColumn === workspace.localColumn && workspace.localColumn.directory == localB
        }
        try require(workspace.remoteColumn === remoteB, "Local reveal must preserve the right server")

        // All former presentation entry points reuse one fixed pair and the original sessions.
        let localColumn = workspace.localColumn
        localColumn.open(localA)
        try await eventually("browse local independently of terminal cwd") { localColumn.directory == localA }
        let sessionIDs = model.tabs.map(\.sessionID)
        let fileIDs = workspace.allTabs.map(\.id)
        for layout in [FileWorkspaceLayout.belowTerminal, .sideBySide, .belowTerminal] {
            model.selectFilesLayout(layout, in: state)
            try require(!state.presentation.filesDockVisible && state.presentation.fullFilesWorkspace && state.section == .files,
                        "Legacy choices must normalize to the independent page")
        }
        model.hideFiles(in: state)
        try require(!state.presentation.filesVisible && state.section == .terminals,
                    "Terminal navigation must release the Files page")
        model.selectOnly(hostB.id, in: state)
        model.toggleSection(in: state)
        try require(workspace.remoteColumn === remoteB && workspace.localColumn === localColumn && localColumn.directory == localA,
                    "Ordinary shortcut navigation must preserve both browsing endpoints")
        try require(workspace.allTabs.map(\.id) == fileIDs && model.tabs.map(\.sessionID) == sessionIDs,
                    "Navigation must preserve file identities and running terminal sessions")

        model.openHostPicker(in: state, purpose: .files)
        try require(state.hostPickerPresented && state.hostPickerPurpose == .files, "File picker must record file purpose")
        model.openFilesTabs(hosts: ["fixture-a"], in: state)
        try await settle()
        try require(!state.hostPickerPresented && workspace.remoteColumn === remoteA && remoteA.directory == "/remote/a-browsed",
                    "Host picker must reuse that server's last browsed location")
        try require(model.tabs.map(\.sessionID) == sessionIDs, "Choosing a file server must never create a terminal session")
        model.hideFiles(in: state)
        model.notePaneFocused(hostB.id, in: state)
        model.selectFilesLayout(.sideBySide, in: state)
        try require(workspace.remoteColumn === remoteA && remoteA.directory == "/remote/a-browsed",
                    "Changing terminal pane focus must not retarget the independent Files page")

        // Mount process-free terminal views to make an accidental asynchronous focus observable.
        let native = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: native.contentLayoutRect)
        native.contentView = container
        let fileInput = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        container.addSubview(fileInput)
        var terminalFocuses = 0
        for tab in model.tabs {
            let view = SSHTerminalRegistry.view(for: tab.sessionID) { SSHTerminalNSView(frame: .zero) }!
            view.onFocus = {
                terminalFocuses += 1
                model.notePaneFocused(tab.id, in: state)
            }
            container.addSubview(view)
        }
        model.selectOnly(hostA.id, in: state)
        try await settle()
        try require(terminalFocuses > 0 && native.firstResponder is SSHTerminalNSView,
                    "The focus probe must detect normal terminal activation")
        model.selectFilesLayout(.sideBySide, in: state)
        try require(native.makeFirstResponder(fileInput), "The file input must accept keyboard focus")
        model.focusFiles(in: state)
        terminalFocuses = 0

        let selections: [(String, () -> Void)] = [
            ("selectOnly", { model.selectOnly(hostA.id, in: state, focusTerminal: false) }),
            ("selectTab", { model.selectTab(hostB.id, in: state, focusTerminal: false) }),
            ("plain sidebar", { model.clickSidebar(hostA.id, command: false, shift: false, in: state, focusTerminal: false) }),
            ("command sidebar", { model.clickSidebar(hostB.id, command: true, shift: false, in: state, focusTerminal: false) }),
            ("shift sidebar", { model.clickSidebar(hostA.id, command: false, shift: true, in: state, focusTerminal: false) })
        ]
        for (name, selection) in selections {
            selection()
            try await settle()
            try require(state.section == .files && state.presentation.filesVisible, "\(name) must keep file mode")
            try require(native.firstResponder === fileInput && terminalFocuses == 0, "\(name) must not focus a hidden terminal")
        }

        model.selectOnly(hostA.id, in: state, focusTerminal: false)
        model.showFiles(for: hostA.id, in: state, preserveRemoteDirectory: true)
        try await settle()
        try require(workspace.focusedColumn === remoteA && remoteA.directory == "/remote/a-browsed",
                    "Explicit preserve-directory routing must retain that server's browsed directory")
        model.hideFiles(in: state)
        // Drain the explicit terminal-mode focus before testing the next Files transition.
        try await settle()
        model.toggleSection(in: state)
        try require(state.presentation.fullFilesWorkspace && remoteA.directory == "/remote/a-browsed",
                    "The existing shortcut must use the same entry and preserve browsing state")
        model.showFiles(for: hostA.id, in: state)
        try await eventually("Explicit host routing follows terminal cwd") { remoteA.directory == "/remote/a-terminal" }

        native.orderOut(nil)
        try await verifyFileTabLayout(model: model, state: state)
        try await verifyTerminalAccessibility(model: model, state: state, window: chromeWindow)
        try await verifyHostPickerAccessibility(model: model, state: state, window: chromeWindow, home: home)
        for tab in model.tabs { SSHTerminalRegistry.destroy(tab.sessionID) }
        native.orderOut(nil)
        defaults.removePersistentDomain(forName: suiteName)
        print("ok: independent Files navigation; explicit cwd reveal; host picker without terminals; hidden-terminal focus guard")
        print("ok: one real RootView Files entry and one file page; legacy dock normalization; paths and sessions preserved")
        print("ok: restoration leaves live input available; explicit history follows selected session; switching panels/pages retains native terminal identity and size")
        print("ok: modal host accessibility connects the selection; Files browsing creates no terminal")
        print("ok: isolated defaults/home; fake remote responses; real SSH and network denied by sandbox")
    }

    @MainActor
    private static func verifyFileTabLayout(model: AppModel, state: WindowState) async throws {
        let localID = UUID(), remoteID = UUID()
        var saved = FileWorkspaceSnapshot()
        saved.layout = .split(SplitNode(id: UUID(), axis: .vertical, ratio: 0.5,
                                       leading: .leaf(localID), trailing: .leaf(remoteID)))
        saved.groups = [
            .init(id: localID, tabs: [.init(host: nil, path: NSHomeDirectory())], active: 0),
            .init(id: remoteID, tabs: [
                .init(host: "fixture-a", path: "/remote/a-browsed", selection: ["/remote/a-browsed/file.txt"], filter: "file"),
                .init(host: "fixture-b", path: "/remote/b-browsed"),
                .init(host: "fixture-c", path: "/remote/c-browsed")
            ], active: 0)
        ]
        let files = FileWorkspace(saved: saved, model: model, window: state, loadImmediately: false)
        try verifyFileTabHitTesting(FileWorkspace(saved: saved, model: model, window: state, loadImmediately: false))
        try await verifyFileTabMenu(FileWorkspace(saved: saved, model: model, window: state, loadImmediately: false))
        let local = files.localColumn, a = files.remoteTabs[0], b = files.remoteTabs[1], c = files.remoteTabs[2]
        let originalIDs = Set(files.allTabs.map(\.id))
        var snapshot: FileWorkspaceSnapshot?
        files.onChange = { snapshot = $0 }
        files.reorder(c, toward: a)
        try require(files.remoteTabs.map(\.id) == [c.id, a.id, b.id], "Dragging reorders the existing file tabs")
        let firstGroup = files.remoteGroupID
        files.drop(a, on: firstGroup, edge: .bottom)
        let lowerGroup = files.groupID(of: a)!
        try require(files.groupIDs.count == 3 && lowerGroup != firstGroup, "An edge drop splits a remote tab into its own pane")
        files.drop(b, on: lowerGroup, edge: .right)
        try require(files.groupIDs.count == 4 && Set(files.allTabs.map(\.id)) == originalIDs,
                    "Nested horizontal and vertical splits retain every column identity")
        try require(files.localColumn === local && files.localColumn.savedPath == NSHomeDirectory()
                    && a.savedPath == "/remote/a-browsed" && a.filter == "file" && a.selection == ["/remote/a-browsed/file.txt"],
                    "Dragging must preserve browsing paths, selection, filter and the local pane")
        files.activate(a)
        files.activate(local)
        guard let snapshot else { throw TestFailure(description: "Layout changes must be saved") }
        let roundtrip = try JSONDecoder().decode(FileWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
        let restored = FileWorkspace(saved: roundtrip, model: model, window: state, loadImmediately: false)
        try require(roundtrip.hasRestorableLayout && restored.layout == files.layout && restored.groupIDs == files.groupIDs,
                    "Restart must retain the split tree, pane identity and tab order")
        try require(restored.remoteColumn?.fileSystem.host == "fixture-a" && restored.focusedColumn === restored.localColumn,
                    "Local focus must preserve the last remote destination across restart")
        files.drop(a, on: firstGroup, edge: .center, before: c)
        try require(files.groups[lowerGroup] == nil && files.groups[firstGroup]?.tabs.map(\.id) == [a.id, c.id],
                    "Joining a tab strip inserts at the requested position and removes the emptied pane")
        files.close(b)
        try require(files.groupIDs.count == 2 && files.remoteColumn === a, "Closing a split's last tab collapses only that split")
        files.close(c)
        files.close(a)
        try require(files.remoteTabs.isEmpty && files.remoteColumn == nil && files.groupIDs.count == 2
                    && files.localColumn === local, "Closing the last remote tab keeps a usable local/remote page")
        try require(!files.canDrop(local, on: files.remoteGroupID, edge: .center), "Local navigation remains in its dedicated pane")
        print("ok: file tab reorder, nested splits, merge, close and layout restoration preserve browsing state")
    }

    @MainActor
    private static func verifyFileTabHitTesting(_ files: FileWorkspace) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let root = UnclippedFileAnchor(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        window.contentView = root
        defer { window.contentView = nil }
        let tracker = FileTabDragTracker()
        let remoteID = files.remoteGroupID
        for (index, id) in files.groupIDs.enumerated() {
            let pane = UnclippedFileAnchor(frame: NSRect(x: index * 500, y: 0, width: 500, height: 600))
            let strip = UnclippedFileAnchor(frame: NSRect(x: 0, y: 0, width: 500, height: 40))
            root.addSubview(pane)
            pane.addSubview(strip)
            tracker.panes[id] = AnchorBox(pane)
            tracker.strips[id] = AnchorBox(strip)
            for (tabIndex, column) in (files.groups[id]?.tabs ?? []).enumerated() {
                let handle = UnclippedFileAnchor(frame: NSRect(x: tabIndex * 120, y: 0, width: 100, height: 40))
                strip.addSubview(handle)
                tracker.tabs[column.id] = FileTabDragTracker.Entry(view: handle, column: column)
            }
        }
        let a = files.remoteTabs[0], b = files.remoteTabs[1], c = files.remoteTabs[2]
        let last = tracker.tabs[c.id]!.view!
        let tabPoint = last.convert(NSPoint(x: 50, y: 20), to: nil)
        tracker.dragMoved(a, to: tabPoint, in: files)
        tracker.dragMoved(a, to: tabPoint, in: files)
        try require(files.remoteTabs.map(\.id) == [a.id, b.id, c.id] && tracker.zone?.reordering == true,
                    "Repeated pointer updates must show an insertion marker without changing the target geometry")
        tracker.dragEnded(a, at: tabPoint, in: files)
        try require(files.remoteTabs.map(\.id) == [b.id, c.id, a.id],
                    "Unclipped neighboring tabs must not steal the pointer from the hovered tab")
        let pane = tracker.panes[remoteID]!.view!
        let bottomPoint = pane.convert(NSPoint(x: 250, y: 550), to: nil)
        tracker.dragMoved(a, to: bottomPoint, in: files)
        try require(tracker.zone?.group == remoteID && tracker.zone?.edge == .bottom,
                    "The header's oversized visibleRect must not swallow a drop near the pane bottom")
        tracker.dragEnded(a, at: bottomPoint, in: files)
        try require(files.groupIDs.count == 3 && files.groupID(of: a) != remoteID,
                    "A native pane target must produce a real split on release")
        print("ok: native file tab hit testing respects bounds even when visibleRect extends beyond the view")
    }

    @MainActor
    private static func verifyFileTabMenu(_ files: FileWorkspace) async throws {
        let column = files.remoteTabs[0]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: FileTabButton(workspace: files, column: column,
                                                        groupID: files.remoteGroupID, tabDrag: FileTabDragTracker()))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await settle()
        host.layoutSubtreeIfNeeded()
        func handle(_ view: NSView) -> FileTabHandleView? {
            (view as? FileTabHandleView) ?? view.subviews.compactMap(handle).first
        }
        guard let native = handle(host) else {
            throw TestFailure(description: "The real file tab must expose its native handle")
        }
        try require(!native.menuItems.contains(where: { $0.title == String(localized: "Close Tab") }),
                    "The file tab context menu must not offer Close Tab")
        try require(native.menuItems.last?.isSeparator == false, "The menu must not end with a separator")
        guard let open = native.menuItems.first(where: { $0.title == String(localized: "Open in Terminal") }),
              let model = files.model, let state = files.windowState else {
            throw TestFailure(description: "File tabs must expose their own directory action")
        }
        try require(!open.enabled, "Opening a terminal is disabled until a directory is known")
        column.start(at: "/remote/menu-target")
        try await eventually("load menu target") { column.directory == "/remote/menu-target" }
        files.activate(files.remoteTabs[1])
        try await settle()
        let oldSessions = Set(model.tabs.map(\.id))
        guard let loadedOpen = native.menuItems.first(where: { $0.title == String(localized: "Open in Terminal") }) else {
            throw TestFailure(description: "Loaded tab lost its menu")
        }
        try require(loadedOpen.enabled, "A loaded directory enables its terminal action")
        loadedOpen.action()
        try await eventually("open terminal from inactive file tab") { model.tabs.contains { !oldSessions.contains($0.id) } }
        let created = model.tabs.first { !oldSessions.contains($0.id) }!
        try require(created.alias == column.fileSystem.host && created.remoteDirectory == column.directory,
                    "Right-clicking an inactive file tab must open that host and folder")
        model.closeTab(created.id)
        model.selectFilesLayout(.sideBySide, in: state)
        native.requestClose()
        try await eventually("file tab close confirmation") { window.childWindows?.contains(where: { $0 is FamilyModalWindow }) == true }
        try require(files.allTabs.contains(where: { $0 === column }), "Requesting close must leave the tab open")
        let cancelledSheet = window.childWindows!.first { $0 is FamilyModalWindow }!
        cancelledSheet.cancelOperation(nil)
        try await eventually("dismiss cancelled close") { window.childWindows?.contains(where: { $0 is FamilyModalWindow }) != true }
        try require(files.allTabs.contains(where: { $0 === column }), "Cancel must retain the tab and its directory")
        native.requestClose()
        try await eventually("confirm file tab close again") { window.childWindows?.contains(where: { $0 is FamilyModalWindow }) == true }
        let dialog = window.childWindows!.first { $0 is FamilyModalWindow }!
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let confirm = descendants(dialog.contentView!).compactMap { $0 as? FamilyNativeButton }.first { $0.tag == 0 }!
        confirm.performClick(nil)
        try await eventually("close confirmed file tab") { !files.allTabs.contains(where: { $0 === column }) }
        try require(!files.allTabs.contains(where: { $0 === column }) && files.remoteTabs.count == 2,
                    "Confirming close must close only the requested file tab")
        print("ok: file tab close button requires confirmation; Cancel preserves the tab; context menu has no close action")
    }

    @MainActor
    private static func verifyTerminalAccessibility(model: AppModel, state: WindowState, window: NSWindow) async throws {
        let emptyHistoryTab = model.tabs[0]
        try require(SSHTerminalRegistry.history(for: emptyHistoryTab.sessionID) == nil,
                    "The empty-history fixture must have no saved archive")
        model.hideFiles(in: state)
        model.toggleTerminalHistory(for: emptyHistoryTab.id, in: state)
        window.contentView = NSHostingView(rootView: RootView(model: model, window: state))
        window.orderFront(nil)
        try await settle()
        let emptyElements = accessibilityElements(window.contentView!)
        guard let emptyClose = emptyElements.first(where: {
            accessibilityValue($0, "accessibilityIdentifier") as? String == "terminal.history.close"
        }) else { throw TestFailure(description: "Empty history must expose its own close button") }
        try require(accessibilityLabels(window.contentView!).contains(String(localized: "No Previous History")),
                    "A terminal without an archive shows the empty-history message")
        try require(accessibilityBool(emptyClose, "accessibilityPerformPress"), "Empty history close must be actionable")
        try await settle()
        try require(!state.historyVisible, "Empty history closes without changing sessions")

        // Reuse the process-free registry views above. The real Canvas and AppKit
        // history overlay reproduce the accessibility subtree that leaked offscreen.
        var terminals: [UUID: SSHTerminalNSView] = [:]
        let markers = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, "accessibility-fixture-\($0.id)") })
        for tab in model.tabs {
            let terminal = SSHTerminalRegistry.view(for: tab.sessionID) { SSHTerminalNSView(frame: .zero) }!
            try require(terminal.processHost == nil, "Accessibility fixture must not start a terminal process")
            let marker = markers[tab.id]!
            terminal.restoreHistory(TerminalHistorySnapshot(mainText: marker, lastScreenText: marker,
                                                            mainViewportTop: 0, visibleRows: 1, wasAlternateScreen: false))
            terminals[tab.id] = terminal
        }
        model.hideFiles(in: state)
        let first = model.tabs[0], second = model.tabs[1]
        model.selectOnly(first.id, in: state)
        window.contentView = NSHostingView(rootView: RootView(model: model, window: state))
        window.orderFront(nil)
        try await settle()
        window.contentView?.layoutSubtreeIfNeeded()

        func exposedMarkers() -> Set<String> {
            let values = accessibilityElements(window.contentView!).compactMap { element -> String? in
                let value = accessibilityValue(element, "accessibilityValue")
                return (value as? String) ?? (value as? NSAttributedString)?.string
            }
            return Set(markers.values.filter { marker in values.contains(where: { $0.contains(marker) }) })
        }
        try require(exposedMarkers().isEmpty, "Restoration must not cover the live terminal with history")
        let terminalRect = window.convertToScreen(terminals[first.id]!.convert(terminals[first.id]!.bounds, to: nil))
        let rootRect = window.convertToScreen(window.contentView!.convert(window.contentView!.bounds, to: nil))
        try require(abs(terminalRect.maxY - rootRect.maxY) < 1,
                    "A single terminal starts at the content top without a global header")
        let historyMenu = terminals[second.id]!.selectionContextMenu()
        guard let history = historyMenu.items.first(where: { $0.title == String(localized: "History") }) else {
            throw TestFailure(description: "Terminal context menu must contain history")
        }
        try require(history.isEnabled && history.state == .off, "History starts unchecked")
        try require(NSApp.sendAction(history.action!, to: history.target, from: history), "Native history selector must dispatch")
        try await settle()
        try require(state.selectedTabID == second.id && state.historyVisible,
                    "The history action selects its own terminal even when another pane was active")
        try require(terminals[second.id]!.selectionContextMenu().items.first(where: { $0.title == String(localized: "History") })?.state == .on,
                    "The native history menu reflects the current drawer state")
        func historyClose(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityIdentifier() == "terminal.history.close" { return button }
            return view.subviews.compactMap(historyClose).first
        }
        try await eventually("mount history close control") { historyClose(window.contentView!) != nil }
        guard let closeHistory = historyClose(window.contentView!) else {
            throw TestFailure(description: "History must have its own native close button")
        }
        try require(!closeHistory.isHidden && closeHistory.isEnabled, "History close button must be visible and actionable")
        try require(NSApp.sendAction(closeHistory.action!, to: closeHistory.target, from: closeHistory), "Native history close selector must dispatch")
        try await settle()
        try require(!state.historyVisible, "Closing history restores terminal space")
        let filesMenu = terminals[first.id]!.selectionContextMenu()
        guard let reveal = filesMenu.items.first(where: { $0.title == String(localized: "Reveal in Files") }) else {
            throw TestFailure(description: "Terminal context menu must contain file reveal")
        }
        try require(NSApp.sendAction(reveal.action!, to: reveal.target, from: reveal), "Native reveal selector must dispatch")
        try await eventually("context menu file reveal") {
            state.presentation.fullFilesWorkspace && model.fileWorkspace(for: state).remoteColumn?.fileSystem.host == first.alias
        }
        try require(state.filesSourceTabID == first.id, "File reveal uses the clicked terminal, not the selected one")
        model.hideFiles(in: state)
        model.selectOnly(first.id, in: state)
        try await settle()
        try require(terminals.values.allSatisfy { !$0.isShowingHistory }, "Restoring archives must keep terminal input available")
        state.historyVisible = true
        try await settle()
        window.contentView?.layoutSubtreeIfNeeded()
        try require(exposedMarkers() == [markers[first.id]!], "Explicit history drawer must show only the focused session")
        let firstSize = terminals[first.id]!.bounds.size
        try require(firstSize.width > 0 && firstSize.height > 0, "The selected native terminal must have a real layout size")
        model.selectOnly(second.id, in: state)
        try await settle()
        window.contentView?.layoutSubtreeIfNeeded()
        try require(exposedMarkers() == [markers[second.id]!], "Panel selection must swap the accessible native history")
        try require(terminals[first.id]!.bounds.size == firstSize, "A parked terminal must retain its prior dimensions")
        model.selectFilesLayout(.sideBySide, in: state)
        try await settle()
        try require(exposedMarkers().isEmpty, "The Files page must expose no terminal history")
        model.hideFiles(in: state)
        try await settle()
        try require(exposedMarkers() == [markers[second.id]!], "Returning to Terminal must expose only its selected history")
        for tab in model.tabs {
            let current = SSHTerminalRegistry.view(for: tab.sessionID) { preconditionFailure("A terminal was recreated") }
            try require(current === terminals[tab.id], "Page and panel switches must preserve every native terminal")
        }
        state.historyVisible = false
        window.orderOut(nil)
        window.contentView = nil
    }

    @MainActor
    private static func verifyFamilyFolderPicker(window: NSWindow, home: String) async throws {
        window.orderFront(nil)
        let originalPins = PinnedLocations.shared.items
        var chosen: [URL]?
        var cancelled = false
        var presentation: FamilyModalPresentation?
        func makePicker() {
            let host = NSHostingView(rootView: FamilyFolderPicker(initialDirectory: home, onCancel: {
                cancelled = true
                presentation?.close()
            }, onChoose: { urls in
                chosen = urls
                presentation?.close()
            }).environment(\.windowChrome, WindowChrome(isDark: false)))
            presentation = FamilyModalPresentation(content: host,
                size: NSSize(width: SheetLayout.folderPicker, height: SheetLayout.sessionBodyHeight), owner: window) {
                    cancelled = true
                    presentation?.close()
                }
            presentation?.show()
        }
        func button(_ title: String) -> NSObject? {
            guard let root = presentation?.window.contentView else { return nil }
            return accessibilityElements(root).first {
                accessibilityValue($0, "accessibilityRole") as? String == "AXButton" &&
                (accessibilityValue($0, "accessibilityLabel") as? String == title || accessibilityValue($0, "accessibilityTitle") as? String == title)
            }
        }
        makePicker()
        try await eventually("load custom folder picker") { button("local-a") != nil }
        try require(accessibilityBool(button("local-a")!, "accessibilityPerformPress"), "folder can be selected through accessibility")
        try await settle()
        try require(accessibilityBool(button(String(localized: "Pin Folder"))!, "accessibilityPerformPress"), "chosen folders can be confirmed")
        try require(chosen?.map(\.path) == [home + "/local-a"], "picker returns selected folder rather than browsing location")
        makePicker()
        try await eventually("reopen custom folder picker") { button("local-b") != nil }
        presentation?.window.cancelOperation(nil)
        try require(cancelled && PinnedLocations.shared.items == originalPins,
                    "cancel leaves saved pinned locations unchanged")
        print("ok: family folder picker loads directories asynchronously, selects and confirms a folder, and cancels without changing saved locations")
    }

    @MainActor
    private static func verifyHostPickerAccessibility(model: AppModel, state: WindowState, window: NSWindow, home: String) async throws {
        let config = URL(fileURLWithPath: home).appendingPathComponent(".ssh/config")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Host fixture-a\n  HostName fixture-a.example.invalid\nHost fixture-b\n  HostName fixture-b.example.invalid\n"
            .write(to: config, atomically: true, encoding: .utf8)
        model.reloadHosts()
        try require(model.hosts.map(\.alias) == ["fixture-a", "fixture-b"], "Picker fixture must use only isolated SSH config")
        let sessions = model.tabs.map(\.sessionID)
        func pressHost(_ alias: String) throws {
            guard let sheet = window.childWindows?.first(where: { $0 is FamilyModalWindow }), let content = sheet.contentView else {
                throw TestFailure(description: "Host picker must be a family dialog")
            }
            let elements = accessibilityElements(content)
            guard let row = elements.first(where: {
                accessibilityValue($0, "accessibilityIdentifier") as? String == "hosts.row." + alias
            }), let connect = elements.first(where: {
                accessibilityValue($0, "accessibilityIdentifier") as? String == "hosts.connect"
            }) else { throw TestFailure(description: "Missing modal host: \(alias)") }
            try require(accessibilityBool(row, "accessibilityPerformPress"), "Host row must select a host")
            try require(accessibilityBool(connect, "accessibilityPerformPress"), "Sheet must connect the selected host")
        }
        model.selectFilesLayout(.sideBySide, in: state)
        window.contentView = NSHostingView(rootView: RootView(model: model, window: state))
        window.orderFront(nil)
        try await settle()
        try require(!accessibilityElements(window.contentView!).contains {
            accessibilityValue($0, "accessibilityIdentifier") as? String == "sidebar.host.search"
        }, "The sidebar must not show a permanent server list")
        model.openHostPicker(in: state, purpose: .files)
        try await settle()
        try pressHost("fixture-b")
        try await eventually("Modal file connection") {
            model.fileWorkspace(for: state).remoteColumn?.fileSystem.host == "fixture-b"
        }
        try require(model.tabs.map(\.sessionID) == sessions, "Files host selection must not create a terminal")
        model.hideFiles(in: state)
        model.openHostPicker(in: state, purpose: .terminal)
        try await settle()
        try pressHost("fixture-b")
        try await eventually("Modal terminal connection") { model.tabs.count == sessions.count + 1 }
        try require(model.tabs.last?.alias == "fixture-b", "Picker must connect the chosen host")
        try require(!state.hostPickerPresented, "Connecting closes the host picker")

        window.setContentSize(NSSize(width: 880, height: 620))
        for files in [false, true] {
            if files { model.selectFilesLayout(.sideBySide, in: state) } else { model.hideFiles(in: state) }
            try await settle()
            window.contentView?.layoutSubtreeIfNeeded()
            let elements = accessibilityElements(window.contentView!)
            let titles = [String(localized: "Settings"), String(localized: "New Local Terminal")]
            for title in titles {
                let buttons = elements.filter {
                    accessibilityValue($0, "accessibilityRole") as? String == "AXButton" &&
                    (accessibilityValue($0, "accessibilityLabel") as? String == title || accessibilityValue($0, "accessibilityTitle") as? String == title)
                }
                try require(buttons.count == 1, "Page must expose exactly one entry for \(title)")
            }
            let ids = Set(files ? ["folder.badge.plus", "doc.badge.plus", "trash", "doc.on.clipboard"] :
                            ["terminal.history", "terminal.revealFiles"])
            let actions = elements.filter { ids.contains(accessibilityValue($0, "accessibilityIdentifier") as? String ?? "") }
            if files {
                try require(actions.isEmpty, "File mutations belong in context menus, not the page toolbar")
            } else {
                try require(actions.isEmpty, "Terminal actions belong in menus; no global toolbar remains")
                let removedIDs: Set<String> = ["plus.square", "rectangle.split.2x1", "rectangle.split.1x2",
                                              "arrow.up.left.and.arrow.down.right", "xmark.square"]
                let removedButtons = elements.filter {
                    accessibilityValue($0, "accessibilityRole") as? String == "AXButton" &&
                    removedIDs.contains(accessibilityValue($0, "accessibilityIdentifier") as? String ?? "")
                }
                try require(removedButtons.isEmpty, "Window operations use keyboard shortcuts, not toolbar buttons")
            }
            let contentFrame = window.convertToScreen(NSRect(origin: .zero, size: window.contentView!.bounds.size))
            for action in actions {
                let selector = NSSelectorFromString("accessibilityFrame")
                typealias FrameGetter = @convention(c) (AnyObject, Selector) -> NSRect
                let frame = unsafeBitCast(action.method(for: selector), to: FrameGetter.self)(action, selector)
                try require(frame.width > 0 && frame.minX >= contentFrame.minX - 1 && frame.maxX <= contentFrame.maxX + 1,
                            "Compact primary action must fit inside the window: \(frame)")
            }
        }
        window.setContentSize(NSSize(width: 1440, height: 900))
        try await verifyCompactHeaderGeometry(model: model, state: state, window: window)
        print("ok: single page entries, no global headers, 32-point file strips and recoverable narrow sidebar")

        model.hideFiles(in: state)
        guard let source = model.selectedTab(in: state) else {
            throw TestFailure(description: "New terminal shortcut requires a selected fixture session")
        }
        let splitIDs = Array(model.tabs.prefix(2).map(\.id))
        try require(splitIDs.count == 2, "Split preview fixture requires two terminals")
        model.mergeSidebar(splitIDs, onto: splitIDs[0], as: .columns, in: state)
        model.selectOnly(source.id, in: state)
        try require(SwitcherLayout.grid(count: 2, in: CGSize(width: 1080, height: 700)).columns == 2,
                    "Two preview cards should sit side by side when space permits")
        let switcher = TerminalSwitcher.shared
        let beforePreview = state.selectedTabID
        let chord = AppShortcutID.terminalSwitcher.defaultChord
        try require(switcher.open(model: model, window: state, chord: chord, host: window), "Preview must open")
        try require(switcher.items.filter { $0.kind == .terminals }.count == model.panelRows(in: state).count, "One preview card per panel, not per split leaf")
        try require(switcher.items.contains { $0.panes.count > 1 }, "Preview must include the fixture's split layout")
        try require(state.selectedTabID == beforePreview, "Highlighting previews must not switch live terminals")
        try await settle()
        guard let previewView = window.childWindows?.first?.contentView else {
            throw TestFailure(description: "Switcher preview window must be attached to the host")
        }
        previewView.layoutSubtreeIfNeeded()
        let previewCards = accessibilityElements(previewView).filter {
            (accessibilityValue($0, "accessibilityIdentifier") as? String ?? "").hasPrefix("terminal.switcher.card.")
        }
        try require(!previewCards.isEmpty, "Every preview card must be accessible")
        if let bitmap = previewView.bitmapImageRepForCachingDisplay(in: previewView.bounds) {
            previewView.cacheDisplay(in: previewView.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "/tmp/oneagent-switcher-fixture.png"))
            }
        }
        let initialHighlight = switcher.highlighted
        switcher.move(by: switcher.items.count)
        try require(switcher.highlighted == initialHighlight, "Cycling wraps across all cards")
        switcher.move(by: -1)
        switcher.move(by: 1)
        try require(switcher.highlighted == initialHighlight, "Reverse navigation is symmetric")
        func previewEvent(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags, key: UInt16) throws -> NSEvent {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key) else {
                throw TestFailure(description: "Could not create switcher keyboard event")
            }
            return event
        }
        let typingEvent = try previewEvent(.keyDown, flags: [], key: 0)
        try require(switcher.handle(typingEvent),
                    "Text entry must be consumed while previews are visible")
        _ = switcher.handle(try previewEvent(.flagsChanged, flags: [.control], key: 56))
        try require(switcher.isOpen, "Releasing Shift while Control stays down must keep previews open")
        switcher.scope = .terminals
        let target = switcher.filteredItems.first { $0.id == switcher.highlighted }?.targetID
        _ = switcher.handle(try previewEvent(.flagsChanged, flags: [], key: 59))
        try require(!switcher.isOpen && state.selectedTabID == target, "Control release commits the highlighted panel")
        let committed = state.selectedTabID
        try require(switcher.open(model: model, window: state, chord: chord, host: window), "Reopen preview")
        _ = switcher.handle(try previewEvent(.keyDown, flags: [.control], key: 53))
        _ = switcher.handle(try previewEvent(.flagsChanged, flags: [], key: 59))
        try require(!switcher.isOpen && state.selectedTabID == committed, "Escape cancels and later release cannot commit")
        let files = model.fileWorkspace(for: state)
        let fileColumn = files.localColumn
        let historicalLocal = files.addLocalTab(at: fileColumn.savedPath)
        files.activate(fileColumn)
        files.openRemote(host: "fixture-b", at: nil)
        let currentFileIDs = Set([files.localColumn.id, files.remoteColumn!.id])
        let historicalFileIDs = Set(files.allTabs.map(\.id)).subtracting(currentFileIDs)
        try require(historicalFileIDs.contains(historicalLocal.id) && !historicalFileIDs.isEmpty,
                    "The overview fixture must include saved locations outside the two open endpoints")
        let savedFilePath = fileColumn.savedPath
        let savedSelection = fileColumn.selection
        let savedFilter = fileColumn.filter
        let savedAnchor = fileColumn.savedScrollAnchor
        let savedPreview = fileColumn.savedPreviewPath
        let sessionCount = model.tabs.count
        let restoredWindow = WindowState()
        guard let deferredFiles = FileBrowserStore.shared.previewWorkspace(for: restoredWindow, model: model) else {
            throw TestFailure(description: "Saved file tabs must appear before the first Files visit")
        }
        try await settle()
        try require(!deferredFiles.allTabs.isEmpty && deferredFiles.allTabs.allSatisfy { !$0.loading && $0.directory.isEmpty && $0.savedPath != nil },
                    "Preview restoration must keep saved paths without loading directories")
        let activeFiles = model.fileWorkspace(for: restoredWindow)
        try require(activeFiles === deferredFiles, "Activating restored file tabs must reuse their preview identities")
        // This read-only restart probe must not overwrite the live fixture's saved state
        // when its asynchronous directory requests finish.
        activeFiles.onChange = nil
        try await eventually("lazy Files activation loads the preserved local directory") { !activeFiles.localColumn.loading && !activeFiles.localColumn.directory.isEmpty }
        try require(switcher.open(model: model, window: state, chord: chord, host: window, searching: true), "Search overview opens")
        try await settle()
        try require(Set(switcher.items.filter { $0.kind == .files }.map(\.id)) == currentFileIDs,
                    "Ctrl+Tab must show only the two open file endpoints, not inactive saved locations")
        guard let editor = switcher.searchField?.currentEditor() as? NSTextView else {
            throw TestFailure(description: "Search must use a native field editor")
        }
        try require(editor.window?.firstResponder === editor, "The search editor must receive typing immediately")
        editor.setMarkedText("本机", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let composingReturn = try previewEvent(.keyDown, flags: [], key: 36)
        try require(!switcher.handle(composingReturn) && switcher.isOpen, "IME confirmation must not commit the switcher")
        editor.insertText("本机", replacementRange: NSRange(location: NSNotFound, length: 0))
        try require(switcher.query == "本机", "Chinese text insertion must update the query")
        switcher.query = ""
        try require(switcher.items.filter { $0.kind == .files && !$0.isRemoteFile }.allSatisfy { $0.fileSymbol == "desktopcomputer" } &&
                    switcher.items.contains { $0.kind == .files && $0.isRemoteFile && $0.fileSymbol == "server.rack" },
                    "Local and remote file cards must use distinct device symbols")
        _ = switcher.handle(try previewEvent(.flagsChanged, flags: [], key: 59))
        try require(switcher.isOpen, "Search mode survives modifier release")
        switcher.scope = .files
        let fileItem = switcher.filteredItems.first { $0.id == fileColumn.id }!
        switcher.query = fileItem.subtitle.uppercased()
        try require(switcher.filteredItems.contains { $0.id == fileColumn.id }, "File names, hosts and paths are case-insensitive searchable")
        switcher.query = "impossible-no-result-76DE"
        try require(switcher.filteredItems.isEmpty && switcher.highlighted == nil, "No matches must clear the highlighted target")
        switcher.commit()
        try require(switcher.isOpen && state.selectedTabID == committed, "Enter on empty results must not switch anything")
        switcher.query = "fixture-b.example.invalid"
        try require(switcher.filteredItems.contains { $0.subtitle.contains("fixture-b") }, "Search must match SSH HostName, not just aliases")
        switcher.query = ""
        switcher.commit(fileColumn.id)
        try require(!switcher.isOpen && state.section == .files && files.focusedColumn === fileColumn, "File result activates the exact existing file tab")
        try require(fileColumn.savedPath == savedFilePath && fileColumn.selection == savedSelection &&
                    fileColumn.filter == savedFilter && fileColumn.savedScrollAnchor == savedAnchor &&
                    fileColumn.savedPreviewPath == savedPreview && model.tabs.count == sessionCount,
                    "Switching preserves file browsing state and never creates a terminal")
        try require(switcher.open(model: model, window: state, chord: chord, host: window, searching: true), "Overview opens from Files")
        switcher.cancel()
        try require(state.section == .files && files.focusedColumn === fileColumn, "Cancel preserves the starting file page")
        try require(switcher.open(model: model, window: state, chord: chord, host: window, searching: true), "Reopen mixed overview")
        switcher.scope = .terminals
        let terminalItem = switcher.filteredItems.first { $0.targetID == source.id } ?? switcher.filteredItems[0]
        switcher.commit(terminalItem.id)
        try require(state.section == .terminals && state.selectedTabID == terminalItem.targetID, "Terminal result returns from Files to the existing terminal")
        print("ok: mixed file/terminal previews; native search editor; token/host search; empty results; sticky search; file state retention")

        let closingRemote = files.remoteColumn!
        files.activate(closingRemote)
        try require(switcher.open(model: model, window: state, chord: chord, host: window, searching: true),
                    "Overview opens before closing a file location")
        try require(switcher.items.contains { $0.id == closingRemote.id }, "The current remote endpoint must have a card")
        try require(files.closeFocusedTab(), "The Files close shortcut must close the focused location")
        try await settle()
        let remainingFileIDs = Set([files.localColumn.id] + [files.remoteColumn?.id].compactMap { $0 })
        try require(!files.allTabs.contains { $0.id == closingRemote.id } &&
                    Set(switcher.items.filter { $0.kind == .files }.map(\.id)) == remainingFileIDs,
                    "Closing a location must remove its card and refresh the current file endpoints")
        switcher.cancel()

        let afterCloseWindow = WindowState()
        guard let afterCloseFiles = FileBrowserStore.shared.previewWorkspace(for: afterCloseWindow, model: model) else {
            throw TestFailure(description: "The closed-location snapshot must remain restorable")
        }
        try require(!afterCloseFiles.allTabs.contains { $0.fileSystem.host == closingRemote.fileSystem.host },
                    "A closed remote location must not return after restoring the saved workspace")
        try require(afterCloseFiles.allTabs.count > 2,
                    "Inactive saved locations must remain preserved for the location menus")
        try require(switcher.open(model: model, window: afterCloseWindow, chord: chord, host: window, searching: true),
                    "Overview opens from the restored workspace")
        let restoredFileIDs = Set([afterCloseFiles.localColumn.id] + [afterCloseFiles.remoteColumn?.id].compactMap { $0 })
        try require(Set(switcher.items.filter { $0.kind == .files }.map(\.id)) == restoredFileIDs,
                    "Restoring saved locations must still show only the current endpoints in Ctrl+Tab")
        try await settle()
        guard let restoredPreview = window.childWindows?.first?.contentView else {
            throw TestFailure(description: "The restored file overview must render a native panel")
        }
        restoredPreview.layoutSubtreeIfNeeded()
        guard let bitmap = restoredPreview.bitmapImageRepForCachingDisplay(in: restoredPreview.bounds) else {
            throw TestFailure(description: "Could not capture the native two-file overview")
        }
        restoredPreview.cacheDisplay(in: restoredPreview.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw TestFailure(description: "Could not encode the native two-file overview")
        }
        try png.write(to: URL(fileURLWithPath: "/tmp/oneagent-switcher-current-files-fixture.png"))
        switcher.cancel()

        try require(switcher.open(model: model, window: state, chord: chord, host: window, searching: true),
                    "Overview opens before closing the last remote location")
        for location in files.remoteTabs { files.close(location) }
        try await settle()
        try require(files.remoteColumn == nil && switcher.items.filter { $0.kind == .files }.map(\.id) == [files.localColumn.id],
                    "An empty remote pane must have no file card")
        switcher.cancel()
        print("ok: Ctrl+Tab excludes historical locations; live close removes cards; restored close stays closed; empty remote pane has no card")
        model.selectOnly(source.id, in: state)
        print("ok: preview panel grouping; stable selection; forward/reverse cycling; modifier release; Escape cancellation")
        let countBeforeNewTab = model.tabs.count
        model.newTab(in: state)
        try await eventually("new terminal in current context") { model.tabs.count == countBeforeNewTab + 1 }
        let newTab = model.selectedTab(in: state)
        try require(newTab?.id != source.id && newTab?.alias == source.alias &&
                    newTab?.directory == source.directory && newTab?.remoteDirectory == source.remoteDirectory,
                    "New terminal shortcut must preserve the source host and directory")
        try require(!state.hostPickerPresented, "New terminal shortcut must not open the host picker")

        window.orderOut(nil)
        window.contentView = nil
    }

    @MainActor
    private static func verifyFilePanePointerFocus(model: AppModel, state: WindowState, workspace: FileWorkspace, window: NSWindow) async throws {
        let local = workspace.localColumn
        guard let remote = workspace.remoteColumn, let localEntry = local.shown.first, let remoteEntry = remote.shown.first else {
            throw TestFailure(description: "Pointer focus requires populated local and remote endpoints")
        }
        let localSelection = local.selection
        let remoteSelection = remote.selection
        // Mount the production file page without leaving a second RootView alive to create
        // terminal surfaces when later routing checks switch the fixture back to Terminal mode.
        window.contentView = NSHostingView(rootView: FilesWorkspaceView(model: model, window: state, relay: CanvasDropRelay()))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        local.selection = [localEntry.path]
        try await settle()
        local.selection = []
        remote.selection = []
        workspace.focus(local)
        try await settle()
        window.contentView?.layoutSubtreeIfNeeded()

        func frame(of element: NSObject) throws -> NSRect {
            let selector = NSSelectorFromString("accessibilityFrame")
            guard element.responds(to: selector) else { throw TestFailure(description: "Pointer targets must expose a native frame") }
            typealias Getter = @convention(c) (AnyObject, Selector) -> NSRect
            return unsafeBitCast(element.method(for: selector), to: Getter.self)(element, selector)
        }
        func elements(_ id: String) -> [NSObject] {
            accessibilityElements(window.contentView!).filter { accessibilityValue($0, "accessibilityIdentifier") as? String == id }
        }
        func click(_ screenPoint: NSPoint) async throws {
            let point = window.convertPoint(fromScreen: screenPoint)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                    throw TestFailure(description: "Could not create a native file-pane click")
                }
                NSApp.sendEvent(event)
                try await settle()
            }
        }
        guard let row = elements("files.row.\(localEntry.path)").first else {
            throw TestFailure(description: "The local file row must be visible for the pointer probe")
        }
        let rowFrame = try frame(of: row)
        try await click(NSPoint(x: rowFrame.midX, y: rowFrame.midY))
        try require(local.selection == [localEntry.path], "The native click probe must select the actual local file row")

        let paths = try elements("files.path").map(frame).sorted { $0.minX < $1.minX }
        try require(paths.count == 2, "Both file panes must expose a path control")
        let blankY = window.frame.minY + 150
        try await click(NSPoint(x: paths[1].midX, y: blankY))
        try require(workspace.focusedColumn === remote,
                    "Clicking the right file pane's blank area must move operation focus from the left pane")
        guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125) else {
            throw TestFailure(description: "Could not create a native file-list arrow key")
        }
        NSApp.sendEvent(down)
        try await settle()
        try require(remote.selection == [remoteEntry.path] && local.selection == [localEntry.path],
                    "After clicking the right blank area, arrow keys must select files on the right and preserve the left selection")

        try await click(NSPoint(x: paths[0].midX, y: blankY))
        try require(workspace.focusedColumn === local, "Clicking the left blank area must restore left operation focus")
        let leftBeforeHeader = local.selection
        try await click(NSPoint(x: paths[1].midX, y: paths[1].maxY + 20))
        NSApp.sendEvent(down)
        try await settle()
        try require(workspace.focusedColumn === remote && local.selection == leftBeforeHeader,
                    "Clicking the right pane header must also move keyboard navigation to the right list")
        try await click(NSPoint(x: paths[0].midX, y: blankY))
        let editTargets = try elements("files.path.edit").map(frame).sorted { $0.minX < $1.minX }
        try require(editTargets.count == 2, "Each breadcrumb bar must retain a blank editing target")
        try await click(NSPoint(x: editTargets[1].midX, y: editTargets[1].midY))
        try require(workspace.focusedColumn === remote && window.firstResponder is NSTextView,
                    "Clicking the right path must focus the right pane and retain the native text editor")

        let localDirectory = local.directory, remoteDirectory = remote.directory
        if local.directory == local.home {
            local.open(local.home + "/local-a")
            try await eventually("browse before local home") { local.directory != local.home && !local.loading }
        }
        let beforeLocalHome = local.directory
        let homes = try elements("files.home").map(frame).sorted { $0.minX < $1.minX }
        try require(homes.count == 2, "Both local and remote panes expose a Home button")
        try await click(NSPoint(x: homes[0].midX, y: homes[0].midY))
        try await eventually("local Home button") { local.directory == local.home && !local.loading }
        try require(remote.directory == remoteDirectory, "Local Home must not navigate the remote pane")
        local.back()
        try await eventually("back after local Home") { local.directory == beforeLocalHome && !local.loading }
        local.open(localDirectory)
        try await eventually("restore local home probe") { local.directory == localDirectory && !local.loading }
        try require(remote.home == "/fixture-remote-home", "Remote Home resolves the user home instead of the shell startup directory")
        try await click(NSPoint(x: homes[1].midX, y: homes[1].midY))
        try await eventually("remote Home button") { remote.directory == remote.home && !remote.loading }
        try require(local.directory == localDirectory && workspace.focusedColumn === remote,
                    "Remote Home targets and focuses only its own file pane")
        remote.back()
        try await eventually("back after remote Home") { remote.directory == remoteDirectory && !remote.loading }

        guard let ancestor = elements("files.path.component./remote").first else {
            throw TestFailure(description: "The remote path must expose clickable ancestors")
        }
        let ancestorFrame = try frame(of: ancestor)
        try await click(NSPoint(x: ancestorFrame.midX, y: ancestorFrame.midY))
        try await eventually("click breadcrumb ancestor") { remote.directory == "/remote" && !remote.loading }
        try require(local.directory == localDirectory && !(window.firstResponder is NSTextView),
                    "Clicking an ancestor navigates only its pane without starting path editing")
        remote.back()
        try await eventually("back after breadcrumb") { remote.directory == remoteDirectory && !remote.loading }
        guard let current = elements("files.path.component." + remoteDirectory).first else {
            throw TestFailure(description: "The current directory must expose its own breadcrumb")
        }
        let currentFrame = try frame(of: current)
        try await click(NSPoint(x: currentFrame.midX, y: currentFrame.midY))
        guard let editor = window.firstResponder as? NSTextView else {
            throw TestFailure(description: "Clicking the current directory must edit the full path")
        }
        try require(editor.string == remoteDirectory, "Path editing starts with the complete absolute directory")
        let typedPath = "/remote/目录 with spaces"
        editor.selectAll(nil)
        editor.insertText(typedPath, replacementRange: editor.selectedRange())
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        NSApp.sendEvent(enter)
        try await eventually("commit edited remote path") { remote.directory == typedPath && !remote.loading }
        try require(elements("files.path.editor").isEmpty, "Submitting the path returns to breadcrumbs")
        let blankTarget = try elements("files.path.edit").map(frame).max { $0.minX < $1.minX }!
        try await click(NSPoint(x: blankTarget.midX, y: blankTarget.midY))
        guard let cancelledEditor = window.firstResponder as? NSTextView else {
            throw TestFailure(description: "Blank path space must reopen the path editor")
        }
        cancelledEditor.selectAll(nil)
        cancelledEditor.insertText("/remote/do-not-navigate", replacementRange: cancelledEditor.selectedRange())
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        NSApp.sendEvent(escape)
        try await settle()
        try require(remote.directory == typedPath && elements("files.path.editor").isEmpty,
                    "Escape discards the edited path without navigating")
        remote.back()
        try await eventually("restore breadcrumb probe") { remote.directory == remoteDirectory && !remote.loading }
        local.selection = localSelection
        remote.selection = remoteSelection
        window.makeFirstResponder(nil)
        window.orderOut(nil)
        window.contentView = nil
        print("ok: native file-pane clicks move operation focus; blank-area arrow keys follow the clicked pane; path input retains its editor")
        print("ok: local and remote Home buttons target their own user home and preserve Back navigation")
        print("ok: breadcrumb ancestors navigate directly; blank space and current folder edit; Enter accepts full Unicode paths")
    }

    @MainActor
    private static func verifyFolderLoadStates(window: NSWindow, workspace: FileWorkspace, folder: String) async throws {
        let column = FileColumn(fileSystem: FolderLoadFixture(folder: folder))
        let emptyLabel = String(localized: "This folder is empty")
        window.contentView = NSHostingView(rootView: FileColumnView(workspace: workspace, column: column) { Text("Fixture") })
        try await settle()
        try require(!accessibilityLabels(window.contentView!).contains(emptyLabel), "An unrequested folder must not be reported as empty")
        column.start(at: nil)
        try require(column.loading, "Initial home lookup must immediately enter the loading state")
        try await eventually("first folder load failure") { !column.loading && column.error != nil }
        try await settle()
        try require(column.directory.isEmpty && !accessibilityLabels(window.contentView!).contains(emptyLabel),
                    "A failed first load must show its error without claiming the folder is empty")

        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        column.refresh()
        try require(column.loading && column.error == nil, "Refresh must retry a failed first load and clear its stale error")
        try await eventually("empty folder retry success") { !column.loading && column.directory == folder && column.error == nil }
        try await eventually("loaded empty folder accessibility text") { accessibilityLabels(window.contentView!).contains(emptyLabel) }
        print("ok: unloaded and failed folders never claim empty; initial failure can refresh into a real empty folder")

        let longFolder = folder + "/" + String(repeating: "long-project-directory-", count: 6)
        try FileManager.default.createDirectory(atPath: longFolder, withIntermediateDirectories: false)
        let file = longFolder + "/" + String(repeating: "large-artifact-", count: 8) + ".txt"
        try Data("fixture".utf8).write(to: URL(fileURLWithPath: file))
        column.open(longFolder)
        try await eventually("load long path") { column.directory == longFolder && !column.loading }
        for width in [CGFloat(185), 310, 620] {
            window.setContentSize(NSSize(width: width, height: 500))
            try await settle()
            window.contentView?.layoutSubtreeIfNeeded()
            let labels = accessibilityLabels(window.contentView!)
            try require(labels.contains(String(localized: "Modified")) == (width == 620),
                        "Optional metadata must follow the assigned pane width, not a long path's intrinsic width")
            let elements = accessibilityElements(window.contentView!)
            let protected = elements.filter { element in
                let id = accessibilityValue(element, "accessibilityIdentifier") as? String
                let titles = ["accessibilityLabel", "accessibilityTitle"].compactMap { name -> String? in
                    let value = accessibilityValue(element, name)
                    return (value as? String) ?? (value as? NSAttributedString)?.string
                }
                return id == "files.path" || id == "files.home" || id == "files.row.\(file)" || titles.contains(String(localized: "Refresh")) || titles.contains(String(localized: "Filter"))
            }
            try require(protected.count >= 5, "Home, path, file row, refresh and filter must remain accessible at narrow widths")
            let contentFrame = window.convertToScreen(NSRect(origin: .zero, size: window.contentView!.bounds.size))
            for element in protected {
                let selector = NSSelectorFromString("accessibilityFrame")
                guard element.responds(to: selector) else { throw TestFailure(description: "Visible file controls must expose their frame") }
                typealias FrameGetter = @convention(c) (AnyObject, Selector) -> NSRect
                let frame = unsafeBitCast(element.method(for: selector), to: FrameGetter.self)(element, selector)
                try require(frame.width > 0 && frame.minX >= contentFrame.minX - 1 && frame.maxX <= contentFrame.maxX + 1,
                            "Long paths and rows must fit inside the assigned \(width)-point file pane: \(frame), container \(contentFrame)")
            }
        }
        window.setContentSize(NSSize(width: 1440, height: 900))
        print("ok: long file paths, rows and navigation controls stay within 185/310/620-point panes")
    }

    @MainActor
    private static func verifyCompactHeaderGeometry(model: AppModel, state: WindowState, window: NSWindow) async throws {
        func element(_ id: String) -> NSObject? {
            accessibilityElements(window.contentView!).first { accessibilityValue($0, "accessibilityIdentifier") as? String == id }
        }
        func frame(_ object: NSObject) -> NSRect {
            let selector = NSSelectorFromString("accessibilityFrame")
            typealias Getter = @convention(c) (AnyObject, Selector) -> NSRect
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
        func split(_ view: NSView) -> NSSplitView? {
            (view as? NSSplitView) ?? view.subviews.compactMap(split).first
        }
        let savedWidth = UserDefaults.standard.double(forKey: SidebarLayout.widthKey)
        defer { UserDefaults.standard.set(savedWidth, forKey: SidebarLayout.widthKey) }
        UserDefaults.standard.set(420.0, forKey: SidebarLayout.widthKey)
        model.selectFilesLayout(.sideBySide, in: state)
        window.setContentSize(NSSize(width: 880, height: 620))
        state.presentation.sidebarCollapsed = true
        try await settle()
        window.contentView?.layoutSubtreeIfNeeded()
        guard let restore = element("workspace.revealSidebar") else {
            throw TestFailure(description: "A collapsed sidebar must expose its restore button")
        }
        let rootTop = window.convertToScreen(window.contentView!.convert(window.contentView!.bounds, to: nil)).maxY
        guard let controls = element("workspace.windowControls"), let local = element("files.localLocation") else {
            throw TestFailure(description: "Collapsed chrome and local title must be accessible")
        }
        try require(abs(frame(controls).height - 32) < 1, "Only a 32-point window control strip remains when collapsed")
        try require(frame(local).maxY <= rootTop - 32 + 1, "Window controls cannot cover file headers")
        try require(accessibilityBool(restore, "accessibilityPerformPress"), "Sidebar restore must be actionable")
        try await settle()
        window.contentView?.layoutSubtreeIfNeeded()
        try require(element("workspace.revealSidebar") == nil && !state.presentation.sidebarCollapsed,
                    "Restoring the sidebar must remove the control strip even in a narrow window")
        guard let native = split(window.contentView!), let title = element("files.localLocation") else {
            throw TestFailure(description: "Restored native sidebar and file header are required")
        }
        try require(native.arrangedSubviews[0].frame.width >= SidebarLayout.minWidth && native.arrangedSubviews[0].frame.width <= 276,
                    "Restored sidebar temporarily fits beside two file panes")
        try require(UserDefaults.standard.double(forKey: SidebarLayout.widthKey) == 420,
                    "Narrow recovery must preserve the saved sidebar width")
        try require(rootTop - frame(title).midY < 32 && frame(title).maxY <= rootTop,
                    "File labels start in the first 32-point strip without a global title row")
        try require(FileBrowserLayout.tabStripHeight == 32 && Theme.PaneStyle.headerHeight == 28,
                    "File and split-terminal strips retain their approved heights")
        window.setContentSize(NSSize(width: 1440, height: 900))
        try await settle()
        window.contentView?.layoutSubtreeIfNeeded()
        try require(abs(native.arrangedSubviews[0].frame.width - 420) < 2,
                    "A wider window restores the preferred sidebar width")
    }

    @MainActor
    private static func accessibilityBool(_ element: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(element.method(for: selector), to: Getter.self)(element, selector)
    }

    @MainActor
    private static func eventually(_ name: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TestFailure(description: "Timed out: \(name)")
    }

    private static func settle() async throws {
        try await Task.sleep(nanoseconds: 80_000_000)
    }

    @MainActor
    private static func verifySingleFilesEntry(_ window: NSWindow, visible: Bool) throws {
        let elements = accessibilityElements(window.contentView!)
        let identifiers = elements.compactMap { accessibilityValue($0, "accessibilityIdentifier") as? String }
        try require(identifiers.filter { $0 == "workspace.files" }.count == 1,
                    "Files must have exactly one presentation entry")
        try require(identifiers.filter { $0 == "workspace.files.content" }.count == (visible ? 1 : 0),
                    "Only one file workspace can be visible, and Terminal mode must remove it")
        let labels = accessibilityLabels(window.contentView!)
        for removed in ["Toggle Files Panel", "Expand Files Panel", "Dock Files Panel", "Hide Files Panel", "Open File Manager"] {
            try require(!labels.contains(Bundle.main.localizedString(forKey: removed, value: nil, table: nil)),
                        "Duplicate Files control must be absent: \(removed)")
        }
    }

    @MainActor
    private static func accessibilityValue(_ element: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }

    @MainActor
    private static func accessibilityElements(_ object: Any) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        func walk(_ object: Any) -> [NSObject] {
            guard let element = object as? NSObject, visited.insert(ObjectIdentifier(element)).inserted else { return [] }
            let children = accessibilityValue(element, "accessibilityChildren") as? [Any] ?? []
            return [element] + children.flatMap(walk)
        }
        return walk(object)
    }

    @MainActor
    private static func accessibilityLabels(_ object: Any) -> [String] {
        // SwiftUI nodes may return attributed labels without declaring protocol conformance.
        accessibilityElements(object).flatMap { element in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { selector -> String? in
                let value = accessibilityValue(element, selector)
                return (value as? String) ?? (value as? NSAttributedString)?.string
            }
        }
    }


    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw TestFailure(description: message) }
    }
}
