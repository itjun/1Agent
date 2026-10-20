# Run by the remote account's Bash without startup files, then hand off to a real login shell.
source "$GHOSTTY_RESOURCES_DIR/shell-integration/bash/oneagent-agent-sessions"
export -f _oneagent_agent_run _oneagent_report_cwd grok pi omp codex claude
export PROMPT_COMMAND
if [[ $ONEAGENT_SAVED_BASH_ENV_SET == 1 ]]; then export BASH_ENV=$ONEAGENT_SAVED_BASH_ENV; fi
unset ONEAGENT_SAVED_BASH_ENV_SET ONEAGENT_SAVED_BASH_ENV
if [[ ${1:-restore} == restore && -s $GHOSTTY_RESOURCES_DIR/resume.json ]]; then
    exec "$ONEAGENT_SHELL_PATH" -l -i -c '"$ONEAGENT_AGENT_HELPER" resume "$GHOSTTY_RESOURCES_DIR/resume.json"; exec "$ONEAGENT_AGENT_SHELL_START" normal'
fi
exec "$ONEAGENT_SHELL_PATH" -l -i
