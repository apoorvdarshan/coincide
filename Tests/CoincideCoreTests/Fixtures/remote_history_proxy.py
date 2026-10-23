"""Drop one actual native command receipt, then join that owned helper on EOF."""
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import threading
import time

root = Path(sys.argv[1]).resolve(strict=True)
assert root.name.startswith("coincide-remote-history-") and os.stat(root).st_mode & 0o077 == 0
command_id, helper = sys.argv[2:4]
assert Path(helper).resolve(strict=True) == root / "native-host"
child = subprocess.Popen([helper, *sys.argv[4:]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
with (root / "proxy-pids.txt").open("a") as out:
    out.write(str(os.getpid()) + "\n")
write_lock = threading.RLock()
state_lock = threading.Lock()
reply_id = None
closed = False


def close_input(*_):
    global closed
    with write_lock:
        if not closed:
            closed = True
            child.stdin.close()


def input_pump():
    global reply_id
    try:
        for line in sys.stdin.buffer:
            frame = json.loads(line)
            if frame.get("method") == "remoteEnvironment.command" and frame.get("params", {}).get("id", "").lower() == command_id.lower():
                with state_lock:
                    assert reply_id is None
                    reply_id = frame["id"]
            with write_lock:
                if closed:
                    return
                child.stdin.write(line); child.stdin.flush()
    except (BrokenPipeError, ValueError):
        pass
    finally:
        close_input()


def drain_errors():
    data = child.stderr.read(65536)
    if data:
        fd = os.open(root / "native-stderr.txt", os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)


def close_after_durable_history():
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        try:
            with sqlite3.connect((root / "data/workspace.sqlite").as_uri() + "?mode=ro", uri=True) as db:
                snapshot = json.loads(db.execute("SELECT payload FROM workspace WHERE id=1").fetchone()[0])
            if any(item["phase"] in ("applied", "unconfirmed", "failed") for item in snapshot.get("conversationHistoryOperations", [])):
                break
        except (FileNotFoundError, KeyError, json.JSONDecodeError, sqlite3.Error):
            pass
        time.sleep(.005)
    close_input()


signal.signal(signal.SIGTERM, close_input)
threading.Thread(target=input_pump, daemon=True).start()
threading.Thread(target=drain_errors, daemon=True).start()
try:
    for line in child.stdout:
        frame = json.loads(line)
        with state_lock:
            target = reply_id
        if target is not None and frame.get("id") == target:
            assert "result" in frame and "error" not in frame
            fd = os.open(root / "dropped-response.json", os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            try:
                os.write(fd, line)
            finally:
                os.close(fd)
            threading.Thread(target=close_after_durable_history, daemon=True).start()
            continue
        sys.stdout.buffer.write(line); sys.stdout.buffer.flush()
finally:
    close_input()
    try:
        status = child.wait(timeout=8)
    except subprocess.TimeoutExpired:
        child.kill(); child.wait(); status = 79
    os._exit(status if status >= 0 else 128 - status)
