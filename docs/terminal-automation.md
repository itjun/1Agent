# 终端窗口与自动化

1Agent 使用自己的应用身份 `com.itjun.1agent`、`oneagent://` 和 `/Applications/1Agent.app`。终端引擎随应用打包，运行窗口、命令行与 AppleScript 不需要安装 Ghostty。

## 单窗口

- 1Agent 只有一个终端窗口。所有终端都在这个窗口里，用左侧侧栏的垂直标签切换；不提供横向标签（macOS 标题栏标签），也不提供新建窗口或浮动的快速终端。
- 关闭窗口（红色按钮、⇧⌘W）不确认，只隐藏窗口，会话继续运行；点 Dock 图标恢复。⌘Q 先保存输出、会话快照并停止 Agent 会话，再结束所有终端会话及其进程（包括忽略挂断信号的后台任务），下次启动时恢复。旧版本保存的多个窗口（含快速终端）在启动时合并进这个窗口。
- Finder 的“在此新建 1Agent 标签”每次在窗口中新建终端；选择文件时进入其父目录。
- GitHub Desktop、`open` 和 Finder 打开的文件夹都作为新终端加入窗口。GitHub Desktop 自定义 Shell：Path 为 `/Applications/1Agent.app`，Arguments 为 `%TARGET_PATH%`。旧的 `--new-window`、`--tab` 和 `window=` 参数会被忽略。
- 安全键盘输入支持本机规范模式下的密码输入检测，也可手动打开。输入框、弹窗、其他应用获得焦点，或退出时，释放本应用持有的安全输入引用。远端密码可手动启用。

## 命令行

在“系统集成 → 自动化”安装命令行工具，位置为 `~/.local/bin/1agent`。

```sh
1agent --working-directory="$PWD"
1agent --wait-after-command -e /usr/bin/printf '%s\n' '带 空格的参数'
```

每次在 1Agent 窗口中新建终端。运行中的实例确认接收后返回，交接超时会返回失败。冷启动返回 LaunchServices 的启动请求状态。程序参数在 `-e` 后保留原有边界与引用。

## AppleScript

“系统集成”可整体关闭终端自动化。窗口、标签和终端均有稳定 UUID；输入和操作必须指定终端。失效 ID、无效目录与配置返回脚本错误。

```applescript
tell application id "com.itjun.1agent"
    set cfg to new surface configuration
    set initial working directory of cfg to "/tmp"
    set newTab to new tab with configuration cfg
    set term to focused terminal of newTab
    input text "printf 'hello\\n'" to term
    send key "enter" to term
    return id of term
end tell
```

脚本字典提供新建标签、分屏、聚焦、选择与关闭（没有新建窗口命令，`new_window` 动作返回脚本错误），以及文本、物理键、鼠标与引擎动作。配置支持初始目录、命令、初始输入、环境变量、字号和命令结束后保留 Shell。命令与环境覆盖只用于这一次创建，不会在会话恢复时重新执行。

`input text` 使用粘贴语义；执行需要明确的 Enter。`send key` 支持字符、功能键与命名物理键；`action release` 在传统终端模式中通常不产生字节。原生输入法仍由实际终端视图处理。

## 系统快捷指令的当前限制

已提供“打开 1Agent 终端”“聚焦 1Agent 终端”“向 1Agent 终端输入文本”三个 App Intent，系统操作库能显示中文名称。当前本机使用自签名证书，没有有效 Apple Team ID；macOS 的 `linkd` 拒绝建立 App Intents 通信，实测不能运行原生动作。需要使用有效的 Apple 开发者签名后重新验收，不能将元数据生成或操作可搜索记为执行通过。

本机快捷指令的“运行脚本”也处于关闭状态，本次未修改该系统安全设置。AppleScript 已通过 `osascript` 的真实端到端调用，可用于现有脚本与开发工具。

## 回归命令

先执行 `make build`，再执行测试，避免测试链接的应用模块在构建中被替换。

```sh
make test
make test-terminal-windows test-sidebar-groups test-terminal-restoration
make test-terminal-automation
make test-terminal-compatibility
make test-terminal-stress
```

`test-terminal-windows` 使用隔离偏好与原生 AppKit 窗口，Shell 夹具仅运行 `cat` 或本测试自身；覆盖多窗口存档合并为单窗口、终端归属、保存与恢复、缩放、脚本对象描述符和安全输入生命周期。`test-terminal-automation` 操作已安装应用，只向新建的测试终端输入，不退出应用。

`test-terminal-compatibility` 需要 GNU Bash、fish、Elvish、Nushell 和 tmux（可通过 Homebrew 安装），另使用系统 Zsh/Vim。它运行真实 PTY、内嵌引擎、协议回包、剪贴板权限判断、TUI、原生窗口及全屏测试，默认功能与全部功能关闭各测一次。测试打开临时窗口并短暂进入全屏；HOME、XDG 及偏好隔离，IP 网络被禁止，tmux 使用自己的 Unix socket。剪贴板仅写入测试标记，并在没有其他应用改写时恢复原内容。

多屏测试驱动真实 NSWindow/AppKit 的 1x/2x backing 与 screen-change 回调，检查 Metal 缩放、PTY 像素、窗口重新挂载和内容保持；同时自动正反遍历所有已连接的真实显示器，检查屏幕归属和内容。物理显示器的组合仍需在对应硬件上验收，不能将缩放注入等同于真实双屏。

`test-terminal-stress` 在约一分钟内持续写入约 121 MiB 数据，验证每批尾部、查询响应、导出上限及预热后的内存范围。终端的异步输入需等待应用状态变化；窗口缩小后应同时检查滚动历史，不能仅凭当前视口判断内容丢失。

## Shell 集成

Zsh、GNU Bash、fish 和 Nushell 自动加载随应用打包的集成。Apple 的 `/bin/bash` 3.2 不支持 ENV 注入，检测模式与上游一样跳过；可使用 GNU Bash，或在自己的 rc 中手动加载 Bash 集成脚本。

Elvish 与固定版本上游相同：应用提供模块搜索路径，用户的 Elvish rc 需要导入模块。测试使用隔离 rc 环境并显式执行该导入，不修改用户配置：

```elvish
try { use ghostty-integration } catch { }
```

关闭全部可选功能时，应用显式传递空的 `GHOSTTY_SHELL_FEATURES`，清除父进程遗留的启用项，并保证 Nushell 的 `ssh`/`sudo` 包装器仍能读取该环境字段。`ssh-env`/`ssh-terminfo` 不会注入，因为应用使用自己的远程连接准备流程。

集成资源和启动行为参考[固定引擎版本的上游说明](https://github.com/ghostty-org/ghostty/blob/0538f7535be0/src/shell-integration/README.md)，协议用例参考 [Ghostty VT 文档](https://ghostty.org/docs/vt/reference)与 [Kitty 键盘协议](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)。

2026-10-19 的崩溃先由 Cocoa Scripting 转换异步返回值时抛出 Objective-C 异常，随后在终端布局的 Swift 执行器检查中表现为 SIGSEGV。现在返回引用先验证完整描述符，回复转换的异常被限制在 Objective-C 边界，转成脚本错误；禁止通过关闭执行器检查来掩盖问题。另一次 `TerminalWindowsTests` 报告来自测试本身对 `/var` 和 `/private/var` 路径的错误断言，现已改为规范化路径和普通失败退出。
