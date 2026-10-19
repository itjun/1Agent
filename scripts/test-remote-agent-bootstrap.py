#!/usr/bin/env python3
"""Real PTY bootstrap/stop/reconnect tests; optional --ssh ALIAS uses existing SSH auth."""
import base64
import errno
import json
import os
from pathlib import Path
import pty
import select
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
HARNESS = '/tmp/oneagent-remote-shell-tests'
FAKE = '''#!/usr/bin/env python3
import json,os,signal,sys,time,uuid
from pathlib import Path
cwd=Path.cwd();state=Path(os.environ['ONEAGENT_AGENT_STATE']);inv=json.loads(state.read_text())
args=sys.argv[1:]
if '--session' in args:
 file=Path(args[args.index('--session')+1]);sid=json.loads(file.read_text().splitlines()[0])['id']
else:
 sid=str(uuid.uuid4());file=cwd/(sid+'.jsonl');file.write_text(json.dumps({'type':'session','id':sid,'cwd':str(cwd)})+'\\n')
event={'kind':'pi','sessionID':sid,'sessionFile':str(file),'directory':str(cwd),'executable':sys.argv[0],'storageEnvironment':{}}
(state.parent/(inv['invocationID']+'.json')).write_text(json.dumps(event))
with (cwd/'launches.jsonl').open('a') as log:log.write(json.dumps({'id':sid,'pid':os.getpid(),'args':args})+'\\n')
print('AGENT_IDLE_'+sid,flush=True)
while True:time.sleep(.05)
'''


class Terminal:
    def __init__(self, workspace, shell, home, alias=None, seed=None):
        self.token = str(uuid.uuid4()).upper()
        self.remote_root = '/tmp/1a-remote-' + self.token
        self.local = tempfile.mkdtemp(prefix='1a-pty-', dir='/tmp')
        self.endpoint = self.local + '/a' if alias else self.remote_root + '/agent'
        seed_path = Path(self.local)/'seed.json'
        if seed:
            seed_path.write_text(json.dumps(seed))
        command = subprocess.check_output([HARNESS, '--agent-bootstrap', str(ROOT/'Resources'), self.token,
                                           str(seed_path) if seed else '-', workspace], text=True).strip()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            if alias:
                os.execv('/usr/bin/ssh', ['ssh', '-tt', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
                                        '-o', 'ControlPath=' + str(Path.home()/'.ssh/ghostty-%C'),
                                        '-L', self.endpoint + ':' + self.remote_root + '/agent', '--', alias, command])
            env = dict(os.environ, HOME=home, ZDOTDIR=home, SHELL=shell, TERM='xterm-256color')
            os.execve('/bin/sh', ['sh', '-c', command], env)
        self.output = bytearray()

    def drain(self):
        if select.select([self.fd], [], [], .03)[0]:
            try:
                self.output.extend(os.read(self.fd, 65536))
            except OSError as error:
                if error.errno != errno.EIO: raise

    def wait(self, predicate, label):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            self.drain()
            try:
                value = predicate()
                if value: return value
            except (OSError, ValueError):
                pass
        raise AssertionError(label + ': ' + repr(bytes(self.output[-2000:])))

    def exchange(self, action='snapshot', invocation=None):
        request = {'id': str(uuid.uuid4()), 'token': self.token, 'action': action}
        if invocation: request['invocationID'] = invocation
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(6); connection.connect(self.endpoint)
            connection.sendall(json.dumps(request).encode()+b'\n'); data = b''
            while b'\n' not in data:
                chunk = connection.recv(4096)
                if not chunk: return None
                data += chunk
        response = json.loads(data)
        assert uuid.UUID(response['id']) == uuid.UUID(request['id'])
        return response

    def send(self, command):
        os.write(self.fd, command.encode()+b'\n')

    def conversation(self):
        value = self.exchange()
        return value if value and value.get('invocationID') and value.get('phase') == 'active' and value.get('conversation') else None

    def stop(self, state):
        response = self.exchange('stop', state['invocationID'])
        assert response['phase'] == 'suspended' and response['conversation'] == state['conversation']
        return response['conversation']

    def close(self):
        try: self.exchange('stop')
        except OSError: pass
        self.send('exit')
        deadline = time.monotonic()+5
        while time.monotonic() < deadline:
            self.drain()
            ended, _ = os.waitpid(self.pid, os.WNOHANG)
            if ended: break
        else:
            os.kill(self.pid, signal.SIGKILL); os.waitpid(self.pid, 0)
        os.close(self.fd); shutil.rmtree(self.local)


def exercise(workspace, shell, home, alias=None):
    first = Terminal(workspace, shell, home, alias)
    try:
        first.wait(lambda: first.exchange() is not None, 'private control endpoint never became ready')
        first.send('export PATH=' + shlex.quote(workspace+'/bin') + ':$PATH; pi')
        state = first.wait(first.conversation, 'shell wrapper did not record exact conversation')
        first.wait(lambda: ('AGENT_IDLE_'+state['conversation']['sessionID']).encode() in first.output, 'Agent did not reach idle')
        seed = first.stop(state)
    finally:
        first.close()
    resumed = Terminal(workspace, shell, home, alias, seed)
    try:
        state = resumed.wait(resumed.conversation, 'reconnected shell did not resume')
        assert state['conversation'] == seed
        resumed.wait(lambda: ('AGENT_IDLE_'+seed['sessionID']).encode() in resumed.output, 'resumed Agent not idle')
        resumed.stop(state)
        if not alias:
            profiles = list(Path(home).glob('profile-*'))
            resumed.wait(lambda: profiles and all(path.read_text().splitlines() == ['loaded']*3 for path in profiles), 'login profile must load once for each login shell')
        resumed.send("typeset -f pi; printf 'SHELL_READY\\n'")
        resumed.wait(lambda: b'SHELL_READY\r\n' in resumed.output and b'_oneagent_agent_run' in resumed.output, 'Agent exit must return to an integrated shell')
    finally:
        resumed.close()


if len(sys.argv) == 3 and sys.argv[1] == '--ssh':
    alias = sys.argv[2]
    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-o', 'ControlPath='+str(Path.home()/'.ssh/ghostty-%C'), alias]
    workspace = subprocess.check_output(ssh+['mktemp -d /tmp/oneagent-ssh-test.XXXXXX'], text=True).strip()
    assert workspace.startswith('/tmp/oneagent-ssh-test.')
    setup = 'mkdir -p '+shlex.quote(workspace+'/bin')+'; printf %s '+shlex.quote(base64.b64encode(FAKE.encode()).decode())+' | base64 -d > '+shlex.quote(workspace+'/bin/pi')+'; chmod 700 '+shlex.quote(workspace+'/bin/pi')
    try:
        subprocess.run(ssh+[setup], check=True)
        exercise(workspace, None, None, alias)
        rows = subprocess.check_output(ssh+['cat '+shlex.quote(workspace+'/launches.jsonl')], text=True).splitlines()
        launches = [json.loads(row) for row in rows]
        assert len(launches) == 2 and launches[0]['id'] == launches[1]['id']
        assert launches[1]['args'][-2:] == ['--session', workspace+'/'+launches[0]['id']+'.jsonl']
        print('Real SSH PTY passed: managed cwd, private forwarding, owned Agent stop, exact reconnect and idle input')
    finally:
        subprocess.run(ssh+['rm -rf -- '+shlex.quote(workspace)], check=True)
else:
    for shell in ('/bin/zsh', '/bin/bash'):
        with tempfile.TemporaryDirectory(prefix='1a-bootstrap-', dir='/tmp') as folder:
            home = Path(folder)/'home'; home.mkdir()
            workspace = Path(folder)/'目录 ? # %'; workspace.mkdir()
            binary = workspace/'bin'; binary.mkdir(); (binary/'pi').write_text(FAKE); (binary/'pi').chmod(0o700)
            rc = '.zprofile' if shell.endswith('zsh') else '.bash_profile'
            (home/rc).write_text('printf "loaded\\n" >> "$HOME/profile-login"\n')
            exercise(str(workspace), shell, str(home))
            rows = [json.loads(row) for row in (workspace/'launches.jsonl').read_text().splitlines()]
            assert len(rows) == 2 and rows[0]['id'] == rows[1]['id']
    print('Bash/Zsh PTY bootstraps passed: login profiles, special-character cwd, stop and precise resume without prompts')
