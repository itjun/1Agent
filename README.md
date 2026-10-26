# 1Agent

[中文](#中文) · [English](#english)

[![CI](https://github.com/itjun/1Agent/actions/workflows/ci.yml/badge.svg)](https://github.com/itjun/1Agent/actions/workflows/ci.yml)
[![MIT License](https://img.shields.io/github/license/itjun/1Agent)](LICENSE.md)

原生 macOS 终端。和 [1Panel](https://github.com/itjun/1Panel) 共用本机 OpenSSH。

[应用官网](https://itjun.github.io/1Agent/) · [安装指南](https://itjun.github.io/1Agent/install.html) · [下载最新版](https://github.com/itjun/1Agent/releases/latest)

## 中文

远程 SSH 连上之后，目标主机的状态仍然不好看：CPU、内存、磁盘和进程要再单独敲命令才能知道。另一边，打开终端时，现有收费软件往往不能马上打开，也留不下可用的会话记录。

1Agent 和 1Panel 的做法是只使用通用 OpenSSH。两个应用都读取 `~/.ssh/config` 及其 `Include`，沿用已经配好的密钥、端口和跳板机，尽快把主机会话建起来。

[1Panel](https://github.com/itjun/1Panel) 负责看主机。它把 SSH 配置里的主机分组，直接给出状态，不用为了看一眼再去敲命令。1Agent 负责终端：在 macOS 上快速打开本机或远程会话，支持多窗口、分屏和文件管理，并保留终端历史，离开后可以恢复。

两个项目可以单独使用。装在同一台 Mac 上时，1Panel 通过 `oneagent://open` 把当前主机交给 1Agent 打开。1Agent 只提供 macOS 终端；Windows 和 Linux 上的主机面板仍使用 1Panel。

### 下载安装

当前正式安装包适用于 Apple 芯片 Mac，要求 macOS 14 或更高版本。从 [GitHub Releases](https://github.com/itjun/1Agent/releases/latest) 下载 DMG，打开后将 1Agent 拖入“应用程序”。首次打开如被系统拦截，请按[安装指南](https://itjun.github.io/1Agent/install.html#first-open)处理。

### 本地构建

需要 macOS、Xcode 和 XcodeGen。在项目目录执行：

```sh
make build
```

构建脚本会安装并启动 `/Applications/1Agent.app`。应用的 Bundle ID 为 `com.itjun.1agent`，URL 协议为 `oneagent://`。

官方 Ghostty 使用独立的 `com.mitchellh.ghostty` 与 `ghostty://` 身份。Swift 模块名仍为 `GooseAgent`，Xcode 工程和 target 名为 `1Agent`。

GitHub 上的 [CI](https://github.com/itjun/1Agent/actions/workflows/ci.yml) 只编译 macOS 应用，不安装到运行器的 `/Applications`。推送 `v*` 标签会另外构建安装包，并发布签名的 `latest.json`。已安装的应用会检查这份清单，有新版本时可以下载并替换自己。

### 第三方组件

终端引擎、Swift 封装、Shell 集成、字体、语法高亮和图标等第三方内容保留各自的许可证与署名，详见 `Vendor/libghostty-spm/LICENSE`、`Resources/Fonts/SymbolsNerdFont-LICENSE.txt`、`Resources/PreviewSyntax.LICENSE.txt`、`Resources/FileIcons-NOTICE.txt` 和 `Resources/shell-integration/` 中的许可文件。

### 许可证

1Agent 主项目采用 [MIT 许可证](LICENSE.md)，与 Ghostty 使用的许可证类型相同。第三方组件和素材遵循其各自的许可与署名要求。

## English

A remote SSH connection still leaves the host state hard to see. CPU, memory, disk, and processes each need another command. Opening the terminal has the same kind of friction: paid apps currently on the market often cannot open a session immediately, and they do not keep a usable record of it.

1Agent and 1Panel stay on ordinary OpenSSH. Both read `~/.ssh/config` and its `Include` files, reuse the keys, ports, and jump hosts already configured there, and bring the host session up quickly.

[1Panel](https://github.com/itjun/1Panel) is for seeing the host. It groups the hosts from the SSH config and shows their state, so a glance does not require typing the commands. 1Agent is the terminal. On macOS it opens a local or remote session quickly, with multiple windows, splits, and file management, and it keeps the terminal history so the session can be restored.

Each project works on its own. On the same Mac, 1Panel hands the current host to 1Agent through `oneagent://open`. 1Agent is the macOS terminal; the host panel on Windows and Linux remains 1Panel.

### Install

The official DMG currently supports Apple silicon Macs running macOS 14 or later. Download it from [GitHub Releases](https://github.com/itjun/1Agent/releases/latest), open it, and drag 1Agent into Applications. See the [installation guide (Chinese)](https://itjun.github.io/1Agent/install.html) for first-launch instructions.

### Build locally

macOS, Xcode, and XcodeGen are required. From the project directory:

```sh
make build
```

The build script installs and launches `/Applications/1Agent.app`. The bundle ID is `com.itjun.1agent`, and the URL scheme is `oneagent://`.

Official Ghostty keeps its own `com.mitchellh.ghostty` bundle ID and `ghostty://` scheme. The Swift module is still `GooseAgent`. The Xcode project and target are named `1Agent`.

The [CI workflow](https://github.com/itjun/1Agent/actions/workflows/ci.yml) compiles the macOS app. It does not install the app into `/Applications` on the runner. Pushing a `v*` tag builds the installable app and publishes a signed `latest.json`. An installed copy checks that manifest and can download and replace itself.

### Third-party components

The terminal engine, Swift wrappers, shell integration, fonts, syntax highlighting, and icons keep their own licenses and attribution. See `Vendor/libghostty-spm/LICENSE`, `Resources/Fonts/SymbolsNerdFont-LICENSE.txt`, `Resources/PreviewSyntax.LICENSE.txt`, `Resources/FileIcons-NOTICE.txt`, and the license files under `Resources/shell-integration/`.

### License

The 1Agent project itself uses the [MIT License](LICENSE.md), the same license type used by Ghostty. Third-party components and artwork remain under their own licenses and attribution requirements.
