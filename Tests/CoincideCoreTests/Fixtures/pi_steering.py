#!/usr/bin/python3
"""Native Pi JSONL contract peer; private stdio only, no Pi/vendor dependencies.

Shapes follow provider-pi adapter.ts and Pi rpc-mode.ts. Responses correlate by
id; session events intentionally do not carry a fabricated turn/input identity.
"""
import json
import os
import sys
import threading
import time

root = os.getcwd() if sys.argv[1:3] == ["--mode", "rpc"] else sys.argv[1]
lock = threading.RLock()
ui_reply = threading.Event()
stopped = threading.Event()
state_held = False
session_file = os.path.join(root, "native-session.jsonl")
state = {"model": {"provider": "native", "id": "baseline"}, "thinkingLevel": "medium",
         "isStreaming": False, "isCompacting": False, "pendingMessageCount": 0,
         "sessionFile": session_file, "sessionId": "owned-native-session"}
with open(os.path.join(root, "parents.jsonl"), "a", encoding="utf8") as out:
    out.write(json.dumps({"pid": os.getpid()}) + "\n")
if not os.path.exists(session_file):
    with open(session_file, "w", encoding="utf8") as out:
        out.write(json.dumps({"type": "session", "id": "owned-native-session", "cwd": root, "version": 3}) + "\n")


def options():
    try:
        with open(os.path.join(root, "options.json"), encoding="utf8") as out:
            return json.load(out)
    except (OSError, ValueError):
        return {}


def emit(frame):
    with lock:
        sys.stdout.buffer.write((json.dumps(frame, ensure_ascii=False) + "\n").encode("utf8"))
        sys.stdout.buffer.flush()


def reply(frame, data=None, success=True):
    emit({"type": "response", "id": frame["id"], "command": frame["type"], "success": success,
          "data": data, "error": None if success else "PRIVATE_NATIVE_ERROR_CANARY"})


def start(text):
    with lock:
        state["isStreaming"] = True
        state["pendingMessageCount"] = 0
    emit({"type": "agent_start"})
    emit({"type": "message_start", "message": {"role": "assistant"}})
    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": text}})
    emit({"type": "tool_execution_start", "toolCallId": "owned-tool", "toolName": "read"})


def finish(aborted=False):
    emit({"type": "message_end", "message": {"role": "assistant", "stopReason": "aborted" if aborted else "stop",
          "content": [{"type": "text", "text": "native finished"}]}})
    emit({"type": "agent_end", "messages": []})
    with lock:
        state["isStreaming"] = False
        state["pendingMessageCount"] = 0
    emit({"type": "agent_settled", "aborted": aborted})


def handle(frame):
    global state_held
    kind, opts = frame["type"], options()
    if kind == "get_state":
        with lock:
            snapshot = dict(state)
            hold = opts.get("holdIdle") and not state_held
            if hold:
                state_held = True
        if hold:
            with open(os.path.join(root, "held-idle"), "w", encoding="utf8") as out:
                out.write("held")
            while options().get("holdIdle") and not stopped.is_set():
                time.sleep(.005)
        reply(frame, snapshot)
    elif kind == "switch_session":
        state["sessionFile"] = frame["sessionPath"]
        reply(frame, {"cancelled": False})
    elif kind == "set_model":
        state["model"] = {"provider": frame["provider"], "id": frame["modelId"]}
        reply(frame, state["model"])
    elif kind == "set_thinking_level":
        state["thinkingLevel"] = frame["level"]
        reply(frame)
    elif kind == "get_available_models":
        reply(frame, {"models": [{"provider": "native", "id": "baseline", "name": "Baseline", "reasoning": True}]})
    elif kind == "prompt" and not frame["message"].startswith("STEER"):
        reply(frame, {"disposition": "started"})
        start("opening 日本語")
    elif kind in ("prompt", "compact"):
        if opts.get("rejectSteering"):
            reply(frame, success=False)
            return
        if opts.get("foreignReply"):
            emit({"type": "response", "id": "unowned-id", "command": kind, "success": False})
            emit({"type": "agent_settled", "sessionFile": "/unowned/session.jsonl"})
        if opts.get("uiOnSteer"):
            emit({"type": "extension_ui_request", "id": "steering-confirm", "method": "confirm", "title": "Confirm native input", "message": "Review this request"})
            ui_reply.wait(5)
        if kind == "compact":
            state["isCompacting"] = True
            emit({"type": "compaction_start"})
            state["isCompacting"] = False
            emit({"type": "compaction_end", "aborted": False})
        elif opts.get("startSteeringCycle"):
            if opts.get("abortedPriorCycle"):
                finish(aborted=True)
            start("steering continuation")
        if opts.get("terminalBeforeACK"):
            finish()
            # This barrier proves the stream consumed the terminal first.
            emit({"type": "extension_ui_request", "id": "notice", "method": "notify", "message": "terminal barrier"})
        while options().get("holdSteeringACK") and not stopped.is_set():
            time.sleep(.005)
        reply(frame, {"disposition": "queued" if state["isStreaming"] else "started"})
    elif kind == "abort":
        finish(aborted=True)
        reply(frame)
    elif kind == "clear_queue":
        state["pendingMessageCount"] = 0
        reply(frame, {"steering": [], "followUp": []})
    elif kind == "extension_ui_response":
        ui_reply.set()
    else:
        reply(frame, success=False)


def signals():
    seen = None
    while not stopped.is_set():
        signal = options().get("signal")
        if signal and signal.get("id") != seen and signal.get("pid", os.getpid()) == os.getpid():
            seen = signal["id"]
            if signal["name"] == "finish":
                finish()
        time.sleep(.005)


threading.Thread(target=signals, daemon=True).start()
for line in sys.stdin.buffer:
    frame = json.loads(line)
    with lock:
        with open(os.path.join(root, "wire.jsonl"), "a", encoding="utf8") as out:
            out.write(json.dumps(frame) + "\n")
    threading.Thread(target=handle, args=(frame,), daemon=True).start()
stopped.set()
