#!/usr/bin/env python3
"""Ephemeral SSH terminal adapter. Control accepts snapshot/stop only, never commands."""
import datetime
import json
import os
from pathlib import Path
import shlex
import signal
import socket
import sqlite3
import stat
import subprocess
import sys
import time
import uuid

KINDS = {"pi", "omp", "grok", "codex", "claude"}
STORAGE_KEYS = {"CODEX_HOME", "GROK_HOME", "PI_CODING_AGENT_DIR", "PI_AGENT_DIR", "CLAUDE_CONFIG_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME"}
ENV = dict(os.environ)
STATE = Path(ENV.get("ONEAGENT_AGENT_STATE", "/nonexistent/invocation.json"))
ROOT = STATE.parent
STOP = 0


def read_json(path):
    try:
        with open(path, "rb") as handle:
            data = handle.read(65537)
        return json.loads(data) if len(data) <= 65536 else None
    except (OSError, ValueError):
        return None


def write_json(path, value):
    temporary = str(path) + "." + str(os.getpid()) + ".tmp"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(value, handle, ensure_ascii=False, separators=(",", ":"))
    os.replace(temporary, path)


def valid_context():
    try:
        info = ROOT.lstat()
        return ROOT.name.startswith("1a-remote-") and uuid.UUID(ROOT.name[10:]) and info.st_uid == os.getuid() and stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o700
    except (OSError, ValueError):
        return False


def valid_conversation(value):
    try:
        uuid.UUID(value["sessionID"])
        return value["kind"] in KINDS and all(isinstance(value[key], str) and value[key].startswith("/") and "\0" not in value[key] for key in ("directory", "executable")) and (value["kind"] not in ("pi", "omp") or value.get("sessionFile", "").startswith("/"))
    except (KeyError, ValueError, TypeError, AttributeError):
        return False


def header(path):
    try:
        with open(path, "rb") as handle:
            lines = handle.read(32768).splitlines()[:4]
        for line in lines:
            value = json.loads(line)
            if value.get("type") == "session_meta":
                return value["payload"]["id"], value["payload"]["cwd"]
            if value.get("type") == "session":
                return value["id"], value["cwd"]
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


def birth(pid):
    if pid <= 1:
        return None
    try:
        # comm is parenthesized and may itself contain spaces or parentheses.
        fields = Path("/proc/%d/stat" % pid).read_text().rsplit(")", 1)[1].split()
        if fields[0] == "Z":
            return None
        return fields[19]
    except (OSError, IndexError):
        if sys.platform == "darwin":
            value = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="], capture_output=True, text=True).stdout.strip()
            return value or None
        return None


def owned_signal(pid, identity, value):
    descriptor = None
    try:
        if hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal"):
            try:
                descriptor = os.pidfd_open(pid)
            except OSError:
                pass  # Older kernels can expose Python's API without implementing pidfds.
        if identity is not None and birth(pid) == identity:
            if descriptor is not None:
                signal.pidfd_send_signal(descriptor, value)
            else:
                os.kill(pid, value)
            return True
    except OSError:
        pass
    finally:
        if descriptor is not None:
            os.close(descriptor)
    return False


def descendants(pid):
    result, pending = {}, [pid]
    while pending and len(result) < 512:
        current = pending.pop()
        identity = birth(current)
        if identity is None or current in result:
            continue
        result[current] = identity
        try:
            children = Path("/proc/%d/task/%d/children" % (current, current)).read_text().split()
            pending.extend(int(child) for child in children)
        except OSError:
            if sys.platform == "darwin":
                rows = subprocess.run(["/bin/ps", "-axo", "pid=,ppid="], capture_output=True, text=True).stdout.splitlines()
                pending.extend(int(row.split()[0]) for row in rows if len(row.split()) == 2 and int(row.split()[1]) == current)
    return result


def open_paths(pid):
    try:
        result = []
        for descriptor in Path("/proc/%d/fd" % pid).iterdir():
            try:
                result.append(os.readlink(descriptor))
            except OSError:
                pass
        return result
    except OSError:
        if sys.platform == "darwin":
            output = subprocess.run(["/usr/sbin/lsof", "-Fn", "-p", str(pid)], capture_output=True, text=True).stdout
            return [line[1:] for line in output.splitlines() if line.startswith("n/")]
        return []


def tracks(kind, args):
    excluded = {"--help", "-h", "--version", "-V", "--no-session", "--no-session-persistence", "--ephemeral", "--no-extensions", "--print", "--mode", "--remote"}
    if excluded.intersection(args) or (kind != "codex" and "-p" in args):
        return False
    if kind == "grok" and {"--single", "--prompt-file", "--prompt-json"}.intersection(args):
        return False
    values = {"-c", "--config", "-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval", "-C", "--cd", "--add-dir", "--enable", "--disable", "--local-provider", "--settings", "--image", "-i"}
    index, first = 0, None
    while index < len(args):
        if args[index] == "--":
            break
        if args[index] in values:
            index += 2
            continue
        if not args[index].startswith("-"):
            first = args[index]
            break
        index += 1
    if kind == "codex" and first in {"exec", "e", "review", "login", "logout", "mcp", "plugin", "app-server", "remote-control", "app", "completion", "update", "doctor", "sandbox", "debug", "apply", "a", "queue", "archive", "delete", "unarchive", "migrate-rollouts", "cloud", "exec-server", "features", "help", "agents"}:
        return False
    return not (kind == "grok" and first in {"agent", "sessions", "export", "login", "logout", "update", "completion", "help", "mcp"})


def event_path(invocation):
    return ROOT / (invocation["invocationID"] + ".json")


def current_conversation(invocation):
    if not invocation or invocation.get("phase") == "ended":
        return None
    value = read_json(event_path(invocation)) or invocation.get("conversation")
    if not valid_conversation(value) or value["kind"] != invocation["kind"] or value["executable"] != invocation["executable"]:
        return None
    if value["kind"] in ("pi", "omp"):
        info = header(value["sessionFile"])
        if not info or info[0].lower() != value["sessionID"].lower():
            return None
    return value


def discover(invocation, pid, env):
    kind = invocation["kind"]
    value = {"kind": kind, "executable": invocation["executable"], "storageEnvironment": {key: val for key, val in env.items() if key in STORAGE_KEYS}}
    if kind == "codex":
        paths, candidates = open_paths(pid), {}
        for path in paths:
            try:
                if "/thread-writer-locks/" in path and path.endswith(".lock"):
                    candidate = Path(path).stem
                    uuid.UUID(candidate)
                    candidates[candidate] = None
                elif "/sessions/" in path and path.endswith(".jsonl"):
                    info = header(path)
                    if info:
                        uuid.UUID(info[0]); candidates[info[0]] = info[1]
            except ValueError:
                pass
        if len(candidates) != 1:
            return None
        session_id, cwd = next(iter(candidates.items()))
        for path in set(paths):
            if Path(path).name.startswith("state_") and path.endswith(".sqlite"):
                try:
                    with sqlite3.connect(Path(path).as_uri() + "?mode=ro", uri=True, timeout=.05) as database:
                        row = database.execute("SELECT cwd FROM threads WHERE id=? AND has_user_event=1", (session_id,)).fetchone()
                    if row:
                        cwd = row[0]
                except sqlite3.Error:
                    pass
        if not cwd:
            return None
        value.update(sessionID=session_id, directory=cwd)
    elif kind == "grok":
        home = Path(env.get("GROK_HOME", str(Path(env.get("HOME", "~")) / ".grok")))
        entries = read_json(home / "active_sessions.json")
        pids, matches = descendants(pid), []
        if not isinstance(entries, list):
            return None
        for entry in entries:
            if entry.get("pid") not in pids:
                continue
            try:
                opened = datetime.datetime.fromisoformat(entry["opened_at"].replace("Z", "+00:00")).timestamp()
                if sys.platform == "darwin":
                    started = time.mktime(time.strptime(pids[entry["pid"]], "%a %b %d %H:%M:%S %Y"))
                else:
                    boot = float(next(line.split()[1] for line in Path("/proc/stat").read_text().splitlines() if line.startswith("btime ")))
                    started = boot + float(pids[entry["pid"]]) / os.sysconf("SC_CLK_TCK")
                if opened < started - 1:
                    continue
                uuid.UUID(entry["session_id"])
                matches.append(entry)
            except (OSError, ValueError, KeyError, StopIteration):
                continue
        if len(matches) != 1:
            return None
        value.update(sessionID=matches[0]["session_id"], directory=matches[0]["cwd"])
    else:
        return None
    return value if valid_conversation(value) else None


def record():
    invocation = read_json(STATE)
    if not invocation or invocation["kind"] != "claude" or invocation["invocationID"] != ENV.get("ONEAGENT_AGENT_INVOCATION"):
        return
    try:
        body = json.loads(sys.stdin.buffer.read(65536))
        if body.get("hook_event_name") != "SessionStart":
            return
        value = {"kind": "claude", "sessionID": body["session_id"], "sessionFile": body.get("transcript_path"), "directory": body["cwd"], "executable": invocation["executable"], "storageEnvironment": {key: val for key, val in ENV.items() if key in STORAGE_KEYS}}
        if valid_conversation(value):
            write_json(event_path(invocation), value)
    except (ValueError, KeyError, OSError):
        pass


def note_signal(value, _frame):
    global STOP
    STOP = value


def run(kind, executable, args, resumed=None):
    try:
        foreground = os.tcgetpgrp(0)
    except OSError:
        foreground = os.getpgrp()
    if foreground != os.getpgrp() or not tracks(kind, args):
        os.execv(executable, [executable] + args)
    invocation = {"invocationID": str(uuid.uuid4()).upper(), "ownerPID": os.getpid(), "ownerStart": birth(os.getpid()), "kind": kind, "executable": executable, "phase": "active", "conversation": resumed}
    write_json(STATE, invocation)
    env = dict(ENV)
    env.update({key: value for key, value in (resumed or {}).get("storageEnvironment", {}).items() if key in STORAGE_KEYS})
    env.update(ONEAGENT_AGENT_INVOCATION=invocation["invocationID"], ONEAGENT_AGENT_KIND=kind, ONEAGENT_AGENT_EXECUTABLE=executable)
    child_args = list(args)
    if kind in ("pi", "omp"):
        child_args = ["--extension", str(ROOT / "agent-sessions/session-extension.mjs")] + child_args
    if kind == "claude":
        settings, filtered, index = {}, [], 0
        try:
            while index < len(child_args):
                word = child_args[index]
                if word == "--settings":
                    raw = child_args[index + 1]; index += 2
                elif word.startswith("--settings="):
                    raw = word[11:]; index += 1
                else:
                    filtered.append(word); index += 1; continue
                settings = json.loads(raw) if raw.lstrip().startswith("{") else json.loads(Path(raw).read_text())
            settings.setdefault("hooks", {}).setdefault("SessionStart", []).append({"hooks": [{"type": "command", "command": shlex.quote(ENV["ONEAGENT_AGENT_HELPER"]) + " record", "timeout": 3}]})
            child_args = ["--settings", json.dumps(settings, separators=(",", ":"))] + filtered
        except (OSError, ValueError, IndexError, TypeError, AttributeError):
            invocation["phase"] = "ended"; write_json(STATE, invocation)
            os.execv(executable, [executable] + args)
    if kind == "codex" and "--no-daemon" not in args:
        try:
            if "--no-daemon" in subprocess.run([executable, "--help"], capture_output=True, text=True, timeout=2).stdout:
                child_args.insert(0, "--no-daemon")
        except (OSError, subprocess.TimeoutExpired):
            pass
    signal.signal(signal.SIGINT, lambda *_: None)
    signal.signal(signal.SIGQUIT, lambda *_: None)
    signal.signal(signal.SIGTERM, note_signal)
    signal.signal(signal.SIGHUP, note_signal)
    try:
        pid = os.posix_spawn(executable, [executable] + child_args, env, setsigdef=(signal.SIGINT, signal.SIGQUIT, signal.SIGTERM, signal.SIGHUP, signal.SIGPIPE), setsigmask=())
    except OSError:
        invocation["phase"] = "ended"; write_json(STATE, invocation)
        raise
    child_birth, stopping, stop_at, status = birth(pid), {}, None, 0
    while True:
        if not STOP and kind in ("grok", "codex"):
            found = discover(invocation, pid, env)
            if found:
                write_json(event_path(invocation), found)
            else:
                try: event_path(invocation).unlink()
                except FileNotFoundError: pass
            if invocation.get("conversation") != found:
                invocation["conversation"] = found; write_json(STATE, invocation)
        if STOP and stop_at is None:
            stop_at = time.monotonic(); stopping = descendants(pid)
            owned_signal(pid, child_birth, signal.SIGTERM)
        ended, status = os.waitpid(pid, os.WNOHANG)
        if ended:
            break
        if stop_at is not None and time.monotonic() - stop_at > 2.5:
            stopping.update(descendants(pid))
            for target, identity in stopping.items():
                owned_signal(target, identity, signal.SIGKILL)
            _, status = os.waitpid(pid, 0)
            break
        time.sleep(.15)
    invocation["conversation"] = current_conversation(invocation)
    if STOP:
        for target, identity in stopping.items():
            if target != pid:
                owned_signal(target, identity, signal.SIGTERM)
        invocation["phase"] = "suspended"
    else:
        invocation["phase"] = "ended"
    write_json(STATE, invocation)
    return os.waitstatus_to_exitcode(status)


def snapshot():
    invocation = read_json(STATE)
    if invocation:
        return {"invocationID": invocation["invocationID"], "phase": invocation.get("phase", "ended"), "conversation": current_conversation(invocation)}
    seed = read_json(ROOT / "resume.json")
    return {"phase": "suspended" if valid_conversation(seed) else "ended", "conversation": seed if valid_conversation(seed) else None}


def stop_owned(expected=None):
    invocation = read_json(STATE)
    if expected is not None and invocation and invocation.get("invocationID", "").lower() != expected.lower():
        return snapshot()
    if invocation and invocation.get("phase") == "active":
        pid, identity = invocation.get("ownerPID", 0), invocation.get("ownerStart")
        try:
            belongs = os.getsid(pid) == os.getsid(0)
        except ProcessLookupError:
            belongs = False
        if belongs and owned_signal(pid, identity, signal.SIGTERM):
            deadline = time.monotonic() + 3.2
            while time.monotonic() < deadline:
                current = read_json(STATE)
                if not current or current.get("invocationID") != invocation["invocationID"] or current.get("phase") != "active" or birth(pid) != identity:
                    break
                time.sleep(.03)
    return snapshot()


def serve():
    token = ENV["ONEAGENT_AGENT_TOKEN"]
    address = str(ROOT / "agent")
    parent, parent_birth = os.getppid(), birth(os.getppid())
    signal.signal(signal.SIGTERM, note_signal); signal.signal(signal.SIGHUP, note_signal)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(address); os.chmod(address, 0o600); listener.listen(4); listener.settimeout(.2)
    try:
        while not STOP and birth(parent) == parent_birth:
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            with connection:
                connection.settimeout(.5)
                try:
                    data = b""
                    while b"\n" not in data and len(data) <= 4096:
                        chunk = connection.recv(1024)
                        if not chunk: break
                        data += chunk
                    request = json.loads(data)
                    if request.get("token") != token or request.get("action") not in ("snapshot", "stop"):
                        continue
                    request_id = str(uuid.UUID(request["id"]))
                    value = stop_owned(request.get("invocationID")) if request["action"] == "stop" else snapshot()
                    value["id"] = request_id
                    connection.sendall(json.dumps(value, separators=(",", ":")).encode() + b"\n")
                except (OSError, ValueError, KeyError, TypeError):
                    continue
    finally:
        stop_owned(); listener.close()
        try: Path(address).unlink()
        except FileNotFoundError: pass


def main():
    if not valid_context():
        return 64
    args = sys.argv[1:]
    if args == ["serve"]:
        serve(); return 0
    if args == ["record"]:
        record(); return 0
    if args and args[0] == "resume" and len(args) == 2:
        value = read_json(args[1])
        valid = valid_conversation(value) and os.access(value["executable"], os.X_OK) and os.path.isdir(value["directory"])
        if valid and value["kind"] in ("pi", "omp"):
            info = header(value["sessionFile"])
            valid = info is not None and info[0].lower() == value["sessionID"].lower()
        if not valid:
            sys.stderr.write(ENV.get("ONEAGENT_AGENT_RESTORE_ERROR", "无法恢复 Agent 对话，请检查工具、会话文件和工作目录。\n"))
            return 1
        os.chdir(value["directory"])
        key = "--session" if value["kind"] == "pi" else "resume" if value["kind"] == "codex" else "--resume"
        target = value["sessionFile"] if value["kind"] in ("pi", "omp") else value["sessionID"]
        return run(value["kind"], value["executable"], [key, target], resumed=value)
    if len(args) >= 3 and args[0] == "run" and args[1] in KINDS:
        return run(args[1], args[2], args[3:])
    return 64


if __name__ == "__main__":
    sys.exit(main())
