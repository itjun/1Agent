import AppKit
import GhosttyTerminal
@testable import GooseAgent

/// Replay real remote OSC bytes through the production transport callback and terminal engine.
@main enum RemoteDirectoryTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let host = TerminalProcessHost()
            var paths: [String] = []
            host.onRemoteDirectory = { paths.append($0) }
            host.start(TerminalLaunch(executable: "/bin/cat", args: [], environment: ["PATH=/usr/bin:/bin"],
                                      directory: "/tmp", integratesRemoteShell: true))
            let view = SSHTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
            view.processHost = host
            view.eventRelay.terminal = view
            view.delegate = view.eventRelay
            view.controller = GhosttyRuntime.controller
            view.configuration = TerminalSurfaceOptions(backend: .inMemory(host.session))
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view; window.orderFront(nil)
            for _ in 0..<100 {
                host.startWhenReady()
                if host.process.shellPid > 0 { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            precondition(host.process.shellPid > 0, "Fixture PTY must start")
            for value in ["file://fixture-build/root/sample-project", "kitty-shell-cwd://fixture-build/root/sample-project", "file:///root/sample-project"] {
                paths = []
                host.process.write(Data(("\u{1b}]7;" + value + "\u{7}\n").utf8))
                for _ in 0..<100 {
                    if paths.contains("/root/sample-project") { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                guard paths.contains("/root/sample-project"), host.remoteWorkingDirectory == "/root/sample-project" else {
                    fputs("FAIL: remote cwd report never reaches app: \(value)\n", stderr); exit(1)
                }
            }
            let stale = host.process
            host.restart(notice: "TEST_RECONNECT")
            paths = []
            stale.onOutput?(Data("\u{1b}]7;file:///stale\u{7}".utf8))
            try? await Task.sleep(for: .milliseconds(100))
            precondition(!paths.contains("/stale") && host.remoteWorkingDirectory == nil, "Old process must not overwrite reconnected cwd")
            host.terminate()
            print("RemoteDirectoryTests passed: PTY OSC 7 reports reach app state; stale reconnect reports ignored")
            exit(0)
        }
        NSApp.run()
    }
}
