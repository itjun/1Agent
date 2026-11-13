import AppKit
import GhosttyTerminal
@testable import GooseAgent

@main enum TerminalFontTests {
    @MainActor static func main() {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await run()
            exit(0)
        }
        NSApp.run()
    }

    @MainActor static func expect(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); exit(1) }
    }

    @MainActor static func run() async {
        let home = ProcessInfo.processInfo.environment["ONEAGENT_TEST_HOME"]!
        precondition(home.hasPrefix("/private/tmp/oneagent-terminal-font."))
        precondition(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == URL(fileURLWithPath: home).resolvingSymlinksInPath())
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        let families = TerminalFontSettings.availableFamilies()
        expect(families.contains(TerminalSettings.defaults.fontFamily), "The default must be an available font")
        expect(Set(families).count == families.count, "Font choices must not be duplicated")
        for family in families {
            expect(installed.contains(family), "Picker offers unavailable font: \(family)")
            let font = TerminalFontSettings.previewFont(family: family, size: 14)
            expect(font?.familyName == family, "Preview must resolve the selected family: \(family)")
        }
        expect(TerminalFontSettings.previewFont(family: "OneAgent Missing Font Test", size: 14) == nil, "Missing fonts must not silently produce a preview")
        UserDefaults.standard.set("OneAgent Missing Font Test", forKey: TerminalFontSettings.familyKey)
        expect(!TerminalFontSettings.availableFamilies().contains("OneAgent Missing Font Test"), "A saved missing font must not become an available choice")
        let menlo = TerminalFontSettings.previewFont(family: "Menlo", size: 14)!
        let monaco = TerminalFontSettings.previewFont(family: "Monaco", size: 14)!
        expect(menlo.fontName != monaco.fontName, "Switching installed fonts must change the preview face")
        expect(TerminalFontSettings.previewFont(family: "Menlo", size: 24)?.pointSize == 24, "Preview must honor the selected size")

        // 已挂载的本机与远程终端都应立即重载字体，测试不启动 shell 或 SSH。
        for target in TerminalThemeTarget.allCases {
            let metrics = Metrics()
            let session = InMemoryTerminalSession(write: { _ in }, resize: { metrics.set($0) })
            UserDefaults.standard.set("Menlo", forKey: TerminalFontSettings.familyKey)
            UserDefaults.standard.set(14, forKey: TerminalFontSettings.sizeKey)
            GhosttyRuntime.applyTerminalSettings()
            let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
            view.controller = GhosttyRuntime.controller(for: target)
            view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            await settle()
            let before = metrics.get()
            expect(before != nil, "Terminal must report its font metrics")
            UserDefaults.standard.set("Monaco", forKey: TerminalFontSettings.familyKey)
            GhosttyRuntime.applyTerminalSettings()
            await settle()
            let after = metrics.get()
            expect(before?.columns != after?.columns || before?.rows != after?.rows, "Changing family must update an existing \(target) terminal")
            UserDefaults.standard.set(24, forKey: TerminalFontSettings.sizeKey)
            GhosttyRuntime.applyTerminalSettings()
            await settle()
            expect(metrics.get()!.rows < after!.rows, "Changing size must update an existing terminal")
            print("\(target): Menlo \(before!.columns)x\(before!.rows) -> Monaco \(after!.columns)x\(after!.rows)")
            window.close()
        }
        print("TerminalFontTests passed: installed choices, missing fonts, preview faces/sizes, live local and remote terminal font changes")
    }

    @MainActor static func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
    }
}

private final class Metrics: @unchecked Sendable {
    private let lock = NSLock()
    private var value: InMemoryTerminalViewport?
    func set(_ next: InMemoryTerminalViewport) {
        lock.lock()
        defer { lock.unlock() }
        value = next
    }
    func get() -> InMemoryTerminalViewport? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
