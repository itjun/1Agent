import Foundation

/// 只识别启动命令的位置，不在提示词、文件内容或终端输出里搜索程序名。
struct TerminalProgram: Equatable {
    enum Kind: String { case shell, pi, omp, claude, codex, grok, python, htop, btop, vim, nvim, command }
    let kind: Kind
    let name: String

    static func identify(command: String) -> TerminalProgram? {
        TerminalProgram.identify(arguments: TerminalProgram.words(command))
    }

    static func identify(arguments: [String]) -> TerminalProgram? {
        var args = arguments
        while let first = args.first {
            if first.contains("="), !first.hasPrefix("/"), first.first != "-" { args.removeFirst(); continue }
            let name = (first as NSString).lastPathComponent.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if ["command", "exec", "nohup", "builtin"].contains(name) { args.removeFirst(); continue }
            if name == "sudo" || name == "env" {
                args.removeFirst()
                while let option = args.first, option.hasPrefix("-") {
                    args.removeFirst()
                    if ["-u", "-g", "-h", "-p", "--user", "--group", "--unset"].contains(option), !args.isEmpty { args.removeFirst() }
                }
                continue
            }
            if ["npx", "bunx", "uvx"].contains(name) {
                args.removeFirst()
                while args.first?.hasPrefix("-") == true { args.removeFirst() }
                continue
            }
            if name == "uv", args.dropFirst().first == "run" { args.removeFirst(2); continue }
            if ["node", "bun", "deno"].contains(name), let script = args.dropFirst().first {
                if script.contains("@oh-my-pi/") { return .init(kind: .omp, name: "OMP") }
                if script.contains("pi-coding-agent/") { return .init(kind: .pi, name: "Pi") }
                if script.contains("@anthropic-ai/claude-code/") { return .init(kind: .claude, name: "Claude Code") }
                if script.contains("@openai/codex/") { return .init(kind: .codex, name: "Codex") }
                if script.hasSuffix("grok.js") || script.contains("grok-cli/") { return .init(kind: .grok, name: "Grok") }
            }
            switch name {
            case "pi", "pi-coding-agent": return .init(kind: .pi, name: "Pi")
            case "omp", "oh-my-pi": return .init(kind: .omp, name: "OMP")
            case "claude", "claude-code": return .init(kind: .claude, name: "Claude Code")
            case "codex": return .init(kind: .codex, name: "Codex")
            case "grok", "grok-cli": return .init(kind: .grok, name: "Grok")
            case "htop": return .init(kind: .htop, name: "htop")
            case "btop": return .init(kind: .btop, name: "btop")
            case "vim", "vi": return .init(kind: .vim, name: "Vim")
            case "nvim": return .init(kind: .nvim, name: "Neovim")
            case "zsh", "bash", "fish", "sh", "dash", "ksh", "nu", "elvish", "pwsh": return .init(kind: .shell, name: name)
            default:
                if name.range(of: "^(python([0-9]+(\\.[0-9]+)*)?|ipython[0-9]*)$", options: .regularExpression) != nil {
                    return .init(kind: .python, name: name)
                }
                return .init(kind: .command, name: name)
            }
        }
        return nil
    }

    private static func words(_ text: String) -> [String] {
        var words: [String] = [], word = "", quote: Character?, isEscaped = false
        for char in text.prefix(4096) {
            if isEscaped { word.append(char); isEscaped = false; continue }
            if char == "\\", quote != "'" { isEscaped = true; continue }
            if let current = quote {
                if char == current { quote = nil } else { word.append(char) }
            } else if char == "'" || char == "\"" { quote = char }
            else if char.isWhitespace { if !word.isEmpty { words.append(word); word = "" } }
            else if "|;&<>".contains(char) { break }
            else { word.append(char) }
        }
        if !word.isEmpty { words.append(word) }
        return words
    }
}
