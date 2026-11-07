#!/usr/bin/env python3
"""Native upload acceptance against an already running, private fresh CI app.

The caller owns app startup/Quit and supplies its synthetic thread. Only owned
synthetic files under this run's RUNNER_TEMP are attached, to an owned loopback
page. This never opens a picker, a personal file, browser profile or provider.
No local invocation is authorized by this fixture's existence.
"""
import http.server
import json
import os
from pathlib import Path
import tempfile
import threading
import time

PAGE = '''<!doctype html><meta charset="utf-8"><title>Owned native upload fixture</title>
<input id="single" type="file"><input id="multi" type="file" multiple><input id="text">
<output id="result">upload-ready</output>
<script>
const out = document.getElementById('result');
const hex = buffer => Array.from(new Uint8Array(buffer), byte => byte.toString(16).padStart(2, '0')).join('');
for (const input of document.querySelectorAll('input[type=file]')) input.addEventListener('change', async () => {
  const parts = await Promise.all([...input.files].map(async file =>
    file.name + ':' + file.type + ':' + file.size + ':' + hex(await file.arrayBuffer())));
  out.textContent = input.id + '=' + parts.join('|');
});
</script>'''.encode('utf-8')
BINARY_NAME = '界 upload.bin'
BINARY = bytes([0, 255, 10, 65, 0xc3, 0xa9])
TEXT_NAME = 'second.txt'
TEXT = b'owned second file\n'


def wait_for(description, action, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = action()
        if value:
            return value
        time.sleep(0.1)
    raise AssertionError(f'Timed out: {description}')


def exercise_uploads(rpc, thread_id):
    assert os.environ.get('GITHUB_ACTIONS') == 'true', 'Fresh GitHub runner only'
    runner = os.environ.get('RUNNER_TEMP')
    assert runner, 'Owned fresh runner scratch required'
    root = Path(tempfile.mkdtemp(prefix='owned-native-upload-', dir=runner)).resolve()
    binary = root / BINARY_NAME
    binary.write_bytes(BINARY)
    text = root / TEXT_NAME
    text.write_bytes(TEXT)
    folder = root / 'folder'
    folder.mkdir()
    private = {str(root), json.dumps(str(root))[1:-1]}
    thread = thread_id

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != '/owned-upload-fixture':
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
        value = wait_for(f'browser {action}', result)['result']
        encoded = json.dumps(value, ensure_ascii=False)
        assert not any(path in encoded for path in private), 'Browser result exposed an owned file path'
        return value

    def output(expected, tab):
        return wait_for(f'page read {expected!r}',
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
    checks = []
    report = {'scope': 'Actual native upload of owned synthetic files to an owned loopback page only',
              'checks': checks, 'cleanupErrors': [], 'passed': False}
    first_error = None
    try:
        opened = browser('new-tab', url=f'http://127.0.0.1:{server.server_port}/owned-upload-fixture')
        assert 'error' not in opened, opened
        tab = opened['tab']
        output('upload-ready', tab)
        tabs = browser('tabs')
        assert 'upload' not in tabs['unsupported'], tabs
        single = browser('upload', tab=tab, selector='#single', files=[str(binary)])
        assert single.get('attached') is True and single.get('count') == 1, single
        assert single.get('submissionRequested') is False, single
        output(f'single={BINARY_NAME}:application/octet-stream:6:{BINARY.hex()}', tab)
        checks.append('single-exact-bytes')
        multi = browser('upload', tab=tab, selector='#multi', files=[str(binary), str(text)])
        assert multi.get('attached') is True and multi.get('count') == 2, multi
        output(f'multi={BINARY_NAME}:application/octet-stream:6:{BINARY.hex()}'
               f'|{TEXT_NAME}:text/plain:{len(TEXT)}:{TEXT.hex()}', tab)
        checks.append('multiple-exact-bytes')
        for label, selector, files in [
            ('text-field-selector', '#text', [str(text)]),
            ('two-files-single-input', '#single', [str(binary), str(text)]),
            ('directory', '#single', [str(folder)]),
            ('missing-file', '#single', [str(root / 'missing.txt')]),
        ]:
            refused = browser('upload', tab=tab, selector=selector, files=files)
            assert 'error' in refused, (label, refused)
            checks.append(label + '-refused')
        # Refusals neither dispatched page events nor replaced the earlier files.
        output(f'multi={BINARY_NAME}:application/octet-stream:6:{BINARY.hex()}'
               f'|{TEXT_NAME}:text/plain:{len(TEXT)}:{TEXT.hex()}', tab)
        assert binary.read_bytes() == BINARY and text.read_bytes() == TEXT
        closed = browser('close-tab', tab=tab)
        assert 'error' not in closed, closed
        tab = None
        checks.append('sources-unchanged-and-tab-closed')
    except BaseException as error:
        first_error = error
        report['failure'] = repr(error)
    finally:
        if tab:
            try:
                closed = browser('close-tab', tab=tab)
                assert 'error' not in closed, closed
            except Exception as error:
                report['cleanupErrors'].append({'tab': tab, 'error': repr(error)})
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)
        if worker.is_alive():
            report['cleanupErrors'].append({'worker': 'owned HTTP server', 'error': 'did not actually return'})
    if first_error is not None or report['cleanupErrors']:
        # Preserve the actual original exception as the cause, plus all exact
        # cleanup failures. The outer fixture retains normal app Quit custody.
        raise AssertionError(json.dumps(report)) from first_error
    report['passed'] = True
    return report
