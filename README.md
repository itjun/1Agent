# 1Agent

1Agent 是原生 macOS 终端与 SSH 工作区应用，支持本机终端、远程连接、多窗口、分屏和文件管理。

SSH 连接使用系统 OpenSSH，读取 `~/.ssh/config` 及其 `Include` 配置，沿用用户已有的密钥、端口和跳板机设置。

## 本地构建

需要 macOS、Xcode 和 XcodeGen。在项目目录执行：

```sh
make build
```

构建脚本会安装并启动 `/Applications/1Agent.app`。应用的 Bundle ID 为 `com.itjun.1agent`，URL 协议为 `oneagent://`。

官方 Ghostty 使用独立的 `com.mitchellh.ghostty` 与 `ghostty://` 身份。Swift 模块名仍为 `GooseAgent`，Xcode 工程和 target 名为 `1Agent`。

## 第三方组件

终端引擎、Swift 封装、Shell 集成、字体、语法高亮和图标等第三方内容保留各自的许可证与署名，详见 `Vendor/libghostty-spm/LICENSE`、`Resources/Fonts/SymbolsNerdFont-LICENSE.txt`、`Resources/PreviewSyntax.LICENSE.txt`、`Resources/FileIcons-NOTICE.txt` 和 `Resources/shell-integration/` 中的许可文件。

## 许可证

1Agent 主项目采用 [MIT 许可证](LICENSE.md)，与 Ghostty 使用的许可证类型相同。第三方组件和素材遵循其各自的许可与署名要求。
