#!/usr/bin/env python3
"""一键重新部署 1Agent：停止旧应用 → 编译、签名、安装 → 启动新应用。

用法：python3 build.py（也可从其他目录传入本脚本的绝对路径）。
依赖：macOS、完整 Xcode、xcodegen、make；使用现有 make build 流程。
在 1Agent 自身终端中执行时，转为独立进程并将输出写入日志，避免退出应用时中断构建。
"""

import hashlib
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path


ROOT = Path(__file__).resolve().parent
APP_NAME = "1Agent"
BUNDLE_ID = "com.itjun.1agent"
INSTALLED_APP = Path("/Applications/1Agent.app")
BUILT_APP = ROOT / "build/DerivedData.noindex/Build/Products/Debug/1Agent.app"
STAGE_TIMES = []


@contextmanager
def stage(name):
    print(f"==> {name}", flush=True)
    started = time.perf_counter()
    try:
        yield
    finally:
        STAGE_TIMES.append((name, time.perf_counter() - started))


def running_pids(app):
    """只匹配这个应用包的主程序，不匹配 shell 命令或其他应用。"""
    executable = app / "Contents/MacOS" / APP_NAME
    pattern = "^" + re.escape(str(executable)) + "([[:space:]]|$)"
    result = subprocess.run(
        # macOS 默认排除祖先进程；在 1Agent 自身终端中运行时也必须找到宿主应用。
        ["/usr/bin/pgrep", "-af", pattern], capture_output=True, text=True, check=False
    )
    if result.returncode == 1:
        return []
    if result.returncode != 0:
        raise RuntimeError(f"查询进程失败：{result.stderr.strip()}")
    return [int(pid) for pid in result.stdout.split()]


def is_running_inside_app():
    app_pids = set(running_pids(INSTALLED_APP) + running_pids(BUILT_APP))
    if not app_pids:
        return False
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid=,ppid="], capture_output=True, text=True, check=True
    )
    parents = {}
    for line in result.stdout.splitlines():
        pid, parent = map(int, line.split())
        parents[pid] = parent
    pid = os.getppid()
    while pid in parents:
        if pid in app_pids:
            return True
        pid = parents[pid]
    return False


def launch_detached_build():
    with tempfile.NamedTemporaryFile(prefix="1agent-build-", suffix=".log", delete=False) as log:
        print(f"==> 从 1Agent 内启动，构建将在独立进程中继续；日志：{log.name}", flush=True)
        # 独立会话避开应用退出时对整个 PTY 会话的清理；所有标准流也必须脱离终端。
        worker = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "--worker"], cwd=ROOT,
            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        print(f"    构建进程 PID：{worker.pid}，完成后将自动启动新应用", flush=True)


def wait_for_exit(app, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not running_pids(app):
            return True
        time.sleep(0.1)
    return not running_pids(app)


def stop_running():
    for app in (INSTALLED_APP, BUILT_APP):
        if not running_pids(app):
            continue
        print(f"    退出 {app}", flush=True)
        # 正常退出会保存会话与终端历史；无响应时再强杀。
        try:
            subprocess.run(
                ["/usr/bin/osascript", "-e", f'tell application "{app}" to quit'],
                capture_output=True, timeout=5, check=False,
            )
        except subprocess.TimeoutExpired:
            pass
        if wait_for_exit(app, timeout=5):
            continue
        for pid in running_pids(app):
            print(f"    强制结束旧进程 {pid}", flush=True)
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if not wait_for_exit(app, timeout=3):
            raise RuntimeError(f"旧应用未退出：{app}")


def verify_running_build():
    with (INSTALLED_APP / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise RuntimeError("安装后的应用包标识不正确")
    # Debug 主程序负责加载 dylib，因此也核对实际包含应用代码的文件。
    for name in (APP_NAME, f"{APP_NAME}.debug.dylib"):
        source = BUILT_APP / "Contents/MacOS" / name
        if not source.is_file():
            if name == APP_NAME:
                raise RuntimeError(f"缺少构建产物：{source}")
            continue
        installed = INSTALLED_APP / "Contents/MacOS" / name
        if hashlib.sha256(source.read_bytes()).digest() != hashlib.sha256(installed.read_bytes()).digest():
            raise RuntimeError(f"安装后的 {name} 与本次构建不一致")
    pids = running_pids(INSTALLED_APP)
    if not pids:
        raise RuntimeError("新安装的 1Agent 未运行")
    print(f"==> 新构建已安装并运行，PID：{', '.join(map(str, pids))}", flush=True)


def main():
    if sys.platform != "darwin":
        raise RuntimeError("1Agent 当前仅支持在 macOS 上构建和运行")
    missing = [tool for tool in ("make", "xcodegen", "xcodebuild") if not shutil.which(tool)]
    if missing:
        raise RuntimeError(f"缺少构建工具：{', '.join(missing)}")
    if sys.argv[1:] != ["--worker"] and is_running_inside_app():
        launch_detached_build()
        return
    with stage("停止旧应用"):
        stop_running()
    with stage("重新编译、签名、安装并启动"):
        subprocess.run(["make", "build"], cwd=ROOT, check=True)
    verify_running_build()
    print("\n阶段耗时：", flush=True)
    for name, seconds in STAGE_TIMES:
        print(f"    {name}：{seconds:.1f}s", flush=True)
    print(f"    总计：{sum(seconds for _, seconds in STAGE_TIMES):.1f}s", flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n构建已取消", file=sys.stderr)
        sys.exit(130)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"\n构建失败：{error}", file=sys.stderr)
        sys.exit(1)
