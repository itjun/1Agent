import AppKit
import SwiftUI
@testable import GooseAgent

@main struct WorkspaceRefreshTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        Task { @MainActor in
            do { try await run(); print("WorkspaceRefreshTests passed"); exit(0) }
            catch { fputs("WorkspaceRefreshTests failed: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("oneagent-refresh-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("old\n".utf8).write(to: root.appendingPathComponent("old.txt"))
        try Data("child\n".utf8).write(to: root.appendingPathComponent("nested/child.txt"))
        let state = WindowState()
        let host = NSHostingView(rootView: AnyView(WorkspaceFilesView(location: GitLocation(directory: root.path), window: state)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        func element(_ id: String) -> NSObject? {
            elements(host).first { value($0, "accessibilityIdentifier") as? String == id }
        }
        func file(_ path: String) -> NSObject? { element("workspace.fileRow." + root.appendingPathComponent(path).path) }
        func refresh(_ id: String) throws {
            // The help fallback also lets this regression run against the pre-fix app.
            let button = element(id) ?? elements(host).first {
                value($0, "accessibilityHelp") as? String == "Refresh"
                    && $0.responds(to: NSSelectorFromString("accessibilityPerformPress"))
            }
            guard let button, press(button) else { throw failure("Refresh button must be actionable") }
        }
        try await Task.sleep(for: .milliseconds(500))
        try await until("initial file list") { file("old.txt") != nil && file("nested") != nil }
        guard press(file("nested")!) else { throw failure("Folder must expand") }
        try await until("expanded child") { file("nested/child.txt") != nil }
        try FileManager.default.removeItem(at: root.appendingPathComponent("old.txt"))
        try Data("new\n".utf8).write(to: root.appendingPathComponent("new.txt"))
        try Data("new child\n".utf8).write(to: root.appendingPathComponent("nested/new-child.txt"))
        try refresh("workspace.files.refresh")
        try await until("manual refresh must reload the current directory") { file("new.txt") != nil && file("old.txt") == nil }
        try await until("manual refresh must preserve and reload expanded folders") { file("nested/new-child.txt") != nil && file("nested/child.txt") != nil }
        print("PASS: file refresh reloads root and expanded descendants")

        host.rootView = AnyView(WorkspaceChangesView(location: GitLocation(directory: root.path), window: state))
        try await until("non-repository status") { text(host).contains("This folder is not a Git repository.") }
        try refresh("workspace.changes.refresh")
        try await until("non-repository refresh completes") { text(host).contains("This folder is not a Git repository.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "init", "-q"]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure("Fixture Git init failed") }
        try refresh("workspace.changes.refresh")
        try await until("manual Git refresh must discover a new repository") { element("workspace.gitFile.new.txt") != nil }
        try FileManager.default.removeItem(at: root.appendingPathComponent("new.txt"))
        try Data("another\n".utf8).write(to: root.appendingPathComponent("another.txt"))
        try refresh("workspace.changes.refresh")
        try await until("manual Git refresh must replace stale changes") {
            element("workspace.gitFile.another.txt") != nil && element("workspace.gitFile.new.txt") == nil
        }
        print("PASS: Git refresh rechecks non-repositories and updates changed files")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "WorkspaceRefreshTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    @MainActor static func until(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<60 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw failure(message)
    }
    @MainActor static func text(_ root: NSView) -> String {
        elements(root).flatMap { object in
            ["accessibilityValue", "accessibilityLabel"].compactMap { value(object, $0) as? String }
        }.joined(separator: "\n")
    }
    @MainActor static func value(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
    }
    @MainActor static func press(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method, to: Action.self)(object, selector)
    }
    @MainActor static func elements(_ root: Any) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ item: Any) -> [NSObject] {
            guard let object = item as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            return [object] + ((value(object, "accessibilityChildren") as? [Any] ?? [])
                + ((object as? NSView)?.subviews ?? [])).flatMap(walk)
        }
        return walk(root)
    }
}
