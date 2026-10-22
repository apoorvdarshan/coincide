#!/usr/bin/python3
"""Private v0.80.5-shaped history peer; no vendor, network, auth or model."""
import copy
import json
import os
import sys
import threading
import time
import uuid

ROOT = os.path.dirname(os.path.realpath(sys.argv[0]))
LOCK = threading.RLock()
STOP = threading.Event()
WIRE = os.path.join(ROOT, "operations-wire.jsonl")
OPTIONS = os.path.join(ROOT, "operations-options.json")
STAMP = "2026-01-01T00:00:00.000Z"


def options():
    try:
        with open(OPTIONS, encoding="utf8") as file:
            return json.load(file)
    except (OSError, ValueError):
        return {}


def record(value):
    with LOCK:
        with open(WIRE, "a", encoding="utf8") as file:
            file.write(json.dumps(value, ensure_ascii=False) + "\n")


def emit(value):
    with LOCK:
        sys.stdout.write(json.dumps(value, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def reply(frame, data=None):
    emit({"type": "response", "command": frame["type"], "id": frame.get("id"), "success": True, "data": data})


record({"kind": "launch", "pid": os.getpid(), "argv": sys.argv[1:]})
if sys.argv[1:] == ["--version"]:
    print("0.80.5", flush=True)
    sys.exit(0)
if sys.argv[1:3] != ["--mode", "rpc"]:
    sys.exit(2)

DIRECTORY = os.path.join(ROOT, "native")
os.makedirs(DIRECTORY, mode=0o700, exist_ok=True)
if "--session-dir" in sys.argv:
    DIRECTORY = sys.argv[sys.argv.index("--session-dir") + 1]

HEADER = None
ENTRIES = []
LEAF = None
PATH = None
MODEL = {"provider": "native", "id": "baseline"}
THINKING = "medium"
STREAMING = False
UI = {}


def persist(exclusive=False, force=False):
    # SessionManager delays its first write until an assistant is present;
    # forkFrom, unlike createBranchedSession, writes its entire copy directly.
    if not force and not any(row["type"] == "message" and row["message"]["role"] == "assistant" for row in ENTRIES):
        return
    with open(PATH, "x" if exclusive else "w", encoding="utf8") as file:
        for row in [HEADER, *ENTRIES]:
            file.write(json.dumps(row, ensure_ascii=False) + "\n")
    os.chmod(PATH, 0o600)


def fresh(parent=None, exact_path=None):
    global HEADER, ENTRIES, LEAF, PATH
    identity = str(uuid.uuid4())
    HEADER = {"type": "session", "version": 3, "id": identity, "timestamp": STAMP, "cwd": os.getcwd()}
    if parent is not None:
        HEADER["parentSession"] = parent
    PATH = exact_path or os.path.join(DIRECTORY, "2026-01-01T00-00-00-000Z_" + identity + ".jsonl")
    ENTRIES, LEAF = [], None


def load(path):
    global HEADER, ENTRIES, LEAF, PATH, MODEL, THINKING
    with open(path, encoding="utf8") as file:
        rows = [json.loads(line) for line in file if line.strip()]
    HEADER, ENTRIES, PATH = rows[0], rows[1:], path
    LEAF = ENTRIES[-1]["id"] if ENTRIES else None
    for row in ENTRIES:
        if row["type"] == "model_change":
            MODEL = {"provider": row["provider"], "id": row["modelId"]}
        elif row["type"] == "thinking_level_change":
            THINKING = row["thinkingLevel"]


def append(kind, **values):
    global LEAF
    row = {"type": kind, "id": uuid.uuid4().hex[:8], "parentId": LEAF, "timestamp": STAMP, **values}
    ENTRIES.append(row)
    LEAF = row["id"]
    persist()


fresh()
if "--fork" in sys.argv:
    source = sys.argv[sys.argv.index("--fork") + 1]
    load(source)
    copied = copy.deepcopy(ENTRIES)
    fresh(parent=source)
    ENTRIES = copied
    LEAF = ENTRIES[-1]["id"] if ENTRIES else None
    persist(exclusive=True, force=True)
    record({"kind": "cliClone", "path": PATH, "parent": source})


def fork(frame):
    global ENTRIES, LEAF, DIRECTORY
    if options().get("forkDialog"):
        event = threading.Event()
        box = {"event": event, "confirmed": False}
        UI["history-confirm"] = box
        emit({"type": "extension_ui_request", "id": "history-confirm", "method": "confirm", "title": "Native history lifecycle", "message": "Continue native fork?"})
        while not STOP.is_set() and not event.wait(.005):
            pass
        if not box["confirmed"]:
            reply(frame, {"cancelled": True})
            return
    if options().get("vetoFork"):
        reply(frame, {"cancelled": True})
        return
    by_id = {row["id"]: row for row in ENTRIES}
    target = by_id[frame["entryId"]]
    assert target["type"] == "message" and target["message"]["role"] == "user"
    cursor, reverse = target["parentId"], []
    while cursor is not None:
        reverse.append(by_id[cursor])
        cursor = by_id[cursor]["parentId"]
    retained = [copy.deepcopy(row) for row in reversed(reverse) if row["type"] != "label"]
    labels = {}
    for row in ENTRIES:
        if row["type"] == "label":
            if row.get("label"):
                labels[row["targetId"]] = row
            else:
                labels.pop(row["targetId"], None)
    source = PATH
    DIRECTORY = os.path.dirname(source)
    fresh(parent=source)
    parent = None
    for row in retained:
        row["parentId"] = parent
        ENTRIES.append(row)
        parent = row["id"]
    LEAF = parent
    kept_ids = {row["id"] for row in retained}
    for target_id, row in labels.items():
        if target_id in kept_ids:
            regenerated = copy.deepcopy(row)
            regenerated["id"], regenerated["parentId"] = uuid.uuid4().hex[:8], LEAF
            ENTRIES.append(regenerated)
            LEAF = regenerated["id"]
    persist()
    record({"kind": "rpcFork", "path": PATH, "parent": source, "empty": not ENTRIES})
    if options().get("loseForkACK"):
        os._exit(0)
    if options().get("wakeBeforeForkACK"):
        emit({"type": "agent_start"})
    while options().get("holdForkACK") and not STOP.wait(.005):
        pass
    content = target["message"]["content"]
    text = content if isinstance(content, str) else "".join(item.get("text", "") for item in content if item.get("type") == "text")
    reply(frame, {"cancelled": False, "text": text})


def handle(frame):
    global MODEL, THINKING, STREAMING
    kind = frame["type"]
    record({"kind": "request", "pid": os.getpid(), **frame})
    if kind == "get_state":
        reply(frame, {"sessionFile": PATH, "sessionId": HEADER["id"], "model": MODEL, "thinkingLevel": THINKING,
                      "isStreaming": STREAMING, "isCompacting": False, "pendingMessageCount": 0})
    elif kind == "get_entries":
        reply(frame, {"entries": ENTRIES, "leafId": LEAF})
    elif kind == "switch_session":
        if os.path.exists(frame["sessionPath"]):
            load(frame["sessionPath"])
        else:
            fresh(exact_path=frame["sessionPath"])
        reply(frame, {"cancelled": False})
    elif kind == "fork":
        fork(frame)
    elif kind == "extension_ui_response":
        box = UI.pop(frame["id"])
        box["confirmed"] = frame.get("confirmed") is True
        box["event"].set()
    elif kind == "get_available_models":
        reply(frame, {"models": [{"provider": "native", "id": "baseline", "name": "Native", "reasoning": True}]})
    elif kind == "set_model":
        MODEL = {"provider": frame["provider"], "id": frame["modelId"]}
        append("model_change", provider=frame["provider"], modelId=frame["modelId"])
        reply(frame, MODEL)
    elif kind == "set_thinking_level":
        THINKING = frame["level"]
        append("thinking_level_change", thinkingLevel=THINKING)
        reply(frame)
    elif kind == "prompt":
        STREAMING = True
        append("message", message={"role": "user", "content": [{"type": "text", "text": frame["message"]}], "timestamp": 1})
        emit({"type": "agent_start"})
        reply(frame)
        append("message", message={"role": "assistant", "content": [{"type": "text", "text": "private native answer"}], "stopReason": "stop", "timestamp": 1})
        STREAMING = False
        emit({"type": "agent_settled"})
    else:
        emit({"type": "response", "id": frame.get("id"), "command": kind, "success": False, "error": "private fixed peer refusal"})


try:
    for line in sys.stdin:
        threading.Thread(target=handle, args=(json.loads(line),), daemon=True).start()
finally:
    STOP.set()
    record({"kind": "closed", "pid": os.getpid()})
