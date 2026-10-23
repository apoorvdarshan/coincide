"""Private, offline native Codex peer checking copied attachment bytes exactly."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import sys

root = Path(sys.argv[1]).resolve(strict=True)
assert root.name.startswith("coincide-remote-attachment-")
assert os.stat(root).st_mode & 0o077 == 0
assert Path(os.environ["CODEX_HOME"]).resolve(strict=True) == root / "codex-home"
assert sys.argv[2:] == ["app-server", "--stdio"]
wire = root / "provider-wire.jsonl"


def record(kind, **fields):
    data = (json.dumps({"kind": kind, "pid": os.getpid(), **fields}) + "\n").encode()
    fd = os.open(wire, os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        assert os.write(fd, data) == len(data)
    finally:
        os.close(fd)


def emit(frame):
    data = (json.dumps(frame, ensure_ascii=False) + "\n").encode()
    # Native framing must tolerate multiple reads, including a split scalar.
    split = data.find("✓".encode()) + 1 if "✓".encode() in data else min(9, len(data))
    for part in (data[:split], data[split:]):
        sys.stdout.buffer.write(part)
        sys.stdout.buffer.flush()


def notify(method, **fields):
    emit({"method": method, "params": {"threadId": "attachment-native-thread", **fields}})


exited = False


def finish(*_):
    global exited
    if not exited:
        exited = True
        record("exit")
    raise SystemExit(0)


signal.signal(signal.SIGTERM, finish)
record("launch", cwd=os.getcwd())
expected = json.loads((root / "expected-provider.json").read_text())
workspace = Path(expected["workspace"]).resolve(strict=True)
assert Path.cwd().resolve(strict=True) == workspace
for line in sys.stdin:
    frame = json.loads(line)
    method, ident, params = frame.get("method"), frame.get("id"), frame.get("params", {})
    if method == "initialize":
        assert params["clientInfo"]["name"] == "coincide"
        emit({"id": ident, "result": {"userAgent": "private-attachment-peer/1"}})
    elif method == "initialized":
        assert ident is None
    elif method in ("thread/start", "thread/resume"):
        assert Path(params["cwd"]).resolve(strict=True) == workspace
        if method == "thread/resume":
            assert params["threadId"] == "attachment-native-thread"
        emit({"id": ident, "result": {"thread": {"id": "attachment-native-thread"}}})
    elif method == "turn/start":
        assert params["threadId"] == "attachment-native-thread"
        assert Path(params["cwd"]).resolve(strict=True) == workspace
        assert params["model"] == "remote-attachment-offline"
        assert params["approvalPolicy"] == "on-request" and params["sandboxPolicy"]["type"] == "readOnly"
        assert len(params["input"]) == 2 and params["input"][0]["type"] == "text"
        text = params["input"][0]["text"]
        assert text.startswith(expected["text"])
        annotation = re.compile(r'\[Attached (image|file) ("(?:[^"\\]|\\.)*") is saved at: ("(?:[^"\\]|\\.)*")\]')
        matches = list(annotation.finditer(text))
        assert len(matches) == len(expected["attachments"]) == 2
        observed = []
        for match in matches:
            kind, name, path = match.group(1), json.loads(match.group(2)), Path(json.loads(match.group(3)))
            physical = path.resolve(strict=True)
            assert physical.parent == (root / "data" / "Attachments").resolve(strict=True)
            assert not path.is_symlink() and path.is_file() and os.stat(path).st_mode & 0o077 == 0
            data = path.read_bytes()
            item = {"kind": kind, "name": name, "digest": hashlib.sha256(data).hexdigest(), "byteCount": len(data)}
            assert item in expected["attachments"]
            observed.append(item)
        image = params["input"][1]
        assert image["type"] == "image" and image["url"].startswith("data:image/png;base64,")
        image_bytes = base64.b64decode(image["url"].split(",", 1)[1], validate=True)
        assert any(item["kind"] == "image" and item["digest"] == hashlib.sha256(image_bytes).hexdigest() for item in observed)
        assert not any(json.loads(row).get("kind") == "turn" for row in wire.read_text().splitlines())
        # Retain bounded metadata only, never raw input or inline image payloads.
        record("turn", attachmentCount=len(observed), imageDigest=hashlib.sha256(image_bytes).hexdigest())
        emit({"id": ident, "result": {"turn": {"id": "attachment-native-turn"}}})
        notify("turn/started", turn={"id": "attachment-native-turn"})
        notify("item/started", turnId="attachment-native-turn", item={"id": "attachment-native-message", "type": "agentMessage", "text": ""})
        notify("item/agentMessage/delta", turnId="attachment-native-turn", itemId="attachment-native-message", delta="REMOTE_ATTACHMENTS_✓")
        notify("item/completed", turnId="attachment-native-turn", item={"id": "attachment-native-message", "type": "agentMessage", "text": "REMOTE_ATTACHMENTS_✓"})
        notify("turn/completed", turn={"id": "attachment-native-turn", "status": "completed"})
    else:
        raise AssertionError("Unexpected private attachment provider method")
finish()
