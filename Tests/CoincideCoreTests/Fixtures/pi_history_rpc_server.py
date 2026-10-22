#!/usr/bin/python3
"""Private native Pi RPC peer. No vendor module, model, auth or network."""
import json
import os
import sys
import threading
import time

root = os.getcwd()
lock = threading.RLock()
stopping = threading.Event()
options_path = os.path.join(root, "options.json")
wire_path = os.path.join(root, "wire.jsonl")


def options():
    try:
        with open(options_path, encoding="utf8") as file:
            return json.load(file)
    except (OSError, ValueError):
        return {}


def record(value):
    with lock:
        with open(wire_path, "a", encoding="utf8") as file:
            file.write(json.dumps(value, ensure_ascii=False) + "\n")


record({"kind": "launch", "pid": os.getpid(), "versionOnly": sys.argv[1:] == ["--version"],
        "homeMatches": os.environ.get("HOME") == root,
        "agentOverride": "PI_CODING_AGENT_DIR" in os.environ,
        "agentPath": os.environ.get("PI_CODING_AGENT_DIR"),
        "sessionOverride": "PI_CODING_AGENT_SESSION_DIR" in os.environ})
if sys.argv[1:] == ["--version"]:
    print(options().get("version", "0.80.5"), flush=True)
    sys.exit(0)
if sys.argv[1:3] != ["--mode", "rpc"]:
    sys.exit(2)

session_dir = os.path.expanduser(os.environ.get("PI_CODING_AGENT_SESSION_DIR", os.path.join(root, "native")))
os.makedirs(session_dir, mode=0o700, exist_ok=True)
session_file = os.path.join(session_dir, "2026-01-01T00-00-00-000Z_native-session.jsonl")
header = {"type": "session", "version": 3, "id": "native-session", "timestamp": "2026-01-01T00:00:00.000Z", "cwd": root}
entries = []
leaf = None
next_entry = 0
state = {"model": {"provider": "native", "id": "baseline"}, "thinkingLevel": "medium",
         "isStreaming": False, "isCompacting": False, "steeringMode": "all", "followUpMode": "all",
         "sessionFile": session_file, "sessionId": "native-session", "pendingMessageCount": 0,
         "messageCount": 0, "autoCompactionEnabled": True}


def load_session(path):
    global entries, leaf, next_entry, header, session_file
    with open(path, encoding="utf8") as file:
        values = [json.loads(line) for line in file if line.strip()]
    header, entries = values[0], values[1:]
    leaf = entries[-1]["id"] if entries else None
    next_entry = max([int(item["id"], 16) for item in entries] or [0])
    session_file = path
    state["sessionFile"], state["sessionId"] = path, header["id"]
    for item in entries:
        if item["type"] == "model_change":
            state["model"] = {"provider": item["provider"], "id": item["modelId"]}
        elif item["type"] == "thinking_level_change":
            state["thinkingLevel"] = item["thinkingLevel"]


if os.path.exists(session_file):
    load_session(session_file)


def emit(value):
    with lock:
        sys.stdout.write(json.dumps(value, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def reply(frame, data=None, success=True):
    emit({"id": frame.get("id"), "type": "response", "command": frame["type"], "success": success,
          "data": data, "error": None if success else "private-native-error-canary"})


def append(kind, **values):
    global leaf, next_entry
    with lock:
        next_entry += 1
        entry = {"id": format(next_entry, "08x"), "parentId": leaf, "type": kind,
                 "timestamp": "2026-01-01T00:00:00.000Z", **values}
        entries.append(entry)
        leaf = entry["id"]
        if any(item["type"] == "message" and item["message"]["role"] == "assistant" for item in entries):
            with open(session_file, "w", encoding="utf8") as file:
                for item in [header, *entries]:
                    file.write(json.dumps(item, ensure_ascii=False) + "\n")
        return entry


def finish(aborted=False):
    with lock:
        append("message", message={"role": "assistant", "content": [{"type": "text", "text": "native completion"}],
                                   "stopReason": "aborted" if aborted else "stop", "timestamp": 1})
        state["isStreaming"] = False
        state["messageCount"] += 1
    emit({"type": "message_end", "message": {"role": "assistant", "content": [{"type": "text", "text": "native completion"}],
                                             "stopReason": "aborted" if aborted else "stop"}})
    emit({"type": "agent_end", "messages": []})
    emit({"type": "agent_settled", "aborted": aborted})


def handle(frame):
    global leaf
    record({"kind": "request", **frame})
    kind = frame["type"]
    if kind == "get_state":
        with lock:
            snapshot = dict(state)
        reply(frame, snapshot)
    elif kind == "get_entries":
        with lock:
            selected = list(entries)
            if "since" in frame:
                indexes = [index for index, item in enumerate(selected) if item["id"] == frame["since"]]
                if not indexes:
                    reply(frame, success=False)
                    return
                selected = selected[indexes[0] + 1:]
            snapshot = {"entries": selected, "leafId": leaf}
            hold = not state["isStreaming"] and any(item["type"] == "message" and item["message"]["role"] == "assistant" for item in entries)
        if hold and options().get("holdFinalEntries"):
            record({"kind": "gate", "name": "finalEntriesHeld"})
            while options().get("holdFinalEntries") and not stopping.is_set():
                time.sleep(.005)
        reply(frame, snapshot)
    elif kind == "set_model":
        with lock:
            state["model"] = {"provider": frame["provider"], "id": frame["modelId"]}
            append("model_change", provider=frame["provider"], modelId=frame["modelId"])
        reply(frame, state["model"])
    elif kind == "switch_session":
        with lock:
            load_session(frame["sessionPath"])
        reply(frame, {"cancelled": False})
    elif kind == "set_thinking_level":
        with lock:
            state["thinkingLevel"] = frame["level"]
            append("thinking_level_change", thinkingLevel=frame["level"])
        reply(frame)
    elif kind == "prompt":
        if options().get("rejectPrompt"):
            reply(frame, success=False)
            return
        with lock:
            was_streaming = state["isStreaming"]
            state["isStreaming"] = True
            text = "extension rewrote input" if options().get("rewriteInput") else frame["message"]
            append("message", message={"role": "user", "content": [{"type": "text", "text": text}, *frame.get("images", [])], "timestamp": 1})
            state["messageCount"] += 1
        if not was_streaming:
            emit({"type": "agent_start"})
            emit({"type": "message_start", "message": {"role": "assistant"}})
            emit({"type": "message_update", "message": {"role": "assistant"},
                  "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "native "}})
        if options().get("holdPromptACK"):
            record({"kind": "gate", "name": "promptACKHeld"})
        while options().get("holdPromptACK") and not stopping.is_set():
            time.sleep(.005)
        reply(frame)
    elif kind == "compact":
        append("compaction", summary="native summary", firstKeptEntryId=entries[0]["id"] if entries else "none", tokensBefore=10)
        reply(frame)
    elif kind == "abort":
        finish(aborted=True)
        reply(frame)
    elif kind == "clear_queue":
        reply(frame, {"steering": [], "followUp": []})
    elif kind == "get_available_models":
        reply(frame, {"models": [{"provider": "native", "id": "baseline", "name": "Native", "reasoning": True}]})
    else:
        reply(frame, success=False)


def signals():
    global leaf
    seen = set()
    while not stopping.wait(.005):
        value = options().get("signal")
        if not isinstance(value, dict) or value.get("id") in seen:
            continue
        seen.add(value.get("id"))
        name = value.get("name")
        if name == "finish":
            finish()
        elif name == "endOnly":
            emit({"type": "message_end", "message": {"role": "assistant", "content": [{"type": "text", "text": "native completion"}], "stopReason": "stop"}})
            emit({"type": "agent_end", "messages": []})
        elif name == "moveLeaf":
            with lock:
                leaf = None
        elif name == "unownedUser":
            append("message", message={"role": "user", "content": "unowned native input", "timestamp": 1})
        record({"kind": "signal", "name": name})


threading.Thread(target=signals, daemon=True).start()
try:
    for line in sys.stdin:
        frame = json.loads(line)
        threading.Thread(target=handle, args=(frame,), daemon=True).start()
finally:
    stopping.set()
    record({"kind": "closed", "pid": os.getpid()})
