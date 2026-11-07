#!/usr/bin/env python3
"""Native dialog acceptance against an already running, private fresh CI app.

The caller owns app startup/Quit and supplies its synthetic thread. This never
opens a personal browser/profile, runs providers, or touches a password manager.
No local invocation is authorized by this fixture's existence.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import subprocess
import threading
import time
import uuid

PAGE = b'''<!doctype html><meta charset="utf-8"><title>Owned native dialog fixture</title>
<button id="alert">Alert</button><button id="confirm">Confirm</button>
<button id="prompt">Prompt</button><button id="sequence">Sequence</button>
<output id="result">ready</output>
<script>
const out = document.getElementById('result');
document.getElementById('alert').onclick = () => {alert('Synthetic alert'); out.textContent='alert-completed';};
document.getElementById('confirm').onclick = () => {out.textContent=String(confirm('Synthetic confirm'));};
document.getElementById('prompt').onclick = () => {out.textContent=JSON.stringify(prompt('Synthetic prompt','synthetic default'));};
document.getElementById('sequence').onclick = () => {alert('Synthetic first'); alert('Synthetic second'); out.textContent='sequence-completed';};
</script>'''


def wait_for(description, action, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = action()
        if value:
            return value
        time.sleep(0.1)
    raise AssertionError(f'Timed out: {description}')


def run_fixture(rpc, thread):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != '/owned-dialog-fixture':
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(PAGE)))
            self.send_header('Content-Security-Policy', "default-src 'none'; script-src 'unsafe-inline'")
            self.end_headers()
            self.wfile.write(PAGE)

        def log_message(self, *_):
            pass

    def browser(action, **params):
        queued = rpc('browser.request', threadId=thread, action=action, **params)
        operation = queued['operationId']
        def result():
            response = rpc('browser.result', threadId=thread, operationId=operation)
            return response if response.get('ready') else None
        return wait_for(f'browser {action}', result)['result']

    def output(expected, tab):
        return wait_for('exact native JavaScript continuation result',
                        lambda: browser('read', tab=tab, selector='#result').get('text') == expected)

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    tab = None
    spare = None
    checks = []
    try:
        opened = browser('new-tab', url=f'http://127.0.0.1:{server.server_port}/owned-dialog-fixture')
        assert 'error' not in opened, opened
        tab = opened['tab']
        output('ready', tab)
        tabs = browser('tabs')
        assert 'dialogs' not in tabs['unsupported'], tabs
        for kind, accept, text, expected in [
            ('alert', True, None, 'alert-completed'),
            ('confirm', True, None, 'true'),
            ('confirm', False, None, 'false'),
            ('prompt', True, 'synthetic native response', '"synthetic native response"'),
            ('prompt', False, None, 'null'),
        ]:
            # Click's evaluation is genuinely blocked by the native dialog.
            # The owner must release its API reply before we can answer it.
            result = browser('click', tab=tab, selector=f'#{kind}')
            dialog = result.get('dialog')
            assert dialog and dialog['kind'] == kind, result
            assert browser('read', tab=tab)['dialog']['id'] == dialog['id']
            bad = browser('dialog', tab=tab, dialogId=str(uuid.uuid4()), accept=True)
            assert 'error' in bad, bad
            assert browser('read', tab=tab)['dialog']['id'] == dialog['id']
            answer = browser('dialog', tab=tab, dialogId=dialog['id'], accept=accept, text=text)
            assert answer.get('answered') == kind, answer
            assert 'error' in browser('dialog', tab=tab, dialogId=dialog['id'], accept=True)
            output(expected, tab)
            checks.append(f'{kind}-{accept}')
        first = browser('click', tab=tab, selector='#sequence')['dialog']
        assert first['message'] == 'Synthetic first'
        browser('dialog', tab=tab, dialogId=first['id'], accept=True)
        second = wait_for('second actual dialog', lambda: browser('read', tab=tab).get('dialog'))
        assert second['message'] == 'Synthetic second' and second['id'] != first['id']
        browser('dialog', tab=tab, dialogId=second['id'], accept=True)
        output('sequence-completed', tab)
        checks.append('reentrant-sequence')
        pending = browser('click', tab=tab, selector='#prompt')['dialog']
        spare = browser('new-tab')['tab']
        assert 'error' in browser('dialog', tab=spare, dialogId=pending['id'], accept=True)
        assert browser('read', tab=tab)['dialog']['id'] == pending['id']
        browser('close-tab', tab=tab)
        assert 'error' in browser('dialog', tab=tab, dialogId=pending['id'], accept=True)
        tab = None
        checks.append('wrong-tab-and-close-cancellation')
        return {'scope': 'Actual native dialogs on owned loopback page only', 'checks': checks, 'passed': True}
    finally:
        for owned in (tab, spare):
            if owned:
                try:
                    browser('close-tab', tab=owned)
                except Exception:
                    # Do not replace the original failure. App lifetime belongs
                    # to the outer native fixture and its normal Quit custody.
                    pass
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)
        assert not worker.is_alive(), 'Owned HTTP fixture worker did not return'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--client', required=True)
    parser.add_argument('--data-dir', required=True)
    parser.add_argument('--home', required=True)
    parser.add_argument('--thread', required=True)
    parser.add_argument('--report', required=True)
    args = parser.parse_args()
    assert os.environ.get('GITHUB_ACTIONS') == 'true', 'Fresh GitHub runner only'
    runner = Path(os.environ['RUNNER_TEMP']).resolve()
    for value in (args.data_dir, args.home, args.report):
        assert Path(value).resolve().is_relative_to(runner), 'Fixture must remain in owned runner scratch'
    env = {name: value for name, value in os.environ.items() if name in ('PATH', 'SystemRoot', 'WINDIR', 'TEMP', 'TMP')}
    env.update(HOME=args.home, USERPROFILE=args.home, COINCIDE_RUST_DATA_DIR=args.data_dir)
    def rpc(method, **params):
        process = subprocess.run([args.client, 'api'], input=json.dumps({'id': 1, 'method': method, 'params': params})+'\n',
                                 text=True, capture_output=True, timeout=20, env=env, check=True)
        response = json.loads(process.stdout)
        assert 'error' not in response, f'{method}: local request failed'
        return response['result']
    assert rpc('app.status').get('preview'), 'Owned application control required'
    # browser.request additionally requires the actual desktop UI owner; a
    # standalone client/Core fallback cannot pass any of the tests below.
    report = run_fixture(rpc, args.thread)
    Path(args.report).write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
