"""Persistent, private native-history peer; no network or installed Codex state."""
import json
import os
from pathlib import Path
import signal
import sys
import time

root = Path(sys.argv[1]).resolve(strict=True)
assert root.name.startswith("coincide-remote-history-") and os.stat(root).st_mode & 0o077 == 0
workspace = root / "isolated"
assert Path.cwd().resolve() == workspace
assert Path(os.environ["CODEX_HOME"]).resolve() == root / "codex-home"
assert sys.argv[2:] == ["app-server", "--stdio"]
os.umask(0o077)
wire = root / "codex-wire.jsonl"
native_path = root / "native-state.json"


def record(kind, **fields):
    data = (json.dumps({"kind": kind, "pid": os.getpid(), **fields}) + "\n").encode()
    fd = os.open(wire, os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        assert os.write(fd, data) == len(data)
    finally:
        os.close(fd)


def emit(frame):
    print(json.dumps(frame), flush=True)


def state():
    return json.loads(native_path.read_text())


def save(value):
    temporary = root / (".native-state-" + str(os.getpid()))
    fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        data = json.dumps(value, sort_keys=True).encode()
        assert os.write(fd, data) == len(data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(temporary, native_path)


def thread(identifier, value):
    entry = value["threads"][identifier]
    return {"id": identifier, "cwd": str(workspace), "historyMode": "paginated", "status": {"type": "idle"},
            "forkedFromId": entry.get("source"), "turns": [{"id": x, "status": "completed", "items": []} for x in entry["turns"]]}


exited = False


def finish(reason):
    global exited
    old = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
    try:
        if not exited:
            record("exit", reason=reason)
            exited = True
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, old)


def terminated(_signal, _frame):
    finish("owned-signal")
    raise SystemExit(0)


signal.signal(signal.SIGTERM, terminated)
record("launch")
try:
    for line in sys.stdin:
        frame = json.loads(line)
        method, ident, params = frame.get("method"), frame.get("id"), frame.get("params", {})
        record("method", method=method)
        if method == "initialized":
            assert ident is None
            continue
        if method == "initialize":
            result = {"userAgent": "coincide/0.163.0 (macos; arm64)"}
        elif method == "thread/goal/get":
            result = {"goal": None}
        elif method in ("thread/read", "thread/resume"):
            result = {"thread": thread(params["threadId"], state()), "readState": None}
        elif method == "thread/turns/list":
            assert params["sortDirection"] == "desc" and params["itemsView"] == "summary"
            turns = list(reversed(state()["threads"][params["threadId"]]["turns"]))
            offset = int(params.get("cursor", "offset:0").removeprefix("offset:"))
            limit = params["limit"]
            selected = turns[offset:offset + limit]
            result = {"data": [{"id": x, "status": "completed"} for x in selected],
                      "nextCursor": "offset:" + str(offset + limit) if offset + limit < len(turns) else None, "backwardsCursor": None}
        elif method in ("thread/fork", "thread/revert"):
            value = state(); settings = json.loads((root / "settings.json").read_text())
            source = params["threadId"]; turns = value["threads"][source]["turns"]
            boundary = params.get("lastTurnId") or params.get("beforeTurnId")
            assert boundary in turns
            keep = turns.index(boundary) + (1 if "lastTurnId" in params else 0)
            if settings.get("holdMutation"):
                (root / "mutation-entered").write_bytes(b"")
                deadline = time.monotonic() + 15
                while not (root / "release-mutation").exists():
                    assert time.monotonic() < deadline
                    time.sleep(.005)
            record("mutation-request", method=method)
            outcome = settings.get("outcome", "ack")
            if outcome == "lost-before":
                finish("lost-before")
                break
            target = "native-fork" if method == "thread/fork" else source
            value["threads"][target] = {"turns": turns[:keep], "source": source if method == "thread/fork" else None}
            value["writes"][method] = value["writes"].get(method, 0) + 1
            save(value); record("mutation-committed", method=method)
            if outcome == "lost-after":
                finish("lost-after")
                break
            result = {"thread": thread(target, value)}
        else:
            raise AssertionError("Unexpected private native history method")
        emit({"id": ident, "result": result})
    finish("stdin-eof")
except BrokenPipeError:
    finish("owned-output-closed")
except Exception as error:
    record("fixture-error", errorType=type(error).__name__)
    finish("fixture-error")
    raise
