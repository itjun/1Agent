# 原生终端面板与外部打开：验收边界

日期：2026-10-13。本记录只覆盖本次模型和启动接口修改，不沿用旧版布局的实机验收结论。

- 侧栏一行对应一个 `TerminalPanel`。重排、移组、解散工作区保留整棵分屏树和 panel ID；窗格标题菜单仍能单独操作一个终端。
- 普通“终端 / 文件”切页保留两边现场。旧 dock 路由参数被忽略，文件始终进入独立页面。只有显式“在文件中定位”才导航到终端的主机和目录。
- Finder、GitHub Desktop 的目录请求优先选择仍在同一目录的活动本地终端，按最近焦点排序；带命令的请求始终新建。非法目录明确报错，不回退到 Home 后执行命令。
- 快照版本 2 保存远程已知目录、panel 标题及最后焦点、最近使用顺序、缩放与选中页面；迁移前原始快照保存在 `session.openTabs.backup.v1`。
- 恢复远程会话、“在此打开终端”及复制远程终端，都通过 SSH 认证后的远端启动命令进入已知目录，然后启动登录 shell。不会把 `cd` 写入认证阶段的 PTY，也不会重放终端历史命令。目录不可进入时输出明确错误并在远程 Home 启动 shell；仅该次连接覆盖 `RemoteCommand=none`，不改 SSH 配置。
- `Cmd-T` 和新建按钮统一打开选择器；“当前目录新建终端”仍由 `duplicateAsTab` 提供。

已通过隔离测试：`WorkspaceBoardTests`（含 600 步状态序列）、`ExternalOpenTests`、`PaneLayoutTests`、`SSHLaunchTests`。SSH 启动测试只执行临时的本地替身 shell，验证路径引号/元字符、工作目录与失败回退；没有发起 SSH、读取认证信息或修改用户设置。

真实 SSH 密码/密钥认证、服务器登录脚本是否自行改变目录，以及完整应用重启后的远程目录与 UI 恢复，仍须在授权的集成环境验收。服务器的强制命令或登录脚本可能覆盖客户端请求，不能由离线启动测试证明。

## GitHub Desktop 真实 GUI 验收

2026-10-13，通过 Computer Use 在现有 GitHub Desktop 中选择 `sample-service`，两次点击 **Repository → Open in Shell**。未改变外部软件设置：只读核对其自定义 shell 已配置 `/Applications/1Agent.app`、bundle ID `com.itjun.1agent`、参数 `%TARGET_PATH%`。

- 首次操作进入 1Agent 的本地 `sample-service` 终端。截图中实际命令输出 `1AGENT_GITHUB_DESKTOP=/Users/developer/iWork/sample-service`，确认运行 shell 的工作目录正确。
- 首次操作后，已保存快照共有 14 个会话；该项目唯一会话及独立 panel 的 UUID 为 `C2B883B1-FD1F-4369-B82A-A5E0EAB9AF76`。
- 第二次操作后仍为 14 个会话；同目录匹配仍只有该 UUID，当前 selected 仍为该 UUID，页面为终端。没有新建重复会话。
- 只读核验只提取会话 ID、目录、选中状态和计数，没有读取用户终端历史或写入偏好设置。

实际界面证据：[GitHub Desktop 打开项目终端](qa-captures-2026-10-13/github-desktop-terminal.png)。首次/二次元数据快照为本机 `/tmp/1agent-github-open-first.json` 与 `/tmp/1agent-github-open-second.json`。
