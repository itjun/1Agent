# 长日志与历史保存性能记录

日期：2026-10-13（Asia/Shanghai）。范围：选定原生版本的真实 libghostty 引擎与历史处理函数；没有操作用户终端、启动 shell/SSH、修改应用代码、构建或重启应用。

## 结论

10 万行混合英文/中文日志的 6 次独立进程测量均保留最新文字和中文，历史保持合计 20,000 行以内、8 MiB 以内，原子保存后回读一致。**这证明本次工作负载下的数据正确性与边界；不等于性能验收通过。**

当前 Debug 链路存在值得进一步测量的开销：9.4 MB 日志经过历史边界扫描并送入引擎，耗时 2.20–2.84 秒；默认配置下单次读取与快照计算中位数分别为 364 ms 和 277 ms。生产代码将这些工作放在后台队列，不能据此宣称主线程卡顿。后台捕获与接收共用串行队列，捕获期间排队的新输出可能延后处理；这是从代码得到的推断，本次未测量真人操作时的显示延迟。

## 方法与运行边界

- 机器：Apple M4（Mac16,13，10 核），24 GiB 内存，macOS 27.0.1，arm64。
- 引擎：直接链接当前 `build/DerivedData.noindex/Build/Products/Debug` 中的 `GhosttyTerminal.o`、`GhosttyKit.o`、`MSDisplayLink.o`、`libghostty.a`，并使用真实 `AppTerminalView` 与 `InMemoryTerminalSession`。
- 窗口：原生 1000 × 650 点离屏窗口，未执行 `orderFront`。没有 PTY、网络、用户配置、实时会话或截图替代机制。
- 历史函数：编译当前 `TerminalHistory.swift`，与 Debug 应用相同使用 Swift `-Onone`；未测试 Release 优化版本。
- 输入：100,000 行，英文与中文交替；合计 9,400,028 UTF-8 字节，64 KiB 分块。英文包含构建结果、状态和计时，中文包含路径、应用状态及上传下载文案。末尾额外附加唯一标记 `PERF-END-100000-中文完成`。
- 每一块先通过生产 `TerminalHistoryBoundaryParser.scan`，再交给真实引擎；计时终点等待输出队列排空。生产的 `TerminalHistoryRecorder` 本身未实例化，以免写入用户的全局历史目录；其扫描、读回、定位、边界和存储函数被直接测量。
- 分别采用 wrapper 默认配置和显式 `scrollback-limit = 67108864` 的压力配置，各运行 3 个全新进程，每个进程保存 3 份快照。压力配置仅在该测试进程生效。
- 读回计时包含 `readScreenText` 和 `readViewportText`。快照计时包含 `viewportRow` 与 `TerminalHistorySnapshot`。保存计时包含后台 `TerminalHistoryStore.save`、二次边界验证、JSON 编码、原子写入和 `flush`。
- 保存到 UUID 命名的临时目录，验证后自动移除。未读取或更改用户已有的历史文件。
- 所有时间均为单调时钟的墙钟时间。临时 JSON 中 `boundary_parser_cpu_ms` 是探针的历史字段名，实际也是扫描段墙钟时间，**不是进程 CPU 时间**。
- 输入整体字符串、Data 与分块都预先驻留内存。峰值 RSS 包含这些夹具、AppKit、引擎、字形缓存和验证成本，不能当作应用增加的内存量，也不能当作单个终端的稳态内存。

## 结果

下表为中位数（最小–最大）。吞吐量和 RSS 来自每种配置 3 次运行；读回、快照和保存来自各 9 次捕获。

| 测量项 | 默认配置 | 64 MiB scrollback 压力配置 |
|---|---:|---:|
| 100,000 行扫描、送入与排空 | 2,490 ms（2,204–2,724） | 2,429 ms（2,202–2,838） |
| 吞吐量 | 3.60 MiB/s（3.29–4.07） | 3.69 MiB/s（3.16–4.07） |
| 边界扫描墙钟时间 | 2,489 ms（2,204–2,723） | 2,427 ms（2,201–2,835） |
| 原生文本读回 | 364 ms（347–387） | 548 ms（531–683） |
| 视口定位与快照边界计算 | 277 ms（270–398） | 280 ms（267–312） |
| 校验、JSON 编码、原子保存与 flush | 137 ms（133–216） | 140 ms（134–152） |
| 上述三段捕获链路合计 | 774 ms（757–1,001） | 967 ms（945–1,134） |
| 进程峰值 RSS | 189.0 MiB（187.6–212.3） | 228.2 MiB（203.1–230.5） |

说明：输入阶段的引擎消费在后台与扫描重叠，不能用总耗时减去扫描时间推算引擎自身耗时。这里没有独立测量 libghostty 纯解析吞吐量。完整探针的 `total_ms` 还包含断言、磁盘回读和 JSON 解码，故不用于上表的生产捕获链路合计。

18 次归档均为：

- 主历史 19,966 行，最后屏幕 34 行，合计 20,000 行。
- 文本合计 1,859,872 字节；JSON 约 1,900,015 字节（日期编码的最后一位长度可差 1 字节）。
- 最新英文/中文内容与结束标记仍在主历史中，没有 U+FFFD 替代字符。
- 文件权限为 `0600`，JSON 解码并重新验证后与保存快照完全一致。
- 行数上限实际被触发；8 MiB 上限在本工作负载下未被触发，只验证结果不越界。它不是“任意大输入均小于 8 MiB 内存”的证明，C 导出的临时空间还取决于引擎 scrollback。
- 默认配置导出时，wrapper 对仍保留的引擎内容再舍弃 29,251 行；压力配置再舍弃 45,897 行。这个数不包括已经被引擎自身清理的旧内容，不能据此声称恢复全部 100,000 行。

## 主线程与后续输入的影响

当前源码证据：

- `TerminalHistoryRecorder.receive` 与 `checkpoint` 只向专用 `com.itjun.1agent.terminal-history.capture` utility 队列提交任务。
- `captureMain`、`readViewportText`、视口定位与快照构造运行于上述队列；磁盘写入进一步提交到 `TerminalHistoryStore` 的独立 utility 队列。
- `withCurrentSurface` 在 C 调用前释放生命周期锁；它保护 surface 不被销毁，并不是在整个导出期间一直持有 wrapper 锁。不能把全部读取时间表述为主线程持锁时间。
- 捕获任务与 `receive` 共用 recorder 串行队列，所以捕获结束前后续接收块需等待。默认配置读取与快照两段约 0.64 秒的合计中位数可作为进一步测量的线索，**不能直接当作用户已观察到的输入延迟**。实际帧调度、Ghostty 内部锁、运行时并发与优化级别均未在此测量。
- 常规检查点受 10 秒节流约束；强制检查点、退出 flush 和屏幕切换另有捕获路径。节流减少发生频率，不会消除单次处理成本。

后续优化应先对运行中的 Release 构建测量持续输出期间的字符出现延迟和捕获耗时，再决定是否优化边界扫描、读回或快照计算。本轮没有预设随意的“流畅”阈值，也没有修改代码。

## 复现材料与指纹

临时探针保留于 `/tmp/oneagent-history-benchmark/`（系统清理临时目录后可能消失）：

- `TerminalHistoryPerformanceProbe.swift`：本次探针源码。
- `run.sh`：编译并执行 6 次测量的完整命令，运行 `bash /tmp/oneagent-history-benchmark/run.sh` 可在当前构建产物上重跑。
- `default-{1,2,3}.json`、`large-{1,2,3}.json`：完整测量值。
- 同名 `.stderr`：`/usr/bin/time -l` 进程计时与内存统计。

本次使用的 SHA-256：

| 文件 | SHA-256 |
|---|---|
| `Sources/GooseAgent/TerminalHistory.swift` | `e0807f40ef27870082d0062cf3dc0c9d5da1a6102537ec7727b7e8c9f07a68cb` |
| `Sources/GooseAgent/TerminalHistoryRecorder.swift`（仅审阅线程路径） | `d03d87b32155aee187e13677d72912f0e9cbacd822acd4ce6a9eca650675b514` |
| `build/DerivedData.noindex/Build/Products/Debug/GhosttyTerminal.o` | `347afd738bdac552f784ba2445cbdaf2b31972a47bec140a97c980d1d05bf4fc` |
| `build/DerivedData.noindex/Build/Products/Debug/libghostty.a` | `51491e70ef34206d5862abe7c272b4b8281b18c106f2600a1bfb4bfde29fed1f` |

本报告不能替代：真实 GUI 的高频切页、帧率、输入响应、中文输入法组合文本、Finder 拖放、截图比对或运行中的任务恢复验收。
