import Foundation

/// All adapter files live under a fresh private directory for this authenticated SSH channel.
enum RemoteAgentBootstrap {
    static func command(resources: String, token: String, conversation: Data?, directory: String?,
                        startupCommand: String?, unavailableMessage: String, restoreError: String) -> String? {
        guard UUID(uuidString: token) != nil else { return nil }
        let files = [
            "shell-integration/zsh/.zshenv", "shell-integration/zsh/ghostty-integration",
            "shell-integration/zsh/oneagent-quick-commands", "shell-integration/zsh/oneagent-agent-sessions",
            "shell-integration/bash/oneagent-agent-sessions", "agent-sessions/remote-agent-session.py",
            "agent-sessions/session-extension.mjs", "agent-sessions/bash-launch.sh",
        ]
        var writes: [String] = []
        for file in files {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: resources).appendingPathComponent(file)) else { return nil }
            writes.append("printf '%s' \(quote(data.base64EncodedString())) | base64 -d > \"$d/\(file)\" || exit 1")
        }
        if let conversation {
            writes.append("printf '%s' \(quote(conversation.base64EncodedString())) | base64 -d > \"$d/resume.json\" || exit 1")
        }
        let helper = """
        #!/bin/sh
        exec "$ONEAGENT_AGENT_PYTHON" "$GHOSTTY_RESOURCES_DIR/agent-sessions/remote-agent-session.py" "$@"
        """
        let launcher = """
        #!/bin/sh
        mode=${1:-restore}
        case "${ONEAGENT_SHELL_PATH##*/}" in
          bash)
            if [ "${BASH_ENV+x}" = x ]; then export ONEAGENT_SAVED_BASH_ENV_SET=1 ONEAGENT_SAVED_BASH_ENV="$BASH_ENV"; fi
            unset BASH_ENV
            exec "$ONEAGENT_SHELL_PATH" --noprofile --norc "$GHOSTTY_RESOURCES_DIR/agent-sessions/bash-launch.sh" "$mode";;
          zsh)
            if [ "${ZDOTDIR:-}" != "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh" ]; then
              if [ "${ZDOTDIR+x}" = x ]; then export GHOSTTY_ZSH_ZDOTDIR="$ZDOTDIR"; else unset GHOSTTY_ZSH_ZDOTDIR; fi
              export ZDOTDIR="$GHOSTTY_RESOURCES_DIR/shell-integration/zsh"
            fi
            if [ "$mode" = restore ] && [ -s "$GHOSTTY_RESOURCES_DIR/resume.json" ]; then
              exec "$ONEAGENT_SHELL_PATH" -l -i -c '"$ONEAGENT_AGENT_HELPER" resume "$GHOSTTY_RESOURCES_DIR/resume.json"; exec "$ONEAGENT_AGENT_SHELL_START" normal'
            fi
            exec "$ONEAGENT_SHELL_PATH" -l;;
        esac
        exec "$ONEAGENT_SHELL_PATH" -l
        """
        writes.append("printf '%s' \(quote(Data(helper.utf8).base64EncodedString())) | base64 -d > \"$d/agent-helper\" || exit 1")
        writes.append("printf '%s' \(quote(Data(launcher.utf8).base64EncodedString())) | base64 -d > \"$d/launch-shell\" || exit 1")
        let fallback = startupCommand.map { "/bin/sh -c " + quote($0) } ?? "\"${SHELL:-/bin/sh}\" -l"
        let start = startupCommand.map { "/bin/sh -c " + quote($0) } ?? "\"$d/launch-shell\""
        let changeDirectory: String
        if let directory, directory.hasPrefix("/"), !directory.contains("\0") {
            changeDirectory = "if ! cd -- \(quote(directory)); then printf '%s\\n' \(quote(restoreError)) >&2; cd -- \"${HOME:-/}\" || exit 1; fi"
        } else { changeDirectory = "" }
        let script = """
        case "${SHELL##*/}" in zsh|bash) ;; *) printf '%s\\n' \(quote(unavailableMessage)) >&2; exec \(fallback);; esac
        py=$(command -v python3) || { printf '%s\\n' \(quote(unavailableMessage)) >&2; exec \(fallback); }
        "$py" -c 'import os,sys; sys.exit(sys.version_info < (3,9) or not hasattr(os,"posix_spawn"))' || { printf '%s\\n' \(quote(unavailableMessage)) >&2; exec \(fallback); }
        d=\(quote(RemoteShellIntegration.remoteFolder(token: token)))
        umask 077
        if ! mkdir "$d"; then exec \(fallback); fi
        cleanup() { if [ -n "${agent_service:-}" ]; then kill "$agent_service" 2>/dev/null; wait "$agent_service" 2>/dev/null; fi; rm -rf -- "$d"; }
        trap cleanup EXIT
        trap 'exit 0' HUP TERM
        mkdir -p "$d/shell-integration/zsh" "$d/shell-integration/bash" "$d/agent-sessions" || exit 1
        \(writes.joined(separator: "\n"))
        chmod 700 "$d/agent-helper" "$d/launch-shell" || exit 1
        export ONEAGENT_AGENT_PYTHON="$py" ONEAGENT_AGENT_HELPER="$d/agent-helper" ONEAGENT_AGENT_STATE="$d/invocation.json"
        export ONEAGENT_AGENT_RESOURCES="$d/agent-sessions" ONEAGENT_AGENT_TOKEN=\(quote(token))
        export ONEAGENT_AGENT_RESTORE_ERROR=\(quote(restoreError + "\n"))
        export ONEAGENT_SHELL_PATH="${SHELL:-/bin/sh}" ONEAGENT_AGENT_SHELL_START="$d/launch-shell"
        if [ "${ZDOTDIR+x}" = x ]; then export GHOSTTY_ZSH_ZDOTDIR="$ZDOTDIR"; else unset GHOSTTY_ZSH_ZDOTDIR; fi
        export ZDOTDIR="$d/shell-integration/zsh" GHOSTTY_RESOURCES_DIR="$d" GHOSTTY_SHELL_FEATURES=path,title
        export ONEAGENT_QC_SOCKET="$d/s" ONEAGENT_QC_TOKEN=\(quote(token)) ONEAGENT_QC_READ_TIMEOUT=5
        unset ONEAGENT_QC_OWNER ONEAGENT_AGENT_INVOCATION
        "$py" "$d/agent-sessions/remote-agent-session.py" serve </dev/null >/dev/null 2>&1 &
        agent_service=$!
        \(changeDirectory)
        \(start)
        """
        return "exec /bin/sh -c " + quote(script)
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
