"""Private no-model protocol peer; records validation metadata, never prompt bodies."""
import json
import os
from pathlib import Path
import sys

profile, root = sys.argv[1], Path(sys.argv[2])
assert root.name.startswith("coincide-context-delivery-") and os.stat(root).st_mode & 0o077 == 0
os.umask(0o077)
(root / "pid").write_text(str(os.getpid()))
expected = json.loads((root / "expected.json").read_text())
count = 0


def send(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def result(frame, value):
    send({"jsonrpc": "2.0", "id": frame["id"], "result": value})


def check(blocks):
    global count
    assert all(part["type"] in ("text", "image") for part in blocks)
    assert [part["text"] for part in blocks if part["type"] == "text"] == expected["text"]
    images = [part for part in blocks if part["type"] == "image"]
    assert len(images) == (1 if "image" in expected else 0)
    if images:
        if profile == "codex":
            assert images[0]["url"] == "data:image/png;base64," + expected["image"]
        elif profile == "claude":
            assert images[0]["source"] == {"type": "base64", "media_type": "image/png", "data": expected["image"]}
        else:
            assert images[0]["mimeType"] == "image/png" and images[0]["data"] == expected["image"]
    count += 1
    assert count == 1
    temporary = root / "checked.tmp"
    temporary.write_text(json.dumps({"count": count, "literalExact": True, "historySeparate": True}))
    os.replace(temporary, root / "checked.json")


for line in sys.stdin:
    frame = json.loads(line)
    if profile == "claude":
        if frame["type"] == "control_request":
            method = frame["request"]["subtype"]
            assert method in ("initialize", "set_permission_mode", "set_model", "interrupt")
            body = {"models": [{"value": "fixture", "displayName": "Fixture"}]} if method == "initialize" else {}
            send({"type": "control_response", "response": {"subtype": "success", "request_id": frame["request_id"], "response": body}})
        elif frame["type"] == "user":
            assert frame["message"]["role"] == "user"
            check(frame["message"]["content"])
            send({"type": "result", "session_id": "context-native", "is_error": False, "result": "Private context accepted"})
        else:
            raise AssertionError("Unexpected private Claude frame type")
        continue
    method = frame.get("method")
    if method == "initialized":
        continue
    if method == "initialize":
        if profile == "codex":
            result(frame, {"userAgent": "coincide/0.163.0"})
        elif profile == "acp1":
            result(frame, {"protocolVersion": 1, "agentCapabilities": {"loadSession": True, "promptCapabilities": {"image": True}}})
        else:
            result(frame, {"protocolVersion": 2, "info": {"name": "private-context", "version": "1"}, "capabilities": {"session": {"prompt": {"image": {}}}}})
    elif method in ("thread/start", "thread/resume"):
        thread = {"id": "context-native"}
        if method == "thread/start":
            assert frame["params"]["historyMode"] == "paginated"
            thread["historyMode"] = "paginated"
        result(frame, {"thread": thread})
    elif method == "turn/start":
        check(frame["params"]["input"])
        result(frame, {"turn": {"id": "context-turn"}})
    elif method == "session/new":
        result(frame, {"sessionId": "context-native", "models": {"currentModelId": "fixture", "availableModels": [{"modelId": "fixture", "name": "Fixture"}]}, "configOptions": []})
    elif method == "session/prompt":
        check(frame["params"]["prompt"])
        if profile == "acp1":
            result(frame, {"stopReason": "end_turn"})
        else:
            result(frame, {"messageId": "context-user"})
            for state in ("running", "idle"):
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "context-native", "update": {"sessionUpdate": "state_update", "state": state, "stopReason": "end_turn"}}})
    elif method == "session/close":
        result(frame, {})
    else:
        raise AssertionError("Unexpected private context provider method: " + str(method))
