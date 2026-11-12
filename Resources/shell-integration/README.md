# Shell 集成来源

脚本版本与引擎版本分别固定，本轮不升级脚本。以下已逐文件与来源比较。

| 文件 | 来源 | 本项目差异 |
| --- | --- | --- |
| `zsh/.zshenv` | [Ghostty 6f51f41d0492ee1125f7bf054619fc31fb21baa2](https://github.com/ghostty-org/ghostty/tree/6f51f41d0492ee1125f7bf054619fc31fb21baa2/src/shell-integration/zsh) | 完全一致 |
| `zsh/ghostty-integration` | 同上 | 仅在 deferred init 末尾增加 `ONEAGENT_QC_SOCKET` 存在时加载 `oneagent-quick-commands` 的四行；其余与来源一致 |
| `zsh/oneagent-quick-commands` | 1Agent 项目代码 | 快捷指令和 Agent 会话桥接，单独维护 |
| `bash/ghostty.bash` | 第三方 Lakr233/libghostty-spm `1.6.20260929` 内 `Sources/GhosttyTerminal/Resources/Ghostty/shell-integration/bash` | 与当前 vendored wrapper 完全一致，MIT；不是 Ghostty 官方 bash 脚本 |
| `bash/bash-preexec.sh` | 同一 wrapper 中的 bash-preexec 副本 | 完全一致，版本和署名保留在文件头 |
| `bash/LICENSE-bash-preexec.md` | 同一 wrapper 中的许可文件 | 完全一致 |
| `fish/vendor_conf.d/ghostty-shell-integration.fish` | [Ghostty 0538f7535be0](https://github.com/ghostty-org/ghostty/tree/0538f7535be0/src/shell-integration) | 完全一致 |
| `elvish/lib/ghostty-integration.elv` | 同上 | 完全一致 |
| `nushell/vendor/autoload/ghostty.nu` | 同上 | 完全一致 |

zsh 改写自 Kitty，GPLv3 声明保留在脚本中；fish/elvish/nushell 使用 Ghostty MIT 许可，见 `LICENSE-ghostty`。这些历史来源不等于当前引擎 v1.4.0 的源码版本。

App 按文件夹打包这些脚本。`ShellIntegrationEnvironment` 设置 `ZDOTDIR` 并通过 `GHOSTTY_ZSH_ZDOTDIR` 保留用户原配置；fish/elvish/nushell 用临时 XDG_DATA_DIRS 入口，在启动后清理。Nushell 额外执行 `use ghostty *`。Apple `/bin/bash` 沿用现有规则跳过自动检测。

`ssh-env` / `ssh-terminfo` 不转到外部 `ghostty +ssh`；1Agent 的远程终端由系统 OpenSSH 和项目远端引导负责。桥接生成逻辑在 `Sources/GooseAgent/RemoteShellIntegration.swift` 等应用文件中，不混记为官方 Shell 脚本。

修改时分别维护上游差异和 1Agent 桥接；更新来源必须重新逐文件比较。环境/参数测试和真实 Shell 运行分开报告，未安装的 Shell 不计为实际验证通过。
