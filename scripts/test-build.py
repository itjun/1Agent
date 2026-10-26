#!/usr/bin/env python3
"""验证自托管构建的进程识别，不退出或构建真实的 1Agent。"""
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin", "使用 macOS 的 pgrep 语义")
class BuildProcessTests(unittest.TestCase):
    def test_build_recognizes_its_host_application(self):
        with tempfile.TemporaryDirectory(prefix="oneagent-build-测试 空格-") as directory:
            app = Path(directory) / "1Agent.app"
            executable = app / "Contents/MacOS/1Agent"
            executable.parent.mkdir(parents=True)
            executable.symlink_to("/bin/sh")
            # 用应用路径启动真实父进程，复现从 1Agent 的终端调用脚本。
            probe = f"""
import importlib.util
import json
import os
from pathlib import Path
spec = importlib.util.spec_from_file_location("oneagent_build", {str(ROOT / 'build.py')!r})
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
build.INSTALLED_APP = Path({str(app)!r})
build.BUILT_APP = Path({str(app / 'missing')!r})
pids = build.running_pids(build.INSTALLED_APP)
assert os.getppid() in pids, (os.getppid(), pids)
assert build.is_running_inside_app(), "未识别宿主应用"
print(json.dumps(pids))
"""
            result = subprocess.run(
                [str(executable), "-c", shlex.join([sys.executable, "-c", probe]) + "; exit $?"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(json.loads(result.stdout))

    def test_external_terminal_stays_in_foreground(self):
        spec = importlib.util.spec_from_file_location("oneagent_build", ROOT / "build.py")
        build = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(build)
        with tempfile.TemporaryDirectory(prefix="oneagent-build-external-") as directory:
            app = Path(directory) / "1Agent.app"
            executable = app / "Contents/MacOS/1Agent"
            executable.parent.mkdir(parents=True)
            executable.symlink_to("/bin/sleep")
            build.INSTALLED_APP = app
            build.BUILT_APP = app / "missing"
            with subprocess.Popen([str(executable), "10"]) as process:
                try:
                    self.assertIn(process.pid, build.running_pids(app))
                    self.assertFalse(build.is_running_inside_app())
                finally:
                    process.terminate()


if __name__ == "__main__":
    unittest.main()
