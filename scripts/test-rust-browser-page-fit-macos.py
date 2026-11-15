#!/usr/bin/env python3
"""Check the production first-paint script in an isolated, windowless WKWebView."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile
from threading import Thread
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parents[1]


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        index = parse_qs(urlsplit(self.path).query).get("fixture", [""])[0]
        if index not in {"0", "1", "2"}:
            self.send_error(404)
            return
        content = "<div>Responsive content</div>" if index == "1" else "<table width='1000'><tr><td>Wide content</td></tr></table>"
        policy = "<meta http-equiv='Content-Security-Policy' content=\"style-src 'none'\">" if index == "2" else ""
        language = json.dumps(self.headers.get("Accept-Language", ""))
        body = ("<!doctype html><html><head>" + policy + "</head><body><input id='owned'><script>"
                "document.getElementById('owned').focus();window.firstFocus=document.activeElement.id;"
                "window.firstOpacity=getComputedStyle(document.documentElement).opacity;"
                "window.headerLanguage=" + language + ";</script>" + content + "</body></html>").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    if sys.platform != "darwin":
        raise SystemExit("This fixture needs macOS WebKit")
    source = (ROOT / "crates/coincide-desktop/src/browser_page_fit.rs").read_text()
    match = re.search(r'pub\(crate\) const WIDTH_SCRIPT: &str = r#"([\s\S]*?)"#;', source)
    if match is None:
        raise SystemExit("Production fit script is missing")
    with tempfile.TemporaryDirectory(prefix="coincide-webkit-fit-") as temporary:
        folder = Path(temporary)
        script = folder / "fit.js"
        executable = folder / "fit-probe"
        script.write_text(match.group(1))
        subprocess.run(["clang", "-fobjc-arc", "-framework", "Cocoa", "-framework", "WebKit",
                        "-o", str(executable), str(ROOT / "scripts/test-rust-browser-page-fit-macos.m")], check=True)
        server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        Thread(target=server.serve_forever, daemon=True).start()
        try:
            # The argument domain is local to this process; macOS settings and
            # the user's real browser profile remain untouched.
            subprocess.run([str(executable), str(script), f"http://127.0.0.1:{server.server_port}",
                            "fr-CA", "-AppleLanguages", "(fr-CA,en-US)"], check=True, timeout=30)
        finally:
            server.shutdown()
            server.server_close()
    print("PASS: native first paint, navigation fit, CSP and preferred language")


if __name__ == "__main__":
    main()
