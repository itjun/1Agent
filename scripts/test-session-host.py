#!/usr/bin/env python3
"""真实 PTY + 独立窗口客户端的协议测试，只使用随机隔离目录。"""
import os
import pathlib
import select
import shlex
import socket
import struct
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
HOST = ROOT / 'build/1AgentSessionHost'
FIXTURE = ROOT / 'Tests/session-host-fixture.py'

def frame(kind, data=b''):
    return kind + struct.pack('!I', len(data)) + data

class Client:
    def __init__(self, path, size=(24, 80)):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(4)
        self.sock.connect(str(path / 's'))
        self.sock.sendall(frame(b'A', struct.pack('!4H', *size, 0, 0)))
        self.messages = self.until(b'H')
        self.pid = struct.unpack('!3I', next(v for k,v in self.messages if k == b'S'))[0]
        self.snapshot = next(v for k,v in self.messages if k == b'R')
    def read(self, n):
        data=b''
        while len(data)<n:
            chunk=self.sock.recv(n-len(data))
            if not chunk: raise EOFError()
            data+=chunk
        return data
    def until(self, target, text=None):
        result=[]; total=b''; deadline=time.monotonic()+6
        while time.monotonic()<deadline:
            k=self.read(1); n=struct.unpack('!I',self.read(4))[0]; value=self.read(n)
            result.append((k,value))
            if k==target:
                total+=value
                if text is None or text in total: return result
        raise AssertionError((target,text,result[-3:]))
    def send(self, value): self.sock.sendall(frame(b'I',value))
    def close(self): self.sock.close()

def wait_path(path, exists=True):
    deadline=time.monotonic()+4
    while path.exists()!=exists and time.monotonic()<deadline: time.sleep(.02)
    assert path.exists()==exists,path

def run():
    with tempfile.TemporaryDirectory(prefix='1a-host-test-',dir='/tmp') as folder:
        base=pathlib.Path(folder); sessions=[]
        try:
            for i in range(2):
                path=base/str(i);path.mkdir(mode=0o700);sessions.append(path)
                subprocess.run([str(HOST),str(path),'80','24','128000000',sys.executable,str(FIXTURE),str(base/f'launch{i}')],check=True)
                wait_path(path/'s')
            a=Client(sessions[0]); b=Client(sessions[1]); pid=a.pid
            if b'TUI_READY' not in a.snapshot: a.until(b'O',b'TUI_READY')
            # 只读状态请求不抢占已经连接的终端。
            for _ in range(10):
                probe=socket.socket(socket.AF_UNIX);probe.settimeout(2);probe.connect(str(sessions[0]/'p'))
                data=b''
                while True:
                    chunk=probe.recv(4096)
                    if not chunk: break
                    data+=chunk
                probe.close();assert b'pi --session test' in data
            a.send(b'd');a.close();time.sleep(.5)
            a=Client(sessions[0]);assert a.pid==pid and b'DETACHED_OUTPUT' in a.snapshot
            assert b'\x1b]7;file://fixture/tmp/a%20b\x1b\\' in a.snapshot and b'\0' not in a.snapshot,'restored directory has NUL suffix'
            assert b'TUI_READY' in a.snapshot and b'PRIMARY_HISTORY' in a.snapshot
            assert b'\x1b[?2004h' in a.snapshot and b'\x1b[?1006h' in a.snapshot
            assert any(k==b'M' and v==b'\1pi --session test' for k,v in a.messages)
            assert len((base/'launch0').read_text().splitlines())==1,'command was rerun'
            a.send(b'q');a.close();time.sleep(.4)
            a=Client(sessions[0]);assert b'QUERY_REPLY:' in a.snapshot,'detached query was not answered'
            for key,marker in [(b'f',b'UTF8_COMPLETE'),(b'e',b'ESCAPE_COMPLETE')]:
                a.send(key);time.sleep(.15);a.close();a=Client(sessions[0])
                # Parser continuation is replayed before remaining live output.
                assert a.snapshot.endswith(b'\xe4\xb8' if key==b'f' else b'\x1b[9;')
                a.until(b'O',marker)
            a.sock.sendall(frame(b'W',struct.pack('!4H',33,100,0,0)))
            a.send(b'w');a.until(b'O',b'SIZE:100x33')
            a.send(b'p');a.until(b'O',b'PRIMARY_RETURN');a.close()
            a=Client(sessions[0],(33,100));assert b'PRIMARY_HISTORY' in a.snapshot and b'PRIMARY_RETURN' in a.snapshot
            a.send(b's');a.until(b'M',b'\0')
            a.sock.sendall(frame(b'K'));a.close();wait_path(sessions[0]/'s',False)
            try: os.kill(pid,0);raise AssertionError('closed child still alive')
            except ProcessLookupError: pass
            b.send(b'w');b.until(b'O',b'SIZE:80x24')
            b.send(b'x');b.close();time.sleep(.3)
            b=Client(sessions[1]);exit_frames=b.until(b'X');assert exit_frames[-1][1]==struct.pack('!I',7)
            b.close();wait_path(sessions[1]/'s',False)
            # 在交互式 shell 中关闭前台 TUI，shell 与 helper 都必须退出。
            # macOS 需要先释放 PTY master；先 waitpid 会把收尾永久卡住。
            path=base/'shell';path.mkdir(mode=0o700);sessions.append(path)
            subprocess.run([str(HOST),str(path),'80','24','128000000','/bin/zsh','-f','-i'],
                           env={'PATH':'/usr/bin:/bin','HOME':str(base),'ZDOTDIR':str(base),'TERM':'xterm-256color'},check=True)
            wait_path(path/'s');shell=Client(path)
            helper=struct.unpack('i',shell.sock.getsockopt(0,2,4))[0] # LOCAL_PEERPID
            command=shlex.join([sys.executable,str(FIXTURE),str(base/'shell-launch')])
            shell.send(command.encode()+b'\r');shell.until(b'O',b'TUI_READY')
            shell.sock.sendall(frame(b'K'))
            try:
                wait_path(path,False)
                for pid in [shell.pid,helper]:
                    try: os.kill(pid,0);raise AssertionError('shell/TUI helper still alive')
                    except ProcessLookupError: pass
            finally:
                shell.close()
                if path.exists():
                    try: os.kill(helper,15)
                    except ProcessLookupError: pass
            print('SessionHost passed: same PID/one launch, background output/query, both screens, modes, partial UTF-8/VT, resize, isolation, explicit shell/TUI close, detached exit')
        finally:
            for path in sessions:
                try:
                    s=socket.socket(socket.AF_UNIX);s.connect(str(path/'s'));s.sendall(frame(b'K'));s.close()
                except OSError: pass

if __name__=='__main__': run()
