# 官方组件优先：实现与验证

2026-11-11，本地实现与验证记录；未创建 Release。

## 采用的组件

| 范围 | 实现 |
| --- | --- |
| 目录选择 | Apple `NSOpenPanel`，所属窗口 sheet、仅目录、多选、初始本地目录、重复打开防护与窗口关闭清理 |
| 开关/复选框/分段 | 现有 SwiftUI / AppKit 原生控件，删除不可达的自绘分支；保留 NSMenu / NSAlert 薄封装 |
| 颜色 | 系统颜色与现有 ANSI 调色板直接生成 TerminalConfiguration；兼容旧偏好，不恢复主题选择 |
| 更新 | 官方 [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0)，SwiftPM exact version，标准窗口与安装器 |
| 终端 | Ghostty v1.4.0 + 第三方 Swift wrapper + 必要 host-managed I/O；[来源与边界](../Vendor/libghostty-spm/UPSTREAM.md) |
| SSH | 列表轻量枚举；主机信息按需运行 `/usr/bin/ssh -G -- alias`，使用连接环境、参数数组、5 秒/1 MiB 限制、合并并发请求及取消 |
| 其他依赖 | 删除 GhosttyTheme、ShellCraftKit；保留 MSDisplayLink、highlight.js、Quick Look、系统 OpenSSH |

## Sparkle 发布配置（2026-11-14 更新）

新客户端只读取 `https://github.com/itjun/1Agent/releases/latest/download/appcast.xml`。启用 `SURequireSignedFeed` 和 `SUVerifyUpdateBeforeExtraction`；自动检查与自动下载安装分开，后两者关闭，安装由用户在 Sparkle 标准窗口触发。

首次启动只迁移旧 `1Agent/update/prefs.json` 的 `autoCheck`。已有 Sparkle 选择不覆盖；旧提醒/强制阻断状态不参与新流程。仅清理已知普通缓存文件，不递归删除下载目录。开发构建没有正式公钥时明确显示“此构建未内置验签公钥”，检查按钮禁用。

更新安装回调先完成会话保存，再允许 Sparkle 继续。普通退出复用同一次保存，实际退出才停止终端进程。失败保留运行中的应用并显示现有日志保存错误；Sparkle 委托否决可能以 nil error 结束，因此同时处理 update cycle 结束以允许重试。Sparkle 重启期间不执行普通重启的 shell；普通“重启应用”仍走原流程。

发布前须在 GitHub Actions 配置以下 Secrets：

- `SPARKLE_PUBLIC_KEY`、`SPARKLE_PRIVATE_KEY`：独立的 Sparkle Ed25519 密钥，使用固定版本包中的 `bin/generate_keys` 生成/导出并安全保管；不要复用旧 updater 密钥。
- `UPDATE_SIGN_KEY`：保留原旧客户端签名种子；对应公钥原样迁至 `release/legacy-update-public-key.txt`，不能轮换，否则老客户端无法迁移。

当前发布工作流采用 ad-hoc 签名，不需要 Apple 开发者账号，也未经过 Apple 公证。首次安装请遵循官网安装指南，在 macOS 中手动允许打开。Release 预构建检查要求有效的 Sparkle 公钥和代码签名；支持 ad-hoc 与 Developer ID，拒绝完全不签名。ad-hoc 发布使用 `Resources/AdHoc.entitlements` 允许加载 Sparkle，保留 Hardened Runtime。先签 Sparkle helper/XPC/framework，再签主应用并执行 deep/strict 验签。使用官方 `generate_appcast` 生成签名源，再用 `sign_update` 校验源和 DMG 的签名；另外用 Apple CryptoKit 和客户端公钥校验 DMG，阻止公私钥配置不匹配的发布。`latest.json`、`latest.json.sig` 与 DMG 继续一起生成；新客户端不运行旧更新器。Debug 与 ad-hoc Release 分别使用对应的 Library Validation 兼容 entitlement；Developer ID 构建不需要该例外。Sparkle 官方许可证随应用资源分发。

构建编号由 release workflow 的运行编号递增。Sparkle 私钥保存在本机钥匙串的独立账号 `com.itjun.1agent.sparkle`，并配置到 GitHub Actions Secrets；不能丢失或随意轮换，否则已有客户端无法验签。旧版签名密钥保持不变。发布时仍须检查真实安装包、更新源签名和旧版兼容清单；本地 fixture 不能替代实际客户端升级验收。

## 终端补丁与 Shell 来源

有序补丁见 [Patches/README.md](../Vendor/libghostty-spm/Patches/README.md)。先应用旧/新补丁逐文件比较 5,932 个文件完全相同，再删除 replay 专属流水线、viewport selection 接口和不需要的精确坐标覆盖。构建缓存纳入全部补丁及顺序。内部 renderer/prompt_redraw 与 host-managed I/O 有真实调用，继续保留。

历史行为是“保存带样式文本并恢复显示”，不是 AppKit 历史视图。归档行数/字节限量、控制序列过滤和恢复顺序沿用现有实现。Shell 的逐文件来源和仅四行的 zsh 桥接差异见 [Shell 集成来源](../Resources/shell-integration/README.md)。

## 本地验证记录

- 三阶段均执行 `make build`。最终产物安装至 `/Applications/1Agent.app` 并启动；签名 deep/strict 校验通过。编译和安装成功不等同于下面未覆盖的项目已经通过。
- `make test`：通过，包括归档过滤/限量、SSH 参数、文件安全、快捷指令、历史存储、系统集成等。
- `make test-appearance` / `make test-modal-appearance`：通过，系统深浅色、旧偏好兼容、原生控件和终端缓冲保留，以及主窗口确认、嵌套编辑、全部弹窗外观。
- `make test-host-information` / `make test-ssh-configuration`：通过，隔离配置 Include、通配符、Match、中文空格路径、超时、取消、输出上限、请求合并/订阅者取消以及复制有效配置；没有批量连接真实服务器。
- 原生目录专项：通过。实际安装应用确认当前目录、多选中文/空格目录、显示隐藏目录与取消后收藏不变；测试覆盖重复打开、completion/cancel 和所属窗口关闭。可访问性树有标准标签；未做完整 VoiceOver 听读验收。
- 文件页面扩展回归：**完整 `scripts/test-file-workspace-routing.sh` 已通过**。覆盖双侧预览、收藏拖动、长路径、面板焦点、筛选、路径编辑、标签确认/重排/分屏、主机选择、880 点窄窗口恢复侧栏与反复切换页面。此前标题缺失断言截到了原生工具栏异步排布的中间状态；只等待布局完成即可恢复，未修改生产布局。测试改为等待工具栏项目及两侧标题可见，保留尺寸/位置断言；同步检查悬停事件的实际状态，并为异步新增的测试会话预建无进程终端视图，避免沙箱拒绝 shell 后自动关页干扰后续断言。
- `make test-terminal-restoration`：通过，1,000 行彩色历史、Unicode/emoji、软换行、备用屏幕、冷启动恢复、输入与重连。
- `make test-terminal-compatibility` / `make test-terminal-stress`：通过，原生 surface、分屏/窗口场景、实际 Shell 兼容，持续 126,812,160 字节输出和 120 个末尾标记，导出有界。
- `make test-app-update-controller` / `make test-app-update-restart`：通过，偏好迁移、单次保存、保存失败否决、nil-error 结束后重试。
- 本地临时 Ed25519 密钥、localhost feed、独立 `Sparkle QA` 应用：官方工具生成/验证 ZIP、DMG 和嵌入发行说明的 appcast 签名；标准 UI 完成一次下载、安装和重启；旧进程保存一次、新进程启动一次。篡改源、篡改包、断网和取消下载均保留原版本；保存失败保持运行。fixture 使用与应用相同的共享保存类，应用自身的委托适配另由生产模块测试覆盖。
- 发布端公钥检查：直接执行 workflow 中的 CryptoKit 验证代码，匹配的公钥接受已签名 DMG，错误公钥拒绝。最终安装包与构建产物的动态库 SHA-256 一致，Sparkle 许可证与官方 artifact 原文一致且已进入安装包。
- 尚未实际验收：正式旧客户端 → 新客户端 → 下一正式版本链路、Developer ID 分发/权限拒绝、完整 VoiceOver。上述需要正式签名配置或人工系统授权场景，不能以本地 fixture 替代。

本地详细日志在 `/tmp/1agent-*.log`，临时 Sparkle 验证记录在 `build/SparkleQA.noindex/`（不入库，临时私钥已删除，不用于产品）。UI 扩展回归同步了原生工具栏、独立预览面板和 NSAlert 按钮的测试定位；同时补回文件标题/筛选的焦点转移、命令管理弹窗复用的操作栏。

## 文件页窄窗口复核（2026-11-11）

- `ONEAGENT_TEST_HOST_PICKER=1 bash scripts/test-file-workspace-routing.sh`：通过，日志 `/tmp/1agent-narrow-observed-layout.log`。
- `bash scripts/test-file-workspace-routing.sh`：完整通过，日志 `/tmp/1agent-files-revalidated.log`。
- `make build`：通过，日志 `/tmp/1agent-narrow-final-build.log`；已替换并运行 `/Applications/1Agent.app`，安装动态库与构建产物 SHA-256 相同，deep/strict 验签通过。
- 实际安装应用：以系统窗口菜单缩为半屏（约 1,226 点宽），检查本地/远程标题、收起/恢复侧栏及终端/文件页切换，截图和辅助功能树均确认标题可见。随后恢复原窗口尺寸、侧栏和工作页面。880 点场景由隔离原生 UI 测试覆盖；没有为测试批量连接真实服务器或修改远程文件。
- 未保留临时尺寸修复或诊断日志。生产文件仅将悬停状态开放为模块内只读，供测试读取；界面绘制和布局逻辑不变。
