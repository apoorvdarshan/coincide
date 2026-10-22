"""Closed-world Codex peer for the hosted native steering workflow.

The first native turn stays running until one exact turn/steer request arrives.
No provider, shell, network, Git, or user configuration is consulted.
"""
import fcntl
import json
import os
from pathlib import Path
import sys

THREAD = "ui-native-steering-thread"
TURN = "ui-native-steering-turn"
RUNNING = "Offline steering turn is running"
FINISHED = "Offline steering acknowledged the literal follow-up"

state_path, wire_path = map(Path, sys.argv[1:3])
root = state_path.parent.resolve(strict=True)
if (not root.name.startswith("coincide-ui-testing-") or not state_path.is_absolute()
        or not wire_path.is_absolute() or wire_path.parent.resolve(strict=True) != root
        or state_path.is_symlink() or wire_path.is_symlink()):
    raise SystemExit("The offline steering peer requires its private native UI test root.")


def turn(state):
    done = state.get("steered") is True
    return {"id": TURN, "status": "completed" if done else "inProgress", "items": [],
            "itemsView": "summary", "rootTurnId": None, "error": None,
            "startedAt": 1, "completedAt": 2 if done else None, "durationMs": 1 if done else None}


def thread(state):
    active = state.get("turnStarted") is True and state.get("steered") is not True
    return {"id": THREAD, "cwd": state["cwd"], "historyMode": "paginated",
            "status": {"type": "active" if active else "idle"},
            "turns": [turn(state)] if state.get("turnStarted") is True else [],
            "forkedFromId": None, "preview": "Offline native steering fixture"}


def validate_checkout(state):
    requested = Path(state["cwd"])
    if not requested.is_absolute() or requested.is_symlink():
        raise SystemExit("The steering checkout must be a real private directory.")
    checkout = requested.resolve(strict=True)
    if not checkout.is_dir() or checkout.parent != root:
        raise SystemExit("The steering checkout must belong to the private fixture root.")


def request(frame, state):
    method, params = frame["method"], frame.get("params") or {}
    notifications = []
    if method == "initialize":
        result = {"userAgent": "coincide/0.163.0 (macos; fixture)", "codexHome": str(root),
                  "platformFamily": "unix", "platformOs": "macos"}
    elif method == "model/list":
        result = {"data": [{"id": "fixture-model", "model": "fixture-model", "displayName": "Offline fixture model"}]}
    elif method == "thread/start":
        if state.get("threadStarted") is True or params.get("historyMode") != "paginated" or params.get("cwd") != state["cwd"]:
            raise ValueError("Only one new paginated native thread in the exact fixture checkout is allowed.")
        state["threadStarted"] = True
        result = {"thread": thread(state)}
    elif method in ("thread/read", "thread/resume", "thread/turns/list", "thread/goal/get"):
        if state.get("threadStarted") is not True or params.get("threadId") != THREAD:
            raise ValueError("Metadata must refer to the one native steering thread.")
        if method == "thread/turns/list":
            result = {"data": [turn(state)] if state.get("turnStarted") is True else [], "nextCursor": None, "backwardsCursor": None}
        elif method == "thread/goal/get":
            result = {"goal": None}
        else:
            result = {"thread": thread(state)}
    elif method == "turn/start":
        if (state.get("threadStarted") is not True or state.get("turnStarted") is True
                or params.get("threadId") != THREAD or params.get("cwd") != state["cwd"]
                or params.get("input") != [{"type": "text", "text": state["firstPrompt"]}]):
            raise ValueError("The fixture accepts exactly one native turn with its original input.")
        state["turnStarted"] = True
        result = {"turn": turn(state)}
        notifications = [
            {"method": "turn/started", "params": {"threadId": THREAD, "turn": turn(state)}},
            {"method": "item/agentMessage/delta", "params": {"threadId": THREAD, "turnId": TURN,
                "itemId": "ui-steering-running", "delta": RUNNING}}]
    elif method == "turn/steer":
        allowed = {"threadId", "expectedTurnId", "input", "clientUserMessageId"}
        if (set(params) != allowed or state.get("turnStarted") is not True or state.get("steered") is True
                or params.get("threadId") != THREAD or params.get("expectedTurnId") != TURN
                or params.get("input") != [{"type": "text", "text": state["steeringPrompt"], "text_elements": []}]):
            raise ValueError("Steering must target the original turn and preserve literal input without configuration overrides.")
        identifier = params["clientUserMessageId"]
        if (not isinstance(identifier, str) or not identifier.strip() or len(identifier.encode("utf-8")) > 4096
                or any(ord(character) < 32 or ord(character) == 127 for character in identifier)):
            raise ValueError("Steering must include its immutable client user-message identity.")
        state["steered"] = True
        state["clientMessageID"] = identifier
        result = {"turnId": TURN}
        notifications = [
            {"method": "item/agentMessage/delta", "params": {"threadId": THREAD, "turnId": TURN,
                "itemId": "ui-steering-finished", "delta": FINISHED}},
            {"method": "turn/completed", "params": {"threadId": THREAD, "turn": turn(state)}}]
    else:
        raise ValueError("Unsupported offline steering method: " + method)
    return result, notifications


for line in sys.stdin:
    if len(line) > 4_194_304:
        raise SystemExit("The offline steering input exceeds its limit.")
    frame = json.loads(line)
    if "id" not in frame:
        continue
    with (root / "steering-peer.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if state_path.stat().st_size > 4_194_304:
            raise SystemExit("The offline steering state exceeds its limit.")
        state = json.loads(state_path.read_text(encoding="utf-8"))
        validate_checkout(state)
        with wire_path.open("a", encoding="utf-8") as wire:
            wire.write(json.dumps(frame, ensure_ascii=False) + "\n")
            wire.flush()
        try:
            result, notifications = request(frame, state)
        except (KeyError, ValueError, TypeError) as error:
            response = {"id": frame["id"], "error": {"code": -32602, "message": str(error)}}
            notifications = []
        else:
            temporary = state_path.with_name(state_path.name + "." + str(os.getpid()) + ".tmp")
            temporary.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
            os.chmod(temporary, 0o600)
            os.replace(temporary, state_path)
            response = {"id": frame["id"], "result": result}
        fcntl.flock(lock, fcntl.LOCK_UN)
    print(json.dumps(response, ensure_ascii=False), flush=True)
    for notification in notifications:
        print(json.dumps(notification, ensure_ascii=False), flush=True)
