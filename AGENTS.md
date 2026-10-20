# 1Agent — 给助手的约定（压缩版）

- **中文优先**：所有用户可见文案必须有 `zh-Hans`；新增 `String(localized:)` / `Label` / `Text` / `Button` / `.help` / `LocalizedStringKey` 时同步写入 `Resources/Localizable.xcstrings`（en + zh-Hans），禁止界面残留英文（专有名词如 Agent、Mac、SSH、路径可保留）。
- **设置与弹窗尺寸**：共用 `SheetLayout` / Settings 最小宽高；改尺寸只改常量，勿各写死。
- **快捷键**：走 `AppShortcuts`；侧栏 hover 显示当前绑定；勿再写死 ⌘⌥ 组合。
- **构建与运行**：改完 `make build`；确认 `/Applications/1Agent.app` 已替换且正在运行的是新安装的应用。安装或重启失败不能只报编译成功，须处理失败并如实说明运行状态；编译通过与实际界面验证分别报告。
- **App 身份**：App 名 1Agent、包名 `com.itjun.1agent`、URL 协议 `oneagent://`。官方 Ghostty 保持包名 `com.mitchellh.ghostty` 与 `ghostty://`。Swift 模块名仍为 GooseAgent，工程/target 仍为 `1Agent`。安装到 `/Applications/1Agent.app`。若 `/Applications/Ghostty.app` 是本应用以前的顶替构建（可执行文件名为 `Ghostty`，且不是官方团队签名），安装脚本会删掉它，并在 `~/iLearn/backups` 有官方备份时还原官方 Ghostty。
- **分支与提交**：默认始终在 `main` 开发；需要提交时按超级原子提交拆分，每个提交只包含一个可独立回退的产品事实；用户明确要求时才推送或合并。
