#!/usr/bin/env python3
"""Native dialog acceptance against an already running, private fresh CI app.

The caller owns app startup/Quit and supplies its synthetic thread. This never
opens a personal browser/profile, runs providers, or touches a password manager.
No local invocation is authorized by this fixture's existence.
"""
import http.server
import json
import os
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


def exercise_dialogs(rpc, thread_id):
    assert os.environ.get('GITHUB_ACTIONS') == 'true', 'Fresh GitHub runner only'
    assert os.environ.get('RUNNER_TEMP'), 'Owned fresh runner scratch required'
    thread = thread_id
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

    class BoundedServer(http.server.HTTPServer):
        def get_request(self):
            connection, address = super().get_request()
            connection.settimeout(2)
            return connection, address

    # One owned request/serve thread, no daemon request workers to outlive it.
    server = BoundedServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.1))
    worker.start()
    tab = None
    spare = None
    checks = []
    report = {'scope': 'Actual native dialogs on owned loopback page only',
              'checks': checks, 'cleanupErrors': [], 'passed': False}
    first_error = None
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
    except BaseException as error:
        first_error = error
        report['failure'] = repr(error)
    finally:
        for owned in (tab, spare):
            if owned:
                try:
                    closed = browser('close-tab', tab=owned)
                    assert 'error' not in closed, closed
                except Exception as error:
                    report['cleanupErrors'].append({'tab': owned, 'error': repr(error)})
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)
        if worker.is_alive():
            report['cleanupErrors'].append({'worker': 'owned HTTP server', 'error': 'did not actually return'})
    if first_error is not None or report['cleanupErrors']:
        # Preserve the actual original exception as the cause, plus all exact
        # cleanup failures. A successful assertion sequence cannot mask a close
        # failure; the outer fixture retains normal app Quit/process custody.
        raise AssertionError(json.dumps(report)) from first_error
    report['passed'] = True
    return report
