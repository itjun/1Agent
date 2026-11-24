#!/usr/bin/env python3
"""按验收范围串行运行现有测试，保留日志和退出码；实机验收另见 docs/acceptance.md。"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
PRODUCTS = ROOT / "build/DerivedData.noindex/Build/Products/Debug"

# 命令清单只在这里维护；文档通过范围名引用，--dry-run 展示实际执行计划。
SUITES = {
    "core": ("基础逻辑、Shell 集成、快捷键、文件安全", [("make", "test")]),
    "focus": ("原生搜索框、焦点转移、弹窗、输入指示", [
        ("bash", "scripts/test-terminal-focus.sh"),
    ]),
    "terminal": ("终端窗口、分屏、侧栏、关闭、重连和远程目录", [
        ("bash", "scripts/test-terminal-focus.sh"),
        ("bash", "scripts/test-terminal-windows.sh"),
        ("bash", "scripts/test-terminal-pane-actions.sh"),
        ("bash", "scripts/test-terminal-pane-drag.sh"),
        ("bash", "scripts/test-sidebar-groups.sh"),
        ("bash", "scripts/test-sidebar-panel-drop.sh"),
        ("bash", "scripts/test-close-terminal-shortcut.sh"),
        ("bash", "scripts/test-terminal-reconnect.sh"),
        ("bash", "scripts/test-remote-directory.sh"),
        ("bash", "scripts/test-host-information.sh"),
    ]),
    "commands": ("命令库、快捷命令、拖放和每会话选择恢复", [
        ("bash", "scripts/test-quick-command-sidebar.sh"),
        ("bash", "scripts/test-command-sidebar-restoration.sh"),
        ("bash", "scripts/test-quick-command-drop.sh"),
        ("bash", "scripts/test-terminal-windows.sh", "", "--command-drag"),
    ]),
    "files": ("文件页路由、预览、刷新、图标和外部打开", [
        ("bash", "scripts/test-file-workspace-routing.sh"),
        ("bash", "scripts/test-workspace-preview.sh"),
        ("bash", "scripts/test-workspace-refresh.sh"),
        ("bash", "scripts/test-file-icons.sh"),
        ("bash", "scripts/test-workspace-external-open.sh"),
    ]),
    "appearance": ("主题、侧栏、原生弹窗、字体和居中通知", [
        ("bash", "scripts/test-family-appearance.sh"),
        ("bash", "scripts/test-sidebar-appearance.sh"),
        ("bash", "scripts/test-modal-appearance.sh"),
        ("bash", "scripts/test-terminal-font.sh"),
        ("bash", "scripts/test-app-notification.sh"),
    ]),
    "restore": ("存档、后台 PTY、重新挂载、退出清理和命令栏恢复", [
        ("bash", "scripts/test-terminal-restoration.sh"),
        ("make", "test-session-host"),
        ("bash", "scripts/test-hosted-terminal.sh"),
        ("bash", "scripts/test-command-sidebar-restoration.sh"),
    ]),
    "release": ("图标、签名规则和更新控制器；不执行真实升级", [
        ("make", "test-release-signing", "test-app-icons", "test-app-update-controller", "test-app-update-restart"),
    ]),
    "automation": ("操作已安装应用，仅创建并清理自己的测试终端", [
        ("python3", "scripts/test-terminal-automation.py"),
    ]),
    "compatibility": ("真实 Shell、TUI、剪贴板、全屏及多屏夹具", [
        ("make", "test-terminal-compatibility"),
    ]),
    "stress": ("终端持续输出、内存和隐藏视图压力测试", [
        ("make", "test-terminal-stress"),
        ("bash", "scripts/test-terminal-visibility-memory.sh"),
    ]),
}
COMMON_SUITES = ("core", "focus", "terminal", "commands", "files", "appearance", "restore", "release")


def make_plan(suites):
    names = []
    commands = []
    for name in suites:
        for expanded in COMMON_SUITES if name == "all" else (name,):
            if expanded not in names:
                names.append(expanded)
            for command in SUITES[expanded][1]:
                if command not in commands:
                    commands.append(command)
    return names, commands


def run_plan(commands, output_dir, report):
    output_dir.mkdir(parents=True, exist_ok=False)
    report.update(automatic="running", manual="pending", tests=[
        {"command": list(command), "status": "not_run", "log": f"{index:02d}.log"}
        for index, command in enumerate(commands, 1)
    ])
    summary = output_dir / "summary.json"

    def save():
        summary.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")

    save()
    for index, item in enumerate(report["tests"], 1):
        print(f"[{index}/{len(commands)}] {shlex.join(item['command'])}", flush=True)
        print(f"日志：{output_dir / item['log']}", flush=True)
        item["status"] = "running"
        save()
        try:
            with (output_dir / item["log"]).open("w") as log:
                result = subprocess.run(item["command"], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            code = result.returncode if result.returncode >= 0 else 128 - result.returncode
        except OSError as error:
            (output_dir / item["log"]).write_text(str(error) + "\n")
            code = 127
        except KeyboardInterrupt:
            code = 130
        item.update(exit_code=code, status="passed" if code == 0 else "failed")
        if code:
            report["automatic"] = "failed"
            save()
            print(f"未通过（退出码 {code}），后续测试未运行。报告：{summary}", file=sys.stderr)
            return code
        save()
    report["automatic"] = "passed"
    save()
    print(f"所选自动化测试通过；实机流程仍需按验收文档核对。报告：{summary}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suites", nargs="*", help="默认 core focus；可组合多个范围，--list 查看")
    parser.add_argument("--list", action="store_true", help="列出范围，不运行测试")
    parser.add_argument("--dry-run", action="store_true", help="展示去重后的命令，不运行测试")
    parser.add_argument("--output-dir", type=Path, help="日志输出到新的目录，默认 build/acceptance/时间戳-随机值")
    args = parser.parse_args()
    for name in args.suites:
        if name not in SUITES and name != "all":
            parser.error(f"未知验收范围：{name}；使用 --list 查看")
    if args.list:
        for name, (description, _) in SUITES.items():
            print(f"{name:14} {description}")
        print("all            常用范围合集；不含 automation、compatibility、stress")
        return 0
    names, commands = make_plan(args.suites or ["core", "focus"])
    if args.dry_run:
        for command in commands:
            print(shlex.join(command))
        return 0
    if sys.platform != "darwin":
        parser.error("验收脚本需要 macOS、完整 Xcode 和登录中的图形桌面")
    if any(name not in ("core", "automation") for name in names) and not (PRODUCTS / "Natty.app/Contents/MacOS/Natty.debug.dylib").is_file():
        parser.error("缺少 Debug 应用模块；先按验收文档完成构建。此入口不会自动安装或重启")
    if "automation" in names and not Path("/Applications/Natty.app/Contents/MacOS/Natty").is_file():
        parser.error("automation 需要已安装的 /Applications/Natty.app；先按验收文档完成安装")
    # make 会设置此变量，直接调用 bash 的测试也需要相同的 Xcode 工具链。
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
    output_dir = args.output_dir.resolve() if args.output_dir else ROOT / "build/acceptance" / stamp
    if output_dir.exists():
        parser.error(f"输出目录已存在，请使用新目录以保留历史结果：{output_dir}")
    report = {
        "started_at": datetime.now().astimezone().isoformat(),
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "working_tree": subprocess.check_output(["git", "status", "--short"], cwd=ROOT, text=True),
        "suites": names,
    }
    return run_plan(commands, output_dir, report)


if __name__ == "__main__":
    sys.exit(main())
