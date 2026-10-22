#!/usr/bin/python3
"""Native flat ACP2 Antigravity fixture; no vendor code, credentials or model."""
import json
import os
import sys
import threading
import time
import uuid

root = os.path.dirname(os.path.realpath(__file__))
options_file = os.path.join(root, "options.json")
wire_file = os.path.join(root, "wire.jsonl")
sessions_file = os.path.join(root, "sessions.json")
lock = threading.RLock()
session = None
prompt = None
old_tool = None
seen_signal = None

def options():
    try:
        with open(options_file, encoding="utf8") as file:
            return json.load(file)
    except (OSError, ValueError):
        return {}

def record(kind, **fields):
    with lock:
        with open(wire_file, "a", encoding="utf8") as file:
            file.write(json.dumps(dict(fields, kind=kind, pid=os.getpid()), ensure_ascii=False) + "\n")

def emit(value):
    with lock:
        encoded = (json.dumps(value, ensure_ascii=False) + "\n").encode("utf8")
        at = encoded.find("日".encode("utf8"))
        if at >= 0:
            sys.stdout.buffer.write(encoded[:at + 1]); sys.stdout.buffer.flush()
            sys.stdout.buffer.write(encoded[at + 1:])
        else:
            sys.stdout.buffer.write(encoded)
        sys.stdout.buffer.flush()

def result(frame, value):
    emit({"jsonrpc": "2.0", "id": frame["id"], "result": value})

def error(frame):
    emit({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": -32000, "message": "synthetic native error"}})

def update(value):
    emit({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session["id"], "update": value}})

def setup():
    return {"sessionId": session["id"], "configOptions": [
        {"id": "mode", "category": "mode", "name": "Permissions", "type": "select", "currentValue": session["mode"],
         "options": [{"value": value, "name": value} for value in ["default", "auto_edit", "yolo"]]},
        {"id": "model", "category": "model", "name": "Model", "type": "select", "currentValue": session["model"],
         "options": [{"group": "Native", "options": [{"value": "native-default", "name": "Default account model"}, {"value": "selected", "name": "Selected account model"}]}]}]}

def save():
    with lock:
        try:
            with open(sessions_file, encoding="utf8") as file:
                data = json.load(file)
        except (OSError, ValueError):
            data = {}
        data[session["id"]] = session
        temporary = sessions_file + "." + str(os.getpid())
        with open(temporary, "w", encoding="utf8") as file:
            json.dump(data, file)
        os.replace(temporary, sessions_file)

def finish(reason="end_turn"):
    global prompt, old_tool
    with lock:
        if prompt is None:
            return
        frame = prompt
        prompt = None
        old_tool = "tool-" + str(frame["id"])
        result(frame, {"stopReason": reason})
        record("terminal", reason=reason)

def permission(question=False):
    tool_id = "interaction_exact" if question else "permission_exact"
    rows = [{"optionId": "id-one", "name": "First label", "kind": "allow_once"},
            {"optionId": "id-two", "name": "Second label", "kind": "allow_always",
             "_meta": {"agy.security.warning": {"title": "Persistent grant", "message": "This grants future native tool access."}}},
            {"optionId": "id-decline", "name": "Decline", "kind": "reject_once"}]
    emit({"jsonrpc": "2.0", "id": 700, "method": "session/request_permission", "params": {
        "sessionId": session["id"], "toolCall": {"toolCallId": tool_id, "title": "Choose an exact option"}, "options": rows}})

def handle(frame):
    global session, prompt
    method = frame.get("method")
    if method is None:
        record("clientResponse", wireID=frame.get("id"), value=frame.get("result"), errorCode=frame.get("error", {}).get("code"))
        return
    params = frame.get("params", {})
    record("request", method=method, params=params)
    selected = options()
    if method == "initialize":
        # Shape copied from T3's real antigravity-initialize.json (1.1.1),
        # unlike generic ACP2's nested capabilities/session envelope.
        result(frame, {"protocolVersion": 2, "agentCapabilities": {
            "loadSession": True, "promptCapabilities": {"image": True, "audio": True, "embeddedContext": True},
            "mcpCapabilities": {"http": True, "sse": True}, "sessionCapabilities": {"list": {}, "resume": {}}, "auth": {"logout": {}}},
            "authMethods": [{"id": value, "name": value} for value in ["oauth-personal", "oauth-business", "gemini-api-key", "agent-platform"]],
            "agentInfo": {"name": "antigravity-acp", "title": "Google Antigravity", "version": "agy_acp_server_1.1.1"}})
    elif method == "authenticate":
        if selected.get("authRequired"):
            error(frame)
        else:
            result(frame, {})
    elif method == "logout":
        result(frame, {})
    elif method == "session/new":
        session = {"id": str(uuid.uuid4()), "cwd": params["cwd"], "model": "native-default", "mode": "default"}
        save()
        profile = os.environ["GEMINI_HOME"]
        folder = os.path.join(profile, "antigravity-acp", "conversations")
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, session["id"] + ".meta"), "w", encoding="utf8") as file:
            json.dump({"cwd": params["cwd"]}, file)
        with open(os.path.join(folder, session["id"] + ".db"), "wb") as file:
            file.write(b"synthetic native session")
        result(frame, setup())
    elif method == "session/resume":
        try:
            with open(os.path.join(os.environ["GEMINI_HOME"], "antigravity-acp", "conversations", params["sessionId"] + ".meta"), encoding="utf8") as file:
                metadata = json.load(file)
            if metadata.get("cwd") != params["cwd"]:
                error(frame); return
            with open(sessions_file, encoding="utf8") as file:
                session = json.load(file)[params["sessionId"]]
        except (OSError, ValueError, KeyError):
            error(frame); return
        session["model"] = "native-default"; session["mode"] = "default"
        update({"sessionUpdate": "tool_call", "toolCallId": "replayed-do-not-display", "title": "Old replay", "status": "completed"})
        result(frame, setup())
    elif method == "session/set_config_option":
        while params["configId"] == "model" and options().get("holdModel"):
            time.sleep(.005)
        session[params["configId"]] = params["value"]; save()
        value = setup()
        update({"sessionUpdate": "config_option_update", "configOptions": value["configOptions"]})
        result(frame, {"configOptions": value["configOptions"]})
    elif method == "session/prompt":
        prompt = frame
        record("prompt", model=session["model"], mode=session["mode"], sessionID=session["id"], prompt=params["prompt"])
        update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Native 日本語 "}})
        update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "reply"}})
        tool_id = "tool-" + str(frame["id"])
        update({"sessionUpdate": "tool_call", "toolCallId": tool_id, "title": "Native command", "status": "in_progress", "rawInput": {"CommandLine": "echo generated", "WorkingDirectory": session["cwd"]}})
        update({"sessionUpdate": "tool_call_update", "toolCallId": tool_id, "status": "completed", "rawOutput": {"combined_output": "Native tool output", "exit_code": 0}})
        if selected.get("interaction"):
            permission(selected["interaction"] == "question")
        if selected.get("delegateFiles"):
            emit({"jsonrpc": "2.0", "id": 801, "method": "fs/write_text_file", "params": {"sessionId": session["id"], "path": os.path.join(session["cwd"], "delegated.txt"), "content": "first\nsecond\nthird"}})
        if selected.get("eof"):
            os._exit(0)
    elif method == "session/cancel":
        record("cancel", sessionID=params["sessionId"], exact=params["sessionId"] == session["id"])
        if not selected.get("holdCancel"):
            finish("cancelled")
    else:
        if "id" in frame:
            error(frame)

def signals():
    global seen_signal
    while True:
        selected = options().get("signal")
        if selected and selected.get("id") != seen_signal and selected.get("pid") == os.getpid():
            seen_signal = selected["id"]
            name = selected.get("name")
            if name == "finish": finish()
            elif name == "cancelled": finish("cancelled")
            elif name == "late-tool" and old_tool:
                update({"sessionUpdate": "tool_call_update", "toolCallId": old_tool, "status": "completed", "rawOutput": "Original-run late tool result"})
        time.sleep(.005)

record("process", cwd=os.getcwd(), arguments=sys.argv[1:], harnessPresent=bool(os.environ.get("ANTIGRAVITY_HARNESS_PATH")),
       keyPresent=bool(os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")))
threading.Thread(target=signals, daemon=True).start()
for line in sys.stdin.buffer:
    value = json.loads(line)
    threading.Thread(target=handle, args=(value,), daemon=True).start()
