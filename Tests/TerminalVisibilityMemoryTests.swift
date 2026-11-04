import AppKit
import Darwin
import GhosttyTerminal
@testable import GooseAgent

@main enum TerminalVisibilityMemoryTests {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await run()
                print("TerminalVisibilityMemoryTests passed")
                exit(0)
            } catch {
                fputs("TerminalVisibilityMemoryTests failed: \(error)\n", stderr)
                exit(1)
            }
        }
        NSApp.run()
    }

    @MainActor private static func run() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var hosts: [TerminalHostView] = []
        var sessions: [InMemoryTerminalSession] = []
        var terminals: [SSHTerminalNSView] = []
        var processes: [TerminalProcessHost] = []
        defer {
            for process in processes { process.terminate() }
            for terminal in terminals { terminal.controller = nil }
            window.close()
        }
        for _ in 0..<5 {
            let process = TerminalProcessHost()
            let session = process.session
            let terminal = SSHTerminalNSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
            terminal.processHost = process
            terminal.eventRelay.terminal = terminal
            terminal.delegate = terminal.eventRelay
            terminal.controller = GhosttyRuntime.controller
            terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
            process.start(TerminalLaunch(executable: "/bin/cat", args: [], environment: ["PATH=/usr/bin:/bin"], directory: "/tmp"))
            let host = TerminalHostView(frame: terminal.frame)
            window.contentView!.addSubview(host)
            host.attach(terminal)
            hosts.append(host)
            sessions.append(session)
            terminals.append(terminal)
            processes.append(process)
        }
        window.orderFront(nil)
        try await Task.sleep(for: .seconds(3))
        let pids = processes.map { $0.process.shellPid }
        guard pids.allSatisfy({ $0 > 0 }) else { throw Failure(description: "Every fixture must start a real PTY") }
        let shown = try footprint()
        let lastPresentedImage = terminals[1].layer?.contents as AnyObject?
        guard lastPresentedImage != nil else { throw Failure(description: "The visible terminal must present a rendered image") }
        for host in hosts.dropFirst() { host.setPresented(false) }
        sessions[1].receive("background-output-marker\r\n")
        sessions[1].waitForPendingOutput()
        try await Task.sleep(for: .seconds(3))
        let hidden = try footprint()
        print("physical footprint: shown=\(shown / 1_048_576) MiB hidden=\(hidden / 1_048_576) MiB")
        let oneBuffer = UInt64(1200 * 800 * 4 * window.backingScaleFactor * window.backingScaleFactor)
        guard shown > hidden, shown - hidden > 2 * oneBuffer else {
            throw Failure(description: "Hidden terminal views must release their full-size rendering buffers")
        }
        guard sessions[1].readViewportText()?.contains("background-output-marker") == true else {
            throw Failure(description: "A hidden terminal must continue processing output")
        }
        // AppKit 的布局与图层 display 回调不经过 Swift 层的可见性守卫。
        // 隐藏后反复重绘，不能重新持有三重缓冲区，也不能丢失后台输出。
        var redrawMilliseconds: [Double] = []
        for iteration in 0..<6 {
            for terminal in terminals.dropFirst() {
                let started = DispatchTime.now().uptimeNanoseconds
                terminal.layoutSubtreeIfNeeded()
                terminal.layer?.display()
                redrawMilliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            }
            sessions[1].receive("hidden-redraw-\(iteration) 中文\r\n")
            try await Task.sleep(for: .milliseconds(100))
        }
        sessions[1].waitForPendingOutput()
        try await Task.sleep(for: .seconds(1))
        let redrawnHidden = try footprint()
        print("physical footprint: hidden redraw=\(redrawnHidden / 1_048_576) MiB")
        print("hidden redraw main-thread time: total=\(redrawMilliseconds.reduce(0, +)) ms max=\(redrawMilliseconds.max() ?? 0) ms")
        guard redrawnHidden < hidden + 2 * oneBuffer else {
            throw Failure(description: "AppKit redraws must not recreate hidden terminal rendering buffers")
        }
        guard sessions[1].readViewportText()?.contains("hidden-redraw-5 中文") == true else {
            throw Failure(description: "Hidden redraws must preserve new Unicode output")
        }
        processes[1].process.write(Data("HIDDEN_PTY_INPUT_OK\n".utf8))
        for _ in 0..<100 {
            if sessions[1].readViewportText()?.contains("HIDDEN_PTY_INPUT_OK") == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard sessions[1].readViewportText()?.contains("HIDDEN_PTY_INPUT_OK") == true else {
            throw Failure(description: "A hidden terminal must still accept input and drain real PTY output")
        }
        for host in hosts.dropFirst() { host.setPresented(true) }
        try await Task.sleep(for: .seconds(2))
        guard sessions[1].readViewportText()?.contains("background-output-marker") == true,
              terminals[1].layer?.contents != nil,
              (terminals[1].layer?.contents as AnyObject?) !== lastPresentedImage,
              terminals[1].superview === hosts[1], terminals[1].frame.size == NSSize(width: 1200, height: 800) else {
            throw Failure(description: "Restoring a terminal must preserve its output, view and geometry")
        }
        let restored = try footprint()
        window.miniaturize(nil)
        try await Task.sleep(for: .seconds(3))
        guard window.isMiniaturized else { throw Failure(description: "The fixture window must minimize") }
        let minimized = try footprint()
        print("physical footprint: restored=\(restored / 1_048_576) MiB minimized=\(minimized / 1_048_576) MiB")
        guard restored > minimized, restored - minimized > 2 * oneBuffer else {
            throw Failure(description: "Minimizing a window must release its terminal rendering buffers")
        }
        sessions[1].receive("minimized-output-marker\r\n")
        sessions[1].waitForPendingOutput()
        hosts[4].setPresented(false)
        window.deminiaturize(nil)
        try await Task.sleep(for: .seconds(2))
        guard !window.isMiniaturized, !hosts[1].isHidden, hosts[4].isHidden,
              processes.map({ $0.process.shellPid }) == pids,
              sessions[1].readViewportText()?.contains("minimized-output-marker") == true,
              terminals[1].superview === hosts[1], terminals[1].frame.size == NSSize(width: 1200, height: 800) else {
            throw Failure(description: "Restoring a window must preserve visibility, output and terminal geometry")
        }
        window.orderOut(nil)
    }

    private static func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw Failure(description: "Cannot measure process footprint") }
        return info.phys_footprint
    }
}
