import json
import sys
import traceback
import os
import time
import uuid

mode = sys.argv[1] if len(sys.argv) > 1 else "normal"
session = "fixture-session"
prompt_id = None
tool_id = ""
message_id = ""
chosen_model = "default"
chosen_mode = "code"
new_sessions = 0


def send(value):
    print(json.dumps({"jsonrpc": "2.0", **value}, ensure_ascii=False), flush=True)


def result(request, value):
    send({"id": request["id"], "result": value})


def failed(kind, error, trace):
    line = traceback.extract_tb(trace)[-1].lineno
    send({"id": prompt_id if prompt_id is not None else request.get("id"),
          "error": {"code": -32000, "message": f"ACP fixture failed at line {line}: {error}"}})


sys.excepthook = failed


def update(variant, **fields):
    send({"method": "session/update", "params": {
        "sessionId": session, "update": {"sessionUpdate": variant, **fields}}})


def setup():
    if mode == "config":
        return {"configOptions": [
            {"id": "future-model", "name": "Future model UI", "type": "future", "category": "model", "currentValue": "future"},
            {"id": "opaque-model", "name": "Model", "type": "select", "category": "model", "currentValue": chosen_model,
             "options": [{"group": "models", "name": "Models", "options": [{"value": "default", "name": "Default"}, {"value": "fixture", "name": "Fixture"}]}]},
            {"id": "opaque-mode", "name": "Mode", "type": "select", "category": "mode", "currentValue": chosen_mode,
             "options": [{"value": "code", "name": "Code"}, {"value": "read", "name": "Read"}]}]}
    return {"models": {"currentModelId": chosen_model, "availableModels": [
        {"modelId": "default", "name": "Default"}, {"modelId": "fixture", "name": "Fixture"}]},
        "modes": {"currentModeId": chosen_mode, "availableModes": [
            {"id": "code", "name": "Code"}, {"id": "read", "name": "Read Only"}]}}


for line in sys.stdin:
    request = json.loads(line)
    assert request["jsonrpc"] == "2.0"
    method = request.get("method")
    params = request.get("params", {})
    if method == "initialize":
        assert params["protocolVersion"] == (2 if mode == "v2_fallback" else 1)
        assert params["clientCapabilities"] == {}
        result(request, {"protocolVersion": 2 if mode == "unsupported" else 1,
                         "agentCapabilities": {"loadSession": mode != "noresume",
                                               "promptCapabilities": {"image": mode != "noimage"}},
                         "authMethods": [{"id": "login", "name": "Sign in"}]})
    elif method == "session/new":
        new_sessions += 1
        assert new_sessions == 1
        assert params["cwd"].startswith("/") and params["mcpServers"] == []
        if mode == "auth":
            send({"id": request["id"], "error": {"code": -32000, "message": "Authentication required; sign in with the agent CLI."}})
        else:
            result(request, {"sessionId": session, **setup()})
    elif method == "session/load":
        assert params["sessionId"] == session
        # A burst makes notification-consumer lag observable without a time-based sleep.
        for _ in range(40):
            update("agent_message_chunk", content={"type": "text", "text": "OLD HISTORY"})
            update("user_message_chunk", content={"type": "text", "text": "OLD USER"})
        result(request, setup())
    elif method == "session/set_model":
        chosen_model = params["modelId"]
        assert chosen_model == "fixture"
        result(request, {})
    elif method == "session/set_config_option":
        assert mode == "config"
        if params["configId"] == "opaque-model":
            chosen_model = params["value"]
            assert chosen_model == "fixture"
        elif params["configId"] == "opaque-mode":
            chosen_mode = params["value"]
            assert chosen_mode == "read"
        else:
            raise AssertionError("Invented config option")
        result(request, setup())
    elif method == "session/set_mode":
        chosen_mode = params["modeId"]
        assert chosen_mode == "read"
        result(request, {})
    elif method == "session/prompt":
        assert params["sessionId"] == session
        prompt_id = request["id"]
        tool_id = "tool-" + uuid.uuid4().hex
        message_id = "message-" + uuid.uuid4().hex
        blocks = params["prompt"]
        text = next((block["text"] for block in blocks if block["type"] == "text"), "")
        if text == "images":
            assert blocks[0] == {"type": "image", "mimeType": "image/png", "data": "aW1hZ2U="}
            assert chosen_model == "fixture" and chosen_mode == "read"
        if text == "fail":
            send({"id": prompt_id, "error": {"code": -32000, "message": "Fixture prompt failed"}})
            prompt_id = None
            continue
        update("agent_thought_chunk", content={"type": "text", "text": "Thinking"})
        update("agent_message_chunk", messageId=message_id, content={"type": "text", "text": "hello "})
        if text == "hang":
            continue
        update("plan", entries=[{"content": "Read fixture", "status": "pending", "priority": "high"}])
        update("tool_call", toolCallId=tool_id, title="Read Fixture", kind="read", status="pending", rawInput={"path": "fixture.txt"})
        send({"id": "opaque-17", "method": "session/request_permission", "params": {
            "sessionId": session, "toolCall": {"toolCallId": tool_id, "title": "Read Fixture", "rawInput": {"path": "fixture.txt"}},
            "options": [{"optionId": "opaque-once", "name": "Read once", "kind": "allow_once"},
                        {"optionId": "opaque-always", "name": "Always read", "kind": "allow_always"},
                        {"optionId": "opaque-no", "name": "Reject", "kind": "reject_once"}]}})
    elif method == "session/cancel":
        assert "id" not in request and params["sessionId"] == session
        if mode == "ignorecancel":
            continue
        if prompt_id is not None:
            send({"id": prompt_id, "result": {"stopReason": "cancelled"}})
            prompt_id = None
    elif "result" in request and request["id"] == "opaque-17":
        outcome = request["result"]["outcome"]
        if outcome == {"outcome": "cancelled"}:
            continue
        assert outcome == {"outcome": "selected", "optionId": "opaque-once"} or outcome == {"outcome": "selected", "optionId": "opaque-no"}
        update("tool_call_update", toolCallId=tool_id, status="completed", rawOutput="Fixture tool result", content=[{"type": "content", "content": {"type": "text", "text": "Fixture tool result"}}])
        update("agent_message_chunk", messageId=message_id, content={"type": "text", "text": "🌍"})
        send({"id": prompt_id, "result": {"stopReason": "end_turn"}})
        prompt_id = None
        if mode == "background":
            while not os.path.exists(sys.argv[2]):
                time.sleep(.005)
            update("tool_call_update", toolCallId="background-tool", title="Background result", status="completed", rawOutput={"kept": "after idle"})
    else:
        raise AssertionError("Unexpected client frame: " + str(method))
