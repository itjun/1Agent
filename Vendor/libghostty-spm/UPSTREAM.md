# libghostty-spm 来源与项目适配

这不是 Ghostty 官方 Swift 包，而是第三方 [Lakr233/libghostty-spm](https://github.com/Lakr233/libghostty-spm) 的 Swift 封装，基线 tag 为 `1.6.20260929`。引擎来自官方 [Ghostty v1.4.0](https://github.com/ghostty-org/ghostty/tree/83fb95624b0439ee660c2679b43b38c8b63769cd)，commit `83fb95624b0439ee660c2679b43b38c8b63769cd`。

`scripts/build-libghostty.sh` 校验官方源码压缩包 SHA-256，然后按 `Patches/series` 应用补丁；缓存同时包含补丁内容与顺序。生成的 framework 不入库。补丁基于第三方封装 `2.2.2026102101` 的 host-managed I/O 和渲染修改，再适配 Ghostty v1.4.0 / Zig 0.17.x；各项用途与删除条件见 [补丁说明](Patches/README.md)。

1Agent 保留 `GhosttyTerminal`、`GhosttyKit`、`MSDisplayLink`。未使用的 `ShellCraftKit` 以及不再参与系统配色的 `GhosttyTheme` 已移除。默认终端颜色由应用的系统颜色和现有 ANSI 调色板生成；独立主题使用引擎锁定版本的离线主题包，来源见 `Resources/GhosttyThemes/SOURCE.md`。

`TerminalController.applyTheme(_:colorScheme:)` 在验证成功后一起更新主题与明暗状态，再刷新所有已保留 surface；不变的选择也视为成功，失败保留之前状态。

## 历史保存与恢复

1Agent 保存带样式文本并恢复显示：使用官方文本读取 API，以及 `select_all` / `copy_to_clipboard:vt` 彩色复制动作；`TerminalOutputStore` 限制行数和字节数，仅保留文本与允许的 SGR 样式，过滤屏幕操作、OSC 和其他控制序列。恢复先向 Ghostty 显示输出注入归档，再启动会话；归档不写入 PTY stdin，也不恢复原来的运行进程或交互式 TUI 状态。

`InMemoryTerminalSession.readScreenText(maxRows:maxBytes:)` 是薄封装，读取当前活动屏幕。SCREEN 文本会连接软换行；VIEWPORT 按物理行读取。不用独立 AppKit 历史视图显示归档，也不新建终端解析器。备用屏幕切换和归档顺序继续沿用应用的现有处理。

官方 C API 会先分配所选文本，再由 Swift 限量；底层临时分配受引擎 scrollback 限制，并非 Swift 字节上限。没有新增专用 C 导出接口来实现第二套限量。

## 验证

`make test-terminal-restoration` 在隔离存储和原生 Ghostty surface 上检查 1,000 行彩色历史、中文/emoji、软换行、跨进程保存恢复、PTY 输入和重连。`make test-terminal-compatibility` / `make test-terminal-stress` 检查终端兼容和压力场景。上游未随包提供测试 fixture，因此未声明原第三方包测试 target；应用测试在 `Tests/`。
