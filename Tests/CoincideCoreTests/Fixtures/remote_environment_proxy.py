"""Task-owned byte forwarder: real native host, one dropped reply or bad version."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

root = Path(sys.argv[1]).resolve(strict=True)
assert root.name.startswith("coincide-remote-acceptance-") and os.stat(root).st_mode & 0o077 == 0
mode, dropped_id, helper = sys.argv[2:5]
assert mode in ("drop-command-response", "wrong-protocol", "sequence-regression")
assert Path(helper).resolve(strict=True) == root / "native-host"
child = subprocess.Popen([helper, *sys.argv[5:]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
write_lock = threading.RLock()
state_lock = threading.Lock()
reply_id = None
closed = False


def close_input():
    global closed
    with write_lock:
        if not closed:
            closed = True
            child.stdin.close()


def forward_input():
    global reply_id
    try:
        for line in sys.stdin.buffer:
            frame = json.loads(line)
            if mode == "drop-command-response" and frame.get("method") == "remoteEnvironment.command" and frame.get("params", {}).get("id", "").lower() == dropped_id.lower():
                with state_lock:
                    reply_id = frame["id"]
            with write_lock:
                if closed:
                    return
                child.stdin.write(line)
                child.stdin.flush()
    except (BrokenPipeError, ValueError):
        pass
    finally:
        close_input()


def drain_errors():
    # Retain bounded synthetic diagnostics without contaminating protocol stdout.
    data = child.stderr.read(65536)
    if data:
        path = root / "native-host-stderr.txt"
        fd = os.open(path, os.O_CREAT | os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)


def close_after_native_delivery():
    deadline = time.monotonic() + 5
    wire = root / "provider-wire.jsonl"
    while time.monotonic() < deadline:
        try:
            if any(json.loads(line).get("kind") == "turn-start" for line in wire.read_text().splitlines()):
                close_input()
                return
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.005)
    close_input()


signal.signal(signal.SIGTERM, lambda *_: close_input())
threading.Thread(target=forward_input, daemon=True).start()
threading.Thread(target=drain_errors, daemon=True).start()
try:
    for line in child.stdout:
        frame = json.loads(line)
        with state_lock:
            target = reply_id
        if mode == "drop-command-response" and target is not None and frame.get("id") == target:
            assert "result" in frame and "error" not in frame
            path = root / "dropped-command-response.json"
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            try:
                os.write(fd, line)
            finally:
                os.close(fd)
            threading.Thread(target=close_after_native_delivery, daemon=True).start()
            continue
        if mode == "wrong-protocol" and isinstance(frame.get("result"), dict) and "protocolVersion" in frame["result"]:
            frame["result"]["protocolVersion"] = 999
            line = (json.dumps(frame) + "\n").encode()
        if mode == "sequence-regression":
            value = frame.get("result") if "result" in frame else frame.get("params")
            if isinstance(value, dict) and "workspace" in value and "sequence" in value:
                value["sequence"] = 0
                line = (json.dumps(frame) + "\n").encode()
        sys.stdout.buffer.write(line)
        sys.stdout.buffer.flush()
finally:
    close_input()
    try:
        status = child.wait(timeout=8)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
        status = 79
    # A daemon input pump may still await the client's stdin; only the owned
    # proxy ends here, after its native child has exited and been reaped.
    os._exit(status if status >= 0 else 128 - status)
