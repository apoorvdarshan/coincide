#!/usr/bin/env python3
"""Own-WebView screenshot acceptance; fresh hosted CI only, never personal UI.

Caller owns the private app, ordinary Quit, thread and data directory. Only
loopback pages/fake secrets are captured. No OS desktop screenshot, JS RPC,
credential provider, external network or personal-profile operation is used.
"""
import http.server
import json
import os
from pathlib import Path
import stat
import struct
import threading
import time
import zlib


def wait_for(description, action, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = action()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError(f'Timed out: {description}')


def decode_owned_png(path):
    """Bounded stdlib decoder for the Core encoder's 8-bit noninterlaced RGBA."""
    encoded = path.read_bytes()
    assert len(encoded) <= 16 * 1024 * 1024 and encoded[:8] == b'\x89PNG\r\n\x1a\n'
    offset, payload, dimensions = 8, bytearray(), None
    while offset < len(encoded):
        length, kind = struct.unpack('>I4s', encoded[offset:offset + 8])
        assert length <= 16 * 1024 * 1024 and offset + length + 12 <= len(encoded)
        data = encoded[offset + 8:offset + 8 + length]
        crc, = struct.unpack('>I', encoded[offset + 8 + length:offset + 12 + length])
        assert zlib.crc32(kind + data) == crc
        if kind == b'IHDR':
            w, h, bits, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', data)
            assert 0 < w <= 1600 and 0 < h <= 20000 and w * h <= 8_000_000
            assert (bits, color, compression, filtering, interlace) == (8, 6, 0, 0, 0)
            dimensions = w, h
        elif kind == b'IDAT':
            payload.extend(data)
            assert len(payload) <= 16 * 1024 * 1024
        offset += length + 12
        if kind == b'IEND':
            assert offset == len(encoded)
            break
    assert dimensions
    w, h = dimensions
    stride = w * 4
    decoder = zlib.decompressobj()
    rows = decoder.decompress(payload, (stride + 1) * h + 1)
    assert decoder.eof and not decoder.unused_data and len(rows) == (stride + 1) * h
    image = bytearray(w * h * 4)
    def paeth(a, b, c):
        p = a + b - c
        distances = abs(p - a), abs(p - b), abs(p - c)
        return (a, b, c)[distances.index(min(distances))]
    for y in range(h):
        method = rows[y * (stride + 1)]
        assert method <= 4
        for x in range(stride):
            a = image[y * stride + x - 4] if x >= 4 else 0
            b = image[(y - 1) * stride + x] if y else 0
            c = image[(y - 1) * stride + x - 4] if y and x >= 4 else 0
            prediction = (0, a, b, (a + b) // 2, paeth(a, b, c))[method]
            image[y * stride + x] = (rows[y * (stride + 1) + 1 + x] + prediction) & 255
    return w, h, image


def exercise_screenshots(rpc, thread_id, private_root):
    assert os.environ.get('GITHUB_ACTIONS') == 'true'
    assert os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
    private_root = Path(private_root).resolve(strict=True)
    masked = threading.Event()
    release = threading.Event()
    stop = threading.Event()
    slots = threading.BoundedSemaphore(4)
    checks, tabs, artifacts = [], [], []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass
        def do_GET(self):
            if self.path == '/mask-barrier':
                masked.set()
                assert release.wait(10) or stop.is_set(), 'Owned renderer barrier not released'
                body = b'released'
            elif self.path == '/replacement':
                body = b'<!doctype html><title>Owned replacement</title><output id=ready>replacement-ready</output>'
            elif self.path == '/frame':
                body = b'<!doctype html><body style="background:rgb(0,200,0)">Only synthetic frame text</body>'
            else:
                mode = self.path
                # Percent geometry gives exact native-image sampling positions
                # without exposing an arbitrary JavaScript/geometry RPC.
                html = '''<!doctype html><meta charset=utf-8><title>Owned snapshot fixture</title>
<style>html,body{margin:0;width:100%;height:100%;background:rgb(200,100,50)}
input,textarea,[contenteditable],iframe,secret-card{position:fixed;box-sizing:border-box;width:20%;height:10%;border:0;margin:0;padding:0;background:rgb(255,0,0)}
#password{left:10%;top:10%}#otp{left:35%;top:10%}iframe{left:60%;top:10%}
textarea{left:10%;top:35%}[contenteditable]{left:35%;top:35%}secret-card{left:60%;top:35%}
#ready{position:fixed;left:0;bottom:0}#arm{position:fixed;left:0;bottom:20px}</style>
<input id=password type=password value=synthetic-password>
<input id=otp autocomplete=one-time-code value=123456>
<textarea>synthetic-notes</textarea><div contenteditable>synthetic-editable</div>
<iframe src="FRAME_URL"></iframe><secret-card></secret-card>
<output id=ready>snapshot-ready</output><button id=arm>Arm</button><button id=verify style="position:fixed;bottom:40px">Verify</button>
<script>let armed=false;document.querySelector('secret-card').attachShadow({mode:'closed'}).innerHTML='<input value="synthetic-private-shadow">';
customElements.define('secret-card',class extends HTMLElement{
 static get observedAttributes(){return ['style'];}
 attributeChangedCallback(){if(MODE==='reentrant' && armed){armed=false;
  document.querySelector('#otp').style.opacity='0.25';
  const extra=document.createElement('input');extra.value='only-synthetic-reentrant-secret';document.body.append(extra);
  document.querySelector('#ready').textContent='reentrant-detected';
 }}
});
document.querySelector('#verify').onclick=()=>{document.querySelector('#ready').textContent=document.querySelector('#otp').style.opacity==='0.25'?'style-preserved':'style-overwritten';};
document.querySelector('#arm').onclick=()=>{armed=true;new MutationObserver((records,observer)=>{
 if(!records.some(r=>r.target===document.querySelector('#otp') && r.attributeName==='style'))return;
 observer.disconnect();
 if(MODE==='stale'){location.href='/replacement';}
 if(MODE==='cancel'){let x=new XMLHttpRequest();x.open('GET','/mask-barrier',false);x.send();}
}).observe(document.documentElement,{subtree:true,attributes:true});};
</script>'''
                html = html.replace('FRAME_URL', frame_url).replace('MODE', json.dumps(mode.strip('/')))
                if mode == '/tall':
                    html = html.replace('snapshot-ready</output>', 'snapshot-ready</output><div style="height:30000px"></div>')
                body = html.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    class Server(http.server.ThreadingHTTPServer):
        daemon_threads = False
        block_on_close = True
        def get_request(self):
            connection, address = super().get_request()
            connection.settimeout(12)
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

    server = Server(('127.0.0.1', 0), Handler)
    # Separate loopback origin: a native snapshot must mask the whole frame,
    # including content inaccessible to main-frame DOM traversal.
    frames = Server(('127.0.0.1', 0), Handler)
    frame_url = f'http://127.0.0.1:{frames.server_port}/frame'
    workers = [threading.Thread(target=lambda s=s: s.serve_forever(poll_interval=0.05)) for s in (server, frames)]
    for worker in workers:
        worker.start()

    def begin(action, **params):
        return rpc('browser.request', threadId=thread_id, action=action, **params)['operationId']
    def complete(operation):
        def ready():
            response = rpc('browser.result', threadId=thread_id, operationId=operation)
            return response if response.get('ready') else None
        return wait_for('actual browser callback/worker completion', ready)['result']
    def browser(action, **params):
        return complete(begin(action, **params))
    def open_page(mode):
        result = browser('new-tab', url=f'http://127.0.0.1:{server.server_port}/{mode}')
        assert 'error' not in result, result
        tab = result['tab']
        tabs.append(tab)
        browser('select-tab', tab=tab)
        browser('show')
        wait_for('actual native document ready', lambda: browser('read', tab=tab, selector='#ready').get('text') == 'snapshot-ready')
        return tab

    report = {'scope': 'Actual own-WebView SDK screenshot with fake page data only', 'checks': checks, 'passed': False, 'cleanupErrors': []}
    first_error = None
    try:
        tab = open_page('normal')
        shot = browser('screenshot', tab=tab)
        assert 'error' not in shot, shot
        path = Path(shot['path'])
        assert path.is_absolute() and path.suffix == '.png' and path.resolve(strict=True).is_relative_to(private_root)
        assert not path.is_symlink()
        if os.name != 'nt':
            assert stat.S_IMODE(path.stat().st_mode) == 0o600
            assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
        artifacts.append(path)
        w, h, pixels = decode_owned_png(path)
        assert (shot['width'], shot['height']) == (w, h) and shot['mimeType'] == 'image/png'
        def pixel(x, y):
            offset = (int(h * y) * w + int(w * x)) * 4
            return list(pixels[offset:offset + 4])
        for x, y in [(0.2, 0.15), (0.45, 0.15), (0.7, 0.15), (0.2, 0.4), (0.45, 0.4), (0.7, 0.4)]:
            assert pixel(x, y) == [32, 32, 32, 255], (x, y, pixel(x, y))
        assert pixel(0.5, 0.7) == [200, 100, 50, 255], pixel(0.5, 0.7)
        checks.append('actual PNG native viewport, protected fields, cross-origin frame, editable and closed custom shadow host masks')
        tall = open_page('tall')
        refusal = browser('screenshot', tab=tall, fullPage=True)
        assert 'error' in refusal and 'path' not in refusal, refusal
        checks.append('oversized full page refused without viewport or scroll mutation')
        stale = open_page('stale')
        assert 'error' not in browser('click', tab=stale, selector='#arm')
        refused = browser('screenshot', tab=stale)
        assert 'error' in refused and 'path' not in refused, refused
        wait_for('replacement document after real source invalidation', lambda: browser('read', tab=stale, selector='#ready').get('text') == 'replacement-ready')
        checks.append('real mask-time navigation rejects stale native output')
        reentrant = open_page('reentrant')
        assert 'error' not in browser('click', tab=reentrant, selector='#arm')
        refused = browser('screenshot', tab=reentrant)
        assert 'error' in refused and 'path' not in refused, refused
        wait_for('actual synchronous custom-element callback', lambda: browser('read', tab=reentrant, selector='#ready').get('text') == 'reentrant-detected')
        assert 'error' not in browser('click', tab=reentrant, selector='#verify')
        wait_for('newer page styles survive failed snapshot cleanup', lambda: browser('read', tab=reentrant, selector='#ready').get('text') == 'style-preserved')
        checks.append('synchronous custom-element new-input mutation rejects capture and preserves newer field style')
        cancel = open_page('cancel')
        assert 'error' not in browser('click', tab=cancel, selector='#arm')
        operation = begin('screenshot', tab=cancel)
        assert masked.wait(10), 'Actual page did not enter owned mask barrier'
        closed = browser('close-tab', tab=cancel)
        assert 'error' not in closed, closed
        tabs.remove(cancel)
        release.set()
        cancelled = complete(operation)
        assert 'error' in cancelled and 'path' not in cancelled, cancelled
        checks.append('close during actual isolated mask evaluation waits for native completion, emits no artifact')
    except BaseException as error:
        first_error = error
        report['failure'] = repr(error)
    finally:
        stop.set()
        release.set()
        for tab in tabs:
            try:
                result = browser('close-tab', tab=tab)
                assert 'error' not in result, result
            except BaseException as error:
                report['cleanupErrors'].append(repr(error))
        for owned in (server, frames):
            owned.shutdown()
            owned.server_close()
        for worker in workers:
            worker.join(timeout=5)
            if worker.is_alive():
                report['cleanupErrors'].append('Owned HTTP worker did not actually return')
        # Do not remove private runtime artifacts: outer normal Quit owns their
        # app/profile lifetime; exact paths are metadata in its private report.
        report['artifacts'] = [str(path) for path in artifacts]
    if first_error is not None or report['cleanupErrors']:
        raise AssertionError(json.dumps(report)) from first_error
    report['passed'] = True
    return report
