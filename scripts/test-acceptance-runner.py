#!/usr/bin/env python3
"""验收入口的行为回归：只运行临时子进程，不启动应用或触碰用户会话。"""
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("test-acceptance.py")
spec = importlib.util.spec_from_file_location("acceptance", SCRIPT)
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


class AcceptanceRunnerTests(unittest.TestCase):
    def run_commands(self, commands):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "logs"
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                code = acceptance.run_plan(commands, output, {})
            report = json.loads((output / "summary.json").read_text())
            logs = {p.name: p.read_text() for p in output.glob("*.log")}
            return code, report, logs

    def test_success_does_not_mark_manual_acceptance_passed(self):
        code, report, logs = self.run_commands([(sys.executable, "-c", "print('verified')")])
        self.assertEqual(code, 0)
        self.assertEqual(report["automatic"], "passed")
        self.assertEqual(report["manual"], "pending")
        self.assertEqual(logs["01.log"].strip(), "verified")

    def test_failure_keeps_exit_code_and_stops_later_tests(self):
        code, report, logs = self.run_commands([
            (sys.executable, "-c", "import sys; print('broken'); sys.exit(7)"),
            (sys.executable, "-c", "print('must not run')"),
        ])
        self.assertEqual(code, 7)
        self.assertEqual(report["automatic"], "failed")
        self.assertEqual(report["tests"][1]["status"], "not_run")
        self.assertNotIn("02.log", logs)

    def test_focus_interruption_is_not_retried_again_or_counted_as_success(self):
        code, report, logs = self.run_commands([
            (sys.executable, "-c", "import sys; print('one attempt'); sys.exit(75)"),
        ])
        self.assertEqual(code, 75)
        self.assertEqual(report["automatic"], "failed")
        self.assertEqual(logs["01.log"].splitlines(), ["one attempt"])

    def test_overlapping_suites_keep_one_command_and_preserve_empty_argument(self):
        _, commands = acceptance.make_plan(["commands", "restore", "commands"])
        self.assertEqual(commands.count(("bash", "scripts/test-command-sidebar-restoration.sh")), 1)
        self.assertIn(("bash", "scripts/test-terminal-windows.sh", "", "--command-drag"), commands)

    def test_dry_run_has_no_side_effects_and_all_excludes_explicit_suites(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "not-created"
            result = subprocess.run([sys.executable, str(SCRIPT), "all", "--dry-run", "--output-dir", str(output)],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("scripts/test-terminal-focus.sh", result.stdout)
            self.assertNotIn("scripts/test-terminal-automation.py", result.stdout)
            self.assertNotIn("test-terminal-compatibility", result.stdout)
            self.assertNotIn("test-terminal-stress", result.stdout)
            self.assertFalse(output.exists())

    def test_unknown_suite_fails_instead_of_running_default_tests(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "misspelled", "--dry-run"],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("未知验收范围", result.stderr)


if __name__ == "__main__":
    unittest.main()
