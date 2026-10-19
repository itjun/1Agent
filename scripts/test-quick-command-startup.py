#!/usr/bin/env python3
"""Exercise production startup text in real login-shell PTYs with isolated homes."""
import errno
import os
import pathlib
import pty
import select
import shutil
import signal
import subprocess
import tempfile
import time

fixture = "/tmp/oneagent-quick-command-tests"
shells = ["/bin/zsh", "/bin/bash"]
if shutil.which("fish"):
    shells.append(shutil.which("fish"))

with tempfile.TemporaryDirectory(prefix="1Agent startup 中文 '") as root:
    root = pathlib.Path(root)
    for shell in shells:
        for case in ["quotes", "syntax", "missing", "interrupt"]:
            home = root / (pathlib.Path(shell).name + "-" + case)
            home.mkdir()
            work = home / "work ' 中文"
            work.mkdir()
            script = {
                "quotes": "printf '%s\\n' \"quote's 中文\" > result\nprintf second >> result\nexit 7",
                "syntax": "if syntax broken",
                "missing": "printf BAD > should-not-exist",
                "interrupt": "printf started > started; sleep 10; printf BAD > should-not-exist",
            }[case]
            target = work / "missing" if case == "missing" else work
            startup = subprocess.check_output([fixture, "--startup-command", shell, str(target), script], text=True).strip()
            pid, fd = pty.fork()
            if pid == 0:
                os.chdir(home)
                # This fixture has a PTY but no VT emulator to answer terminal queries.
                # Rich fish/VT negotiation is exercised by test-terminal-compatibility.
                env = dict(os.environ, HOME=str(home), ZDOTDIR=str(home), SHELL=shell, TERM="dumb")
                for key in list(env):
                    if key.startswith("ONEAGENT_QC_") or key in ["BASH_ENV", "ENV", "HISTFILE"]:
                        del env[key]
                os.execve("/bin/sh", ["sh", "-c", startup], env)
            output = bytearray()

            def wait_for(predicate, seconds=5):
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    if select.select([fd], [], [], 0.03)[0]:
                        try:
                            output.extend(os.read(fd, 65536))
                        except OSError as error:
                            if error.errno != errno.EIO:
                                raise
                    if predicate():
                        return
                raise AssertionError((shell, case, bytes(output[-3000:])))

            try:
                if case == "interrupt":
                    wait_for(lambda: (work / "started").exists())
                    os.write(fd, b"\x03")
                wait_for(lambda: b"Exit code:" in output)
                if case == "quotes":
                    assert (work / "result").read_text() == "quote's 中文\nsecond"
                    assert b"Exit code: 7" in output
                assert not (work / "should-not-exist").exists(), (shell, case, bytes(output[-2000:]))
                os.write(fd, b"printf interactive > recovered; pwd > final-directory\n")
                final = home if case == "missing" else work
                wait_for(lambda: (final / "recovered").exists())
                actual = (final / "final-directory").read_text().strip()
                assert pathlib.Path(actual).resolve() == final.resolve(), (shell, case, actual, str(final.resolve()))
            finally:
                os.kill(pid, signal.SIGHUP)
                os.close(fd)
                os.waitpid(pid, 0)
    print("Startup PTYs passed: " + ", ".join(shells) + "; quotes, multiline, exit, syntax, missing directory, Ctrl-C, retained shell/cwd")
    if not shutil.which("fish"):
        print("fish runtime unavailable on this Mac; fish execution branch was not run")
