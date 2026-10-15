# 可管理常用目录

用户要求：Finder 拖入或系统文件夹选择器添加固定项，预设项和自定义项均可删除和调整。

## 实现

- 常用目录标题旁仅保留“＋”添加、“编辑”管理两个入口。
- “＋”打开 macOS 文件夹选择器，支持多选；Finder 的本机文件夹 URL 可拖到条目前插入或空白处追加。
- 条目可拖动排序；编辑状态提供改显示名称、上移、下移、取消固定。预设个人目录和下载目录没有特殊删除限制。
- 列表与浏览器打开的目录独立。保存 UUID、路径、显示名称和顺序；空数组是有效保存结果，不会在重启后补回预设。
- 不复制、移动、重命名或删除实际文件夹；同一路径及其符号链接去重，普通文件和非本机 URL 不加入。

## 验证

- `Tests/PinnedLocationsTests.swift` 通过：删除全部预设后的空列表恢复、名称/排序保存、上移与拖至末尾、目录校验、符号链接去重、移除条目不删文件、NSItemProvider 的 URL/Data 两种文件 URL 表示和中文空格路径。
- `scripts/test-file-workspace-routing.sh` 通过，日志 `/tmp/1agent-locations-routing.log`。
- 最终 `make build` 通过并安装、启动 `/Applications/1Agent.app`，日志 `/tmp/1agent-locations-build.log`。签名验证通过，进程 PID 38944。
- 构建和安装的 debug dylib SHA-256 相同：`72c648910b56fb74cc15c935987c8a201dcb071a2e64fa4b70f67494e951540c`。
- 实际窗口已看到新增按钮及两条预设目录。首次文件夹选择检查发现后台窗口缺少 keyWindow，已补 mainWindow fallback。
- 用户解锁后，通过真实系统文件夹选择器添加 `/tmp/1agent-pinned-qa-20261014/固定测试`，编辑为 `QA-Pinned`，使用上移按钮移到下载目录之前。选择器添加、改名和按钮排序通过。
- 用户手动拖入也报告没有出现条目，因此实际问题成立。排查发现生产入口在 `Task` 中延迟启动 NSItemProvider 读取，违反 [Apple performDrop 生命周期要求](https://developer.apple.com/documentation/swiftui/dropdelegate/performdrop(info:))。新增读取时序测试先失败，修复为回调返回前同步发起所有读取、异步汇总结果后通过。
- 修复版已 `make build` 安装并启动，日志 `/tmp/1agent-pin-drop-fix-build.log`，签名验证通过；安装与构建 dylib SHA-256 为 `8e0872cccb3cf9838cfa13281b6edd08279b6f2adec2daefeb1f9246f6e2eccf`，PID 41803。
- 安装过程真正退出再启动后，`QA-Pinned` 显示名称及位于下载之前的顺序均保留。随后通过“取消固定”清理测试条目，确认仅剩个人目录、下载，磁盘测试文件夹仍保留。
- **修复后的 Finder 跨应用拖入、鼠标拖动排序仍待实测**：用户明确要求“先跳过这个，等下再验证”。不能用时序测试通过代替实际成功。临时目录 `/tmp/1agent-pinned-qa-20261014` 及专用 Finder 窗口保留供稍后继续；未触碰其他 Finder 窗口。

仅使用独立临时目录和测试固定项，未修改远程文件；原有工作树修改保留，无提交或推送。
