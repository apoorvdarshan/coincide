"""Strict offline Codex app-server peer for real remote-host acceptance only."""
import json
import os
from pathlib import Path
import signal
import sys

root = Path(sys.argv[1]).resolve(strict=True)
workspace = root / "workspace"
assert root.name.startswith("coincide-remote-acceptance-")
assert os.stat(root).st_mode & 0o077 == 0
wire = root / "provider-wire.jsonl"


def record(kind, **fields):
    data = (json.dumps({"kind": kind, "pid": os.getpid(), **fields}, ensure_ascii=False) + "\n").encode()
    fd = os.open(wire, os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        assert os.write(fd, data) == len(data)
    finally:
        os.close(fd)


def emit(frame):
    # Exercise real framing across both JSON and multibyte UTF-8 boundaries.
    data = (json.dumps(frame, ensure_ascii=False) + "\n").encode()
    boundary = data.find("🌍".encode())
    split = boundary + 1 if boundary >= 0 else min(7, len(data))
    for chunk in (data[:split], data[split:]):
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()


def notify(method, **fields):
    emit({"method": method, "params": {"threadId": "remote-native-thread", **fields}})


exit_recorded = False


def record_exit(reason):
    global exit_recorded
    if not exit_recorded:
        exit_recorded = True
        record("exit", reason=reason)


def terminated(_signal, _frame):
    record_exit("owned-signal")
    raise SystemExit(0)


signal.signal(signal.SIGTERM, terminated)
record("launch", cwd=os.getcwd(), arguments=sys.argv[2:], codexHome=os.environ.get("CODEX_HOME"))
assert Path.cwd().resolve() == workspace
assert Path(os.environ["CODEX_HOME"]).resolve() == root / "codex-home"
assert sys.argv[2:] == ["app-server", "--stdio"]
active = None
try:
    for line in sys.stdin:
        frame = json.loads(line)
        method, ident, params = frame.get("method"), frame.get("id"), frame.get("params", {})
        record("frame", frame=frame)
        if method == "initialize":
            assert params["clientInfo"]["name"] == "coincide"
            emit({"id": ident, "result": {"userAgent": "remote-offline-fixture/1"}})
        elif method == "initialized":
            assert ident is None
        elif method in ("thread/start", "thread/resume"):
            assert Path(params["cwd"]).resolve(strict=True) == workspace
            if method == "thread/resume":
                assert params["threadId"] == "remote-native-thread"
            emit({"id": ident, "result": {"thread": {"id": "remote-native-thread"}}})
        elif method == "turn/start":
            assert active is None
            assert params["threadId"] == "remote-native-thread" and Path(params["cwd"]).resolve(strict=True) == workspace
            assert params["approvalPolicy"] == "on-request" and params["sandboxPolicy"]["type"] == "readOnly"
            assert params["model"] == "remote-offline"
            assert len(params["input"]) == 1 and params["input"][0]["type"] == "text"
            text = params["input"][0]["text"]
            assert text in ("Approve this remote prompt", "Hold for exact remote stop", "Remote prompt with dropped reply")
            prior = sum(json.loads(row).get("kind") == "turn-start" for row in wire.read_text().splitlines())
            active = "remote-turn-" + str(prior + 1)
            record("turn-start", text=text, turnID=active)
            emit({"id": ident, "result": {"turn": {"id": active}}})
            notify("turn/started", turn={"id": active})
            if text == "Approve this remote prompt":
                notify("item/agentMessage/delta", turnId=active, itemId="remote-message-1", delta="REMOTE_STREAM_🌍")
                emit({"method": "item/commandExecution/requestApproval", "id": "remote-approval-1", "params": {
                    "threadId": "remote-native-thread", "turnId": active, "command": "printf offline-only", "cwd": str(workspace)
                }})
            else:
                notify("item/agentMessage/delta", turnId=active, itemId="remote-holding", delta="REMOTE_HOLDING")
        elif ident == "remote-approval-1" and method is None:
            assert active == "remote-turn-1" and frame["result"] == {"decision": "accept"}
            record("approval-response", frame=frame)
            notify("item/agentMessage/delta", turnId=active, itemId="remote-message-1", delta="_APPROVED")
            notify("item/completed", turnId=active, item={"id": "remote-message-1", "type": "agentMessage", "text": "REMOTE_STREAM_🌍_APPROVED"})
            notify("turn/completed", turn={"id": active, "status": "completed"})
            active = None
        elif method == "turn/interrupt":
            assert active is not None and params == {"threadId": "remote-native-thread", "turnId": active}
            record("interrupt", turnID=active)
            emit({"id": ident, "result": {}})
            notify("turn/completed", turn={"id": active, "status": "interrupted"})
            active = None
        else:
            raise AssertionError("Unexpected offline native provider frame")
    record_exit("stdin-eof")
except BrokenPipeError:
    record_exit("owned-output-closed")
