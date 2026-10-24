"""Offline native compaction peers. Never load user config or invoke a model."""
import json
import os
import sys

provider, scenario, root = sys.argv[1:]
turn = 0
native = "fixture-native-session"


def emit(value):
    print(json.dumps(value), flush=True)


def response(frame, result=None):
    if provider == "codex":
        emit({"id": frame["id"], "result": result or {}})
    else:
        emit({"type": "control_response", "response": {"subtype": "success",
             "request_id": frame["request_id"], "response": result or {}}})


def codex_event(method, params):
    emit({"method": method, "params": {"threadId": native, **params}})


def claude_event(kind, **fields):
    emit({"type": kind, "session_id": native, "parent_tool_use_id": None, **fields})


def compact(frame):
    with open(os.path.join(root, "dispatched"), "w") as marker:
        marker.write("yes")
    if scenario == "disconnect":
        sys.exit(0)
    if scenario == "hold":
        if provider == "codex":
            codex_event("turn/started", {"turn": {"id": "compact-turn"}})
            response(frame)
        return
    if scenario == "interactive":
        if provider == "codex":
            response(frame)
            emit({"id": "unexpected-approval", "method": "item/commandExecution/requestApproval",
                  "params": {"threadId": native, "turnId": "compact-turn", "command": "PRIVATE_SUMMARY"}})
        else:
            emit({"type": "control_request", "request_id": "unexpected-approval",
                  "request": {"subtype": "can_use_tool", "tool_name": "Bash",
                              "input": {"command": "PRIVATE_SUMMARY"}}})
        return
    if provider == "codex":
        assert frame["params"] == {"threadId": native}
        # Prior/foreign completions cannot settle this operation.
        codex_event("turn/completed", {"turn": {"id": "public-1", "status": "completed"}})
        codex_event("turn/completed", {"threadId": "foreign", "turn": {"id": "foreign", "status": "failed"}})
        codex_event("turn/started", {"turn": {"id": "compact-turn"}})
        codex_event("item/agentMessage/delta", {"turnId": "compact-turn", "itemId": "private", "delta": "PRIVATE_SUMMARY"})
        codex_event("item/completed", {"turnId": "compact-turn", "item": {"type": "agentMessage", "id": "private", "text": "PRIVATE_SUMMARY"}})
        if scenario != "missing-boundary":
            codex_event("item/completed", {"turnId": "compact-turn", "item": {"type": "contextCompaction", "id": "compact-item"}})
        codex_event("turn/completed", {"turn": {"id": "compact-turn", "status": "failed" if scenario == "failed" else "completed"}})
        # Deliberately ACK after events: neither arrival order can lose evidence.
        response(frame)
        codex_event("item/agentMessage/delta", {"turnId": "compact-turn", "itemId": "private-late", "delta": "PRIVATE_SUMMARY_LATE"})
    else:
        assert frame["message"] == {"role": "user", "content": "/compact"}
        assert frame["parent_tool_use_id"] is None and frame["uuid"]
        claude_event("result", parent_tool_use_id="child", is_error=True)
        claude_event("result", session_id="foreign", is_error=True)
        claude_event("result", user_message_uuids=["stale-input"], is_error=True)
        claude_event("assistant", message={"id": "private", "content": [{"type": "text", "text": "PRIVATE_SUMMARY"}]})
        if scenario != "missing-boundary":
            claude_event("system", subtype="compact_boundary", compact_metadata={"trigger": "manual", "pre_tokens": 123})
        claude_event("result", subtype="error_during_execution" if scenario == "failed" else "success",
                     is_error=scenario == "failed", user_message_uuid=frame["uuid"], result="PRIVATE_SUMMARY")
        claude_event("assistant", message={"id": "private-late", "content": [{"type": "text", "text": "PRIVATE_SUMMARY_LATE"}]})


for line in sys.stdin:
    frame = json.loads(line)
    with open(os.path.join(root, "wire.jsonl"), "a") as log:
        log.write(json.dumps(frame) + "\n")
    if provider == "codex":
        method = frame.get("method")
        if method == "initialize":
            response(frame, {"userAgent": "codex/0.999.0" if scenario == "unsupported" else "codex/0.164.0"})
        elif method == "thread/start":
            response(frame, {"thread": {"id": native, "historyMode": frame["params"].get("historyMode")}})
        elif method == "turn/start":
            turn += 1
            ident = "public-" + str(turn)
            codex_event("turn/started", {"turn": {"id": ident}})
            codex_event("item/completed", {"turnId": ident, "item": {"id": ident + "-reply", "type": "agentMessage", "text": "Public reply " + str(turn)}})
            codex_event("turn/completed", {"turn": {"id": ident, "status": "completed"}})
            response(frame, {"turn": {"id": ident}})
        elif method == "thread/compact/start":
            compact(frame)
        elif method == "turn/interrupt":
            assert frame["params"] == {"threadId": native, "turnId": "compact-turn"}
            response(frame)
            codex_event("turn/completed", {"turn": {"id": "compact-turn", "status": "interrupted"}})
        elif method == "account/read":
            response(frame, {"account": None, "requiresOpenaiAuth": True})
        elif method == "initialized" or "error" in frame:
            pass
        else:
            raise AssertionError(method)
    elif frame["type"] == "control_request":
        method = frame["request"]["subtype"]
        if method == "initialize":
            response(frame, {"commands": [] if scenario == "unsupported" else [
                {"name": "compact", "description": "Compact context", "argumentHint": ""}]})
        elif method in ("set_model", "set_permission_mode"):
            response(frame)
        else:
            raise AssertionError(method)
    elif frame["type"] == "user":
        if frame["message"]["content"] == "/compact":
            compact(frame)
        else:
            turn += 1
            claude_event("system", subtype="init")
            claude_event("assistant", message={"id": "public-" + str(turn), "content": [{"type": "text", "text": "Public reply " + str(turn)}]})
            claude_event("result", subtype="success", is_error=False, user_message_uuid=frame["uuid"], result="Public reply " + str(turn))
    elif frame["type"] != "control_response":
        raise AssertionError(frame["type"])
