# Agent 对话恢复调研

> 历史方案，已于 2026-10-25 移除。1Agent 仅提供普通终端，不再包装 AI CLI、注入扩展或参数、记录和自动恢复 Agent 对话。以下内容保留为历史调研记录。

核查日期：2026-10-19。目标行为：退出 1Agent 时停止 Agent；重开时载入该终端原来的对话，等待用户继续。恢复不重放启动 prompt，不自动续跑被打断的任务，也不以“当前目录最近会话”猜测身份。

本机只运行了帮助、版本等只读命令；没有发起模型请求，没有修改 Agent 配置或会话。已安装 Pi 1.3.0（`@earendil-works/pi-coding-agent`）和 Grok 1.0.62（`1474f9cbdd91`）；OMP、Claude 当前未找到可执行文件，以下对它们的结论来自官方文档或源码，仍需安装后的端到端验收。

## 精确恢复入口

| Agent | 推荐恢复 argv | 会话身份及边界 |
| --- | --- | --- |
| Pi | `pi --session /absolute/session.jsonl` | 使用绝对文件路径；`--continue` 取目录最近会话，`--resume` 打开选择器。`--session-id` 在缺失时创建，不能当作存在性验证。 |
| OMP | `omp --resume /absolute/session.jsonl` | 绝对路径避免 UUID 前缀解析碰撞；`--session` 是 `--resume` 的别名。不要用会自动续跑中断 turn 的 `--restore`。 |
| Grok | `grok --resume <UUID>` | UUID 精确指向会话；title 可重名，`--resume` 无参数和 `--continue` 都会选最近会话。`--session-id` 只创建新会话。 |
| Claude | `claude --resume <UUID>` | UUID 精确恢复。新版也支持绝对 JSONL 路径，但安装版本应再查帮助。不要追加旧 prompt、`--continue` 或 `--fork-session`。 |

依据：[Pi CLI](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli.md)、[OMP flag tables](https://github.com/can1357/oh-my-pi/blob/main/packages/coding-agent/src/cli/flag-tables.ts)、[OMP restore 校验](https://github.com/can1357/oh-my-pi/blob/main/packages/coding-agent/src/cli/args.ts)、[Grok sessions](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/17-sessions.md)、[Claude CLI reference](https://code.claude.com/docs/en/cli-reference)。Pi 与 Grok 的恢复参数同时通过本机 `--help` 核实。

## Pi：用每次调用的扩展准确绑定终端

- 本机默认文件形如 `~/.pi/agent/sessions/--<encoded-cwd>--/<timestamp>_<id>.jsonl`；首行 header 字段为 `type: session`、`version`、`id`、`timestamp`、`cwd`，可选 `parentSession`。自定义存储可通过 `--session-dir`、`PI_CODING_AGENT_SESSION_DIR`、设置项覆盖，应保存真实路径，避免硬推导目录。
- 1.3.0 的 `session_start` 在 `startup/reload/new/resume/fork` 后触发；从 `ctx.sessionManager.getSessionFile()`、`getSessionId()` 与 `ctx.cwd` 取身份。用命令级 `-e <1Agent 扩展绝对路径>` 加载，不必改用户的全局扩展列表。
- 会话文件在第一条 user/assistant message 出现后才落盘；仅打开空会话就退出可能没有文件。记录路径不等于已保存，恢复前必须验证文件存在、header ID 匹配。
- 同步追加的是已经形成的消息；不能承诺保存仍在流式生成中的每一个字符。

依据：[Pi session format](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/session-format.md)、[Pi session manager](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/session-manager.ts)、[Pi extension event types](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/extensions/types.ts)。以上也逐项核对了本机包的 `docs/` 和 `dist/`。

## OMP：事件与格式与 Pi 有差异

- 同时订阅 `session_start`（首次加载）和 `session_switch`（`new/resume/fork` 后）。上下文有 `ctx.sessionManager`、`ctx.mode` 和 `ctx.agent`；只记录 `mode === "tui"`、`agent.kind === "main"`，防止子 Agent 继承终端环境后覆盖主会话。Pi 旧版无这些字段时需能力检测。
- 默认文件在 `~/.omp/agent/sessions/<encoded-cwd>/`。新版物理第一行可为固定宽度 `type: title` 槽，之后才是 `type: session` header；旧版可能直接以 header 开始。不要只解析第一行。
- OMP 会在文件被另一活进程占有或发生写入冲突时迁到新 ID 的 sibling 文件；分支、会话切换和 turn 结束后应重新读取当前路径，不能永久缓存第一次路径。保存仅完成的消息；`flush()` 无 `fsync`，不能承诺断电时的完整性。

依据：[OMP shared events](https://github.com/can1357/oh-my-pi/blob/main/packages/coding-agent/src/extensibility/shared-events.ts)、[OMP extension context](https://github.com/can1357/oh-my-pi/blob/main/packages/coding-agent/src/extensibility/extensions/types.ts)、[OMP session format and persistence](https://github.com/can1357/oh-my-pi/blob/main/docs/session.md)。

## Grok：已有 PID 到会话的注册表

官方 `ActiveSession` 为 `{ session_id, pid, cwd, opened_at }`，保存在 `$GROK_HOME/active_sessions.json`（默认 `~/.grok`）。文件是数组；正常退出删除，崩溃可能遗留，后续注册会清理已死 PID。本机核查时数组为空，未读取或输出用户 prompt。

可在进程仍活着时，将注册项 PID 与该终端的进程树绑定，并验证 `opened_at` 不早于该 PID 的进程开始时间，拒绝 PID 重用遗留项。该表按 `session_id` 去重，允许一个 PID 有多个会话；多个匹配不能据时间猜当前会话，应视为歧义。

持久化布局为 `sessions/<urlencoded-cwd>/<UUID>/`；`summary.json` 的 `info.id/info.cwd` 提供校验，`updates.jsonl` 是恢复依据。本机 header schema 与官方文档相符。不要为恢复添加 `--restore-code`，该参数会涉及代码快照。

依据：[Grok active-session registry](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-active-sessions/src/lib.rs)、[Grok storage and resume](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/17-sessions.md)。

## Claude：会话级 hook 提供精确身份

`SessionStart` hook 输入包含 `session_id`、`transcript_path`、`cwd` 和 `source`（如 `startup/resume/clear/fork`）；可以在开始、切换和清空后更新终端绑定。通过该次调用的 `--settings <JSON>` 注入 hook 可避免写全局配置；若用户已有 `--settings`，需要合并或明确兼容，不能覆盖其原参数。受管策略、禁用 hook 或安全模式可能阻止扩展，应呈现无法准确恢复的状态。

`--no-session-persistence` 以及 `CLAUDE_CODE_SKIP_PROMPT_HISTORY` 禁止会话持久化，不能覆盖用户选择。headless、远程云任务、后台任务等启动方式应排除普通终端恢复。未安装版本不能声称已实测。

依据：[Claude hooks](https://code.claude.com/docs/en/hooks)、[Claude CLI reference](https://code.claude.com/docs/en/cli-reference)。

## 关闭与恢复的实现约束

Codex 使用 `codex resume <UUID>`，不附加 prompt。当前本机 CLI 0.163.0-alpha.10.2 支持 `--no-daemon`；终端内按此模式启动，使退出 TUI 同时结束该终端独有的 Agent 运行。通过该进程当前打开的 `thread-writer-locks/<UUID>.lock`（旧版可为 `sessions/...jsonl`）识别 ID，多重身份拒绝猜测；不添加需用户信任的 Codex hook，也不绕过 hook 信任。[官方 CLI 参考](https://learn.chatgpt.com/docs/cli/reference)、[官方 hooks 信任规则](https://learn.chatgpt.com/docs/hooks)。锁文件识别属于本机实现适配，已通过实际 CLI 空闲启动核对，不应视为稳定公共 API。

本机新版本 Codex 未使用的空会话不会持久保存。实现只读该进程已打开的 `state_*.sqlite`，按精确 ID 查询 `threads.cwd` 且要求 `has_user_event = 1`，以免保存仅有进程锁、尚无历史的会话；旧版以所属 JSONL header 提供 cwd。数据库表结构同样属于版本适配，未知结构时拒绝猜测，不读取 prompt 正文。

1. 只将终端 UUID、Agent 类型、当前会话 ID/路径、cwd、可执行入口以及校验信息保存在 1Agent 状态中；不复制对话正文、凭据或完整启动 argv。
2. 用该终端独有的私有状态文件/随机标识接收扩展报告，并校验报告进程属于终端。子进程继承环境不意味着它可以替换主会话；重新进入 shell 时清理活动标记。
3. 应用退出前先取最终身份，再给 Agent 首次 `SIGTERM` 或 `SIGHUP`，保留 PTY 读取和进程等待窗口，最后才清理终端。Pi 1.3.0 的这些信号先 dispose runtime 并发出 `session_shutdown`；Grok 首次信号走与 `/exit` 相同的 graceful quit，第二信号才强退。不能立即关闭 PTY 后声称所有会话完整保存。
4. Grok 使用共享 leader；不要用 `grok leader kill` 或全局按名称杀进程。客户端断开时 leader 会驱逐不再被观看的会话，其他客户端仍可能使用同一 leader。
5. 恢复前检查路径存在、ID 匹配、目录和宿主对应、Agent 可执行；缺失或歧义时留在 shell 并说明原因，不降级到 latest、不静默新建会话。
6. 恢复时仅启动精确 resume 命令；输入留空。若退出时有未完成的外部命令，其副作用不能靠对话恢复回滚；验收应覆盖正在生成时退出与停止后的持久化边界。

信号依据：[Pi interactive shutdown](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/modes/interactive/interactive-mode.ts)、[Grok graceful signal handling](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/src/app/signal_handler.rs)、[Grok shared leader disconnect](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/leader/server.rs)。其余为基于上述能力提出的 1Agent 实现建议。

## 验收边界

至少验证同目录的两个终端各自恢复不同会话、运行中 `/new`/`/resume`/fork 后恢复新身份、Agent 正常退出回 shell 后不误复活、无会话持久化选项不被覆盖、会话缺失或命令缺失有明确提示；并实际退出和重开 `/Applications/1Agent.app`，分别报告编译结果与运行验证。SSH 上的 Agent 若未部署相应宿主桥接，不应声称已具备本机会话恢复能力。

## 本次实现与验证

- 实现范围包括启用 Shell 集成的本机 zsh，以及普通 SSH 登录终端的 Bash/Zsh。SSH 主机需有 Python 3.9 或更新版本；私有适配资源只放在当前连接的临时目录内，不改用户的 shell 配置。尊重同名 function、自定义 RemoteCommand/tmux；绝对路径直接调用和禁用持久化的调用不自动接管。
- 已运行 `make test-agent-sessions`（五种模拟 CLI 的真实子进程/信号/恢复集成测试、Pi/OMP 扩展事件隔离）、`scripts/test-terminal-restoration.sh`、Shell 集成专项测试。模拟适配测试不等同于五种真实 CLI 全部验收。
- 已对用户正在使用的 Pi 会话实际退出、重开安装版 1Agent。会话 ID `01a1528d-194b-71aa-94be-b9ed8928d569` 保持一致，原 11 个终端保留，旧 Pi/监督进程退出；界面重新呈现原来的对话，输入为空。未重放用户任务。
- 已在独立临时目录让真实 Codex 完成一条无工具的短验证消息，停止后按精确 ID 恢复；内核 writer lock 与该 ID 一致，恢复前后 turn 数仍为 1。没有改动用户项目。
- Grok 依据本机帮助和官方注册表格式完成适配及模拟集成测试；OMP、Claude 本机缺少可执行文件，尚未做真实 CLI 恢复验收。
- SSH 已运行真实 Linux PTY 的启动、私有 Unix socket 转发、定向停止、精确会话重连测试；Bash/Zsh 的隔离 PTY 验证包含中文及 `?/#/%` 目录、正常登录脚本加载和恢复后回 shell 继续适配。
- 已在安装版 1Agent 的新建 SSH 测试终端运行远端现有 Claude 2.1.112，临时 wrapper 只使用主机已有 Node 20，未升级 Node 或安装 Agent。上游 MiniMax 请求发生超时重试，因此在重试期间实际退出应用：原监督进程及 Claude 进程均已退出。重开后原会话 ID `004bd4e9-3e55-4db9-ab2b-44aeb9abd62e` 一致，原消息保留、输入为空，用户消息数仍为 1，重试记录未增加。此验收证明运行中停止及恢复等待输入，不代表模型服务响应成功。
- 已移除本次新建的 SSH 测试终端、清理临时运行目录，并回到原 Pi 终端；原有 11 个终端均保留。`make build` 成功，安装版主程序、原生 helper 及远程 Python 资源与本次构建一致，安装版正在运行。
