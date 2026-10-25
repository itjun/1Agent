# SSH 远程 Agent 对话恢复：实现注意事项

> 历史方案，已于 2026-10-25 移除。远程终端不再部署 Agent helper、包装 AI CLI 或自动恢复 Agent 对话。以下内容保留为历史调研记录。

调研日期：2026-10-19。调研起点为只支持 zsh、按终端隔离的远程快捷指令桥接和本地 Agent helper。下文为据此整理的设计依据；最终实现与实际 SSH、Claude 退出重开验收见 [本次实现与验证](agent-session-restoration-research.md#本次实现与验证)。

## SSH 通道和私有 socket

- OpenSSH 原生支持 `-L local_socket:remote_socket`；沿用该终端已认证连接和现有 Host/ProxyJump/Identity 配置。远程 bootstrap 放在认证后的命令通道，所有动态字符串做 POSIX shell 单引号转义；SSH 会将远程 command 参数拼成字符串，不能把它当远端的 argv 直传。不要把恢复命令预先写进 PTY，避免密码或 host-key 提示误收输入。依据：[ssh(1)](https://man.openbsd.org/ssh.1)。
- `ExitOnForwardFailure=yes` 能发现监听建立失败，但不保证转发目标已启动。新建本地 listener 后，远程 Python 尚未 bind 的阶段，token probe 应做短超时重试。`StreamLocalBindMask` 默认 `0177`；仍应将两端 socket 放在权限 `0700` 的短目录下。`StreamLocalBindUnlink=yes` 只允许针对本次私有路径使用，不能以它解决未知用户路径冲突。依据：[ssh_config(5)](https://man.openbsd.org/ssh_config.5)。
- ControlMaster 会复用连接；终端退出时应以相同 ControlPath 和完全相同 `-L` spec 执行 `ssh -O cancel`。不要为了关一个终端而 `-O exit` 共享 master。应用整体退出的已有 master 清理必须排在所有 Agent 的 snapshot/stop/等待之后。依据：[ssh(1) multiplex control](https://man.openbsd.org/ssh.1#O)。
- `AllowStreamLocalForwarding` 或 `DisableForwarding` 可禁止该能力；不应自行改 sshd 配置。服务器的 session/channel 关闭也不保证所有相关进程随之退出，因此需要 Agent 停止结果，而不能把本地 ssh 已退出当作远端已停止。依据：[sshd_config(5)](https://man.openbsd.org/sshd_config.5)。

建议在现有远程目录内新增一个独立的 Agent socket。协议只允许 `snapshot`、`stop` 等固定动作；`stop` 必须携带当前 invocation ID。服务器从自身状态选择 PID，不接受客户端指定任意 PID、路径、shell script 或可执行命令。每次连接都认证随机 token，限制帧长、读写超时，并循环读取完整帧；单次 `recv()` 不保证得到一整个请求。token 比较可使用 `hmac.compare_digest`。以上为根据 [Python socket](https://docs.python.org/3/library/socket.html) 与 [hmac](https://docs.python.org/3/library/hmac.html#hmac.compare_digest) 能力提出的协议约束。

临时目录使用 `tempfile.mkdtemp()`，或不可复用的随机名称加原子 `mkdir(0700)`；已存在时不可继续使用。只写固定资源名，文件权限 `0600/0700`；原子替换状态文件只发生在本目录内。退出清理只删除自己创建的目录，不能因请求提供路径而递归删除。依据：[Python tempfile](https://docs.python.org/3/library/tempfile.html#tempfile.mkdtemp)。

## Python supervisor 与交互终端

- 用 `Popen([absolute_executable, ...], shell=False, env=..., cwd=...)`，Agent 继承 stdin/stdout/stderr。不要通过 `sh -c` 重放原始启动字符串；也不应捕获 stdout/stderr 后忽略管道背压。`preexec_fn` 在有线程时不安全，server 线程存在后尤其不能依赖它。依据：[Python subprocess](https://docs.python.org/3/library/subprocess.html#subprocess.Popen)。
- 不要为了能 `killpg` 就给交互 Agent 设置 `start_new_session=True`：它调用 `setsid()`，新 session 初始没有 controlling terminal，会破坏原来的前台进程组和 `/dev/tty` 行为。若不实现完整 PTY relay，应让 Agent 保持当前 foreground PGID，并按已验证身份管理自己拥有的进程。依据：[setsid(2)](https://man7.org/linux/man-pages/man2/setsid.2.html)。
- supervisor 可捕获 Ctrl+C 的 SIGINT 以保留监控，但不要把 SIGINT/SIGQUIT 设为 `SIG_IGN` 再启动 Agent：忽略的 disposition 会跨 exec 继承；可调用的 no-op handler 在 exec 时恢复默认。Python 的 `restore_signals=True` 只处理 Python 自己忽略的特定信号，不是任意忽略信号的重置器。依据：[signal(7)](https://man7.org/linux/man-pages/man7/signal.7.html)、[Python subprocess](https://docs.python.org/3/library/subprocess.html#subprocess.Popen)。
- `signal.signal()` 只能在主线程注册；handler 只设简单停止标志，不拿锁或写 JSON。socket 线程提交请求，由主循环执行停止、等待和状态更新；需要唤醒阻塞轮询时可用非阻塞 wakeup fd。依据：[Python signal](https://docs.python.org/3/library/signal.html#signals-and-threads)。

推荐关闭顺序：最后一次 snapshot → 请求指定 invocation 停止 → CLI 首次 SIGTERM → 保持 SSH/PTY 和 helper 存活，允许其取消请求及落盘 → 等待 CLI 退出 → 在身份仍匹配时清理该 invocation 遗留子进程 → 读取最终状态 → ack 已停止 → 关闭 PTY/取消转发/删除临时目录。等待期限使用 monotonic clock；`stop accepted` 与 `stopped` 必须区分。若网络已断、权限不足或超时，返回不能确认远端停止，不声称已完成。

应用关闭后不继续运行的保证不能仅靠 shell 的 SIGHUP：命令可能自行屏蔽信号或脱离 session。也不能在停止逻辑中杀共享 Grok leader、用户 tmux、其他终端或同名进程。进程范围应限制到本次 invocation；自定义 RemoteCommand/tmux attach 继续保留原行为，不自动改为受管 shell。

## Linux PID 身份与进程发现

- 优先在捕获进程时保留 pidfd，再用 `signal.pidfd_send_signal()`；这是避免 PID 重用竞态的 Linux 能力。`os.pidfd_open()` 需要 Python 3.9+、Linux 5.3+，须能力检测，而不能把“有 Python3”当作足够。依据：[Python os.pidfd_open](https://docs.python.org/3/library/os.html#os.pidfd_open)、[Python pidfd_send_signal](https://docs.python.org/3/library/signal.html#signal.pidfd_send_signal)。
- 兼容路径至少记录 `(PID, starttime)`，每次发信号前重新核对；跨启动保存运行身份时再加 boot ID。`/proc/PID/stat` 的第 22 字段 starttime 是开机后的 clock ticks，不是 UNIX 时间；用 `SC_CLK_TCK` 换算。comm 被括号包围且可能包含空格，不能直接对整行 `split()` 后取固定下标。依据：[Linux proc_pid_stat(5)](https://man7.org/linux/man-pages/man5/proc_pid_stat.5.html)。
- starttime 检查与后续 `kill(pid)` 之间仍存在 TOCTOU，不能描述为与 pidfd 同等保证。直接尚未 reap 的子进程由 supervisor 保持 wait 所有权；对身份无法证明的后代不强杀。发现进程后立即记录身份，父进程退出后后代可被重新收养，单次 PPID 扫描并不完整。
- `/proc/PID/fd`、cwd 和进程信息可能受权限、hidepid 或 namespace 限制。无法读取时停止猜测；不能回退到同目录最新会话或全机扫描最近文件。依据：[Linux proc filesystem](https://docs.kernel.org/filesystems/proc.html)。

Codex fd/SQLite 查找应限定在已证明属于本次调用的进程打开的文件上。Python SQLite 使用 `mode=ro` URI 和绑定参数、短 busy timeout；缺表或 schema 不兼容时标记无法绑定，不创建空数据库。路径 URI 必须正确编码 `?/#/%`，不要直接字符串拼接。依据：[Python SQLite URI](https://docs.python.org/3/library/sqlite3.html#how-to-work-with-sqlite-uris)。

## 不改全局配置的 shell 注入

zsh：沿用现有 `ZDOTDIR` 临时 `.zshenv`。先恢复原始 ZDOTDIR，再 source 用户 `.zshenv`，随后由 zsh 自己按登录/交互状态读取原来的 `.zprofile/.zshrc/.zlogin`；保留 `RCS/GLOBAL_RCS` 语义。不要在 bootstrap 里额外 source `.zshrc`；用户配置可以覆盖提前安装的 wrapper 函数。依据：[zsh startup files](https://zsh.sourceforge.io/Doc/Release/Files.html#Startup_002fShutdown-Files)。

bash：`--rcfile file` 用于交互非登录 shell，不能把它与 `--login` 组合就假设会在 profile 后调用。登录启动读取 `/etc/profile`，然后只读取 `~/.bash_profile`、`~/.bash_login`、`~/.profile` 中首个可读文件；profile 可以自行 source `.bashrc`。手动 source 所有 profile 或再额外 source `.bashrc` 会改变原行为。`login_shell` 不能通过 `shopt` 伪造。依据：[Bash startup](https://www.gnu.org/software/bash/manual/html_node/Bash-Startup-Files.html)、[Bash login_shell](https://www.gnu.org/software/bash/manual/html_node/The-Shopt-Builtin.html)。

一个可保留真正登录语义的方案是：短暂 Bash launcher 定义固定 wrappers，使用公共接口 `export -f` 导出这些函数，再 `exec "$SHELL" -l`。真正的 Bash 登录进程会导入导出函数，并自行正常加载 profile；用户随后设置的 alias/同名函数仍优先。不要手写 `BASH_FUNC_name%%` 内部编码。需要临时屏蔽非交互 launcher 的 `BASH_ENV`，并在真正 shell 前还原原值；受限/privileged Bash 禁止函数导入时应降级说明。依据：[Bash functions](https://www.gnu.org/software/bash/manual/html_node/Shell-Functions.html)、[Bash environment](https://www.gnu.org/software/bash/manual/html_node/Environment.html)。

已做一个无 Agent 的本地隔离验证：临时 HOME 内自定义 `.bash_profile`，launcher `export -f` 后 exec Bash login shell；包装函数和用户 profile 函数同时可见，`login_shell` 为真，profile 只执行一次。该实验验证 Bash 机制，不代表 Linux 远程端到端验收。

## 恢复与验收建议

远程 helper 与本机保存相同的精确 ID/path 元数据，仍使用 Agent 自身 resume 入口；不保存旧 prompt、不追加恢复任务、不自动续跑。Pi/OMP 扩展过滤子 Agent；Claude hook 验证 invocation；Grok PID 注册映射和 Codex fd/SQLite 都不能用最近会话替代精确身份。

至少覆盖：同宿主同目录两个终端不串会话；空对话/正常退出回 shell 不误恢复；聊天中切换会话后的身份；Ctrl+C、Ctrl+Z/fg 和窗口 resize；用户 profile/alias/function/BASH_ENV/ZDOTDIR；服务器禁止转发；Python 不存在/版本太低；断网和停止超时；临时目录冲突；拒绝错误 token/旧 invocation/任意动作；实际退出应用后确认对应远程 Agent 不再工作，重开后精确恢复并停在输入状态。不能用模拟 CLI 测试代替真实 SSH 与真实 Agent 的验收。
