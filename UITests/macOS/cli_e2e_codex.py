"""Offline Codex 0.164 app-server for the local CLI end-to-end check.

It answers turns with a fixed reply and confirms manual context compaction with
the same notifications as the real server. No network, shell or Git access.
"""
import json
from pathlib import Path
import sys

state_path = Path(sys.argv[1])
if not state_path.is_absolute() or not state_path.parent.name.startswith("coincide-ui-testing-"):
    raise SystemExit("The offline peer requires its private UI-testing root.")
arguments = sys.argv[2:]
if arguments == ["--version"]:
    print("codex-cli 0.164.0")
    raise SystemExit(0)
if arguments[:1] == ["app-server"] and "--help" in arguments:
    print("Usage: codex app-server [OPTIONS]")
    raise SystemExit(0)
if arguments[:1] != ["app-server"]:
    raise SystemExit("Unsupported offline Codex invocation.")


def emit(value):
    print(json.dumps(value), flush=True)


def turn(identifier, status="completed"):
    return {"id": identifier, "status": status, "items": [], "itemsView": "summary",
            "rootTurnId": None, "error": None, "startedAt": 1, "completedAt": 2, "durationMs": 1}


state = json.loads(state_path.read_text()) if state_path.exists() else {"turns": 0, "compactions": 0}


def save():
    temporary = state_path.with_name(state_path.name + ".tmp")
    temporary.write_text(json.dumps(state))
    temporary.replace(state_path)


def thread(identifier):
    return {"id": identifier, "cwd": state.get("cwd", "/"), "historyMode": "paginated",
            "status": {"type": "idle"}, "turns": [], "preview": "Offline CLI fixture"}


for line in sys.stdin:
    frame = json.loads(line)
    if "id" not in frame:
        continue
    method, params, notifications = frame["method"], frame.get("params") or {}, []
    if method == "initialize":
        result = {"userAgent": "coincide/0.164.0 (macos; fixture)", "platformFamily": "unix", "platformOs": "macos"}
    elif method == "model/list":
        result = {"data": [{"id": "fixture-model", "model": "fixture-model", "displayName": "Offline fixture model"}]}
    elif method == "thread/start":
        state["cwd"] = params.get("cwd", "/")
        result = {"thread": thread("cli-native-thread")}
    elif method in ("thread/read", "thread/resume"):
        result = {"thread": thread(params["threadId"])}
    elif method == "thread/turns/list":
        result = {"data": [], "nextCursor": None, "backwardsCursor": None}
    elif method == "thread/goal/get":
        result = {"goal": None}
    elif method == "turn/start":
        state["turns"] += 1
        native, identifier = "cli-turn-" + str(state["turns"]), params["threadId"]
        base = {"threadId": identifier, "turnId": native}
        result = {"turn": turn(native, "inProgress")}
        notifications = [
            {"method": "turn/started", "params": {"threadId": identifier, "turn": turn(native, "inProgress")}},
            {"method": "item/agentMessage/delta", "params": {**base, "itemId": "reply-" + native,
                                                             "delta": "Offline CLI reply " + str(state["turns"])}},
            {"method": "turn/completed", "params": {"threadId": identifier, "turn": turn(native)}}]
    elif method == "thread/compact/start":
        state["compactions"] += 1
        native, identifier = "cli-compaction-" + str(state["compactions"]), params["threadId"]
        item = {"type": "contextCompaction", "id": "compaction-" + native}
        result = {}
        notifications = [
            {"method": "turn/started", "params": {"threadId": identifier, "turn": turn(native, "inProgress")}},
            {"method": "item/started", "params": {"threadId": identifier, "turnId": native, "item": item}},
            {"method": "item/completed", "params": {"threadId": identifier, "turnId": native, "item": item}},
            {"method": "turn/completed", "params": {"threadId": identifier, "turn": turn(native)}}]
    else:
        emit({"id": frame["id"], "error": {"code": -32601, "message": "Unsupported offline method: " + method}})
        continue
    save()
    emit({"id": frame["id"], "result": result})
    for notification in notifications:
        emit(notification)
