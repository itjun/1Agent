import Foundation

/// Variables that make local shells load bundled integration, following Ghostty's
/// `src/termio/shell_integration.zig`. SSH launches use their own authenticated bootstrap,
/// and `TERM` stays `xterm-256color`: the scripts do not look at it.
enum ShellIntegrationEnvironment {
    /// Features the bundled scripts can act on here. `ssh-env` and `ssh-terminfo` would wrap `ssh`
    /// in `ghostty +ssh`, a command-line tool this app does not ship, so they are never passed on.
    static let supportedFeatures = ["cursor", "path", "sudo", "title"]

    /// Variables to set on top of `environment`; empty when nothing is injected.
    static func variables(
        settings: TerminalSettings,
        shellPath: String,
        resourcesPath: String?,
        environment: [String]
    ) -> [String] {
        guard let resourcesPath, let shell = integrationShell(settings.shellIntegration, shellPath: shellPath) else { return [] }
        if shell != "zsh" {
            let integration = resourcesPath + "/shell-integration"
            var result = ["GHOSTTY_RESOURCES_DIR=\(resourcesPath)"]
            if shell == "bash" {
                guard FileManager.default.fileExists(atPath: integration + "/bash/ghostty.bash") else { return [] }
                result += ["ENV=\(integration)/bash/ghostty.bash", "GHOSTTY_BASH_INJECT=1"]
                if let value = value(of: "ENV", in: environment) { result.append("GHOSTTY_BASH_ENV=\(value)") }
                if value(of: "HISTFILE", in: environment) == nil {
                    let home = value(of: "HOME", in: environment) ?? FileManager.default.homeDirectoryForCurrentUser.path
                    result += ["HISTFILE=\(home)/.bash_history", "GHOSTTY_BASH_UNEXPORT_HISTFILE=1"]
                }
            } else {
                let files = ["fish": "fish/vendor_conf.d/ghostty-shell-integration.fish", "elvish": "elvish/lib/ghostty-integration.elv", "nushell": "nushell/vendor/autoload/ghostty.nu"]
                guard let file = files[shell], FileManager.default.fileExists(atPath: integration + "/" + file) else { return [] }
                let original = value(of: "XDG_DATA_DIRS", in: environment) ?? "/usr/local/share:/usr/share"
                result += ["GHOSTTY_SHELL_INTEGRATION_XDG_DIR=\(integration)", "XDG_DATA_DIRS=\(integration)" + (original.isEmpty ? "" : ":" + original)]
            }
            // Empty is an explicit override: do not inherit enabled features from a parent
            // terminal. Nushell also requires this environment field to exist for its wrappers.
            result.append("GHOSTTY_SHELL_FEATURES=\(features(settings.shellIntegrationFeatures, cursorBlink: settings.cursorBlink) ?? "")")
            return result
        }
        let zshDirectory = resourcesPath + "/shell-integration/zsh"
        if !FileManager.default.fileExists(atPath: zshDirectory + "/.zshenv") {
            return []
        }
        var result: [String] = []
        // The bundled .zshenv puts this back into ZDOTDIR before it loads the user's own files.
        if let oldZDOTDIR = ShellIntegrationEnvironment.value(of: "ZDOTDIR", in: environment) {
            result.append("GHOSTTY_ZSH_ZDOTDIR=\(oldZDOTDIR)")
        }
        result.append("ZDOTDIR=\(zshDirectory)")
        result.append("GHOSTTY_RESOURCES_DIR=\(resourcesPath)")
        result.append("GHOSTTY_SHELL_FEATURES=\(features(settings.shellIntegrationFeatures, cursorBlink: settings.cursorBlink) ?? "")")
        return result
    }

    static func integrationShell(_ mode: TerminalSettings.ShellIntegration, shellPath: String) -> String? {
        switch mode {
        case .none: return nil
        case .detect:
            let name = (shellPath as NSString).lastPathComponent
            // Apple's legacy Bash disables the ENV startup mechanism. Match upstream detection.
            if shellPath == "/bin/bash" { return nil }
            return ["bash", "zsh", "fish", "elvish"].contains(name) ? name : name == "nu" ? "nushell" : nil
        case .zsh: return "zsh"
        case .bash: return "bash"
        case .fish: return "fish"
        case .elvish: return "elvish"
        case .nushell: return "nushell"
        }
    }

    static func launchArguments(settings: TerminalSettings, shellPath: String, variables: [String]) -> [String] {
        let shell = integrationShell(settings.shellIntegration, shellPath: shellPath)
        if !variables.isEmpty, shell == "bash" { return ["--posix", "-l"] }
        if !variables.isEmpty, shell == "nushell" { return ["--login", "--execute", "use ghostty *"] }
        return (shellPath as NSString).lastPathComponent == "nu" ? ["--login"] : ["-l"]
    }

    static func injectsZsh(_ mode: TerminalSettings.ShellIntegration, shellPath: String) -> Bool {
        switch mode {
        case .none:
            return false
        case .zsh:
            return true
        case .detect:
            return (shellPath as NSString).lastPathComponent == "zsh"
        case .bash, .elvish, .fish, .nushell:
            return false
        }
    }

    /// Ghostty's format: enabled names in alphabetical order, `cursor` carrying `:blink` or `:steady`.
    /// Nil when nothing is enabled. The injector still clears any inherited feature value.
    static func features(_ enabled: Set<String>, cursorBlink: Bool) -> String? {
        var parts: [String] = []
        for name in ShellIntegrationEnvironment.supportedFeatures where enabled.contains(name) {
            if name == "cursor" {
                parts.append(cursorBlink ? "cursor:blink" : "cursor:steady")
            } else {
                parts.append(name)
            }
        }
        if parts.isEmpty {
            return nil
        }
        return parts.joined(separator: ",")
    }

    /// `base` with every key in `overrides` replaced, so the child never sees a key twice.
    static func merged(_ base: [String], overrides: [String]) -> [String] {
        var overriddenKeys = Set<String>()
        for entry in overrides {
            overriddenKeys.insert(ShellIntegrationEnvironment.key(of: entry))
        }
        var result: [String] = []
        for entry in base where !overriddenKeys.contains(ShellIntegrationEnvironment.key(of: entry)) {
            result.append(entry)
        }
        return result + overrides
    }

    private static func key(of entry: String) -> String {
        String(entry.prefix(while: { $0 != "=" }))
    }

    private static func value(of key: String, in environment: [String]) -> String? {
        for entry in environment where ShellIntegrationEnvironment.key(of: entry) == key {
            return String(entry.dropFirst(key.count + 1))
        }
        return nil
    }
}
