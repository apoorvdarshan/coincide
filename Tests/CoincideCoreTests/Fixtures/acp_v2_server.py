import base64
import json
import os
import sys
import time
import uuid

mode = sys.argv[1]
gate = sys.argv[2]
session = "v2-session"
prompt_id = None
inserted = False
user_id = None
entity_id = None
turn = 0
held_prompt = None
held_config = None
permissions = set()
values = {"model": "default", "mode": "ask", "boolean": False}


def send(value):
    print(json.dumps({"jsonrpc": "2.0", **value}, ensure_ascii=False), flush=True)


def result(request, value):
    send({"id": request["id"], "result": value})


def update(variant, **fields):
    send({"method": "session/update", "params": {"sessionId": session, "update": {"sessionUpdate": variant, **fields}}})


def state(value, **fields):
    update("state_update", state=value, **fields)


def config():
    return [
        {"configId": "model", "type": "select", "category": "model", "name": "Model", "currentValue": values["model"],
         "options": [{"groupId": "models", "name": "Models", "options": [{"value": "default", "name": "Default"}, {"value": "fixture", "name": "Fixture"}]}]},
        {"configId": "mode", "type": "select", "category": "mode", "name": "Mode", "currentValue": values["mode"],
         "options": [{"value": "ask", "name": "Ask"}, {"value": "plan", "name": "Plan"}]},
        {"configId": "boolean", "type": "boolean", "name": "Boolean fixture", "currentValue": values["boolean"]}]


def wait_gate():
    while not os.path.exists(gate):
        time.sleep(.005)


def echo():
    update("user_message", messageId=user_id, content=[{"type": "text", "text": "Provider echo"}])


def permit(request_id):
    if request_id in permissions:
        return
    permissions.add(request_id)
    send({"id": request_id, "method": "session/request_permission", "params": {
        "sessionId": session, "title": "Read the synthetic fixture?", "description": "Fixture permission context",
        "subject": {"type": "tool_call", "toolCall": {"toolCallId": entity_id}},
        "options": [{"optionId": "opaque-allow", "name": "Allow fixture once", "kind": "allow_once"},
                    {"optionId": "opaque-reject", "name": "Reject fixture", "kind": "reject_once"}]}})


def finish():
    global prompt_id
    update("tool_call_update", toolCallId=entity_id, status="completed", rawOutput={"saved": True})
    update("agent_message", messageId=entity_id, content=[{"type": "text", "text": "hello 🌍"}])
    if mode == "max_tokens":
        state("idle", stopReason="max_tokens")
    elif mode == "unknown_stop":
        state("idle", stopReason={"malformed": "retained"})
    else:
        state("idle", stopReason="end_turn")
    if mode == "echo_after":
        echo()
    if mode in ["background", "agent_initiated"]:
        wait_gate()
        if mode == "agent_initiated":
            state("running")
            while not os.path.exists(gate + ".finish"):
                time.sleep(.005)
            update("agent_message", messageId="ambient-message", content=[{"type": "text", "text": "Agent initiated follow-up"}])
            state("idle", stopReason="end_turn")
        else:
            update("tool_call_update", toolCallId="ambient-tool", title="Background tool", status="pending")
            permit("background-request")
    prompt_id = None


for line in sys.stdin:
    request = json.loads(line)
    assert request["jsonrpc"] == "2.0"
    method = request.get("method")
    params = request.get("params", {})
    if method == "initialize":
        assert params["protocolVersion"] == 2 and params["info"]["name"] == "coincide" and params["capabilities"] == {}
        result(request, {"protocolVersion": 2, "info": {"name": "fixture", "version": "2"},
                         "capabilities": {"session": {"prompt": {"image": {}}}}})
    elif method in ["session/new", "session/resume"]:
        assert params["cwd"].startswith("/") and "replayFrom" not in params
        if method == "session/resume":
            assert params["sessionId"] == session
        if method == "session/resume" and mode == "resume_busy":
            entity_id = "resume-tool"
            state("requires_action")
            permit("resume-request")
        elif mode != "cancel_setup_quiet":
            state("running" if mode in ["early_state", "cancel_setup"] else "idle", **({} if mode in ["early_state", "cancel_setup"] else {"stopReason": "end_turn"}))
        result(request, {"sessionId": session, "configOptions": config()})
    elif method == "session/set_config_option":
        key = params["configId"]
        assert params["type"] == ("boolean" if key == "boolean" else "id")
        values[key] = params["value"]
        if mode in ["cancel_setup", "cancel_setup_quiet"]:
            held_config = request
            open(gate + ".config", "w").close()
            continue
        result(request, {"configOptions": config()})
    elif method == "session/prompt":
        if mode in ["cancel_setup", "cancel_setup_quiet"]:
            open(gate + ".prompt", "w").close()
        turn += 1
        prompt_id = request["id"]
        entity_id = "shared-" + uuid.uuid4().hex
        user_id = "user-" + uuid.uuid4().hex
        inserted = False
        if mode == "resume_busy" and "resume-request" in permissions:
            held_prompt = request
            continue
        for block in params["prompt"]:
            if block["type"] == "image":
                assert block["mimeType"] == "image/png" and base64.b64decode(block["data"]).startswith(b"\x89PNG")
        if mode == "cancel_before":
            continue
        if mode in ["reject", "hook_failure"]:
            if mode == "hook_failure":
                state("running")
            send({"id": prompt_id, "error": {"code": -32000, "message": "Rejected before insertion"}})
            if mode == "hook_failure":
                state("idle", stopReason="error", error={"code": -32000, "message": "Hook failed"})
            prompt_id = None
            continue
        inserted = True
        if mode != "echo_after":
            echo()
        if mode not in ["idle_before_ack", "lost_ack"]:
            result(request, {"messageId": user_id})
        if mode in ["accept_only", "repeat_idle"]:
            if mode == "repeat_idle":
                state("idle", stopReason="end_turn")
                state("idle", stopReason="end_turn")
            wait_gate()
        state("running")
        if mode == "exit_after_ack":
            update("agent_message", messageId=entity_id, content=[{"type": "text", "text": "hello 🌍"}])
            state("idle", stopReason="end_turn")
            sys.exit(0)
        if mode in ["cancel_after", "cancel_ignored"]:
            continue
        update("agent_message", messageId=entity_id, content=[{"type": "text", "text": "old"}])
        update("agent_message_chunk", messageId=entity_id, content={"type": "text", "text": " chunk"})
        update("agent_thought", messageId=entity_id, content=[{"type": "text", "text": "Thinking"}])
        update("tool_call_update", toolCallId=entity_id, title="Fixture tool", status="pending", rawInput={"path": "synthetic", "boolean": values["boolean"]})
        update("terminal_output_chunk", terminalId=entity_id, data=base64.b64encode(bytes([0xF0, 0x9F])).decode())
        update("terminal_output_chunk", terminalId=entity_id, data=base64.b64encode(bytes([0x8C, 0x8D])).decode())
        update("plan_update", plan={"type": "items", "planId": entity_id, "entries": [{"content": "Fixture plan", "status": "completed", "priority": "medium"}]})
        update("_future", raw={"preserved": True})
        if mode in ["idle_before_ack", "lost_ack"]:
            update("agent_message", messageId=entity_id, content=[{"type": "text", "text": "hello 🌍"}])
            state("idle", stopReason="end_turn")
            if mode == "idle_before_ack":
                wait_gate()
                result(request, {"messageId": user_id})
            continue
        permit("req-" + str(turn) + "-one")
        if mode == "concurrent_requests":
            permit("req-" + str(turn) + "-two")
        state("requires_action")
    elif method == "$/cancel_request":
        if mode == "cancel_ignored":
            continue
        if params["requestId"] == prompt_id and not inserted:
            send({"id": prompt_id, "error": {"code": -32800, "message": "Request cancelled before insertion"}})
            prompt_id = None
    elif method == "session/cancel":
        if mode != "cancel_ignored":
            permissions.clear()
            state("idle", stopReason="cancelled")
            if held_config is not None:
                result(held_config, {"configOptions": config()})
                held_config = None
    elif method == "session/close":
        result(request, {})
    elif "result" in request:
        request_id = request["id"]
        if request_id in permissions:
            outcome = request["result"]["outcome"]
            assert outcome == {"outcome": "selected", "optionId": "opaque-allow"} or outcome == {"outcome": "cancelled"}
            permissions.remove(request_id)
            if request_id == "resume-request":
                state("running")
                if held_prompt is not None:
                    inserted = True
                    result(held_prompt, {"messageId": user_id})
                    echo()
                    update("agent_message", messageId=entity_id, content=[{"type": "text", "text": "hello 🌍"}])
                    state("idle", stopReason="end_turn")
                    held_prompt = None
                    prompt_id = None
            elif request_id == "background-request":
                update("tool_call_update", toolCallId="ambient-tool", status="completed", rawOutput={"saved": "while idle"})
            elif not any(key.startswith("req-") for key in permissions):
                state("running")
                finish()
    else:
        raise AssertionError("Unexpected frame " + str(method))
