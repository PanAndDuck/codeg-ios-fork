#!/usr/bin/env python3
"""Simulator adapter for a codeg server checkout with the optional e2e/ harness.

Run with --help for required paths and environment selection. This repository
does not include the server harness; see docs/FORK.md for its module contract.
"""
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
CONFIG = ROOT / 'CodegiOSUITests/E1bController.json'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['bridge', 'ui', 'move-home', 'restore-home', 'seed', 'proxy'])
    parser.add_argument('command', nargs='?', default='{}')
    parser.add_argument('--name', default='latest')
    parser.add_argument('--server-checkout', type=Path, required=True,
                        help='codeg server checkout containing e2e/ harness modules')
    parser.add_argument('--state-name', required=True,
                        help='disposable environment name understood by harness.load_state')
    parser.add_argument('--evidence-dir', type=Path, required=True,
                        help='directory for local UI and proxy evidence (use .codex/...)')
    parser.add_argument('--proxy-url', help='proxy status URL; required for the proxy action')
    parser.add_argument('--app-path', type=Path,
                        default=ROOT / 'build/fork/simulator/Build/Products/Debug-iphonesimulator/Codeg.app',
                        help='built fork simulator .app for the bridge action')
    args = parser.parse_args()
    if args.action == 'proxy' and not args.proxy_url:
        parser.error('proxy requires --proxy-url')
    harness_dir = args.server_checkout.expanduser().resolve() / 'e2e'
    required_modules = ['harness.py', 'ui_bridge.py', 'ui_command.py', 'e1b_lifecycle.py']
    missing = [name for name in required_modules if not (harness_dir / name).is_file()]
    if missing:
        parser.error(f'{harness_dir} is missing required harness modules: {", ".join(missing)}')
    sys.path.insert(0, str(harness_dir))
    from harness import api, load_state, state_path

    def state():
        return load_state(args.state_name)

    evidence = args.evidence_dir.expanduser().resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    if args.action == 'bridge':
        import ui_bridge
        from http.server import ThreadingHTTPServer
        ui_bridge.load_state = lambda _: state()
        with (args.app_path.expanduser() / 'Info.plist').open('rb') as file:
            bundle_id = plistlib.load(file)['CFBundleIdentifier']
        assert re.fullmatch(r'app\.codeg\.ios\.fork(?:\.[A-Za-z0-9-]+)*', bundle_id), 'Build the isolated fork first'
        server = ThreadingHTTPServer(('127.0.0.1', 0), ui_bridge.Handler)
        CONFIG.write_text(json.dumps({'url': f'http://127.0.0.1:{server.server_port}', 'bundleID': bundle_id}))
        print(f'UI bridge PID={os.getpid()} port={server.server_port}', flush=True)
        server.serve_forever()
    elif args.action == 'ui':
        import ui_command
        ui_command.CONFIG, ui_command.EVIDENCE = CONFIG, evidence
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
        s = state()
        session = json.loads(state_path(args.state_name).with_suffix('.session.json').read_text())
        api(s['relay_url'], s['token'], 'acp_prompt',
            {'connectionId': session['connectionId'],
             'blocks': [{'type': 'text', 'text': '#echo RELAY_READY'}],
             'folderId': session['folderId'], 'conversationId': session['conversationId']},
            s['fingerprint'])
        print('Synthetic session seeded')
    elif args.action == 'proxy':
        import urllib.request
        with urllib.request.urlopen(args.proxy_url, timeout=10) as response:
            result = json.load(response)
        (evidence / (args.name + '-proxy.json')).write_text(json.dumps(result, indent=2))
        print('Proxy evidence saved')


if __name__ == '__main__':
    main()
