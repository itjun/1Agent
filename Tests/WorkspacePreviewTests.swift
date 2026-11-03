import AppKit
import Quartz
import GhosttyTerminal
import SwiftUI
@testable import GooseAgent

@main struct WorkspacePreviewTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print(error); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func run() async throws {
        verifyPreviewPolicy()
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ONEAGENT_PREVIEW_FIXTURE"]!)
        let location = GitLocation(directory: root.path)
        let snapshot = try await WorkspaceGit.snapshot(at: location)!
        let state = WindowState()
        state.synchronizeToolContext(sessionID: "first", location: location)
        let initialRequest = GitPreviewRequest(location: location, snapshot: snapshot, change: GitChange(path: "fixture.swift", status: "M"), revision: 0)
        state.toolPreviewWidth = 1000
        state.isToolPreviewEqualSplit = true
        state.openToolGitPreview(initialRequest)
        precondition(state.toolPreviewWidth == WorkspacePreviewLayout.defaultWidth && !state.isToolPreviewEqualSplit,
                     "a new card opens at single-column width, not the last expanded width")
        state.toolPreviewWidth = 900
        state.openToolGitPreview(initialRequest)
        precondition(state.toolPreviewWidth == 900, "refreshing an open diff preserves manual width")
        state.isToolPreviewEqualSplit = true
        state.openToolGitPreview(initialRequest)
        precondition(state.isToolPreviewEqualSplit, "refreshing an open diff preserves explicit equal split")
        let host = NSHostingView(rootView: WorkspaceFilePreview(model: AppModel(), window: state))
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1000,height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(1))
        host.layoutSubtreeIfNeeded()
        precondition(textViews(in: host).contains { $0.string.contains("value599") }, "measure loaded diff, not a loading placeholder")
        try await measure(host, label: "Git diff")
        let request = state.toolGitPreview
        state.synchronizeToolContext(sessionID: "first", location: location)
        precondition(state.toolGitPreview == request, "unchanged context preserves preview")
        state.toolGitBranchComparison = true
        state.synchronizeToolContext(sessionID: "second", location: location)
        precondition(!state.toolGitBranchComparison, "switching terminal defaults changes to uncommitted")
        precondition(!state.isToolPreviewOpen, "switching terminal clears previous diff even in the same folder")
        let column = FileColumn(fileSystem: fileSystem(for: nil))
        let entry = try await column.fileSystem.list(root.path).first { $0.name == "fixture.swift" }!
        column.showPreview(entry)
        state.openToolFilePreview(column)
        precondition(state.toolPreviewWidth == WorkspacePreviewLayout.defaultWidth && !state.isToolPreviewEqualSplit,
                     "opening a file after a context change resets width")
        state.toolPreviewWidth = 820
        state.openToolFilePreview(column)
        precondition(state.toolPreviewWidth == 820, "switching files in an open card preserves width")
        state.toolPreviewColumn = nil
        state.openToolFilePreview(column)
        precondition(state.toolPreviewWidth == WorkspacePreviewLayout.defaultWidth, "closing and reopening a file resets width")
        try await Task.sleep(for: .seconds(1))
        precondition(column.preview?.decoded?.text.contains("value599") == true, "measure loaded text preview")
        try await measure(host, label: "Text file")
        let imageEntry = try await column.fileSystem.list(root.path).first { $0.name == "preview.png" }!
        column.showQuickLook(imageEntry, window: nil)
        window.orderFrontRegardless()
        try await Task.sleep(for: .seconds(1))
        host.layoutSubtreeIfNeeded()
        precondition(previewContainers(in: host).count == 1, "measure the actual image preview")
        try await measure(host, label: "PNG image")
        window.orderOut(nil)
        try await measureImageBesideTerminal(url: root.appendingPathComponent("preview.png"))
        state.synchronizeToolContext(sessionID: "second", location: GitLocation(directory: root.path + "/other"))
        precondition(!state.isToolPreviewOpen, "directory change clears previous file")
        state.toolGitPreview = request
        state.synchronizeToolContext(sessionID: "second", location: GitLocation(host: "test-only", directory: root.path))
        precondition(!state.isToolPreviewOpen, "host change clears previous preview")
        window.contentView = nil
        print("WorkspacePreviewTests passed: resize performance and terminal/directory/host context")
    }
    @MainActor static func verifyPreviewPolicy() {
        let blocked = ["service.jar", "APP.EXE", "image.bin", "backup.zip", "archive.tar.gz", "archive.7z",
                       "data.rar", "archive.zst", "library.so", "library.dll", "disk.dmg", "package.deb",
                       "module.class", "store.sqlite", "unknown.xyz", "executable", ".env.jar", "movie.mp4"]
        for name in ["README.md", "Makefile", "config.yml", ".env.production", "script.sh", "app.swift"] {
            precondition(FilePreviewPolicy.kind(for: name) == .text)
        }
        for name in ["photo.PNG", "photo.jpg", "image.webp", "scan.pdf", "report.docx", "table.xlsx", "slides.pptx"] {
            precondition(FilePreviewPolicy.kind(for: name) == .quickLook)
        }
        let model = AppModel()
        let state = WindowState()
        let workspace = FileWorkspace(saved: nil, model: model, window: state, loadImmediately: false)
        let systems: [any FileSystem] = [LocalFileSystem(), RemoteFileSystem(alias: "preview-test.invalid")]
        for system in systems {
            let column = FileColumn(fileSystem: system)
            for name in blocked {
                precondition(FilePreviewPolicy.kind(for: name) == nil)
                let entry = FileEntry(name: name, path: "/unread-preview-fixture/" + name,
                                      isDirectory: false, size: 1_000_000_000, mode: "-rw-r--r--")
                column.showPreview(entry)
                precondition(column.preview == nil, "binary text preview must stop before starting a read")
                column.showQuickLook(entry, window: nil)
                precondition(column.preview == nil, "binary Quick Look must stop before starting a download")
                workspace.open(entry, in: column, window: nil)
                precondition(column.preview == nil, "file workspace must use the same preview policy")
            }
            let previous = FileColumn.Preview(entry: FileEntry(name: "previous.txt", path: "/previous.txt",
                isDirectory: false, size: 0, mode: "-rw-r--r--"), truncated: false)
            column.preview = previous
            let binary = FileEntry(name: "blocked.jar", path: "/blocked.jar", isDirectory: false,
                                  size: 1_000_000_000, mode: "-rw-r--r--")
            column.showQuickLook(binary, window: nil)
            workspace.open(binary, in: column, window: nil)
            precondition(column.preview == previous, "unsupported selection keeps the existing preview")
        }
        print("Preview policy passed: local/remote archives, executables and unknown files never start preview")
    }
    @MainActor static func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }
    @MainActor static func previewContainers(in view: NSView) -> [PreviewContainerView] {
        (view as? PreviewContainerView).map { [$0] } ?? view.subviews.flatMap { previewContainers(in: $0) }
    }
    @MainActor static func measureImageBesideTerminal(url: URL) async throws {
        TerminalDefaults.registerBundledFonts()
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let terminal = SSHTerminalNSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1000))
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        terminal.controller = GhosttyRuntime.controller
        let terminalHost = TerminalHostView(frame: terminal.frame)
        terminalHost.attach(terminal)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 2100, height: 1000))
        let image = PreviewContainerView(frame: NSRect(x: 1207, y: 0, width: 893, height: 1000))
        container.addSubview(terminalHost)
        container.addSubview(image)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.orderFrontRegardless()
        image.show(url)
        defer { terminal.controller = nil; image.close(); window.close() }
        for _ in 0..<100 {
            if session.hasAttachedSurface { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(session.hasAttachedSurface)
        session.receive(String(repeating: "\u{1b}[32m~/1Agent main\u{1b}[0m terminal preview resize regression\r\n", count: 100))
        session.waitForPendingOutput()
        try await Task.sleep(for: .seconds(1))
        var times: [Double] = []
        let initialSize = terminal.frame.size
        terminalHost.beginDividerResize()
        for i in 0..<60 {
            let start = CFAbsoluteTimeGetCurrent()
            let width = CGFloat(800 + (i < 30 ? i : 59 - i) * 20)
            terminalHost.setFrameSize(NSSize(width: width, height: 1000))
            image.frame = NSRect(x: width + 7, y: 0, width: 2093 - width, height: 1000)
            container.layoutSubtreeIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(2))
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000 - 2)
            precondition(terminal.frame.size == initialSize, "divider drag must not rebuild the terminal grid for each pixel")
        }
        terminalHost.endDividerResize()
        precondition(terminal.frame == terminalHost.bounds, "release must apply the final terminal dimensions")
        precondition(terminal.layer?.affineTransform() == .identity, "release must restore sharp unscaled terminal rendering")
        terminalHost.beginDividerResize()
        terminalHost.setFrameSize(NSSize(width: 900, height: 650))
        precondition(terminal.frame.height == 1000, "horizontal dividers also defer terminal grid resizing")
        precondition(terminal.layer?.affineTransform().d == 0.65, "drag feedback must scale to the visible height")
        terminalHost.endDividerResize()
        precondition(terminal.frame == terminalHost.bounds && terminal.layer?.affineTransform() == .identity)
        terminalHost.setFrameSize(NSSize(width: 1000, height: 700))
        precondition(terminal.frame == terminalHost.bounds, "ordinary resizing must still work after a drag")
        let sorted = times.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        print(String(format: "Terminal + PNG resize mean=%.2fms p95=%.2fms max=%.2fms", times.reduce(0,+)/Double(times.count),p95,sorted.last!))
        if p95 > 33 { print("FAIL: terminal + image resize exceeds 33ms frame budget"); exit(2) }
    }
    @MainActor static func measure(_ host: NSHostingView<WorkspaceFilePreview>, label: String) async throws {
        var times: [Double] = []
        for i in 0..<36 {
            let width = CGFloat(600 + (i % 18) * 30)
            let start = CFAbsoluteTimeGetCurrent()
            host.setFrameSize(NSSize(width: width, height: 800))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(2))
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000 - 2)
        }
        let sorted = times.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        print(label + " " + String(format:"resize frames=%d mean=%.2fms p95=%.2fms max=%.2fms",times.count,times.reduce(0,+)/Double(times.count),p95,sorted.last!))
        if p95 > 50 { print("FAIL: resize main-thread work exceeds 50ms"); exit(2) }
        print("PASS")
    }
}
