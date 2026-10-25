#!/usr/bin/env python3
"""Probe real shell startup and optional installed PTYs without running any AI CLI."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
KINDS = ('pi', 'omp', 'grok', 'codex', 'claude')
EXPECTED = ['update', 'two words', '', '中文', '--flag=value']


def apple(body):
    result = subprocess.run(['osascript', '-e', 'tell application id "com.itjun.1agent"\n' + body + '\nend tell'],
                            text=True, capture_output=True, timeout=20)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def command(folder):
    lines = ['export PATH=' + shlex.quote(str(folder / 'bin')) + ':$PATH']
    for kind in KINDS:
        lines.append(kind + ' ' + shlex.join(EXPECTED))
        lines.append('printf "%s" "$?" > ' + shlex.quote(str(folder / (kind + '.status'))))
    lines.append('printf done > ' + shlex.quote(str(folder / 'done')))
    return '; '.join(lines)


def verify(folder):
    for kind in KINDS:
        value = json.loads((folder / (kind + '.json')).read_text())
        assert value['args'] == EXPECTED, (kind, value)
        assert not value['injectedEnvironment'], (kind, value)
        assert (folder / (kind + '.status')).read_text() == '23', kind
    assert not (folder / 'helper-called').exists(), 'Terminal called an Agent supervisor'


def fixture(folder):
    binary = folder / 'bin'
    binary.mkdir()
    # Existing adapter environment must not enable interception, even in a nested shell.
    helper = folder / 'helper'
    helper.write_text('#!/bin/sh\ntouch ' + shlex.quote(str(folder / 'helper-called')) + '\nexit 91\n')
    helper.chmod(0o700)
    for kind in KINDS:
        path = binary / kind
        path.write_text('#!' + os.sys.executable + '\n' + f'''import json, os, sys
from pathlib import Path
Path({str(folder / (kind + '.json'))!r}).write_text(json.dumps({{
    'args': sys.argv[1:],
    'injectedEnvironment': {{k: v for k, v in os.environ.items() if k in
        ('ONEAGENT_AGENT_INVOCATION', 'ONEAGENT_AGENT_KIND', 'ONEAGENT_AGENT_EXECUTABLE')}}
}}))
sys.exit(23)
''')
        path.chmod(0o700)
    return helper


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--installed', action='store_true')
    args = parser.parse_args()
    resources = Path('/Applications/1Agent.app/Contents/Resources') if args.installed else ROOT / 'Resources'
    with tempfile.TemporaryDirectory(prefix='oneagent-transparency-', dir='/private/tmp') as directory:
        root = Path(directory)
        if args.installed:
            folder = root / 'installed'; folder.mkdir(); fixture(folder)
            tab = apple('set cfg to new surface configuration\n'
                        'set initial working directory of cfg to ' + json.dumps(str(folder)) + '\n'
                        'set created to new tab with configuration cfg\nreturn id of created')
            try:
                # Input goes through the same PTY as keyboard input, after the user's rc files.
                apple('input text ' + json.dumps(command(folder), ensure_ascii=False) + ' to (focused terminal of tab id ' + json.dumps(tab) + ')\n'
                      'send key "enter" to (focused terminal of tab id ' + json.dumps(tab) + ')')
                deadline = time.monotonic() + 15
                while not (folder / 'done').exists() and time.monotonic() < deadline:
                    time.sleep(.05)
                verify(folder)
                print('PASS installed PTY: pi update and all five CLIs keep exact arguments and exit codes')
            finally:
                apple('close tab (tab id ' + json.dumps(tab) + ')')
        else:
            runner = root / 'remote-shell-tests'
            subprocess.run(['swiftc', '-o', str(runner), str(ROOT / 'Sources/GooseAgent/RemoteShellIntegration.swift'),
                            str(ROOT / 'Tests/RemoteShellIntegrationTests.swift')], check=True)
            for lane in ('local-zsh', 'local-bash', 'remote-zsh', 'remote-bash'):
                folder = root / lane; folder.mkdir(); helper = fixture(folder)
                env = dict(os.environ, HOME=str(folder), PATH='/usr/bin:/bin',
                           ONEAGENT_AGENT_HELPER=str(helper), ONEAGENT_AGENT_STATE=str(folder / 'invocation.json'),
                           ONEAGENT_AGENT_RESOURCES=str(resources / 'agent-sessions'))
                for key in ('ZDOTDIR', 'GHOSTTY_ZSH_ZDOTDIR', 'ONEAGENT_AGENT_INVOCATION', 'ONEAGENT_AGENT_KIND', 'ONEAGENT_AGENT_EXECUTABLE'):
                    env.pop(key, None)
                if lane.startswith('local'):
                    if lane.endswith('zsh'):
                        env.update(ZDOTDIR=str(resources / 'shell-integration/zsh'), GHOSTTY_ZSH_ZDOTDIR=str(folder),
                                   GHOSTTY_RESOURCES_DIR=str(resources), GHOSTTY_SHELL_FEATURES='')
                        launch = ['/bin/zsh', '-i', '-c', command(folder)]
                    else:
                        env.update(ENV=str(resources / 'shell-integration/bash/ghostty.bash'), GHOSTTY_BASH_INJECT='1',
                                   GHOSTTY_RESOURCES_DIR=str(resources), GHOSTTY_SHELL_FEATURES='')
                        launch = ['/bin/bash', '--posix', '-l', '-i', '-c', command(folder)]
                else:
                    shell = '/bin/zsh' if lane.endswith('zsh') else '/bin/bash'
                    env['SHELL'] = shell
                    # Exercise the production SSH bootstrap locally; never contact a host.
                    startup = shlex.join([shell, '-l', '-i', '-c', command(folder)])
                    bootstrap = subprocess.check_output([str(runner), '--bootstrap', str(resources), str(uuid.uuid4()), startup], text=True)
                    launch = ['/bin/sh', '-c', bootstrap]
                result = subprocess.run(launch, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
                assert result.returncode == 0, (lane, result.stderr)
                verify(folder)
                print('PASS ' + lane + ': exact argv, empty/Unicode arguments, exit codes, no supervisor')


if __name__ == '__main__':
    main()
