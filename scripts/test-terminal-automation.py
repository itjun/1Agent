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
    tab_ids = []
    try:
        assert len(before_windows) == 1, '1Agent has exactly one window'
        window_id = next(iter(before_windows))
        command = 'printf "%s" "$ONEAGENT_AUTOMATION_TEST" > env-marker; read -r value; printf "%s" "$value" > key-marker; exec /bin/cat'
        first_tab = apple(f'''set cfg to new surface configuration
set initial working directory of cfg to {quoted(folder)}
set command of cfg to {quoted(command)}
set environment variables of cfg to {{"ONEAGENT_AUTOMATION_TEST=verified"}}
set firstTab to new tab with configuration cfg
return id of firstTab''')
        assert first_tab
        tab_ids.append(first_tab)
        second_tab = apple(f'''set win to window id {quoted(window_id)}
set firstTerm to focused terminal of tab id {quoted(first_tab)}
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
return id of nextTab''')
        assert second_tab
        tab_ids.append(second_tab)
        for _ in range(100):
            if (root / 'key-marker').exists():
                break
            time.sleep(.05)
        assert (root / 'env-marker').read_text() == 'verified'
        assert (root / 'key-marker').read_text() == 'A', 'Physical key input must preserve uppercase'
        assert ids('window') == before_windows, 'Automation must never open another window'
        for body in [f'''set cfg to new surface configuration
set initial working directory of cfg to {quoted(folder + '/missing')}
new tab with configuration cfg''', 'focus (terminal id "00000000-0000-0000-0000-000000000001")',
                f'perform action "new_window" on (focused terminal of tab id {quoted(first_tab)})']:
            try:
                apple(body)
            except RuntimeError:
                pass
            else:
                raise AssertionError('Invalid object/directory/new window must return an ordinary script error')
        assert ids('window') == before_windows, 'Rejected requests must not open another window'
        assert before_terminals <= ids('terminal')
        print('TerminalAutomation passed: stable object replies, one window, tabs/splits, explicit text/key/mouse targets, uppercase, command pipeline, environment, invalid references, new_window rejection and original-session preservation')
    finally:
        for tab_id in tab_ids:
            try:
                apple(f'close tab (tab id {quoted(tab_id)})')
            except RuntimeError:
                pass
