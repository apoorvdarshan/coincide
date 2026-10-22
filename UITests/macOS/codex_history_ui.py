"""Offline Codex 0.163 peer for one disposable native GUI workflow.

All state and wire receipts are confined to the runner's private test root.
Fresh metadata and fork processes coordinate with flock and atomic replacement.
This peer performs no network, Git, shell, or user Codex operations.
"""
import fcntl
import json
import os
from pathlib import Path
import sys

state_path, wire_path = map(Path, sys.argv[1:3])
root = state_path.parent.resolve(strict=True)
if (not root.name.startswith("coincide-ui-testing-") or not state_path.is_absolute()
        or not wire_path.is_absolute() or wire_path.parent.resolve(strict=True) != root
        or state_path.is_symlink() or wire_path.is_symlink()):
    raise SystemExit("The offline peer requires its private native UI test root.")


def emit(value):
    print(json.dumps(value), flush=True)


def turn(identifier):
    return {"id": identifier, "status": "completed", "items": [], "itemsView": "summary",
            "rootTurnId": None, "error": None, "startedAt": 1, "completedAt": 2, "durationMs": 1}


def thread(identifier, state):
    value = state["threads"][identifier]
    return {"id": identifier, "cwd": state["cwd"], "historyMode": "paginated",
            "status": {"type": "idle"}, "turns": [turn(item) for item in value["turns"]],
            "forkedFromId": value.get("source"), "preview": "Offline native history fixture"}


def request(frame, state):
    method, params = frame["method"], frame.get("params") or {}
    notifications = []
    if method == "initialize":
        result = {"userAgent": "coincide/0.163.0 (macos; fixture)", "codexHome": str(root),
                  "platformFamily": "unix", "platformOs": "macos"}
    elif method == "model/list":
        result = {"data": [{"id": "fixture-model", "model": "fixture-model", "displayName": "Offline fixture model"}]}
    elif method == "thread/start":
        if params.get("historyMode") != "paginated":
            raise ValueError("A new native history fixture must explicitly select paginated mode.")
        identifier = "ui-native-source"
        if identifier in state["threads"]:
            raise ValueError("The fixture must not silently replace an existing source.")
        state["threads"][identifier] = {"turns": []}
        result = {"thread": thread(identifier, state)}
    elif method in ("thread/read", "thread/resume"):
        result = {"thread": thread(params["threadId"], state)}
    elif method == "thread/turns/list":
        turns = list(reversed(state["threads"][params["threadId"]]["turns"]))
        start = int(params.get("cursor") or 0)
        limit = min(int(params.get("limit", 100)), 100)
        result = {"data": [turn(item) for item in turns[start:start + limit]],
                  "nextCursor": str(start + limit) if start + limit < len(turns) else None,
                  "backwardsCursor": None}
    elif method == "thread/goal/get":
        result = {"goal": None}
    elif method == "turn/start":
        identifier = params["threadId"]
        state["nextTurn"] += 1
        native = "ui-turn-" + str(state["nextTurn"])
        state["threads"][identifier]["turns"].append(native)
        result = {"turn": turn(native)}
        base = {"threadId": identifier, "turnId": native}
        notifications = [
            {"method": "turn/started", "params": {"threadId": identifier, "turn": turn(native)}},
            {"method": "item/agentMessage/delta", "params": {**base, "itemId": "reply-" + native,
                "delta": "Offline history reply " + str(state["nextTurn"])}},
            {"method": "turn/completed", "params": {"threadId": identifier, "turn": turn(native)}}]
    elif method in ("thread/fork", "thread/revert"):
        source = params["threadId"]
        turns = state["threads"][source]["turns"]
        boundary = params.get("lastTurnId") or params.get("beforeTurnId")
        index = turns.index(boundary)
        if method == "thread/fork":
            identifier = "ui-native-fork"
            if identifier in state["threads"]:
                raise ValueError("The native fork must not be replayed.")
            state["threads"][identifier] = {"turns": turns[:index + 1], "source": source}
        else:
            identifier = source
            state["threads"][identifier]["turns"] = turns[:index]
        result = {"thread": thread(identifier, state)}
    else:
        raise ValueError("Unsupported offline fixture method: " + method)
    return result, notifications


for line in sys.stdin:
    if len(line) > 4_194_304:
        raise SystemExit("The offline fixture input exceeds its limit.")
    frame = json.loads(line)
    if "id" not in frame:  # initialized is a notification.
        continue
    with (root / "history-peer.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if state_path.stat().st_size > 4_194_304:
            raise SystemExit("The offline fixture state exceeds its limit.")
        state = json.loads(state_path.read_text())
        if Path(state["cwd"]).resolve(strict=True).parent != root:
            raise SystemExit("The offline fixture checkout must belong to this test root.")
        with wire_path.open("a", encoding="utf-8") as wire:
            wire.write(json.dumps(frame) + "\n")
            wire.flush()
        try:
            result, notifications = request(frame, state)
        except (KeyError, ValueError) as error:
            response = {"id": frame["id"], "error": {"code": -32602, "message": str(error)}}
            notifications = []
        else:
            temporary = state_path.with_name(state_path.name + "." + str(os.getpid()) + ".tmp")
            temporary.write_text(json.dumps(state), encoding="utf-8")
            os.chmod(temporary, 0o600)
            os.replace(temporary, state_path)
            response = {"id": frame["id"], "result": result}
        fcntl.flock(lock, fcntl.LOCK_UN)
    emit(response)
    for notification in notifications:
        emit(notification)
