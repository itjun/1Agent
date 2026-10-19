#!/usr/bin/env python3
"""Real supervisor/process/signal tests. Fixtures never connect to an AI provider."""
import datetime
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
HELPER = Path(sys.argv[1]).resolve()
FAKE = r'''#!PYTHON
import datetime,json,os,signal,sqlite3,subprocess,sys,time
from pathlib import Path
e=os.environ; args=sys.argv[1:]
if args==['--help']:
 print('--no-daemon');sys.exit()
p=Path(e['ONEAGENT_AGENT_STATE']);inv=json.loads(p.read_text());kind=inv['kind']
sid=e['TEST_SESSION_ID'];cwd=os.getcwd()
with open(e['TEST_ARGV'],'w') as f:json.dump(args,f)
if kind=='codex':
 d=p.parent/'thread-writer-locks';d.mkdir(exist_ok=True);lock=open(d/(sid+'.lock'),'w')
 db=sqlite3.connect(p.parent/'state_5.sqlite');db.execute('CREATE TABLE IF NOT EXISTS threads(id TEXT,cwd TEXT,has_user_event INTEGER)');db.execute('DELETE FROM threads');db.execute('INSERT INTO threads VALUES(?,?,1)',(sid,cwd));db.commit()
elif kind=='grok':
 d=Path(e['GROK_HOME']);d.mkdir(exist_ok=True)
 (d/'active_sessions.json').write_text(json.dumps([{'session_id':sid,'pid':os.getpid(),'cwd':cwd,'opened_at':datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z')}]))
elif kind=='claude':
 settings=json.loads(args[args.index('--settings')+1]);assert settings.get('model')=='keep-model'
 hook=settings['hooks']['SessionStart'][-1]['hooks'][0]['command']
 subprocess.run(hook,shell=True,input=json.dumps({'hook_event_name':'SessionStart','session_id':sid,'cwd':cwd}),text=True,check=True)
else:
 file=p.parent/(sid+'.jsonl');file.write_text(json.dumps({'type':'session','id':sid,'cwd':cwd})+'\n')
 value={'kind':kind,'sessionID':sid,'sessionFile':str(file),'directory':cwd,'executable':sys.argv[0],'storageEnvironment':{}}
 (p.parent/(inv['invocationID']+'.json')).write_text(json.dumps(value))
Path(e['TEST_READY']).write_text(str(os.getpid()))
while not Path(e['TEST_FINISH']).exists():time.sleep(.05)
'''


def wait_for(check, message):
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.05)
    raise AssertionError(message)


folders = []
processes = []
try:
    for kind in ('pi', 'omp', 'claude', 'codex', 'grok'):
        folder = Path(tempfile.mkdtemp(prefix=f'1a-agent-{os.getuid()}-', dir='/tmp'))
        folders.append(folder)
        fake = folder/'fake-agent'
        fake.write_text(FAKE.replace('PYTHON', sys.executable, 1)); fake.chmod(0o700)
        state = folder/'invocation.json'
        env = dict(os.environ, ONEAGENT_AGENT_STATE=str(state), ONEAGENT_AGENT_RESOURCES=str(ROOT/'Resources/agent-sessions'),
                   TEST_SESSION_ID=str(uuid.uuid4()), TEST_ARGV=str(folder/'argv.json'), TEST_READY=str(folder/'ready'),
                   TEST_FINISH=str(folder/'finish'), GROK_HOME=str(folder/'grok'))
        extra = ['--settings', '{"model":"keep-model","hooks":{"SessionStart":[]}}'] if kind == 'claude' else []
        process = subprocess.Popen([str(HELPER), 'run', kind, str(fake), *extra], env=env, cwd='/tmp')
        processes.append(process)
        child = int(wait_for(lambda: (folder/'ready').read_text(), 'child did not start'))
        invocation = json.loads(state.read_text())
        event = folder/(invocation['invocationID']+'.json')
        saved = wait_for(lambda: json.loads(event.read_text()), 'session was not captured')
        assert saved['sessionID'] == env['TEST_SESSION_ID']
        process.send_signal(signal.SIGTERM); process.wait(timeout=5)
        suspended = json.loads(state.read_text())
        assert suspended['phase'] == 'suspended' and suspended['conversation']['sessionID'] == saved['sessionID']
        try:
            os.kill(child, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError('Agent remained alive after app exit')
        resume = folder/'resume.json'; resume.write_text(json.dumps(saved))
        (folder/'ready').unlink()
        # Claude fixture checks an existing settings object on initial launch only.
        if kind == 'claude':
            fake.write_text(fake.read_text().replace("assert settings.get('model')=='keep-model'", "assert isinstance(settings,dict)"));fake.chmod(0o700)
        process = subprocess.Popen([str(HELPER), 'resume', str(resume)], env=env, cwd='/tmp')
        processes.append(process)
        wait_for(lambda: (folder/'ready').exists(), 'resume did not start')
        argv = json.loads((folder/'argv.json').read_text())
        assert ('--session' if kind == 'pi' else 'resume' if kind == 'codex' else '--resume') in argv
        assert (saved.get('sessionFile') if kind in ('pi', 'omp') else saved['sessionID']) in argv
        assert '--last' not in argv and '--continue' not in argv and '--restore' not in argv
        (folder/'finish').touch(); process.wait(timeout=5)
        assert json.loads(state.read_text())['phase'] == 'ended', 'manual exit must not resurrect the Agent'
        if kind == 'pi':
            Path(saved['sessionFile']).unlink()
            modified = (folder/'argv.json').stat().st_mtime_ns
            failed = subprocess.run([str(HELPER), 'resume', str(resume)], env=env, capture_output=True, timeout=5)
            assert failed.returncode != 0 and failed.stderr, 'missing session needs an explicit failure'
            assert (folder/'argv.json').stat().st_mtime_ns == modified, 'missing session must not start a fresh Agent'
    # Two simultaneous terminals in exactly the same cwd must retain distinct identities.
    pair = []
    for _ in range(2):
        folder = Path(tempfile.mkdtemp(prefix=f'1a-agent-{os.getuid()}-', dir='/tmp')); folders.append(folder)
        fake = folder/'fake-agent'; fake.write_text(FAKE.replace('PYTHON', sys.executable, 1)); fake.chmod(0o700)
        state = folder/'invocation.json'
        env = dict(os.environ, ONEAGENT_AGENT_STATE=str(state), ONEAGENT_AGENT_RESOURCES=str(ROOT/'Resources/agent-sessions'),
                   TEST_SESSION_ID=str(uuid.uuid4()), TEST_ARGV=str(folder/'argv.json'), TEST_READY=str(folder/'ready'), TEST_FINISH=str(folder/'finish'))
        process = subprocess.Popen([str(HELPER), 'run', 'pi', str(fake)], env=env, cwd='/tmp'); processes.append(process)
        wait_for(lambda: (folder/'ready').exists(), 'concurrent terminal did not start')
        invocation = json.loads(state.read_text())
        event = json.loads((folder/(invocation['invocationID']+'.json')).read_text())
        pair.append((folder, process, event))
    assert pair[0][2]['directory'] == pair[1][2]['directory'] and pair[0][2]['sessionID'] != pair[1][2]['sessionID']
    pair[0][1].terminate(); pair[0][1].wait(timeout=5)
    assert pair[1][1].poll() is None, 'stopping one terminal must not stop its sibling'
    (pair[1][0]/'finish').touch(); pair[1][1].wait(timeout=5)
    print('Agent session integration passed: all 5 adapters, precise resume, settings merge, graceful stop and manual exit')
finally:
    for process in processes:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
    for folder in folders:
        shutil.rmtree(folder)
