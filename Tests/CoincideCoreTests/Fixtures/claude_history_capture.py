#!/usr/bin/python3 -S
"""Owned native stream-json peer; never imports or calls a vendor service."""
import json
import os
from pathlib import Path
import signal
import sys

root = Path(__file__).resolve().parent
trace = root / "capture-wire.jsonl"
native = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
args = sys.argv[1:]
for index, value in enumerate(args[:-1]):
    if value in ("--resume", "--session-id"):
        native = args[index + 1]

def record(kind, **fields):
    with trace.open("a", encoding="utf8") as out:
        out.write(json.dumps(dict(kind=kind, pid=os.getpid(), **fields), ensure_ascii=False) + "\n")
        out.flush()

def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)

def finish(reason):
    record("closed", reason=reason)
    raise SystemExit(0)

signal.signal(signal.SIGTERM, lambda _signal, _frame: finish("sigterm"))

record("launch", arguments=args, cwd=os.getcwd(), configRoot=os.environ.get("CLAUDE_CONFIG_DIR"),
       configPresent="CLAUDE_CONFIG_DIR" in os.environ,
       home=os.environ.get("HOME") if os.environ.get("HOME", "").startswith(str(root) + "/") else "not-task-owned",
       projectOverride=os.environ.get("CLAUDE_CODE_PROJECT_DIR_NAME"),
       precompactDisabled=bool(os.environ.get("CLAUDE_CODE_DISABLE_PRECOMPACT_SKIP")))
opening = None
for raw in sys.stdin:
    value = json.loads(raw)
    if value.get("type") == "control_request":
        request = value["request"]
        method = request["subtype"]
        record("control", method=method, model=request.get("model"), mode=request.get("mode"))
        result = {"models": [{"value": "capture-model", "displayName": "Capture model"}]} if method == "initialize" else {}
        emit({"type": "control_response", "response": {"subtype": "success", "request_id": value["request_id"], "response": result}})
        if method == "initialize":
            emit({"type": "system", "subtype": "init", "session_id": native, "parent_tool_use_id": None,
                  "claude_code_version": "2.1.276"})
    elif value.get("type") == "user":
        uid = value["uuid"]
        record("input", uuid=uid, priority=value.get("priority"), content=value["message"]["content"])
        if opening is None:
            opening = uid
            emit({"type": "assistant", "session_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "parent_tool_use_id": None,
                  "uuid": "cccccccc-cccc-4ccc-8ccc-cccccccccccc", "message": {"id": "foreign-api", "content": []}})
            emit({"type": "assistant", "session_id": native, "parent_tool_use_id": None, "replayed": True,
                  "uuid": "dddddddd-dddd-4ddd-8ddd-dddddddddddd", "message": {"id": "replayed-api", "content": []}})
            emit({"type": "assistant", "session_id": native, "parent_tool_use_id": None, "user_message_uuid": uid,
                  "uuid": "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", "message": {"id": "nested-api-is-not-cursor", "content": [{"type": "text", "text": "Opening reply 工作 🌍"}]}})
            emit({"type": "assistant", "session_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "parent_tool_use_id": "child-tool",
                  "uuid": "ffffffff-ffff-4fff-8fff-ffffffffffff", "message": {"id": "child-api", "content": []}})
        else:
            emit({"type": "user", "session_id": native, "parent_tool_use_id": None, "uuid": uid, "message": value["message"]})
            emit({"type": "assistant", "session_id": native, "parent_tool_use_id": None, "user_message_uuid": uid,
                  "user_message_uuids": [opening, uid], "uuid": "11111111-2222-4333-8444-555555555555",
                  "message": {"id": "second-api-is-not-cursor", "content": [{"type": "text", "text": "Steered reply"}]}})
            emit({"type": "result", "session_id": native, "parent_tool_use_id": None, "is_error": False,
                  "user_message_uuid": uid, "user_message_uuids": [opening, uid]})
finish("eof")
