import Foundation

@main
enum ShellIntegrationTests {
    static func main() {
        testFeatures()
        testInjectsZsh()
        testVariables()
        testMerged()
        print("ok")
    }

    static func testFeatures() {
        let all = Set(TerminalSettings.shellIntegrationFeatureNames)
        expect(ShellIntegrationEnvironment.features(all, cursorBlink: true) == "cursor:blink,path,sudo,title", "all features, no ssh-*")
        expect(ShellIntegrationEnvironment.features(["cursor", "title"], cursorBlink: false) == "cursor:steady,title", "steady cursor")
        expect(ShellIntegrationEnvironment.features(["ssh-env", "ssh-terminfo"], cursorBlink: true) == nil, "ssh-* alone leaves it unset")
        expect(ShellIntegrationEnvironment.features([], cursorBlink: true) == nil, "nothing enabled")
    }

    static func testInjectsZsh() {
        expect(ShellIntegrationEnvironment.injectsZsh(.detect, shellPath: "/bin/zsh"), "detect zsh")
        expect(ShellIntegrationEnvironment.injectsZsh(.detect, shellPath: "/opt/homebrew/bin/zsh"), "detect zsh anywhere")
        expect(!ShellIntegrationEnvironment.injectsZsh(.detect, shellPath: "/bin/bash"), "detect bash is not injected")
        expect(!ShellIntegrationEnvironment.injectsZsh(.none, shellPath: "/bin/zsh"), "off")
        expect(ShellIntegrationEnvironment.injectsZsh(.zsh, shellPath: "/bin/bash"), "forced zsh")
        expect(!ShellIntegrationEnvironment.injectsZsh(.fish, shellPath: "/bin/zsh"), "fish is not injected")
    }

    static func testVariables() {
        let resources = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellIntegrationTests-\(ProcessInfo.processInfo.processIdentifier)")
        let zsh = resources.appendingPathComponent("shell-integration/zsh")
        try? FileManager.default.createDirectory(at: zsh, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: zsh.appendingPathComponent(".zshenv").path, contents: Data())
        defer { try? FileManager.default.removeItem(at: resources) }

        let settings = TerminalSettings.defaults
        let plain = ShellIntegrationEnvironment.variables(
            settings: settings,
            shellPath: "/bin/zsh",
            resourcesPath: resources.path,
            environment: ["HOME=/Users/me", "TERM=xterm-256color"]
        )
        expect(plain == [
            "ZDOTDIR=\(zsh.path)",
            "GHOSTTY_RESOURCES_DIR=\(resources.path)",
            "GHOSTTY_SHELL_FEATURES=cursor:blink,path,title",
        ], "default zsh injection: \(plain)")

        let kept = ShellIntegrationEnvironment.variables(
            settings: settings,
            shellPath: "/bin/zsh",
            resourcesPath: resources.path,
            environment: ["ZDOTDIR=/Users/me/.config/zsh"]
        )
        expect(kept.first == "GHOSTTY_ZSH_ZDOTDIR=/Users/me/.config/zsh", "an existing ZDOTDIR is kept for .zshenv")

        var off = settings
        off.shellIntegration = .none
        expect(ShellIntegrationEnvironment.variables(
            settings: off, shellPath: "/bin/zsh", resourcesPath: resources.path, environment: []
        ).isEmpty, "off injects nothing")
        expect(ShellIntegrationEnvironment.variables(
            settings: settings, shellPath: "/bin/zsh", resourcesPath: resources.path + "/missing", environment: []
        ).isEmpty, "missing scripts inject nothing")
    }

    static func testMerged() {
        let merged = ShellIntegrationEnvironment.merged(
            ["HOME=/h", "ZDOTDIR=/old", "TERM=xterm-256color"],
            overrides: ["ZDOTDIR=/new", "GHOSTTY_RESOURCES_DIR=/r"]
        )
        expect(merged == ["HOME=/h", "TERM=xterm-256color", "ZDOTDIR=/new", "GHOSTTY_RESOURCES_DIR=/r"], "override replaces: \(merged)")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("FAIL \(message)\n", stderr)
            exit(1)
        }
    }
}
