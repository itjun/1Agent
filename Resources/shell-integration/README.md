# Ghostty shell 集成脚本

`zsh/` 原样拷贝自 Ghostty 官方仓库 `src/shell-integration/zsh/`（含隐藏文件 `.zshenv`），未做修改。

- 来源：https://github.com/ghostty-org/ghostty
- 来源 commit：`6f51f41d0492ee1125f7bf054619fc31fb21baa2`（2026-09-30）
- 许可：脚本改写自 Kitty 的 zsh 集成，按 GPLv3 分发，许可声明保留在各文件头部。

App 以文件夹引用打包到 `Ghostty.app/Contents/Resources/shell-integration/`。本机 zsh 启动时由
`ShellIntegrationEnvironment` 按官方 `src/termio/shell_integration.zig` 的规则注入：
`ZDOTDIR` 指向这里的 `zsh/`，原 `ZDOTDIR` 存入 `GHOSTTY_ZSH_ZDOTDIR`，`.zshenv` 会把它恢复并加载用户自己的配置。

更新时整体替换 `zsh/` 并改上面的 commit。
