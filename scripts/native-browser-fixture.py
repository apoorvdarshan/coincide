#!/usr/bin/env python3
"""Actual native WebView workflow against an owned loopback HTTP fixture.

Imported by isolated native CI smoke only. No external URL, saved login, cookie,
password, upload, screenshot or arbitrary-script tool command is used.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import threading
import time
import uuid


def exercise_browser(rpc, thread_id, capture_visible):
    assert os.environ.get("GITHUB_ACTIONS") == "true", "Fresh native CI runner only"
    marker = "NativeBrowserReady" + uuid.uuid4().hex
    text = "Native browser input café Ω"
    http_requests = []
    http_timing = []
    started = time.monotonic()
    class Page(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(2)
        def log_message(self, *_args):
            pass
        def log_error(self, message, *args):
            # Includes speculative or idle WebView connections ending at the 2 s limit.
            if len(http_timing) < 128:
                http_timing.append(["error: " + (message % args)[:80], round(time.monotonic() - started, 3)])
        def do_GET(self):
            if len(http_requests) < 64:
                http_requests.append(self.path[:200])
            if len(http_timing) < 128:
                http_timing.append([self.path[:200], round(time.monotonic() - started, 3)])
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
    class OwnedServer(ThreadingHTTPServer):
        # A single serving thread stalls every page request behind an idle or
        # speculative WebView connection until its socket timeout. Requests run
        # concurrently on non-daemon threads that server_close() joins.
        daemon_threads = False
        block_on_close = True
    server = OwnedServer(("127.0.0.1", 0), Page)
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
        import importlib.util
        from pathlib import Path
        spec = importlib.util.spec_from_file_location("owned_native_dialog_fixture", Path(__file__).with_name("test-rust-native-browser-dialogs.py"))
        dialogs = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(dialogs)
        dialog_report = dialogs.exercise_dialogs(rpc, thread_id)
        assert dialog_report["passed"]
        assert request("tabs").get("tabs") == [], "Dialog fixture must close every created tab"
        spec = importlib.util.spec_from_file_location("owned_native_key_fixture", Path(__file__).with_name("test-rust-native-browser-keys.py"))
        keys = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(keys)
        key_report = keys.exercise_keys(rpc, thread_id)
        assert key_report["passed"]
        assert request("tabs").get("tabs") == [], "Key fixture must close every created tab"
        return {"passed": True, "scope": "Actual own native WebView and loopback page only",
                "operations": receipts, "externalNetwork": False, "tabsClosed": True,
                "nativeDialogs": dialog_report, "nativeKeys": key_report}
    except BaseException as error:
        # Diagnose the same failed operation without navigation, repeated input
        # or a changed deadline. These are only this fixture's private pages.
        diagnostics = {"httpRequests": list(http_requests), "httpTiming": list(http_timing),
                       "failedAfterSeconds": round(time.monotonic() - started, 3)}
        for action in ("tabs", "read", "console"):
            try:
                diagnostics[action] = request(action, tabs[0] if tabs else None)
            except Exception as diagnostic:
                diagnostics[action + "Error"] = str(diagnostic)[:2000]
        error.native_browser_diagnostics = diagnostics
        raise
    finally:
        # Actual server thread return is required. No detached server or forced
        # child termination can substitute for a completed browser result.
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)
        assert not worker.is_alive(), "Owned HTTP fixture has not returned"


def main():
    """Windows native smoke uses its existing owner-aware CLI, with fresh env."""
    import argparse
    from pathlib import Path
    import subprocess
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client", type=Path, required=True)
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--thread", required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--capture-ready", type=Path, required=True)
    parser.add_argument("--capture-ack", type=Path, required=True)
    args = parser.parse_args()
    assert os.environ.get("GITHUB_ACTIONS") == "true", "Fresh CI runner only"
    client = args.client.resolve(strict=True)
    data = args.data_dir.resolve(strict=True)
    environment = {key: os.environ[key] for key in ("SystemRoot", "WINDIR", "TEMP", "TMP", "HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA") if key in os.environ}
    environment["COINCIDE_RUST_DATA_DIR"] = str(data)
    def rpc(method, **params):
        process = subprocess.Popen([str(client), "api"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, encoding="utf-8", env=environment)
        # Popen.communicate does not terminate a timed-out child. A failure
        # retains the fixture instead of reporting a semantic cleanup as return.
        try:
            stdout, stderr = process.communicate(json.dumps(dict(id=1, method=method, params=params)) + "\n", timeout=15)
        finally:
            if process.poll() is None:
                # Keep the helper as the real client owner on uncertain return.
                # Its native parent records the deadline failure and retains
                # the private fixture; no detached child can count as cleanup.
                process.wait()
        assert process.returncode == 0, "Owned control client failed: " + method
        response = json.loads(stdout)
        assert "error" not in response, (method, response.get("error"))
        return response["result"]
    def capture_visible():
        nonce = uuid.uuid4().hex
        args.capture_ready.write_text(nonce)
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            if args.capture_ack.exists() and args.capture_ack.read_text() == nonce:
                return
            time.sleep(.05)
        raise AssertionError("Native parent did not acknowledge its actual browser capture")
    try:
        report = exercise_browser(rpc, args.thread, capture_visible)
        args.report.write_text(json.dumps(report, indent=2))
    except BaseException as error:
        args.report.write_text(json.dumps({"passed": False, "error": str(error)[:2000],
            "nativeBrowserFailure": getattr(error, "native_browser_diagnostics", None)}, indent=2))
        raise


if __name__ == "__main__":
    main()
