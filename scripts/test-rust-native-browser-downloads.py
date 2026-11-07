#!/usr/bin/env python3
"""Fresh-GHA-only exact-tab native downloads through the running private CI app.

Linux (WebKitGTK) and Windows (WebView2) share this flow. The outer fixture owns
startup/ordinary Quit and the isolated HOME whose Downloads/Coincide root files
must land in. No subprocess, personal profile, password manager, external
network, arbitrary script RPC or desktop input.
"""
import http.server
import json
import os
import pathlib
import platform
import stat
import threading
import time
from urllib.parse import urlsplit

HTTP_BODY = b'owned synthetic HTTP download\n'
ATTACHMENT_BODY = b'owned synthetic attachment response\n'
BLOB_BODY = b'owned synthetic blob download\n'
PAGE = b'''<!doctype html><meta charset=utf-8><title>Owned native download fixture</title>
<a id=http href=/file download=owned-http.txt>HTTP</a>
<a id=blob download=owned-blob.txt>Blob</a>
<a id=slow href=/slow download=owned-slow.txt>Slow</a><output id=ready>ready</output>
<script>document.querySelector('#blob').href=URL.createObjectURL(new Blob(['owned synthetic blob download\\n'],{type:'text/plain'}));</script>'''


def wait_for(description, action, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = action()
        if value:
            return value
        time.sleep(0.1)
    raise AssertionError(f'Timed out: {description}')


def exercise_downloads(rpc, thread_id, downloads_root):
    assert platform.system() in ('Linux', 'Windows'), 'App-level native adapter fixture only'
    assert os.environ.get('GITHUB_ACTIONS') == 'true', 'Fresh GitHub runner only'
    assert os.environ.get('RUNNER_TEMP'), 'Owned fresh runner scratch required'
    downloads_root = pathlib.Path(downloads_root)
    stop = threading.Event()
    slow_started = threading.Event()
    slow_returned = threading.Event()
    slots = threading.BoundedSemaphore(4)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            route = urlsplit(self.path).path
            if route == '/page':
                body, mime, name = PAGE, 'text/html; charset=utf-8', None
            elif route == '/file':
                body, mime, name = HTTP_BODY, 'application/octet-stream', 'owned-http.txt'
            elif route == '/attachment':
                body, mime, name = ATTACHMENT_BODY, 'application/octet-stream', 'owned-attachment.txt'
            elif route == '/slow':
                body, mime, name = b'owned-slow-' * 65536, 'application/octet-stream', 'owned-slow.txt'
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(body)))
            if name:
                self.send_header('Content-Disposition', f'attachment; filename="{name}"')
            self.end_headers()
            if route != '/slow':
                self.wfile.write(body)
                return
            slow_started.set()
            try:
                for index in range(0, len(body), 1024):
                    if stop.is_set():
                        break
                    self.wfile.write(body[index:index + 1024])
                    self.wfile.flush()
                    if stop.wait(0.025):
                        break
            except (ConnectionError, TimeoutError):  # includes Windows aborts
                pass
            finally:
                slow_returned.set()

        def log_message(self, *_):
            pass

    class BoundedServer(http.server.ThreadingHTTPServer):
        daemon_threads = False
        block_on_close = True

        def get_request(self):
            connection, address = super().get_request()
            connection.settimeout(2)
            return connection, address

        def process_request(self, request, address):
            if not slots.acquire(blocking=False):
                self.shutdown_request(request)
                return
            try:
                super().process_request(request, address)
            except BaseException:
                slots.release()
                raise

        def process_request_thread(self, request, address):
            try:
                super().process_request_thread(request, address)
            finally:
                slots.release()

    server = BoundedServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=server.serve_forever, name='owned-native-download-http')
    worker.start()
    tabs = []
    report = {'checks': [], 'cleanupErrors': []}
    first_error = None

    def browser(action, **params):
        operation = rpc('browser.request', threadId=thread_id, action=action, **params)['operationId']
        def result():
            reply = rpc('browser.result', threadId=thread_id, operationId=operation)
            return reply if reply.get('ready') else None
        return wait_for(f'native browser {action}', result)['result']

    def records(tab=None):
        reply = browser('downloads', **({'tab': tab} if tab else {}))
        assert reply.get('acceptingDownloads') is True, reply
        return reply['downloads']

    def verified_file(row, expected):
        assert row['state'] == 'finished' and row.get('path'), row
        path = pathlib.Path(row['path'])
        assert not path.is_symlink()
        resolved = path.resolve(strict=True)
        # Exactly one fresh folder below the isolated HOME's Downloads/Coincide.
        root = downloads_root.resolve(strict=True)
        assert resolved.parent.parent == root and path == resolved, 'Output escaped Downloads/Coincide'
        flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0) | getattr(os, 'O_BINARY', 0)
        descriptor = os.open(path, flags)
        try:
            metadata = os.fstat(descriptor)
            assert stat.S_ISREG(metadata.st_mode) and metadata.st_size == len(expected)
            assert os.read(descriptor, len(expected) + 1) == expected
        finally:
            os.close(descriptor)

    try:
        base = f'http://127.0.0.1:{server.server_port}/page'
        # Both tabs belong to one thread's selected native profile/context.
        for _ in range(2):
            tab = browser('new-tab', url=base)['tab']
            tabs.append(tab)
            wait_for('owned download page ready', lambda: browser('read', tab=tab, selector='#ready').get('text') == 'ready')
        first, second = tabs
        unsupported = browser('tabs').get('unsupported', [])
        assert 'blob-downloads' not in unsupported, unsupported
        browser('click', tab=first, selector='#http')
        a = wait_for('first exact-tab HTTP download', lambda: next((row for row in records(first) if row['state'] == 'finished'), None))
        assert records(second) == [], 'Shared context attributed first download to second tab'
        verified_file(a, HTTP_BODY)
        browser('click', tab=second, selector='#http')
        b = wait_for('second exact-tab same-URL HTTP download', lambda: next((row for row in records(second) if row['state'] == 'finished'), None))
        verified_file(b, HTTP_BODY)
        assert a['id'] != b['id'] and a['path'] != b['path']
        assert len(records(first)) == 1 and len(records(second)) == 1
        report['checks'].append('same context/same URL downloads attributed once to each exact native tab')
        browser('click', tab=first, selector='#blob')
        blob = wait_for('native document-origin blob download', lambda: next((row for row in records(first) if row['state'] == 'finished' and row['id'] != a['id']), None))
        verified_file(blob, BLOB_BODY)
        assert len(records(second)) == 1
        report['checks'].append('native blob download saved only under originating tab and owned private directory')
        # An API navigation to an attachment exercises the response-policy path.
        browser('navigate', tab=first, url=f'http://127.0.0.1:{server.server_port}/attachment')
        attachment = wait_for('response-policy attachment download', lambda: next((row for row in records(first) if row['state'] == 'finished' and row['id'] not in (a['id'], blob['id'])), None))
        assert attachment['name'] == 'owned-attachment.txt', attachment
        verified_file(attachment, ATTACHMENT_BODY)
        assert len(records(second)) == 1, 'Response download reached the sibling tab'
        report['checks'].append('response-policy attachment saved once under its exact tab')
        browser('click', tab=first, selector='#slow')
        slow = wait_for('actual native transfer started', lambda: next((row for row in records(first) if row['state'] == 'downloading'), None))
        assert slow_started.wait(2), 'Owned server never started slow response'
        assert 'error' not in browser('close-tab', tab=first)
        tabs.remove(first)
        cancelled = wait_for('actual cancellation completion after CloseTab', lambda: next((row for row in records(first) if row['id'] == slow['id'] and row['state'] not in ('downloading', 'unconfirmed')), None))
        assert cancelled['state'] == 'cancelled' and 'path' not in cancelled, cancelled
        wait_for('owned slow server handler actually returned', slow_returned.is_set)
        assert len(records(second)) == 1 and records(second)[0]['state'] == 'finished'
        report['checks'].append('CloseTab cancelled native transfer; its actual native outcome returned without affecting sibling tab')
    except BaseException as error:
        first_error = error
        report['failure'] = repr(error)
    finally:
        for tab in tabs:
            try:
                reply = browser('close-tab', tab=tab)
                assert 'error' not in reply, reply
            except Exception as error:
                report['cleanupErrors'].append({'tab': tab, 'error': repr(error)})
        stop.set()
        server.shutdown()
        server.server_close()  # joins non-daemon handlers; no timeout-as-ACK
        worker.join()
        if worker.is_alive():
            report['cleanupErrors'].append({'server': 'Owned HTTP loop did not return'})
    if first_error is not None or report['cleanupErrors']:
        raise AssertionError(json.dumps(report)) from first_error
    report['passed'] = True
    return report
