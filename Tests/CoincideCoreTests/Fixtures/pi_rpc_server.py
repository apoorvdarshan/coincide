#!/usr/bin/python3
"""Task-owned native Pi JSONL peer. No vendor imports/auth/network/model calls."""
import json
import os
import sys
import threading
import time

if sys.argv[1:3] == ["--mode", "rpc"]:
    root = os.getcwd()
    options_path, wire_path = os.path.join(root, "options.json"), os.path.join(root, "wire.jsonl")
    extension_path = sys.argv[4] if sys.argv[3:4] == ["--extension"] else ""
    with open(extension_path, encoding="utf8") as extension:
        source = extension.read()
    policy = next((mode for mode in ["supervised", "autoAcceptEdits", "auto", "fullAccess"]
                   if ('const mode = "' + mode + '"') in source), "unknown")
    with open(os.path.join(root, "launch.json"), "w", encoding="utf8") as launch:
        json.dump({"args": sys.argv[1:], "toolHook": 'pi.on("tool_call"' in source,
                   "supervised": policy == "supervised"}, launch)
    with open(os.path.join(root, "processes.jsonl"), "a", encoding="utf8") as processes:
        processes.write(json.dumps({"pid": os.getpid(), "policy": policy}) + "\n")
else:
    root, options_path, wire_path = sys.argv[1:4]
lock = threading.RLock()
held_state = False
state = {"model": {"provider": "native", "id": "baseline"}, "thinkingLevel": "medium",
         "isStreaming": False, "isCompacting": False, "pendingMessageCount": 0,
         "sessionFile": os.path.join(root, "native-session.jsonl"), "sessionId": "display-only"}
if not os.path.exists(state["sessionFile"]):
    with open(state["sessionFile"], "w", encoding="utf8") as file:
        file.write(json.dumps({"type": "session", "id": "native", "cwd": root, "version": 3}) + "\n")

def options():
    try:
        with open(options_path, encoding="utf8") as file:
            return json.load(file)
    except (OSError, ValueError):
        return {}

def emit(value):
    with lock:
        data = (json.dumps(value, ensure_ascii=False) + "\n").encode("utf8")
        # Deliberately split a multibyte character across pipe writes.
        split = data.find("日".encode("utf8"))
        if split >= 0:
            sys.stdout.buffer.write(data[:split + 1]); sys.stdout.buffer.flush()
            sys.stdout.buffer.write(data[split + 1:])
        else:
            sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()

def reply(frame, data=None, success=True, command=None):
    emit({"type": "response", "id": frame.get("id"), "command": command or frame["type"],
          "success": success, "data": data, "error": None if success else "synthetic-private-token"})

def start():
    with lock:
        state["isStreaming"] = True
    emit({"type": "agent_start"})
    emit({"type": "message_start", "message": {"role": "assistant"}})
    emit({"type": "message_update", "message": {"role": "assistant"}, "assistantMessageEvent":
          {"type": "text_delta", "contentIndex": 0, "delta": "日本語\u2028exact "}})
    emit({"type": "tool_execution_start", "toolCallId": "tool-1", "toolName": "read"})
    emit({"type": "tool_execution_update", "toolCallId": "tool-1", "partialResult": {"content": [{"type": "text", "text": "partial"}]}})

def finish(aborted=False, failed=False, settle=True):
    emit({"type": "tool_execution_end", "toolCallId": "tool-1", "isError": False,
          "result": {"content": [{"type": "text", "text": "complete"}]}})
    emit({"type": "message_end", "message": {"role": "assistant", "stopReason": "aborted" if aborted else "error" if failed else "stop",
          "errorMessage": "synthetic-private-token", "content": [{"type": "text", "text": "日本語\u2028exact done"}]}})
    emit({"type": "agent_end", "messages": []})
    if settle:
        with lock:
            state["isStreaming"] = False
        emit({"type": "agent_settled", "aborted": aborted})

def handle(frame):
    global held_state
    kind = frame.get("type")
    opts = options()
    if kind == "get_state":
        with lock:
            snapshot = dict(state)
            hold = opts.get("holdNextState") and not held_state
            if hold:
                held_state = True
        if hold:
            with open(os.path.join(root, "held-state"), "w", encoding="utf8") as marker:
                marker.write("held")
            while options().get("holdNextState"):
                time.sleep(.005)
        reply(frame, snapshot)
    elif kind == "get_available_models":
        reply(frame, {"models": [{"provider": "native", "id": "baseline", "name": "Baseline", "reasoning": True,
                                  "thinkingLevelMap": {"minimal": None, "xhigh": "high", "max": "max"}},
                                 {"provider": "other", "id": "model/with/slash", "name": "Other", "reasoning": False}]})
    elif kind == "switch_session":
        if opts.get("switchCancelled"):
            reply(frame, {"cancelled": True})
        else:
            with lock:
                state["sessionFile"] = frame["sessionPath"]
            reply(frame, {"cancelled": False})
    elif kind == "set_model":
        while options().get("holdModel") and not options().get("releaseModel"):
            time.sleep(.005)
        with lock:
            state["model"] = {"provider": frame["provider"], "id": frame["modelId"]}
        reply(frame, state["model"])
    elif kind == "set_thinking_level":
        with lock:
            state["thinkingLevel"] = frame["level"]
        reply(frame)
    elif kind == "compact":
        with lock:
            state["isCompacting"] = True
        while options().get("holdCompact"):
            time.sleep(.005)
        with lock:
            state["isCompacting"] = False
        reply(frame, {"summary": "Synthetic compact summary"})
    elif kind == "prompt":
        if opts.get("rejectPrompt"):
            reply(frame, success=False)
            return
        if opts.get("foreignResponse"):
            emit({"id": "foreign-id", "type": "response", "command": "prompt", "success": False, "error": "synthetic-private-token"})
        if opts.get("beforeAck"):
            start(); finish()
            while options().get("holdAck"):
                time.sleep(.005)
        if opts.get("dropReply"):
            os._exit(0)
        reply(frame, {"disposition": "started"})
        if not opts.get("beforeAck"):
            while options().get("holdStart"):
                time.sleep(.005)
            start()
        if opts.get("ui"):
            emit({"type": "extension_ui_request", "id": "native-ui", "method": opts["ui"], "title": "Review action",
                  "message": "Exact details", "options": ["One", "Two"], "prefill": "existing", "placeholder": "Write here"})
    elif kind == "abort":
        finish(aborted=True, settle=not opts.get("deferAbortSettled"))
        if opts.get("deferAbortSettled"):
            with lock:
                state["isStreaming"] = False
        while options().get("holdAbortAck"):
            time.sleep(.005)
        reply(frame)
    elif kind == "clear_queue":
        with lock:
            state["pendingMessageCount"] = 0
        reply(frame, {"steering": [], "followUp": []})
    elif kind == "extension_ui_response":
        return
    else:
        reply(frame, success=False)

def signals():
    seen = None
    while True:
        signal = options().get("signal")
        if signal and signal.get("id") != seen and signal.get("pid", os.getpid()) == os.getpid():
            seen = signal["id"]
            name = signal.get("name")
            if name == "endOnly":
                finish(settle=False)
            elif name == "finish":
                finish()
            elif name == "settled":
                emit({"type": "agent_settled", "aborted": True})
            elif name == "failed":
                finish(failed=True)
            elif name == "settledCompaction":
                with lock:
                    state["isStreaming"] = False
                    state["isCompacting"] = True
                emit({"type": "agent_settled"})
                emit({"type": "compaction_start"})
                emit({"type": "tool_execution_update", "toolCallId": "tool-1", "partialResult": {"content": [{"type": "text", "text": "compaction barrier"}]}})
            elif name == "compactionEnd":
                with lock:
                    state["isCompacting"] = False
                emit({"type": "compaction_end", "aborted": False})
            elif name == "foreign":
                emit({"type": "agent_settled", "sessionFile": "/foreign/session.jsonl"})
            elif name == "invalid":
                with lock:
                    sys.stdout.buffer.write(b'{invalid}\n'); sys.stdout.buffer.flush()
            elif name == "exit":
                os._exit(0)
        time.sleep(.005)

threading.Thread(target=signals, daemon=True).start()
for line in sys.stdin.buffer:
    frame = json.loads(line)
    with lock:
        with open(wire_path, "a", encoding="utf8") as file:
            file.write(json.dumps(frame) + "\n")
    threading.Thread(target=handle, args=(frame,), daemon=True).start()
