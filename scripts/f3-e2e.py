#!/usr/bin/env python3
"""F3-only adapter for the isolated E0/E1b harness; no official app access."""
import os

for key in list(os.environ):
    if key.startswith("CODEG_"):
        del os.environ[key]

import argparse
import json
from pathlib import Path
import plistlib
import re
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
ENV = Path('/path/to/codeg/e2e-env')
EVIDENCE = Path('/path/to/evidence')
CONFIG = ROOT / 'CodegiOSUITests/E1bController.json'
sys.path.insert(0, str(ENV / 'e2e'))
from harness import api, load_state, state_path


def state():
    value = load_state('f3')
    assert value['server_port'] == 3097
    assert value['relay_port'] == 18487
    return value


def call(command, params=None):
    s = state()
    return api(s['relay_url'], s['token'], command, params, s['fingerprint'])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['bridge', 'ui', 'move-home', 'restore-home', 'seed', 'proxy'])
    parser.add_argument('command', nargs='?', default='{}')
    parser.add_argument('--name', default='latest')
    args = parser.parse_args()
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    if args.action == 'bridge':
        import ui_bridge
        from http.server import ThreadingHTTPServer
        ui_bridge.load_state = lambda _: state()
        with (ROOT / 'build/fork/simulator/Build/Products/Debug-iphonesimulator/Codeg.app/Info.plist').open('rb') as file:
            bundle_id = plistlib.load(file)['CFBundleIdentifier']
        assert re.fullmatch(r'app\.codeg\.ios\.fork(?:\.[A-Za-z0-9-]+)*', bundle_id), 'Build the isolated fork first'
        server = ThreadingHTTPServer(('127.0.0.1', 0), ui_bridge.Handler)
        CONFIG.write_text(json.dumps({'url': f'http://127.0.0.1:{server.server_port}', 'bundleID': bundle_id}))
        print(f'F3 bridge PID={os.getpid()} port={server.server_port}', flush=True)
        server.serve_forever()
    elif args.action == 'ui':
        import ui_command
        ui_command.CONFIG, ui_command.EVIDENCE = CONFIG, EVIDENCE
        start = time.time()
        result = ui_command.ui(json.loads(args.command), args.name)
        print(json.dumps({'start': start, 'end': time.time(), 'error': result.get('error')}))
        print(result.get('tree', ''))
    elif args.action in ('move-home', 'restore-home'):
        from e1b_lifecycle import stop_server, start_server
        s = state()
        stop_server(s)
        start_server(s, 0 if args.action == 'move-home' else s['server_port'])
        print(f'{args.action} completed at {time.time()}')
    elif args.action == 'seed':
        session = json.loads(state_path('f3').with_suffix('.session.json').read_text())
        call('acp_prompt', {'connectionId': session['connectionId'],
             'blocks': [{'type': 'text', 'text': '#echo F3_RELAY_READY'}],
             'folderId': session['folderId'], 'conversationId': session['conversationId']})
        print('Synthetic session seeded')
    elif args.action == 'proxy':
        import urllib.request
        with urllib.request.urlopen('http://127.0.0.1:18449/status') as response:
            result = json.load(response)
        (EVIDENCE / (args.name + '-proxy.json')).write_text(json.dumps(result, indent=2))
        print('Proxy evidence saved')


if __name__ == '__main__':
    main()
