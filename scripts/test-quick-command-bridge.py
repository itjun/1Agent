#!/usr/bin/env python3
"""Exercise the real bundled ZLE adapter in an isolated PTY, without user rc files."""
import base64
import errno
import os
import pathlib
import pty
import re
import select
import signal
import socket
import subprocess
import shutil
import tempfile
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="1a-qc-test-", dir="/tmp") as folder:
    endpoint = folder + "/s"
    token = str(uuid.uuid4())
    remote_bootstrap = os.environ.get("ONEAGENT_REMOTE_INTEGRATION_TEST") == "1"
    bootstrap = None
    if remote_bootstrap:
        endpoint = "/tmp/1a-remote-" + token + "/s"
        pathlib.Path(folder, ".zshrc").write_text("PS1='QC_PROMPT> '\n")
        bootstrap = subprocess.check_output(["/tmp/oneagent-remote-shell-tests", "--bootstrap", str(ROOT / "Resources"), token], text=True).strip()
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(folder)
        env = dict(os.environ, HOME=folder, ZDOTDIR=folder, TERM="xterm-256color",
                   ONEAGENT_QC_SOCKET=endpoint, ONEAGENT_QC_TOKEN=token)
        env.pop("ONEAGENT_QC_OWNER", None)
        if remote_bootstrap:
            env["SHELL"] = "/bin/zsh"
            os.execve("/bin/sh", ["sh", "-c", bootstrap], env)
        os.execve("/bin/zsh", ["zsh", "-dfi"], env)

    output = bytearray()
    def drain(timeout=0.1):
        if select.select([fd], [], [], timeout)[0]:
            try:
                output.extend(os.read(fd, 65536))
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise

    def wait_for(predicate, seconds=3):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            drain(0.03)
            if predicate():
                return
        raise AssertionError(bytes(output[-2500:]))

    def request(action="query", script="", directory=os.path.realpath(folder), ident=None, lifetime=1, send_delay=0):
        ident = ident or str(uuid.uuid4())
        payload = "|".join([token, ident, action, str(round(time.time() + lifetime, 3)),
                            base64.b64encode(directory.encode()).decode(), base64.b64encode(script.encode()).decode()]) + "\n"
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(1.2)
            try:
                client.connect(endpoint)
                if send_delay: time.sleep(send_delay)
                client.sendall(payload.encode())
            except (ConnectionRefusedError, BrokenPipeError):
                return ""
            try:
                reply = client.recv(256).decode().strip()
            except (TimeoutError, socket.timeout):
                reply = ""
        drain()
        return reply.partition("|")[2]

    try:
        adapter = ROOT / "Resources/shell-integration/zsh/oneagent-quick-commands"
        if not remote_bootstrap:
            os.write(fd, f"PS1='QC_PROMPT> '; source '{adapter}'\n".encode())
        wait_for(lambda: os.path.exists(endpoint) and b"QC_PROMPT> " in output)
        assert request() == "ready", bytes(output[-2500:])
        if remote_bootstrap:
            probe = request("probe", lifetime=-3600, send_delay=0.5).split("|")
            assert probe[0] == "ready" and abs(float(probe[1]) - time.time()) < 2, "SSH delay or clock skew broke readiness probe"
            assert b"\x1b]7;kitty-shell-cwd://" in output, "remote login did not report its cwd"
            child_dir = pathlib.Path(folder, "目录 with spaces")
            child_dir.mkdir()
            os.write(fd, f"cd '{child_dir}'\n".encode())
            wait_for(lambda: str(child_dir).encode() + b"\x07" in output)
            os.write(fd, f"cd '{folder}'\n".encode())
            wait_for(lambda: request() == "ready")
        os.write(fd, b"echo preserve-this")
        drain()
        assert request() == "rejected", "pending buffer was accepted"
        assert request("run", "echo WRONG") == "rejected"
        assert b"WRONG" not in output
        os.write(fd, b"\x15")  # clear only this test's line
        drain()
        assert request() == "ready"
        assert request("run", "echo WRONG", directory="/not-the-cwd") == "rejected"
        assert request("run", "echo WRONG", lifetime=-1) != "accepted"
        marker = pathlib.Path(folder) / "runs"
        ident = str(uuid.uuid4())
        script = f"( builtin cd -- '{folder}' && eval -- 'printf run >> runs; printf \\\"hello\\\\nworld\\\\n\\\"; exit 7' )"
        assert request("run", script, ident=ident) == "accepted", bytes(output[-2500:])
        wait_for(lambda: marker.exists())
        assert marker.read_text() == "run"
        wait_for(lambda: request() == "ready", seconds=5)
        assert request("run", script, ident=ident) == "rejected", bytes(output[-2500:])
        assert marker.read_text() == "run"
        assert request() == "ready", "subshell exit killed interactive shell"
        # Sourced initialization scripts must not receive the ZLE listener fd
        # through the widget's positional parameters.
        initializer = pathlib.Path(folder) / "init.sh"
        initializer.write_text('(( $# == 0 )) || return 64\nexport QC_INITIALIZED=ready\n')
        initialized = pathlib.Path(folder) / "initialized"
        assert request("run", "( source ./init.sh && printf %s \"$QC_INITIALIZED\" > initialized )") == "accepted"
        wait_for(lambda: request() == "ready")
        assert initialized.exists() and initialized.read_text() == "ready", "sourced initialization inherited widget arguments"
        # Exercise a multi-line prompt and assert that redisplay does not move
        # above the final output line and clear it (the old MONITOR path did).
        os.write(fd, b"PS1=$'QC_TOP\\nQC_PROMPT> '\n")
        drain()
        wait_for(lambda: request() == "ready")
        start = len(output)
        assert request("run", "( printf 'stdout-preserved\\n'; printf 'stderr-preserved\\n' >&2 )") == "accepted"
        wait_for(lambda: b"stdout-preserved\r\nstderr-preserved\r\n" in output[start:])
        wait_for(lambda: request() == "ready")
        rendered_tail = bytes(output[start:]).split(b"stderr-preserved\r\n", 1)[1]
        assert not re.search(rb"\x1b\[[0-9]*A", rendered_tail), "prompt redraw erased command output"
        assert b"QC_TOP" in rendered_tail and b"QC_PROMPT> " in rendered_tail
        os.write(fd, b"sleep 2\n")
        drain()
        assert request(lifetime=0.2) != "ready", "running process reported ready"
        wait_for(lambda: request() == "ready", seconds=4)
        os.write(fd, b"echo 'unfinished\n")
        drain()
        assert request() != "ready", "continuation accepted"
        os.write(fd, b"\x03")
        drain()
        wait_for(lambda: request() == "ready", seconds=4)
        os.write(fd, b"\x12")  # reverse history search must never be overwritten
        drain()
        assert request() != "ready", "history search accepted"
        os.write(fd, b"\x03")
        drain()
        # Aborted isearch is conservatively unavailable until the next prompt.
        os.write(fd, b"\n")
        wait_for(lambda: request() == "ready", seconds=4)
        interrupted = pathlib.Path(folder) / "interrupted"
        assert request("run", "( printf started > started; sleep 10; printf BAD > interrupted )") == "accepted"
        wait_for(lambda: (pathlib.Path(folder) / "started").exists())
        os.write(fd, b"\x03")
        drain()
        wait_for(lambda: request() == "ready", seconds=4)
        assert not interrupted.exists(), "Ctrl-C did not stop the command"
        assert request("run", "( eval 'if syntax broken' )") == "accepted"
        wait_for(lambda: request() == "ready", seconds=4)
        assert request("run", "( cd /missing-1agent-quick-command-test && printf BAD > missing )") == "accepted"
        wait_for(lambda: request() == "ready", seconds=4)
        assert not (pathlib.Path(folder) / "missing").exists()
        print("ZLE bridge: empty/busy input, cwd, expiry, once-only, subshell exit, sourced initialization, preserved stdout/stderr, multi-line prompt, running job, continuation, history search, Ctrl-C and syntax errors passed")
    except Exception:
        drain()
        print(bytes(output[-6000:]))
        os.write(fd, b"\x03")
        drain(1)
        raise
    finally:
        os.kill(pid, signal.SIGHUP)
        os.close(fd)
        os.waitpid(pid, 0)
        if remote_bootstrap:
            shutil.rmtree("/tmp/1a-remote-" + token, ignore_errors=True)
