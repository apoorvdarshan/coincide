#!/usr/bin/python3 -S
"""Offline ACP peer; synthetic protocol frames only, no Grok/provider imports."""
import json
import os
import pathlib
import signal
import sys

# The transport closes stdin before sending TERM. Drain already-written native
# cancellation frames to EOF, rather than racing signal delivery in this peer.
signal.signal(signal.SIGTERM, lambda *_: None)
os.umask(0o077)

flow, version = sys.argv[1], int(sys.argv[2])
sid = "grok-synthetic"
count = 0
pending = None
first_prompt = None


def send(value):
    print(json.dumps(dict(jsonrpc="2.0", **value), ensure_ascii=False), flush=True)


def reply(request, value):
    send({"id": request["id"], "result": value})


def notice(method, fields):
    send({"method": method, "params": dict(sessionId=sid, **fields)})


def update(prompt, fields):
    notice("session/update", {"_meta": {"promptId": prompt}, "update": fields})


def complete(prompt, reason="end_turn", snake=False):
    if snake:
        notice("_x.ai/session_notification", {"update": {"sessionUpdate": "turn_completed", "prompt_id": prompt, "stop_reason": reason}})
    else:
        notice("_x.ai/session/prompt_complete", {"promptId": prompt, "stopReason": reason,
               "agentResult": "synthetic-private-upstream-body" if reason in ["error", "rate_limit"] else None})


for line in sys.stdin:
    value = json.loads(line)
    method = value.get("method")
    params = value.get("params", {})
    if method is not None:
        with (pathlib.Path.cwd() / "audit-methods").open("a", encoding="utf-8") as audit:
            audit.write(method + "\n")
    if method == "initialize":
        assert params.get("_meta") == {"clientType": "extension"}
        if version == 1:
            reply(value, {"protocolVersion": 1, "agentInfo": {"name": "synthetic-grok", "version": "1"},
                          "agentCapabilities": {"loadSession": True, "promptCapabilities": {"image": False}},
                          "authMethods": [{"id": "cached_token", "name": "Grok login"}, {"id": "xai.api_key", "name": "Existing API key"}]})
        else:
            reply(value, {"protocolVersion": 2, "info": {"name": "synthetic-grok", "version": "2"},
                          "capabilities": {"session": {"resume": {}, "prompt": {}}},
                          "authMethods": [{"id": "cached_token", "name": "Grok login"}, {"id": "xai.api_key", "name": "Existing API key"}]})
    elif method == "authenticate":
        assert params.get("methodId") in ["cached_token", "xai.api_key"]
        if flow == "auth-reject":
            send({"id": value["id"], "error": {"code": -32000, "message": "synthetic-private-upstream-body"}})
        else:
            reply(value, {})
    elif method in ["session/new", "session/load", "session/resume"]:
        reply(value, {"sessionId": sid, "configOptions": [],
                      "models": {"currentModelId": "grok-synthetic-model", "availableModels": [
                          {"modelId": "grok-synthetic-model", "name": "Synthetic model", "_meta": {"totalContextTokens": 32000}}]},
                      "unknownCredential": "synthetic-private-upstream-body"})
    elif method == "session/prompt":
        count += 1
        prompt = params["_meta"]["promptId"]
        assert params["_meta"]["requestId"] == prompt
        if first_prompt is None:
            first_prompt = prompt
        update(prompt, {"sessionUpdate": "agent_message_chunk", "messageId": "same-native-message",
                        "content": {"type": "text", "text": "owned-%d 工作 🌍" % count}})
        if flow == "rpc-reject":
            # The exact prompt request fails before an insertion ACK. The raw
            # upstream body must never become a durable user/foreground error.
            update(prompt, {"sessionUpdate": "state_update", "state": "running"})
            send({"id": value["id"], "error": {"code": -32603, "message": "synthetic-private-rpc-error",
                  "data": {"message": "synthetic-private-upstream-body"}}})
            continue
        if version == 2:
            update(prompt, {"sessionUpdate": "state_update", "state": "running"})
            reply(value, {"messageId": "native-inserted-" + str(count)})
        if flow == "background" and count == 1:
            update(prompt, {"sessionUpdate": "tool_call", "toolCallId": "monitor-tool", "title": "Tool", "kind": "execute", "status": "completed",
                            "rawInput": {"variant": "Monitor", "description": "Synthetic monitor", "persistent": True},
                            "rawOutput": {"type": "Monitor", "taskId": "monitor-native", "persistent": True}})
            complete(prompt)
        elif flow == "background" and count == 2:
            # Prior task and completion frames arrive during the next turn.
            notice("_x.ai/task_completed", {"update": {"sessionUpdate": "task_completed", "task_id": "monitor-native",
                   "task_snapshot": {"task_id": "monitor-native", "kind": "monitor", "output": "old monitor finished", "exit_code": 0}}})
            update(first_prompt, {"sessionUpdate": "tool_call_update", "toolCallId": "monitor-tool", "status": "completed",
                                  "rawOutput": {"type": "Monitor", "taskId": "monitor-native", "persistent": True}})
            complete(first_prompt)
            complete("task-completed-monitor-native")
            update(prompt, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": " second remains owned"}})
            complete(prompt, snake=True)
        elif flow in ["question", "permission", "deferred", "deferred-idle", "plan"]:
            pending = (value, prompt)
            if flow == "question":
                send({"id": "reused-native-question", "method": "_x.ai/ask_user_question", "params": {
                    "method": "_x.ai/ask_user_question", "params": {"sessionId": sid, "toolCallId": "ask-tool", "mode": "plan",
                    "questions": [{"id": "choice", "question": "Choose native labels", "multiSelect": False,
                                   "options": [{"id": "opaque", "label": "Native label", "preview": "# Preview"}]}],
                    "unknownCredential": "synthetic-private-upstream-body"}}})
            elif flow == "plan":
                send({"id": "native-plan", "method": "x.ai/exit_plan_mode", "params": {"sessionId": sid, "toolCallId": "plan-tool", "planContent": "# Synthetic proposal"}})
            else:
                if flow in ["deferred", "deferred-idle"]:
                    update(prompt, {"sessionUpdate": "tool_call", "toolCallId": "shell-tool", "title": "Bash", "status": "completed",
                                    "rawInput": {"command": "printf synthetic"}, "rawOutput": {"type": "BackgroundTaskStarted", "task_id": "call-native-task", "command": "printf synthetic"}})
                    complete(prompt)
                    if flow == "deferred-idle":
                        update(prompt, {"sessionUpdate": "state_update", "state": "idle", "stopReason": "end_turn"})
                send({"id": "permission", "method": "session/request_permission", "params": {"sessionId": sid,
                    "toolCall": {"toolCallId": "edit-tool", "title": "Edit", "kind": "edit"}, "options": [
                        {"optionId": "once", "name": "Once", "kind": "allow_once"},
                        {"optionId": "reject", "name": "Decline", "kind": "reject_once"},
                        {"optionId": "always-workspace", "name": "Always", "kind": "allow_always"},
                        {"optionId": "allow-edits-session", "name": "Edits", "kind": "allow_always"}]}})
        elif flow == "cancel":
            pass  # Only the exact session/cancel message can end this peer's turn.
        elif flow in ["error", "rate_limit"]:
            complete(prompt, flow)
        elif flow == "rpc" and version == 1:
            reply(value, {"stopReason": "end_turn", "_meta": {"promptId": prompt}})
        else:
            complete("foreign-prompt")
            complete("task-completed-foreign")
            update(prompt, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": " after unrelated terminals"}})
            complete(prompt, snake=flow == "snake")
    elif method == "session/cancel":
        assert params == {"sessionId": sid, "_meta": {"cancelTrigger": "ctrl_c"}}
        (pathlib.Path.cwd() / "cancel-proof").write_text("exact", encoding="utf-8")
    elif method == "session/close":
        reply(value, {})
    elif method in ["session/set_mode", "session/set_config_option", "session/set_model"]:
        reply(value, {})
    elif method is None and pending is not None:
        request, prompt = pending
        if flow == "question":
            assert value["result"] == {"outcome": "accepted", "answers": {"Choose native labels": ["Native label"]},
                    "annotations": {"Choose native labels": {"preview": "# Preview", "notes": "Additional native notes"}}}
        elif flow == "plan":
            assert value["result"]["outcome"] == "abandoned"
        else:
            assert value["result"]["outcome"] == {"outcome": "selected", "optionId": "once"}
        if flow in ["deferred", "deferred-idle"]:
            notice("_x.ai/task_completed", {"update": {"sessionUpdate": "task_completed", "task_id": "call-native-task",
                   "task_snapshot": {"task_id": "call-native-task", "output": "background shell finished", "exit_code": 0}}})
        complete(prompt)
        pending = None
