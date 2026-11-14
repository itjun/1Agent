import Foundation

@main enum TerminalProgramTests {
    static func main() {
        let cases: [(String, TerminalProgram.Kind?)] = [
            ("", nil), ("pi", .pi), ("omp --resume", .omp), ("claude --resume id", .claude),
            ("codex resume abc", .codex), ("grok", .grok), ("htop", .htop), ("btop", .btop),
            ("vim a.py", .vim), ("nvim", .nvim), ("/bin/zsh -l", .shell), ("-zsh", .shell),
            ("python3.14 -m http.server", .python), ("ipython3", .python),
            ("FOO=1 env -u BAR /usr/local/bin/pi", .pi), ("sudo -u root htop", .htop),
            ("npx --yes @openai/codex", .codex), ("uv run python main.py", .python),
            ("node '/a folder/node_modules/@anthropic-ai/claude-code/cli.js'", .claude),
            ("bun /a/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js", .omp),
            ("node /a/node_modules/@earendil-works/pi-coding-agent/dist/cli.js", .pi),
            ("node /a/node_modules/@openai/codex/bin/codex.js", .codex),
            ("echo 'claude codex pi'", .command), ("cat /tmp/codex", .command),
            ("python test.py --agent codex", .python), ("echo ok && pi", .command),
            ("rg pi | cat", .command), ("not-python pi", .command)
        ]
        for (command, expected) in cases {
            precondition(TerminalProgram.identify(command: command)?.kind == expected, command)
        }
        print("TerminalProgramTests passed: commands, launchers, quoting, versions and false positives")
    }
}
