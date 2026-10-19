#!/usr/bin/env python3
"""Exercises the installed app's scripting API using only newly owned terminals.
Run after make build. Never quits the app or sends input to a pre-existing terminal.
"""
import json
import pathlib
import re
import subprocess
import tempfile
import time

APP = 'com.itjun.1agent'

def apple(body):
    source = f'tell application id "{APP}"\n{body}\nend tell'
    result = subprocess.run(['osascript', '-e', source], text=True, capture_output=True, timeout=30)
    if result.returncode:
        location = re.search(r'(\d+):(\d+): execution error:', result.stderr)
        context = source[int(location[1]):int(location[2])] if location else ''
        raise RuntimeError(result.stderr.strip() + '\nOperation: ' + context)
    return result.stdout.strip()

def ids(kind):
    return {x.strip() for x in apple(f'get id of every {kind}').split(',') if x.strip()}

def quoted(text):
    return json.dumps(str(text), ensure_ascii=False)

before_windows, before_terminals = ids('window'), ids('terminal')
with tempfile.TemporaryDirectory(prefix='oneagent-automation-验收 空格-', dir='/private/tmp') as folder:
    root = pathlib.Path(folder)
    window_id = None
    try:
        command = 'printf "%s" "$ONEAGENT_AUTOMATION_TEST" > env-marker; read -r value; printf "%s" "$value" > key-marker; exec /bin/cat'
        window_id = apple(f'''set cfg to new surface configuration
set initial working directory of cfg to {quoted(folder)}
set command of cfg to {quoted(command)}
set environment variables of cfg to {{"ONEAGENT_AUTOMATION_TEST=verified"}}
set win to new window with configuration cfg
return id of win''')
        assert window_id and window_id not in before_windows
        result = apple(f'''set win to window id {quoted(window_id)}
set firstTerm to focused terminal of selected tab of win
send key "A" to firstTerm
send key "enter" to firstTerm
set cfg to new surface configuration
set initial working directory of cfg to {quoted(folder)}
set command of cfg to "exec /bin/cat"
set nextTab to new tab in win with configuration cfg
set secondTerm to focused terminal of nextTab
set splitTerm to split secondTerm direction down with configuration cfg
if (count of terminals of nextTab) is not 2 then error "Split must contain two terminals"
focus firstTerm
perform action "set_tab_title:1Agent 自动化验收" on firstTerm
select tab nextTab
activate window win
send key "f5" to splitTerm
send key "f5" to splitTerm action release
input text "AUTOMATION_INPUT" to splitTerm
send mouse position to splitTerm x 10 y 10
send mouse button left button to splitTerm
send mouse button left button to splitTerm action release
send mouse scroll to splitTerm x 0 y 1
close splitTerm
if (count of terminals of nextTab) is not 1 then error "Closing a pane must preserve its sibling"
close tab nextTab
if (count of tabs of win) is not 1 then error "Closing a tab must preserve the other tab"
return id of firstTerm''')
        assert result
        for _ in range(100):
            if (root / 'key-marker').exists():
                break
            time.sleep(.05)
        assert (root / 'env-marker').read_text() == 'verified'
        assert (root / 'key-marker').read_text() == 'A', 'Physical key input must preserve uppercase'
        apple(f'close window (window id {quoted(window_id)})')
        assert window_id not in ids('window')
        window_id = None
        for body in [f'''set cfg to new surface configuration
set initial working directory of cfg to {quoted(folder + '/missing')}
new window with configuration cfg''', 'focus (terminal id "00000000-0000-0000-0000-000000000001")']:
            try:
                apple(body)
            except RuntimeError:
                pass
            else:
                raise AssertionError('Invalid object/directory must return an ordinary script error')
        assert before_windows <= ids('window')
        assert before_terminals <= ids('terminal')
        print('TerminalAutomation passed: stable object replies, windows/tabs/splits, explicit text/key/mouse targets, uppercase, command pipeline, environment, invalid references and original-session preservation')
    finally:
        if window_id and window_id in ids('window'):
            apple(f'close window (window id {quoted(window_id)})')
