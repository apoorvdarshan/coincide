#!/usr/bin/env python3
"""Drive a disposable UI-testing Coincide build only through the `coincide` CLI.

Covers what the click-based UI tests do not: sending from the CLI without
touching the draft, Markdown/JSON export, and manual context compaction followed
by another turn. It launches a GUI app, so it runs only on GitHub Actions unless
--allow-local is passed. The provider is an offline Codex peer.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
CLI = HERE.parents[1] / "script/coincide"
TEST_BUNDLE_ID = "com.apoorvdarshan.coincide.uitesting"


def stage(source, scratch):
    """Copy the verified app as the UI-testing bundle, which never handles real links."""
    staged = scratch / "CoincideCLITestApp.app"
    subprocess.run(["/usr/bin/ditto", str(source), str(staged)], check=True)
    info_path = staged / "Contents/Info.plist"
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != "com.apoorvdarshan.coincide":
        raise SystemExit("The source must be the verified SwiftPM Coincide app.")
    info["CFBundleIdentifier"] = TEST_BUNDLE_ID
    info.pop("CFBundleURLTypes", None)
    with info_path.open("wb") as stream:
        plistlib.dump(info, stream)
    subprocess.run(["codesign", "--force", "--sign", "-", str(staged)], check=True)
    return staged


def install_codex(scratch):
    bin_dir = scratch / "bin"
    bin_dir.mkdir(mode=0o700)
    codex = bin_dir / "codex"
    codex.write_text(f'#!/bin/sh\nexec "{sys.executable}" -I "{HERE / "cli_e2e_codex.py"}" "{scratch / "codex-state.json"}" "$@"\n')
    codex.chmod(0o700)
    return bin_dir


class Coincide:
    def __init__(self, control):
        self.env = dict(os.environ, COINCIDE_CONTROL_DIR=str(control))

    def __call__(self, *arguments, ok=True):
        result = subprocess.run([sys.executable, str(CLI), *map(str, arguments)], env=self.env,
                                capture_output=True, text=True, timeout=60)
        if ok and result.returncode != 0:
            raise AssertionError(f"coincide {arguments[0]} failed: {result.stderr.strip()}")
        return json.loads(result.stdout) if result.returncode == 0 else result


def eventually(check, what, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.25)
    raise AssertionError("Timed out waiting for " + what)


def run(app_source):
    scratch = Path(tempfile.mkdtemp(prefix="coincide-ui-testing-")).resolve()
    scratch.chmod(0o700)
    process = None
    try:
        app = stage(app_source, scratch)
        project = scratch / "CLI project"
        project.mkdir()
        (project / "README.md").write_text("CLI end-to-end fixture\n")
        environment = dict(os.environ, COINCIDE_UI_TESTING="1", COINCIDE_UI_TEST_ROOT=str(scratch),
                           CODEX_HOME=str(scratch / "codex-home"),
                           PATH=str(install_codex(scratch)) + ":/usr/bin:/bin:/usr/sbin:/sbin")
        (scratch / "codex-home").mkdir(mode=0o700)
        process = subprocess.Popen([str(app / "Contents/MacOS/Coincide")], env=environment,
                                   stdout=subprocess.DEVNULL, stderr=open(scratch / "app.log", "w"))
        control = scratch / "Control"
        eventually(lambda: (control / "connection.json").exists() or process.poll() is not None, "the CLI connection", 60)
        assert process.poll() is None, "The app exited during launch:\n" + (scratch / "app.log").read_text()[-4000:]
        coincide = Coincide(control)

        created = coincide("new", project)
        thread = created["threadId"]
        assert created["sent"] is False

        refused = coincide("send", "/app:new", "--thread", thread, "--confirm", ok=False)
        assert refused.returncode != 0, "App commands must never be sent to an agent."

        sent = coincide("send", "Hello from the CLI", "--thread", thread, "--confirm")
        assert sent["sent"] is True and sent["draftUnchanged"] is True and sent["thread"]["provider"] == "codex"

        def replies(count):
            messages = coincide("thread", thread)["messages"]
            texts = [m["text"] for m in messages if m["role"] == "assistant"]
            return texts if len(texts) >= count else None
        assert eventually(lambda: replies(1), "the first reply") == ["Offline CLI reply 1"]

        for fmt in ("markdown", "json"):
            path = scratch / f"export.{fmt}"
            exported = coincide("export", path, "--format", fmt, "--thread", thread)
            text = path.read_text()
            assert exported["messageCount"] == 2 and "Hello from the CLI" in text and "Offline CLI reply 1" in text
            if fmt == "json":
                json.loads(text)
            refused = coincide("export", path, "--format", fmt, "--thread", thread, ok=False)
            assert refused.returncode != 0, "Export must never overwrite an existing file."

        assert coincide("compaction", "--thread", thread)["available"] is True
        accepted = coincide("compact", "--thread", thread, "--confirm")
        assert accepted["requestAccepted"] is True
        phase = eventually(lambda: (coincide("compaction", "--thread", thread)["operation"] or {}).get("phase")
                           in ("completed", "failed", "unconfirmed")
                           and coincide("compaction", "--thread", thread)["operation"]["phase"], "compaction")
        assert phase == "completed", "Compaction finished as " + phase

        coincide("send", "Still here after compaction?", "--thread", thread, "--confirm")
        assert eventually(lambda: replies(2), "the reply after compaction")[-1] == "Offline CLI reply 2"
        state = json.loads((scratch / "codex-state.json").read_text())
        assert state["compactions"] == 1 and state["turns"] == 2
        print("CLI end-to-end check passed: send, export, compaction and a follow-up turn.")
    finally:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
        log = scratch / "app.log"
        if log.exists() and os.environ.get("GITHUB_ACTIONS") == "true":
            print(log.read_text()[-4000:], file=sys.stderr)
        shutil.rmtree(scratch, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="The verified SwiftPM Coincide.app")
    parser.add_argument("--allow-local", action="store_true", help="Run outside GitHub Actions (opens an app window)")
    options = parser.parse_args()
    if os.environ.get("GITHUB_ACTIONS") != "true" and not options.allow_local:
        raise SystemExit("This check opens a GUI app; it runs on GitHub Actions. Pass --allow-local to run it here.")
    run(options.app.resolve())


if __name__ == "__main__":
    main()
