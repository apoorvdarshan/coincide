#!/usr/bin/env python3
"""Fresh-runner callable acceptance of trusted native keys on owned loopback HTML.

The outer fixture owns app/control/native window/Quit. No subprocess, personal
profile, clipboard, vault, browser query or global desktop input is used here.
"""
import http.server
import json
import os
import threading
import time
from urllib.parse import parse_qs, urlsplit

PAGE = b'''<!doctype html><meta charset="utf-8"><title>Owned native key fixture</title>
<form id="form" action="/submitted" method="get">
<input id="first" name="query"><input id="second"><textarea id="multi"></textarea>
<input type="hidden" name="trusted" id="trusted"><button type="submit">Submit</button></form>
<input id="dialog-key"><button id="reset" type="button">Reset events</button>
<pre id="values"></pre><pre id="events">[]</pre><output id="focus">none</output>
<script>
const first=document.getElementById('first'), second=document.getElementById('second'), multi=document.getElementById('multi');
const events=[]; const rendered=document.getElementById('events');
function values(){document.getElementById('values').textContent=JSON.stringify({first:first.value,second:second.value,multi:multi.value});}
document.addEventListener('input',values); values();
document.addEventListener('focusin',e=>{document.getElementById('focus').textContent=e.target.id;});
for(const type of ['keydown','keyup']) document.addEventListener(type,e=>{events.push({type:e.type,key:e.key,trusted:e.isTrusted,target:e.target.id});rendered.textContent=JSON.stringify(events);},true);
document.getElementById('reset').onclick=()=>{events.length=0;rendered.textContent='[]';};
document.getElementById('form').addEventListener('submit',e=>{document.getElementById('trusted').value=String(e.isTrusted);});
document.getElementById('dialog-key').addEventListener('keydown',e=>{if(e.key==='Enter')alert('Synthetic native key dialog');});
</script>'''


def wait_for(description, action, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = action()
        if value:
            return value
        time.sleep(0.1)
    raise AssertionError(f'Timed out: {description}')


def exercise_keys(rpc, thread_id):
    assert os.environ.get('GITHUB_ACTIONS') == 'true', 'Fresh GitHub runner only'
    assert os.environ.get('RUNNER_TEMP'), 'Owned runner scratch required'
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            address = urlsplit(self.path)
            if address.path == '/owned-key-fixture':
                body = PAGE
            elif address.path == '/submitted':
                query = parse_qs(address.query)
                if query.get('trusted') != ['true'] or query.get('query') != ['synthetic-query']:
                    self.send_error(400)
                    return
                body = b'<!doctype html><title>Owned submitted fixture</title><output id="submitted">trusted-default-submit</output>'
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Content-Security-Policy', "default-src 'none'; script-src 'unsafe-inline'; form-action 'self'")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    class BoundedServer(http.server.HTTPServer):
        def get_request(self):
            connection, address = super().get_request()
            connection.settimeout(2)
            return connection, address

    def browser(action, **params):
        operation = rpc('browser.request', threadId=thread_id, action=action, **params)['operationId']
        def result():
            value = rpc('browser.result', threadId=thread_id, operationId=operation)
            return value if value.get('ready') else None
        return wait_for(f'native browser {action}', result)['result']

    def read(selector):
        return browser('read', tab=tab, selector=selector)

    def values():
        response = read('#values')
        return json.loads(response['text']) if response.get('text') else None

    def expected_values(**expected):
        def matches():
            actual = values()
            return actual if actual and all(actual.get(key) == value for key, value in expected.items()) else None
        return wait_for('exact native key default edit', matches)

    def press(key, selector=None):
        response = browser('press', tab=tab, key=key, selector=selector)
        assert response.get('pressed') is True and response.get('nativeKeys') is True, response
        return response

    def trusted_pair(key):
        def complete():
            response = read('#events')
            events = json.loads(response.get('text', '[]'))
            relevant = [event for event in events if event['key'] == key]
            if not any(event['type'] == 'keydown' for event in relevant) or not any(event['type'] == 'keyup' for event in relevant):
                return None
            assert all(event['trusted'] is True for event in relevant), relevant
            return relevant
        return wait_for('trusted native key down/up', complete)

    server = BoundedServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.1))
    worker.start()
    tab = None
    shown = False
    report = {'scope': 'Actual native key trust and default actions on owned loopback HTML', 'checks': [], 'cleanupErrors': [], 'passed': False}
    first_error = None
    try:
        opened = browser('new-tab', url=f'http://127.0.0.1:{server.server_port}/owned-key-fixture')
        assert 'error' not in opened, opened
        tab = opened['tab']
        wait_for('owned fixture loaded', values)
        assert 'native-key-events' not in browser('tabs')['unsupported'], 'Native key adapter was not installed'
        assert browser('show', tab=tab).get('visible') is True
        shown = True
        press('a', '#first')
        expected_values(first='a')
        trusted_pair('a')
        press('Shift+b', '#first')
        expected_values(first='aB')
        trusted_pair('B')
        press('Backspace', '#first')
        expected_values(first='a')
        trusted_pair('Backspace')
        press('Meta+a', '#first')
        press('z', '#first')
        expected_values(first='z')
        report['checks'].append('trusted characters/shift/backspace and platform-primary select-all replaced actual input')
        press('Tab', '#first')
        wait_for('native Tab default focus', lambda: read('#focus').get('text') == 'second')
        trusted_pair('Tab')
        press('Shift+Tab')
        wait_for('native Shift+Tab default focus', lambda: read('#focus').get('text') == 'first')
        press('Enter', '#multi')
        expected_values(multi='\n')
        report['checks'].append('Tab/Shift+Tab traversed actual controls; Enter inserted default textarea newline')
        browser('click', tab=tab, selector='#reset')
        reply = browser('press', tab=tab, key='Enter', selector='#dialog-key')
        # Direct AppKit/GTK event invocation can return before the renderer's
        # dialog callback; observe that real dialog without replaying the key.
        dialog = reply.get('dialog') or wait_for('native key dialog', lambda: read('#events').get('dialog'))
        assert dialog['message'] == 'Synthetic native key dialog', dialog
        assert browser('dialog', tab=tab, dialogId=dialog['id'], accept=True).get('answered') == 'alert'
        trusted_pair('Enter')
        report['checks'].append('dialog-interrupted native key resumed only its old-source release; trusted up observed')
        browser('input', tab=tab, selector='#first', text='synthetic-query')
        submitted_reply = browser('press', tab=tab, key='Enter', selector='#first')
        assert submitted_reply.get('pressed') is True or submitted_reply.get('error') == 'Native key source changed; completion is not confirmed and must not be replayed automatically', submitted_reply
        wait_for('trusted native default form submit navigation', lambda: read('#submitted').get('text') == 'trusted-default-submit')
        report['submitReply'] = submitted_reply
        report['checks'].append('Enter caused a trusted native default form submission to owned loopback endpoint')
    except BaseException as error:
        first_error = error
        report['failure'] = repr(error)
    finally:
        if shown:
            try:
                assert browser('hide', tab=tab).get('visible') is False
            except Exception as error:
                report['cleanupErrors'].append({'panel': 'owned browser', 'error': repr(error)})
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
        raise AssertionError(json.dumps(report)) from first_error
    report['passed'] = True
    return report
