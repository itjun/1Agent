#!/usr/bin/env python3
"""Check cleanup of the real remote bootstrap on exit and terminal hangup.

Set ONEAGENT_REMOTE_CLEANUP_TEST_HOST to an explicitly designated test host
to also exercise a real SSH disconnect. The test creates and removes one
random, private directory on that host.
"""
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
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNNER = "/tmp/oneagent-remote-shell-tests"
HOST = os.environ.get("ONEAGENT_REMOTE_CLEANUP_TEST_HOST")
SSH = ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
       "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "RemoteCommand=none"]


def check(host, action):
    token = str(uuid.uuid4())
    folder = "/tmp/1a-remote-" + token
    bootstrap = subprocess.check_output([RUNNER, "--bootstrap", str(ROOT / "Resources"), token], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="1a-cleanup-test-") as home:
        pathlib.Path(home, ".zshrc").write_text("PS1='CLEANUP_TEST> '\n")

        def remote(command):
            return subprocess.run(SSH + ["--", host, command], stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, timeout=10).returncode

        def exists():
            if host:
                result = remote("test -d " + folder)
                if result not in (0, 1):
                    raise AssertionError("SSH test host is unavailable")
                return result == 0
            return os.path.isdir(folder)

        pid, fd = pty.fork()
        if pid == 0:
            if host:
                os.execv(SSH[0], SSH + ["-tt", "--", host, bootstrap])
            env = dict(os.environ, HOME=home, ZDOTDIR=home, SHELL="/bin/zsh", TERM="xterm-256color")
            os.execve("/bin/sh", ["sh", "-c", bootstrap], env)

        reaped = False
        try:
            os.write(fd, b"printf 'CLEANUP_%s\\n' READY\n")
            output = bytearray()
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and b"CLEANUP_READY" not in output:
                if select.select([fd], [], [], 0.1)[0]:
                    try:
                        output.extend(os.read(fd, 65536))
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        break
            assert b"CLEANUP_READY" in output and exists(), "test session did not start"
            if action == "exit":
                os.write(fd, b"exit\n")
            else:
                os.kill(pid, signal.SIGHUP if action == "hangup" else signal.SIGTERM)
                os.close(fd)
                fd = -1
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if fd >= 0 and select.select([fd], [], [], 0.05)[0]:
                    try:
                        os.read(fd, 65536)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                if os.waitpid(pid, os.WNOHANG)[0]:
                    reaped = True
                    break
                time.sleep(0.05)
            assert reaped, "test session did not exit"
            if fd >= 0:
                os.close(fd)
                fd = -1
            deadline = time.monotonic() + 5
            while exists() and time.monotonic() < deadline:
                time.sleep(0.1)
            assert not exists(), f"session directory remains after {action}"
        finally:
            if fd >= 0:
                os.close(fd)
            if not reaped:
                try:
                    os.killpg(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.waitpid(pid, 0)
            if host:
                if remote("rm -rf -- " + folder + " && test ! -e " + folder) != 0:
                    raise AssertionError("could not remove the SSH test directory")
            else:
                shutil.rmtree(folder, ignore_errors=True)


for action in ("exit", "hangup", "terminate"):
    check(None, action)
if HOST:
    check(HOST, "exit")
    check(HOST, "hangup")
print("Remote shell cleanup: normal exit, hangup and termination passed" +
      ("; real SSH exit and hangup passed" if HOST else ""))
