import Foundation

/// Variables that make a local zsh load Ghostty's shell integration from the app bundle, following
/// Ghostty's `src/termio/shell_integration.zig`. Only zsh is injected. SSH launches never use this,
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
        if !ShellIntegrationEnvironment.injectsZsh(settings.shellIntegration, shellPath: shellPath) {
            return []
        }
        guard let resourcesPath else { return [] }
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
        if let features = ShellIntegrationEnvironment.features(
            settings.shellIntegrationFeatures,
            cursorBlink: settings.cursorBlink
        ) {
            result.append("GHOSTTY_SHELL_FEATURES=\(features)")
        }
        return result
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
    /// Nil when nothing is enabled; Ghostty leaves the variable unset then.
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
