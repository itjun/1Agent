#!/usr/bin/env python3
"""Exercise the portable SSH adapter and its control protocol without model requests."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "Resources/agent-sessions/remote-agent-session.py"
FAKE = r'''#!PYTHON
import datetime,json,os,sqlite3,subprocess,sys,time
from pathlib import Path
args=sys.argv[1:];e=os.environ
if args==['--help']:print('--no-daemon');sys.exit()
p=Path(e['ONEAGENT_AGENT_STATE']);inv=json.loads(p.read_text());sid=e['TEST_SESSION_ID'];kind=inv['kind'];cwd=os.getcwd()
Path(e['TEST_ARGV']).write_text(json.dumps(args))
if kind=='codex':
 d=p.parent/'thread-writer-locks';d.mkdir(exist_ok=True);lock=open(d/(sid+'.lock'),'w')
 db=sqlite3.connect(p.parent/'state_5 ? # %.sqlite');db.execute('CREATE TABLE IF NOT EXISTS threads(id TEXT,cwd TEXT,has_user_event INTEGER)');db.execute('DELETE FROM threads');db.execute('INSERT INTO threads VALUES(?,?,1)',(sid,cwd));db.commit()
elif kind=='grok':
 d=Path(e['GROK_HOME']);d.mkdir(exist_ok=True)
 (d/'active_sessions.json').write_text(json.dumps([{'session_id':sid,'pid':os.getpid(),'cwd':cwd,'opened_at':datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z')}]))
elif kind=='claude':
 settings=json.loads(args[args.index('--settings')+1]);assert settings.get('model')=='keep-model' or '--resume' in args
 command=settings['hooks']['SessionStart'][-1]['hooks'][0]['command']
 subprocess.run(command,shell=True,input=json.dumps({'hook_event_name':'SessionStart','session_id':sid,'cwd':cwd}),text=True,check=True)
else:
 file=p.parent/(sid+'.jsonl');file.write_text(json.dumps({'type':'title','title':'OMP'})+'\n'+json.dumps({'type':'session','id':sid,'cwd':cwd})+'\n')
 event={'kind':kind,'sessionID':sid,'sessionFile':str(file),'directory':cwd,'executable':sys.argv[0],'storageEnvironment':{}}
 (p.parent/(inv['invocationID']+'.json')).write_text(json.dumps(event))
Path(e['TEST_READY']).write_text(str(os.getpid()))
while not Path(e['TEST_FINISH']).exists():time.sleep(.03)
'''


def wait(check, message):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(.04)
    raise AssertionError(message)


class Terminal:
    def __init__(self):
        self.folder = Path(tempfile.mkdtemp(prefix='1a-remote-', dir='/tmp'))
        # The transport directory's name is a UUID, as in the SSH bootstrap.
        target = self.folder.with_name('1a-remote-' + str(uuid.uuid4()).upper())
        self.folder.rename(target); self.folder = target
        self.token = str(uuid.uuid4())
        self.helper = self.folder/'agent-helper'
        self.helper.write_text('#!/bin/sh\nexec ' + shutil.which('python3') + ' ' + str(ADAPTER) + ' "$@"\n'); self.helper.chmod(0o700)
        fake = self.folder/'fake-agent'; fake.write_text(FAKE.replace('PYTHON', sys.executable, 1)); fake.chmod(0o700)
        (self.folder/'agent-sessions').mkdir()
        shutil.copy(ROOT/'Resources/agent-sessions/session-extension.mjs', self.folder/'agent-sessions/session-extension.mjs')
        self.env = dict(os.environ, ONEAGENT_AGENT_STATE=str(self.folder/'invocation.json'), ONEAGENT_AGENT_HELPER=str(self.helper),
                        ONEAGENT_AGENT_TOKEN=self.token, TEST_SESSION_ID=str(uuid.uuid4()), TEST_ARGV=str(self.folder/'argv.json'),
                        TEST_READY=str(self.folder/'ready'), TEST_FINISH=str(self.folder/'finish'), GROK_HOME=str(self.folder/'grok'))
        self.server = subprocess.Popen([sys.executable, str(ADAPTER), 'serve'], env=self.env)
        self.agent = None
        wait(lambda: (self.folder/'agent').exists(), 'control socket did not start')

    def exchange(self, action='snapshot', token=None, invocation=None):
        request = {'id': str(uuid.uuid4()), 'token': token or self.token, 'action': action}
        if invocation: request['invocationID'] = invocation
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(6); connection.connect(str(self.folder/'agent')); connection.sendall(json.dumps(request).encode()+b'\n')
            result = b''
            while b'\n' not in result:
                chunk = connection.recv(4096)
                if not chunk: return None
                result += chunk
        value = json.loads(result); assert uuid.UUID(value['id']) == uuid.UUID(request['id'])
        return value

    def launch(self, kind, resume=None):
        (self.folder/'ready').unlink(missing_ok=True); (self.folder/'finish').unlink(missing_ok=True)
        args = ['resume', str(resume)] if resume else ['run', kind, str(self.folder/'fake-agent')]
        if not resume and kind == 'claude': args += ['--settings', '{"model":"keep-model"}']
        self.agent = subprocess.Popen([sys.executable, str(ADAPTER), *args], env=self.env, cwd='/tmp')
        wait(lambda: (self.folder/'ready').exists(), 'Agent did not start')
        return wait(lambda: (value if (value := self.exchange()).get('conversation') else None), 'exact conversation not reported')

    def close(self):
        if self.agent and self.agent.poll() is None:
            self.agent.terminate()
            try: self.agent.wait(timeout=5)
            except subprocess.TimeoutExpired: self.agent.kill(); self.agent.wait()
        self.server.terminate()
        try: self.server.wait(timeout=5)
        except subprocess.TimeoutExpired: self.server.kill(); self.server.wait()
        shutil.rmtree(self.folder)


terminals = []
try:
    for kind in ('pi', 'omp', 'claude', 'codex', 'grok'):
        terminal = Terminal(); terminals.append(terminal)
        state = terminal.launch(kind)
        assert state['conversation']['sessionID'] == terminal.env['TEST_SESSION_ID']
        assert terminal.exchange('stop', token='wrong') is None
        assert terminal.agent.poll() is None, 'unauthenticated stop must not reach the Agent'
        assert terminal.exchange('run') is None, 'control endpoint must not accept commands'
        unchanged = terminal.exchange('stop', invocation=str(uuid.uuid4()))
        assert unchanged['phase'] == 'active' and terminal.agent.poll() is None, 'stale invocation cannot stop another run'
        stopped = terminal.exchange('stop', invocation=state['invocationID'])
        terminal.agent.wait(timeout=5)
        assert stopped['phase'] == 'suspended' and stopped['conversation']['sessionID'] == state['conversation']['sessionID']
        seed = terminal.folder/'resume.json'; seed.write_text(json.dumps(stopped['conversation']))
        resumed = terminal.launch(kind, seed)
        argv = json.loads((terminal.folder/'argv.json').read_text())
        target = state['conversation'].get('sessionFile') if kind in ('pi', 'omp') else state['conversation']['sessionID']
        assert target in argv and '--last' not in argv and '--continue' not in argv and '--restore' not in argv
        (terminal.folder/'finish').touch(); terminal.agent.wait(timeout=5)
        assert terminal.exchange()['conversation'] is None, 'manual exit must clear restoration'
        terminal.close(); terminals.remove(terminal)
    pair = [Terminal(), Terminal()]; terminals.extend(pair)
    states = [terminal.launch('pi') for terminal in pair]
    assert states[0]['conversation']['directory'] == states[1]['conversation']['directory']
    assert states[0]['conversation']['sessionID'] != states[1]['conversation']['sessionID']
    pair[0].exchange('stop', invocation=states[0]['invocationID']); pair[0].agent.wait(timeout=5)
    assert pair[1].agent.poll() is None, 'sibling terminal was stopped'
    print('Remote Agent protocol passed: five adapters, authenticated snapshot/stop, stale-run rejection, exact resume and terminal isolation')
finally:
    for terminal in terminals:
        terminal.close()
