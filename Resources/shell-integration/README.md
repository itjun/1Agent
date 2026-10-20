# Ghostty shell 集成脚本

`zsh/` 基于 Ghostty 官方仓库 `src/shell-integration/zsh/`（含隐藏文件 `.zshenv`），另接入 1Agent 的指令与 Agent 会话桥接。

- 来源：https://github.com/ghostty-org/ghostty
- 来源 commit：`6f51f41d0492ee1125f7bf054619fc31fb21baa2`（2026-09-30）
- 许可：脚本改写自 Kitty 的 zsh 集成，按 GPLv3 分发，许可声明保留在各文件头部。

App 以文件夹引用打包到 `1Agent.app/Contents/Resources/shell-integration/`。本机 zsh 启动时由
`ShellIntegrationEnvironment` 按官方 `src/termio/shell_integration.zig` 的规则注入：
`ZDOTDIR` 指向这里的 `zsh/`，原 `ZDOTDIR` 存入 `GHOSTTY_ZSH_ZDOTDIR`，`.zshenv` 会把它恢复并加载用户自己的配置。

更新时整体替换 `zsh/` 并改上面的 commit。

其他 Shell：

- `bash/ghostty.bash`、`bash-preexec.sh` 来自本仓库固定的 `Vendor/libghostty-spm`，使用 MIT 许可；bash-preexec 的许可见同目录 `LICENSE-bash-preexec.md`。自动注入面向支持 ENV 的 Bash，Apple 自带 `/bin/bash` 按上游规则跳过自动检测。
- `fish/`、`elvish/`、`nushell/` 来自 Ghostty `0538f7535be0` 的对应 `src/shell-integration/` 目录，与当前引擎版本一致，按 Ghostty MIT 许可分发。上游许可见 https://github.com/ghostty-org/ghostty/blob/0538f7535be0/LICENSE 。
- fish/elvish/nushell 通过临时 XDG_DATA_DIRS 入口加载，保留原有路径，脚本在启动后清理临时入口。Nushell 额外执行 `use ghostty *`。
- `ssh-env` 和 `ssh-terminfo` 不会导向外部 `ghostty +ssh`。1Agent 的 SSH 终端使用自身的远端 Shell、terminfo 与 Agent 引导路径。

测试区分环境和参数生成检查、实际 Shell 运行。未安装的 Shell 不记为运行验收通过。
