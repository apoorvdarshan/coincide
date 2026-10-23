#!/usr/bin/python3
"""Private native MSP fixture from the published 1.4.6 schema. No vendor imports."""
import json
import os
import signal
import sys
import threading
import time
import uuid

root = os.getcwd()
with open(os.path.join(root, "canonical-directory.json"), encoding="utf8") as canonical:
    configured_root = json.load(canonical)["directory"]
directory_verified = os.path.samefile(root, configured_root)
if not directory_verified:
    sys.exit(2)
root = configured_root
lock = threading.RLock()
ready = threading.Event()
approval_settlement = threading.Event()
question_settlement = threading.Event()
options_path = os.path.join(root, "options.json")
wire_path = os.path.join(root, "wire.jsonl")
sessions_path = os.path.join(root, "sessions.json")
session = None
turn = None
last_turn = None
sequence = 0
stage = 0
metadata = "--no-session-log" in sys.argv
old_fingerprint = "sha256:eae467ab60cb9a5d5af4de616830f065e59375c987fd59269c8cc33ed2a1137f"
new_fingerprint = "sha256:f282ad16e21520d0cda68cb190149b86e2b062eef1dd282749360c05aa3d1082"

def options():
    try:
        with open(options_path, encoding="utf8") as file:
            return json.load(file)
    except (OSError, ValueError):
        return {}

def record(kind, data=None):
    with lock:
        with open(wire_path, "a", encoding="utf8") as file:
            file.write(json.dumps(dict(data or {}, kind=kind, pid=os.getpid()), ensure_ascii=False) + "\n")

record("process", {"arguments": sys.argv[1:], "metadata": metadata,
                   "directoryVerified": directory_verified,
                   "keyScrubbed": not any(key.upper() == "META_API_KEY" for key in os.environ),
                   "updatesDisabled": os.environ.get("MUSE_NO_AUTO_UPDATE") == "1"})

def emit(frame):
    with lock:
        data = (json.dumps(frame, ensure_ascii=False) + "\r\n").encode("utf8")
        at = data.find("日".encode("utf8"))
        if at >= 0:
            sys.stdout.buffer.write(data[:at + 1]); sys.stdout.buffer.flush()
            sys.stdout.buffer.write(data[at + 1:])
        else:
            sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()

def result(frame, value):
    emit({"jsonrpc": "2.0", "id": frame["id"], "result": value})

def error(frame, kind="commandRejected", code=-32030):
    emit({"jsonrpc": "2.0", "id": frame["id"], "error": {"code": code,
          "message": "synthetic-private-token", "data": {"kind": kind}}})

def position():
    global sequence
    sequence += 1
    identifier = str(uuid.uuid4())
    return {"viewCursor": "opaque:" + str(sequence), "sourceRange": {
        "stream": {"kind": "session", "id": session["sessionId"]},
        "first": {"id": identifier, "sequence": sequence}, "last": {"id": identifier, "sequence": sequence}}}

def notify(method, params):
    emit({"jsonrpc": "2.0", "method": method, "params": params})

def save():
    with lock:
        existing = {}
        try:
            with open(sessions_path, encoding="utf8") as file:
                existing = json.load(file)
        except (OSError, ValueError):
            pass
        existing[session["sessionId"]] = session
        temporary = sessions_path + "." + str(os.getpid())
        with open(temporary, "w", encoding="utf8") as file:
            json.dump(existing, file)
        os.replace(temporary, sessions_path)

def session_result(history=False):
    value = {"session": dict(session), "viewCursor": "opaque:session-read"}
    if options().get("missingProfile"):
        value["session"].pop("permissionState", None)
    if history:
        value.update({"history": {"mode": "none"}, "pendingRequests": []})
    return value

def item(kind, identifier, revision, status, owner=None, **fields):
    params = dict(position(), sessionId=session["sessionId"], item=dict(
        fields, itemId=identifier, kind=kind, turnId=owner or turn, revision=revision, status=status))
    notify("item/started" if revision == 1 else "item/completed" if status != "inProgress" else "item/updated", params)

def start_turn():
    notify("turn/started", dict(position(), sessionId=session["sessionId"], turnId=turn, commandId=turn))
    item("agentMessage", "message-" + turn, 1, "inProgress", text="")
    notify("item/delta", {"sessionId": session["sessionId"], "viewCursor": "opaque:delta",
                         "itemId": "message-" + turn, "field": "text", "delta": "partial 日本語\u2028"})
    item("agentMessage", "message-" + turn, 2, "completed", text="Exact 日本語\u2028answer")
    item("toolCall", "tool-" + turn, 1, "inProgress", tool="read", args=json.dumps({"path": "generated.txt"}), visibleOutput="partial")
    item("toolCall", "tool-" + turn, 2, "completed", tool="read", args=json.dumps({"path": "generated.txt"}), visibleOutput="Exact tool result")
    if options().get("background"):
        item("subagent", "child-" + turn, 1, "inProgress", childSessionId=str(uuid.uuid4()), role="Worker", objective="Generated fixture task")

def terminal(outcome="completed"):
    global turn, last_turn
    with lock:
        if turn is None:
            return
        owner = turn
        params = dict(position(), sessionId=session["sessionId"], turnId=owner, terminal=outcome)
        session["status"] = "idle"; session["activeTurnId"] = None; save()
        # This SAME cursor on different methods is in T3's recorded transcript.
        notify("session/statusChanged", {"sessionId": session["sessionId"], "status": "idle", "viewCursor": params["viewCursor"]})
        notify("turn/completed", params)
        last_turn = owner; turn = None

def approval_body():
    return dict(position(), approvalId="approval-1", sessionId=session["sessionId"], turnId=turn or last_turn,
                itemId="tool-approval", taskId=None, toolCallId="native-call", toolName="bash", rawArgs="generated fixture",
                currentRequirementId={"approvalId": "approval-1", "sourceIndex": stage},
                availableChoices=[{"choiceId": "once", "label": "Allow once", "decision": "approved", "scope": "once"},
                                  {"choiceId": "session", "label": "Allow for session", "decision": "approvedForSession", "scope": "session"},
                                  {"choiceId": "decline", "label": "Decline", "decision": "denied", "scope": "once"}],
                subject={"kind": "shell", "command": "echo generated"}, protectedWrite=False, judgeEscalated=False)

def question_body():
    return dict(position(), userInputId="question-1", sessionId=session["sessionId"], turnId=turn or last_turn,
                itemId="question-item", toolCallId="question-call", toolName="AskUser",
                questions=[{"id": "approach", "header": "Choice", "question": "Which generated options?",
                            "options": [{"label": "One", "description": "First"}, {"label": "Two", "preview": {"content": "Preview", "format": "text"}}],
                            "selection": {"mode": "multiple", "minSelections": 1, "maxSelections": 2}}])

def interaction(kind):
    body = approval_body() if kind == "approval" else question_body()
    emit({"jsonrpc": "2.0", "id": 77 if kind == "approval" else 78,
          "method": "approval/request" if kind == "approval" else "userInput/request", "params": body})
    notify("approval/requested" if kind == "approval" else "userInput/requested", body)

def handle(frame):
    global session, turn, stage
    method = frame.get("method")
    if method is None:
        record("presentation", {"id": frame.get("id"), "empty": frame.get("result") == {}})
        return
    params = frame.get("params", {})
    record("request", {"method": method, "params": params})
    if method not in ["initialize", "initialized"] and not ready.wait(1):
        error(frame, "invalidParams", -32600)
        return
    opts = options()
    if method == "initialize":
        result(frame, {"serverInfo": {"name": "muse", "version": "1.4.6"}, "schema": {"version": 1, "fingerprint": new_fingerprint if opts.get("newProfileContract") else old_fingerprint},
                       "experimentalApi": False, "grantedCapabilities": [], "sessionDurability": "durable",
                       "museHome": root, "platformFamily": "unix", "platformOs": "macos", "userAgent": "synthetic-msp"})
    elif method == "initialized":
        ready.set()
        record("ready")
    elif method == "model/list":
        result(frame, {"providerId": "meta", "profileId": None, "source": "fakeCatalog", "models": [
            {"providerId": "meta", "profileId": None, "modelId": "native-default", "displayLabel": "Native default", "isDefault": not opts.get("noDefault", False),
             "variants": ["low", "high"], "defaultReasoningEffort": "low", "description": None, "contextLimit": None,
             "outputLimit": None, "cost": None, "releaseDate": None},
            {"providerId": "meta", "profileId": None, "modelId": "selected-model", "displayLabel": "Selected model", "isDefault": False,
             "variants": ["low", "high"], "defaultReasoningEffort": "high", "description": None, "contextLimit": None,
             "outputLimit": None, "cost": None, "releaseDate": None}]})
    elif method == "session/start":
        session = {"sessionId": params["sessionId"], "workspaceRoot": root, "path": root, "providerId": "meta",
                   "modelId": params.get("modelId", "native-default"), "activeTurnId": None, "createdAt": "2026-10-22T00:00:00Z",
                   "updatedAt": "2026-10-22T00:00:00Z", "forkedFrom": None, "status": "idle", "turnCount": 0,
                   "permissionState": {"profileId": opts.get("profile", params["permissionProfile"])},
                   "approvalMode": {"mode": params["approvalMode"]}}
        save(); result(frame, session_result())
    elif method == "session/resume":
        try:
            with open(sessions_path, encoding="utf8") as file:
                session = json.load(file)[params["sessionId"]]
        except (OSError, ValueError, KeyError):
            error(frame, "sessionNotFound"); return
        if "permissionProfile" in params and opts.get("newProfileContract"):
            session["permissionState"] = {"profileId": params["permissionProfile"]}
        result(frame, session_result(history=True))
    elif method == "session/read":
        result(frame, session_result(history=True))
    elif method == "session/setApprovalMode":
        session["approvalMode"] = {"mode": params["mode"]}; save()
        result(frame, {"commandId": params["commandId"], "effectiveMode": {"mode": params["mode"], "source": "approvalReconfigure", "lastCommandId": params["commandId"]}, "applyOutcome": "completed", "status": "accepted"})
    elif method == "session/setModel":
        while options().get("holdModel"):
            time.sleep(.005)
        session["modelId"] = params["model"]["modelId"]; save()
        result(frame, {"commandId": params["commandId"], "status": "accepted"})
    elif method == "turn/start":
        while options().get("holdAdmission"):
            time.sleep(.005)
        if opts.get("rejectTurn"):
            error(frame); return
        turn = params["commandId"]; session["activeTurnId"] = turn; session["status"] = "running"; session["turnCount"] += 1; save()
        record("prompt", {"commandId": turn, "model": session["modelId"], "effort": params.get("reasoningEffort"), "profile": session["permissionState"]["profileId"], "input": params["input"]})
        if opts.get("beforeAck"):
            start_turn(); terminal()
            while options().get("holdAck"):
                time.sleep(.005)
        ack = {"commandId": params["commandId"], "status": "accepted", "disposition": "started", "startedNewTurn": True, "turnId": params["commandId"]}
        if opts.get("lateError"):
            error(frame)
            record("turnReply", {"commandId": params["commandId"], "error": True})
            return
        result(frame, ack)
        record("turnReply", {"commandId": params["commandId"], "error": False})
        if not opts.get("beforeAck"):
            start_turn()
        if opts.get("interaction"):
            interaction(opts["interaction"])
    elif method == "turn/interrupt":
        record("interrupt", {"turnId": params["turnId"], "exact": params["turnId"] == turn})
        if opts.get("interruptBeforeReply"):
            terminal("cancelled")
            while options().get("holdInterruptReply"):
                time.sleep(.005)
            if opts.get("interruptLateError"):
                error(frame)
            else:
                result(frame, {"commandId": params["commandId"], "status": "accepted", "turnId": params["turnId"]})
            record("interruptReply", {"turnId": params["turnId"], "error": bool(opts.get("interruptLateError"))})
            return
        result(frame, {"commandId": params["commandId"], "status": "accepted", "turnId": params["turnId"]})
        if not opts.get("holdInterruptTerminal"):
            terminal("cancelled")
    elif method == "approval/decide":
        staged = opts.get("staged") and stage == 0
        ack = {"commandId": params["commandId"], "approvalId": "approval-1", "status": "accepted", "terminal": not staged}
        held = opts.get("holdInteractionSettlement")
        if held:
            approval_settlement.clear()
            result(frame, ack)
            record("settlementHeld", {"interaction": "approval"})
            approval_settlement.wait()
        if staged:
            stage = 1
            updated = approval_body(); updated.pop("turnId", None); updated.pop("itemId", None)
            notify("approval/updated", updated)
        else:
            notify("approval/resolved", dict(position(), sessionId=session["sessionId"], approvalId="approval-1", itemId="tool-approval",
                   turnId=turn or last_turn, decision="approved", policyResult="allow", resolvedBy="client", stageEvidence=[], decidedByCommandId=params["commandId"]))
        if not held:
            result(frame, ack)
    elif method in ["userInput/answer", "userInput/cancel"]:
        ack = {"commandId": params["commandId"], "userInputId": "question-1", "status": "accepted"}
        held = opts.get("holdInteractionSettlement")
        if held:
            question_settlement.clear()
            result(frame, ack)
            record("settlementHeld", {"interaction": "question"})
            question_settlement.wait()
        notify("userInput/settled", dict(position(), sessionId=session["sessionId"], userInputId="question-1", turnId=turn or last_turn,
               answers=params.get("answers", []), clarification=None, outcome="answered" if method.endswith("answer") else "cancelled",
               reason=None, decidedAt="2026-10-22T00:00:00Z", decidedByCommandId=params["commandId"]))
        if not held:
            result(frame, ack)
    elif method == "approval/listPending":
        result(frame, {"approvals": [], "userInputs": []})
    else:
        error(frame, "invalidParams", -32602)

def signals():
    seen = None
    while True:
        selected = options().get("signal")
        if selected and selected.get("id") != seen and selected.get("pid", os.getpid()) == os.getpid():
            seen = selected["id"]
            name = selected.get("name")
            if name == "finish": terminal()
            elif name == "cancelled": terminal("cancelled")
            elif name == "settle-approval": approval_settlement.set()
            elif name == "settle-question": question_settlement.set()
            elif name == "foreign":
                notify("turn/completed", dict(position(), sessionId=str(uuid.uuid4()), turnId=str(uuid.uuid4()), terminal="completed"))
                notify("turn/completed", dict(position(), sessionId=session["sessionId"], turnId=str(uuid.uuid4()), terminal="completed"))
                notify("session/statusChanged", {"sessionId": session["sessionId"], "status": "idle", "viewCursor": "opaque:reused"})
            elif name == "childFinish" and last_turn:
                item("subagent", "child-" + last_turn, 2, "completed", owner=last_turn, role="Worker", result={"text": "Original child result"})
            elif name == "gap": notify("view/gap", {"sessionId": session["sessionId"], "after": "opaque:old", "next": "opaque:new"})
            elif name == "flood":
                # A fast consumer can drain any finite status-update burst without
                # overflowing its transport queue. Exercise the Session's actual
                # 64-pending-approval bound instead, with 65 distinct valid native
                # notifications (below the connection's 128-event capacity).
                record("notificationFlood", {"type": "pending-approval", "count": 65})
                with lock:
                    for index in range(65):
                        body = approval_body()
                        identifier = "overflow-approval-" + str(index)
                        body["approvalId"] = identifier
                        body["itemId"] = "overflow-item-" + str(index)
                        body["toolCallId"] = "overflow-call-" + str(index)
                        body["currentRequirementId"]["approvalId"] = identifier
                        notify("approval/requested", body)
                        # The test acknowledges each presented request through its
                        # private control file. This bounds transport backlog and
                        # proves the 65th fails the Session registry, not timing.
                        while index < 64 and options().get("floodAcknowledged", 0) < index + 1:
                            time.sleep(.005)
            elif name == "exit": os._exit(0)
        time.sleep(.005)

threading.Thread(target=signals, daemon=True).start()
for line in sys.stdin.buffer:
    value = json.loads(line)
    threading.Thread(target=handle, args=(value,), daemon=True).start()
