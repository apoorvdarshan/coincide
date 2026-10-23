"""Own one real helper; drop one committed response without replaying a request."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

root = Path(sys.argv[1]).resolve(strict=True)
assert root.name.startswith("coincide-remote-attachment-") and os.stat(root).st_mode & 0o077 == 0
method_to_drop, exact_id, wait_for_turn, helper = sys.argv[2:6]
assert method_to_drop in ("remoteEnvironment.attachment.finalize", "remoteEnvironment.command")
assert wait_for_turn in ("yes", "no")
assert Path(helper).resolve(strict=True) == root / "native-host"
child = subprocess.Popen([helper, *sys.argv[6:]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
(root / "proxy-pids.txt").open("a").write(str(os.getpid()) + "\n")
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


def contains_exact_id(value):
    if isinstance(value, dict):
        return any((key == "id" and isinstance(item, str) and item.lower() == exact_id.lower()) or contains_exact_id(item) for key, item in value.items())
    return isinstance(value, list) and any(contains_exact_id(item) for item in value)


def input_pump():
    global reply_id
    try:
        for line in sys.stdin.buffer:
            frame = json.loads(line)
            if frame.get("method") == method_to_drop and contains_exact_id(frame.get("params", {})):
                with state_lock:
                    assert reply_id is None
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


def errors():
    data = child.stderr.read(65536)
    if data:
        fd = os.open(root / "native-host-stderr.txt", os.O_CREAT | os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)


def after_delivery():
    if wait_for_turn == "yes":
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                if any(json.loads(row).get("kind") == "turn" for row in (root / "provider-wire.jsonl").read_text().splitlines()):
                    break
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(.005)
    close_input()


signal.signal(signal.SIGTERM, close_input)
threading.Thread(target=input_pump, daemon=True).start()
threading.Thread(target=errors, daemon=True).start()
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
            threading.Thread(target=after_delivery, daemon=True).start()
            continue
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
    os._exit(status if status >= 0 else 128 - status)
