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
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var hosts: [TerminalHostView] = []
        var sessions: [InMemoryTerminalSession] = []
        var terminals: [SSHTerminalNSView] = []
        for _ in 0..<5 {
            let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
            let terminal = SSHTerminalNSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
            terminal.controller = GhosttyRuntime.controller
            terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
            let host = TerminalHostView(frame: terminal.frame)
            window.contentView!.addSubview(host)
            host.attach(terminal)
            hosts.append(host)
            sessions.append(session)
            terminals.append(terminal)
        }
        window.orderFront(nil)
        try await Task.sleep(for: .seconds(3))
        let shown = try footprint()
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
        for host in hosts.dropFirst() { host.setPresented(true) }
        try await Task.sleep(for: .seconds(2))
        guard sessions[1].readViewportText()?.contains("background-output-marker") == true,
              terminals[1].superview === hosts[1], terminals[1].frame.size == NSSize(width: 1200, height: 800) else {
            throw Failure(description: "Restoring a terminal must preserve its output, view and geometry")
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
