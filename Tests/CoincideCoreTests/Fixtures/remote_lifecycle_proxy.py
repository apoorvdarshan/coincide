"""Drop exactly one committed lifecycle reply; close and join only our host."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading

root = Path(sys.argv[1]).resolve(strict=True)
assert root.name.startswith("coincide-remote-history-") and os.stat(root).st_mode & 0o077 == 0
command_id, helper = sys.argv[2:4]
assert Path(helper).resolve(strict=True) == root / "native-host"
child = subprocess.Popen([helper, *sys.argv[4:]], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
with (root / "proxy-pids.txt").open("a") as output:
    output.write(str(os.getpid()) + "\n")
write_lock = threading.Lock()
state_lock = threading.Lock()
reply_id = None
closed = False


def close_input(*_):
    global closed
    with write_lock:
        if not closed:
            closed = True
            child.stdin.close()


def pump_input():
    global reply_id
    try:
        for line in sys.stdin.buffer:
            frame = json.loads(line)
            if (frame.get("method") == "remoteEnvironment.command"
                    and frame.get("params", {}).get("id", "").lower() == command_id.lower()):
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


signal.signal(signal.SIGTERM, close_input)
threading.Thread(target=pump_input, daemon=True).start()
try:
    for line in child.stdout:
        frame = json.loads(line)
        with state_lock:
            target = reply_id
        if target is not None and frame.get("id") == target:
            assert "result" in frame and "error" not in frame
            receipt = frame["result"]["receipt"]
            assert receipt["commandID"].lower() == command_id.lower() and receipt.get("rejection") is None
            # Record only receipt identity/sequence, never configuration or input.
            fd = os.open(root / "lifecycle-dropped-receipt.json", os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            try:
                os.write(fd, json.dumps({"commandID": command_id, "sequence": receipt["sequence"]}).encode())
            finally:
                os.close(fd)
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
