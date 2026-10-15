# 真实远程文件实现验收

日期：2026-10-13。此记录验证应用自己的远程实现，不替代 GUI 点击、Finder 拖放或视觉验收。

## 执行范围

- 已配置主机 `fixture-build`，使用既有 SSH 认证。未修改 SSH、应用、GitHub Desktop 或系统权限设置。
- `@testable import GooseAgent` 直接链接本次已构建的 `1Agent.debug.dylib`，调用真实 `FileTransferQueue`、`FileTransfer`、`FileColumn` 和 `RemoteFileSystem`。
- 单独进程使用独立 `UserDefaults` suite，不读取或写入应用真实传输队列与浏览快照；不创建应用窗口，不构建或重启应用。
- 每次测试只读写新建的 `/tmp/1agent-queue-qa-<UUID>`，结束后验证远程临时目录已删除，并删除本机夹具与测试 preferences。
- 验收时构建和已安装 dylib 的 SHA-256 均为 `ea5dae5e57d5d9e9864d464c8f85cd5bcfc6b9983809fe8c9946d67ff30e74ab`。

## 结果

| 场景 | 真实证据 | 结果 |
| --- | --- | --- |
| 取消尚未执行的上传 | 队列变为 cancelled，远程目录仍为空 | 通过 |
| 取消后重试 | 相同任务 ID、源路径、目标主机和目录；最终 completed | 通过 |
| 上传下载 | 65,536 字节二进制原件、远程数据、下载数据逐字节相同 | 通过 |
| 流式上传中取消覆盖 | 首个数据块之后取消 4 MiB 上传；远程已有目标保持原字节；无 `.oneagent-transfer-*` 残留 | 通过 |
| 文本预览识别 | 中文 UTF-8 BOM + CRLF 被正确识别 | 通过 |
| 改读取编码 | 仅改变预览；远程原文件字节保持不变 | 通过 |
| 格式修正 | 输出 UTF-8 无 BOM + LF；独立 `.bak.<UUID>` 完全保留原字节 | 通过 |
| 预览过期 | 模拟服务器文件在预览后变化，转换被拒绝；保留新内容，不产生暂存或额外备份 | 通过 |
| 队列持久化 | 重新创建队列后完成状态与任务数一致，无自动新传输 | 通过 |
| 清理 | 唯一远程夹具目录、本机夹具及隔离 preferences 已清理 | 通过 |

往返数据 SHA-256：`4b640d85ab3ba30fd02c9fc9db4a8928f416322ad27022ea58a65aaee68a4df2`。

取消时底层 SSH 可能先报告退出码 255；应用队列通过操作取消标记将该结果归类为 cancelled。测试按实际取消状态和文件完整性判断，不以特定 Swift 错误类型代替行为验收。

最后一次通过的独立远程目录为 `/tmp/1agent-queue-qa-a19f1124-8b64-4b08-835b-f0076da46512`，现已删除。原始 harness 与日志位于本机 `/tmp/1agent-remote-queue-qa.swift` 和 `/tmp/1agent-remote-queue-qa.log`，属于临时验收材料。

## 证据边界

此次未通过此 harness 验证鼠标拖拽、输入法候选交互、按钮的实际排版与系统权限弹窗，也未中断现有用户 SSH 会话。应用中的真实 GUI 流程由主验收记录单独报告。

## 未完成的 GUI 夹具验收与清理

为 GUI 操作准备的本机 `upload.txt`（UTF-8 BOM + CRLF，116 字节）未完成 GUI 上传。Computer Use 的屏幕捕获持续失败，此次不能把上述 API harness 结果表述为已通过鼠标上传、下载或 Finder 拖放。

唯一远程空目录 `/tmp/1agent-ui-qa-cc4dd086b8b1` 已通过 `rmdir` 删除并确认不存在；未使用递归远程删除。其对应本机自建夹具和空下载目录已清理。没有用户文件进入测试或被删除。

## Computer Use 恢复后的 GUI 复验

前述捕获失败属于较早一次尝试。之后 Computer Use 恢复，按用户指定改用 `demo-gray` 做 GUI 验证。唯一新夹具为 `/tmp/1agent-ui-qa-3780a752221a`，此前为这一夹具建立但未使用的 `fixture-build` 空目录已用 `rmdir` 清理。所有后续操作只针对 `demo-gray`。

主验收通过应用实际界面操作；本记录的子任务只负责准备自建夹具和独立只读字节核验，没有用 SSH 替代 GUI 上传、下载或格式修正。

| GUI 操作 | 独立只读核验 | 结果 |
| --- | --- | --- |
| 工具栏上传，选择“原样上传” | 服务器 `upload.txt` 为 116 字节、UTF-8 BOM、3 个 CRLF；与本机原件 SHA-256 一致 | 通过 |
| 打开远程预览并手动修正为 UTF-8 无 BOM + LF | 服务器文件为 110 字节、无 BOM、3 个 LF、无 CR；内容符合预期 | 通过 |
| 格式修正的独立备份 | `upload.txt.bak.37E7F16B-6931-4671-A3B5-B940FAB1D13C` 为 116 字节；与原件逐字节一致 | 通过 |
| 工具栏下载至本机 `downloads` | 下载文件 110 字节，与服务器转换后文件 SHA-256 一致 | 通过 |
| 全程本机源文件保护 | 本机原始 `upload.txt` 仍为 116 字节，SHA-256 未变 | 通过 |

原件及备份 SHA-256：`681c0eca38be5b8d3d676ab1e6543eb58a27cb005f34ff26345873e4d1dae1fc`。

转换及下载结果 SHA-256：`4a7b99ea5f914819db8b83b5c9ec3d663cdf83401bc3d1ea8af906a5bb3a9eff`。

Finder 拖放使用独立的 `drag-drop.txt` 自建夹具（78 字节，UTF-8 无 BOM + LF）。两次 Computer Use 拖放后未出现传输队列，独立只读检查确认 `demo-gray:/tmp/1agent-ui-qa-3780a752221a/drag-drop.txt` 不存在。随后尝试原生文件双栏内拖动时，工具返回 `Computer Use -10005 noWindowsAvailable`，未完成有效拖放。因此外部 Finder 拖放及双栏内拖放仍是受工具限制的未验证项；这些结果不能确认产品拖放功能失败，也不能由工具栏上传成功推定通过。

## GUI 复验后的夹具与会话清理

2026-10-14，结束 GUI 验收后只清理已核对的自建夹具 `/tmp/1agent-ui-qa-3780a752221a`。远程只包含 `upload.txt`、对应唯一 `.bak.37E7F16B-6931-4671-A3B5-B940FAB1D13C` 和空 `empty`。删除两个明确文件后仅用 `rmdir` 删除两个空目录，并确认远程路径不存在。本机只包含上传原件、下载结果、拖放夹具与验收元数据，核对后删除并确认不存在。

原件及下载结果的大小和哈希已在上文保留；Finder 夹具的 SHA-256 为 `7632757f4591a0c28b10a88d1acda41f24a21276f33790e8e63887bf1dbc3cc4`，没有以脚本补传。完整验收元数据另保留于本机 `/tmp/1agent-gui-fixture-cleanup-metadata.json`。

主验收通过 GUI 关闭两条自建 `demo-gray` QA 终端和新增的 `sample-service` 测试终端；会话数从 14 变为 11，恰好减少 3 条。原用户工作区的 panels 与 members 保持，完整 workspaces 的排序 JSON SHA-256 `ed92fb952e3eb92eac6dba64bba096fb609069c656cbcbea39c876bb72c83f78` 与开始时基线完全相同。清理期间辅助功能树短暂显示过期状态，随后快照确认目标关闭正确，没有恢复或改写用户会话。
