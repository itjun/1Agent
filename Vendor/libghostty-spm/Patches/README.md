# Ghostty v1.4.0 补丁清单

依照 `series` 顺序应用。引擎是 Ghostty 官方源码；这些补丁不是官方发布包的一部分。共同来源是 Lakr233/libghostty-spm `2.2.2026102101` 的补丁栈及 1Agent 对 v1.4.0 / Zig 0.17 的移植。不要直接修改生成的 `build/libghostty/source`。

| 补丁 | 用途及调用方 | 删除条件 |
| --- | --- | --- |
| `01-build-platform.patch` | Zig 0.17 / Apple SDK / CoreText / keycode 兼容、构建裁剪、Metal 编译及预生成 frame data；由构建脚本和引擎平台代码调用 | 官方固定版本和构建参数可直接生成同样的 macOS 静态库，双架构构建及字体/键盘回归通过 |
| `02-host-io.patch` | host-managed backend、输入/resize 回调、write_buffer、process_exit，以及现有 replay / selection viewport 扩展；`GhosttyTerminal` 的内存会话由应用 PTY/SSH 传输驱动；同文件内还保留 inspector 裁剪适配 | 官方带绘制层的嵌入接口支持宿主管理 I/O，恢复、重连、快捷指令和进程状态全部迁移完成 |
| `03-rendering.patch` | Metal/IOSurface 呈现、帧调度与 resize 提示符保持；由原生终端 surface 触发 | 上游覆盖这些行为，分屏 resize、拖动跨窗口及压力回归无闪烁/旧帧问题 |
| `04-terminal-state.patch` | resize 期间 prompt_redraw 状态及 SGR 查询兼容；Screen/Terminal/stream_terminal/C 层内部使用 | 上游包含相同行为；03 的内部依赖先解除，SGR 与 resize 回归通过 |

分类按完整文件拆分以保持可审查性；02 内的 inspector guards 是和 host I/O 共用 embedded.zig 的构建适配，04 的提示符状态是 03 的依赖，不能仅按文件名独立删除。

## 先证明等价，再缩减

原单补丁 SHA-256：`4730d4de37e250fcdcc9685813004050c6fcf35e8d10fac86da2dd1342869a9b`。首次拆分后对官方源码分别应用旧补丁和有序补丁，逐文件比较 **5,932 个文件，全部相同**。等价版本补丁哈希保存在 [split-equivalence.json](split-equivalence.json)，用于区分纯拆分和后续缩减；它不是当前补丁的哈希清单。

所有补丁内容、名称和顺序都进入构建缓存校验；更改 `series` 或任一补丁必须重建。进一步缩减应一次只改变一个行为，并保留相应回归。
