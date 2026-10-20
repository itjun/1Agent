import Foundation

@main
enum ShellIntegrationTests {
    static func main() {
        testFeatures()
        testInjectsZsh()
        testVariables()
        testOtherShells()
        testMerged()
        print("ok")
    }

    static func testFeatures() {
        let all = Set(TerminalSettings.shellIntegrationFeatureNames)
        expect(ShellIntegrationEnvironment.features(all, cursorBlink: true) == "cursor:blink,path,sudo,title", "all features, no ssh-*")
        expect(ShellIntegrationEnvironment.features(["cursor", "title"], cursorBlink: false) == "cursor:steady,title", "steady cursor")
        expect(ShellIntegrationEnvironment.features(["ssh-env", "ssh-terminfo"], cursorBlink: true) == nil, "no supported features enabled")
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

    static func testOtherShells() {
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent("1agent-shell-modes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: resources) }
        let scripts = ["bash/ghostty.bash", "fish/vendor_conf.d/ghostty-shell-integration.fish", "elvish/lib/ghostty-integration.elv", "nushell/vendor/autoload/ghostty.nu"]
        for file in scripts {
            let url = resources.appendingPathComponent("shell-integration/" + file)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        let settings = TerminalSettings.defaults
        let bash = ShellIntegrationEnvironment.variables(settings: settings, shellPath: "/opt/homebrew/bin/bash", resourcesPath: resources.path, environment: ["HOME=/test", "ENV=/old/env"])
        expect(bash.contains("GHOSTTY_BASH_ENV=/old/env") && bash.contains("HISTFILE=/test/.bash_history"), "Bash preserves ENV and its history location")
        expect(ShellIntegrationEnvironment.launchArguments(settings: settings, shellPath: "/opt/homebrew/bin/bash", variables: bash) == ["--posix", "-l"], "Bash starts its integration through ENV")
        var disabled = settings
        disabled.shellIntegrationFeatures = []
        for shell in ["bash", "fish", "elvish", "nu"] {
            let injected = ShellIntegrationEnvironment.variables(settings: disabled, shellPath: "/opt/homebrew/bin/" + shell, resourcesPath: resources.path, environment: ["GHOSTTY_SHELL_FEATURES=title,ssh-env"])
            let merged = ShellIntegrationEnvironment.merged(["GHOSTTY_SHELL_FEATURES=title,ssh-env"], overrides: injected)
            expect(merged.filter { $0.hasPrefix("GHOSTTY_SHELL_FEATURES=") } == ["GHOSTTY_SHELL_FEATURES="], "Disabled features clear inherited values and preserve Nushell's environment field")
        }
        expect(ShellIntegrationEnvironment.variables(settings: settings, shellPath: "/bin/bash", resourcesPath: resources.path, environment: []).isEmpty, "Apple's legacy Bash is not automatically injected")
        for name in ["fish", "elvish", "nu"] {
            let variables = ShellIntegrationEnvironment.variables(settings: settings, shellPath: "/opt/homebrew/bin/" + name, resourcesPath: resources.path, environment: ["XDG_DATA_DIRS=/existing"])
            expect(variables.contains("XDG_DATA_DIRS=\(resources.path)/shell-integration:/existing"), "\(name) preserves existing XDG data paths")
            expect(variables.contains("GHOSTTY_SHELL_INTEGRATION_XDG_DIR=\(resources.path)/shell-integration"), "\(name) can remove its one-time injected XDG path")
            if name == "nu" { expect(ShellIntegrationEnvironment.launchArguments(settings: settings, shellPath: "/opt/homebrew/bin/nu", variables: variables) == ["--login", "--execute", "use ghostty *"], "Nushell explicitly loads its integration module") }
        }
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("FAIL \(message)\n", stderr)
            exit(1)
        }
    }
}
