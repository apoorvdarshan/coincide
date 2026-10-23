"""Private local-only Codex peer proving queued input uses the ready worktree."""
import json
import os
from pathlib import Path
import signal
import sys

root = Path(sys.argv[1]).resolve(strict=True)
assert root.name.startswith("coincide-remote-worktree-")
assert os.stat(root).st_mode & 0o077 == 0
wire = root / "provider-wire.jsonl"


def record(kind, **fields):
    data = (json.dumps({"kind": kind, "pid": os.getpid(), **fields}, ensure_ascii=False) + "\n").encode()
    fd = os.open(wire, os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        assert os.write(fd, data) == len(data)
    finally:
        os.close(fd)


def emit(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def notify(method, **fields):
    emit({"method": method, "params": {"threadId": "worktree-offline-thread", **fields}})


def stop(*_):
    record("exit")
    raise SystemExit(0)


signal.signal(signal.SIGTERM, stop)
record("launch", cwd=os.getcwd())
expected = Path((root / "expected-provider-workspace").read_text()).resolve(strict=True)
assert Path.cwd().resolve(strict=True) == expected
assert Path(os.environ["CODEX_HOME"]).resolve(strict=True) == root / "codex-home"
assert sys.argv[2:] == ["app-server", "--stdio"]
for line in sys.stdin:
    frame = json.loads(line)
    method, ident, params = frame.get("method"), frame.get("id"), frame.get("params", {})
    if method == "initialize":
        assert params["clientInfo"]["name"] == "coincide"
        emit({"id": ident, "result": {"userAgent": "private-worktree-peer/1"}})
    elif method == "initialized":
        assert ident is None
    elif method == "thread/start":
        assert Path(params["cwd"]).resolve(strict=True) == expected
        emit({"id": ident, "result": {"thread": {"id": "worktree-offline-thread"}}})
    elif method == "turn/start":
        assert params["threadId"] == "worktree-offline-thread"
        assert Path(params["cwd"]).resolve(strict=True) == expected
        assert params["model"] == "remote-worktree-offline"
        assert params["approvalPolicy"] == "on-request" and params["sandboxPolicy"]["type"] == "readOnly"
        assert params["input"] == [{"type": "text", "text": "Remote worktree queued input"}]
        record("turn", cwd=str(expected))
        emit({"id": ident, "result": {"turn": {"id": "worktree-offline-turn"}}})
        notify("turn/started", turn={"id": "worktree-offline-turn"})
        notify("item/started", turnId="worktree-offline-turn", item={"id": "worktree-offline-message", "type": "agentMessage", "text": ""})
        notify("item/agentMessage/delta", turnId="worktree-offline-turn", itemId="worktree-offline-message", delta="READY_WORKTREE_✓")
        notify("item/completed", turnId="worktree-offline-turn", item={"id": "worktree-offline-message", "type": "agentMessage", "text": "READY_WORKTREE_✓"})
        notify("turn/completed", turn={"id": "worktree-offline-turn", "status": "completed"})
    else:
        raise AssertionError("Unexpected private worktree provider frame")
record("exit")
