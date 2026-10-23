"""Private offline app-server peer; its only writes are inside its fixture worktree."""
import json
import os
from pathlib import Path
import signal
import sqlite3
import sys
import time

root = Path(sys.argv[1]).resolve(strict=True)
workspace = root / "isolated"
assert root.name.startswith("coincide-remote-checkpoint-") and os.stat(root).st_mode & 0o077 == 0
assert Path.cwd().resolve() == workspace and Path(os.environ["CODEX_HOME"]).resolve() == root / "codex-home"
assert sys.argv[2:] == ["app-server", "--stdio"]
wire = root / "provider-wire.jsonl"
os.umask(0o077)


def record(kind, **fields):
    data = (json.dumps({"kind": kind, "pid": os.getpid(), **fields}) + "\n").encode()
    fd = os.open(wire, os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        assert os.write(fd, data) == len(data)
    finally:
        os.close(fd)


def emit(value):
    print(json.dumps(value), flush=True)


def notify(method, **fields):
    emit({"method": method, "params": {"threadId": "checkpoint-offline-thread", **fields}})


exited = False


def record_exit(reason):
    global exited
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
    try:
        if not exited:
            record("exit", reason=reason)
            exited = True
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def terminated(_signal, _frame):
    record_exit("owned-signal")
    raise SystemExit(0)


signal.signal(signal.SIGTERM, terminated)
record("launch")
try:
    for line in sys.stdin:
        frame = json.loads(line)
        method, ident, params = frame.get("method"), frame.get("id"), frame.get("params", {})
        if method == "initialize":
            emit({"id": ident, "result": {"userAgent": "checkpoint-private-offline/1"}})
        elif method == "initialized":
            assert ident is None
        elif method in ("thread/start", "thread/resume"):
            assert Path(params["cwd"]).resolve(strict=True) == workspace
            emit({"id": ident, "result": {"thread": {"id": "checkpoint-offline-thread"}}})
        elif method == "turn/start":
            assert Path(params["cwd"]).resolve(strict=True) == workspace
            assert params["model"] == "checkpoint-offline"
            assert params["approvalPolicy"] == "on-request" and params["sandboxPolicy"]["type"] == "readOnly"
            text = params["input"][0]["text"]
            assert text in ("Capture private files", "Queued private successor")
            first = text == "Capture private files"
            if first:
                with sqlite3.connect((root / "data/workspace.sqlite").as_uri() + "?mode=ro", uri=True) as db:
                    snapshot = json.loads(db.execute("SELECT payload FROM workspace WHERE id=1").fetchone()[0])
                # The host may serialize /var while Python resolves /private/var.
                # This private host-side fixture checks actual cwd ownership;
                # production client paths remain compared as exact remote bytes.
                owner = next(t for t in snapshot["threads"] if Path(t["workspacePath"]).resolve(strict=True) == workspace)
                records = [r for r in owner.get("runHistory", []) if r.get("checkpoints", {}).get("baseline", {}).get("phase") == "ready"]
                assert len(records) == 1 and records[0]["checkpoints"]["baseline"]["receipt"]
                record("baseline-ready", runID=records[0]["id"])
            record("turn-start", first=first)
            turn = "checkpoint-turn-1" if first else "checkpoint-turn-2"
            emit({"id": ident, "result": {"turn": {"id": turn}}})
            notify("turn/started", turn={"id": turn})
            if first:
                (workspace / "tracked.txt").write_text("Provider changed 🌍\n")
                (workspace / "provider-created.txt").write_text("Private untracked output\n")
                record("files-written")
                deadline = time.monotonic() + 10
                while not (root / "complete-first").exists():
                    assert time.monotonic() < deadline
                    time.sleep(.005)
                if (root / "fail-post-run").exists():
                    (root / "fail-next-write-tree").write_bytes(b"private failure")
            notify("item/completed", turnId=turn, item={"id": turn + "-message", "type": "agentMessage", "text": "Private checkpoint completion"})
            notify("turn/completed", turn={"id": turn, "status": "completed"})
        else:
            raise AssertionError("Unexpected private checkpoint provider method")
    record_exit("stdin-eof")
except BrokenPipeError:
    record_exit("owned-output-closed")
except Exception as error:
    record("fixture-error", errorType=type(error).__name__)
    record_exit("fixture-error")
    raise
