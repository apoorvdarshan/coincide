#!/usr/bin/env python3
"""Actual native WebView workflow against an owned loopback HTTP fixture.

Imported by isolated native CI smoke only. No external URL, saved login, cookie,
password, upload, screenshot or arbitrary-script tool command is used.
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import threading
import time
import uuid


def exercise_browser(rpc, thread_id, capture_visible):
    assert os.environ.get("GITHUB_ACTIONS") == "true", "Fresh native CI runner only"
    marker = "NativeBrowserReady" + uuid.uuid4().hex
    text = "Native browser input café Ω"
    class Page(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(2)
        def log_message(self, *_args):
            pass
        def do_GET(self):
            if self.path == "/frame":
                html = '<title>Owned frame</title><p>NativeBrowserFrameReady</p>'
            elif self.path in ("/", "/second"):
                if self.path == "/second":
                    html = '<title>Owned second page</title><p>NativeBrowserSecondReady</p>'
                else:
                    html = ('<title>' + marker + '</title><h1>' + marker + '</h1>'
                            '<label>Fixture input<input id="fixture-field"></label>'
                            '<button id="fixture-commit">Commit fixture text</button>'
                            '<p id="fixture-result">Waiting for fixture input</p>'
                            '<iframe title="Owned frame" src="/frame"></iframe>'
                            '<script>document.getElementById("fixture-commit").onclick=()=>{'
                            'document.getElementById("fixture-result").textContent='
                            'document.getElementById("fixture-field").value;'
                            'console.log("NativeBrowserCommitted");};</script>')
            else:
                self.send_error(404)
                return
            body = html.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
    server = HTTPServer(("127.0.0.1", 0), Page)
    worker = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .05},
                              name="owned-browser-http-fixture")
    worker.start()
    origin = "http://127.0.0.1:" + str(server.server_address[1])
    tabs = []
    receipts = []
    def request(action, tab=None, **values):
        params = dict(threadId=thread_id, action=action, **values)
        if tab:
            params["tab"] = tab
        operation = rpc("browser.request", **params)["operationId"]
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            reply = rpc("browser.result", threadId=thread_id, operationId=operation)
            if reply.get("ready"):
                result = reply["result"]
                assert isinstance(result, dict) and "error" not in result, (action, result)
                receipts.append(action)
                return result
            time.sleep(.05)
        raise AssertionError("Actual native browser completion timed out: " + action)
    def wait_text(tab, expected, frame=None):
        values = dict(text=expected, timeout=5)
        if frame:
            values["frame"] = frame
        request("wait-for", tab, **values)
        values = dict(frame=frame) if frame else {}
        result = request("read", tab, **values)
        assert expected in json.dumps(result, ensure_ascii=False), result
        return result
    try:
        first = request("new-tab", url=origin + "/")["tab"]
        tabs.append(first)
        request("show", first)
        wait_text(first, marker)
        request("input", first, selector="#fixture-field", text=text)
        request("click", first, selector="#fixture-commit")
        wait_text(first, text)
        frames = request("frames", first).get("frames", [])
        frame = next((frame for frame in frames if frame.get("title") == "Owned frame"), None)
        assert frame and frame.get("id"), frames
        wait_text(first, "NativeBrowserFrameReady", frame=frame["id"])
        request("navigate", first, url=origin + "/second")
        wait_text(first, "NativeBrowserSecondReady")
        request("back", first)
        wait_text(first, marker)
        request("forward", first)
        wait_text(first, "NativeBrowserSecondReady")
        request("reload", first)
        wait_text(first, "NativeBrowserSecondReady")
        second = request("new-tab", url=origin + "/")["tab"]
        tabs.append(second)
        assert second != first
        wait_text(second, marker)
        request("select-tab", first)
        wait_text(first, "NativeBrowserSecondReady")
        capture_visible()
        request("hide", first)
        request("close-tab", second)
        tabs.remove(second)
        request("close-tab", first)
        tabs.remove(first)
        assert request("tabs").get("tabs") == []
        return {"passed": True, "scope": "Actual own native WebView and loopback page only",
                "operations": receipts, "externalNetwork": False, "tabsClosed": True}
    finally:
        # Actual server thread return is required. No detached server or forced
        # child termination can substitute for a completed browser result.
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)
        assert not worker.is_alive(), "Owned HTTP fixture has not returned"
