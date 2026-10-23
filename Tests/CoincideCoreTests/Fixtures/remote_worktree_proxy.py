"""Owned native-helper forwarder dropping one durable worktree command reply."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

root = Path(sys.argv[1]).resolve(strict=True)
dropped, helper = sys.argv[2:4]
assert root.name.startswith("coincide-remote-worktree-") and os.stat(root).st_mode & 0o077 == 0
assert Path(helper).resolve(strict=True) == root / "native-host"
with (root / "proxy-pids.txt").open("a") as out:
    out.write(str(os.getpid()) + "\n")
child = subprocess.Popen([helper, *sys.argv[4:]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
lock = threading.RLock()
reply = None
closed = False


def close_input():
    global closed
    with lock:
        if not closed:
            closed = True
            child.stdin.close()


def input_pump():
    global reply
    try:
        for line in sys.stdin.buffer:
            frame = json.loads(line)
            with lock:
                if frame.get("method") == "remoteEnvironment.command" and frame.get("params", {}).get("id", "").lower() == dropped.lower():
                    reply = frame["id"]
                if closed:
                    return
                child.stdin.write(line)
                child.stdin.flush()
    except (BrokenPipeError, ValueError):
        pass
    finally:
        close_input()


signal.signal(signal.SIGTERM, lambda *_: close_input())
threading.Thread(target=input_pump, daemon=True).start()
try:
    for line in child.stdout:
        frame = json.loads(line)
        with lock:
            selected = reply
        if selected is not None and frame.get("id") == selected:
            assert "result" in frame and "error" not in frame
            fd = os.open(root / "dropped-worktree-reply.json", os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            try:
                os.write(fd, line)
            finally:
                os.close(fd)
            # Hold actual Git at its private checkout hook before terminating
            # this owned helper. No response or command is fabricated/replayed.
            end = time.monotonic() + 5
            while not (root / "hook-entries.jsonl").exists() and time.monotonic() < end:
                time.sleep(.005)
            close_input()
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
