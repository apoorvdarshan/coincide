#!/usr/bin/python3 -S
"""Private native 1.14.19 history wire. No vendor import, model or auth call.

Session.fork copies chronological entries until lexical info.id >= messageID,
regenerates every message/part ID, remaps assistant parents, and leaves all other
fields (including compaction tail_start_id) literal. State survives owned hosts.
"""
import base64
import contextlib
import copy
import fcntl
import http.server
import json
import os
import pathlib
import queue
import signal
import socket
import sys
import threading
import time
import urllib.parse

os.umask(0o077)
root = pathlib.Path(__file__).resolve().parent
directory = json.loads((root / "fixture-directory.json").read_text())["directory"]
if not os.path.isabs(directory) or not os.path.samefile(directory, pathlib.Path.cwd()):
    raise ValueError("Invalid private working directory")
password = os.environ.get("OPENCODE_SERVER_PASSWORD", "")
expected_auth = "Basic " + base64.b64encode(("opencode:" + password).encode()).decode()
try:
    fresh = len(base64.b64decode(password, validate=True)) == 32
except ValueError:
    fresh = False
stop = threading.Event()
subscribed = threading.Event()
stream_closed = threading.Event()
frames = queue.Queue(maxsize=128)
lock = threading.RLock()
workers = []
model_id = "history-model/with-slash"
model = {"id": model_id, "name": "Private history model", "variants": {"balanced": {}, "fast": {}},
         "modalities": {"input": ["text"], "output": ["text"]}, "toolcall": True}
agents = [{"name": "build", "mode": "primary", "hidden": False, "permission": []},
          {"name": "plan", "mode": "primary", "hidden": False,
           "permission": [{"permission": "edit", "pattern": directory + "/plan.md", "action": "allow"}]}]


def options():
    try:
        return json.loads((root / "options.json").read_text())
    except (OSError, ValueError):
        return {}


def marker(name, **fields):
    with lock:
        temporary = root / (name + ".partial-" + str(os.getpid()))
        temporary.write_text(json.dumps(fields or {"observed": True}))
        temporary.replace(root / name)


def record(kind, **fields):
    # Never record passwords, headers, URLs, environment or native user data.
    with lock, (root / "wire.jsonl").open("a", encoding="utf8") as out:
        fcntl.flock(out.fileno(), fcntl.LOCK_EX)
        out.write(json.dumps(dict(kind=kind, pid=os.getpid(), **fields), ensure_ascii=False) + "\n")
        out.flush()


@contextlib.contextmanager
def database():
    with (root / "native.lock").open("a+b") as held:
        fcntl.flock(held.fileno(), fcntl.LOCK_EX)
        path = root / "native.json"
        state = json.loads(path.read_text()) if path.exists() else {"sessions": {}, "counter": 0}
        yield state
        temporary = root / ("native.partial-" + str(os.getpid()))
        temporary.write_text(json.dumps(state, ensure_ascii=False))
        temporary.replace(path)


def mint(state, prefix):
    state["counter"] += 1
    # Copy IDs sort below later client timestamp IDs but preserve copy order.
    return prefix + "000000000000" + format(state["counter"], "016x")


def emit(kind, sid, fields=None):
    event = {"type": kind, "properties": dict(sessionID=sid, **(fields or {}))}
    frames.put_nowait(("data: " + json.dumps(event, ensure_ascii=False) + "\r\n\r\n").encode())


def background(task):
    thread = threading.Thread(target=task, daemon=True)
    workers.append(thread)
    thread.start()


def run_input(sid, body):
    now = int(time.time() * 1000)
    user = {"id": body["messageID"], "sessionID": sid, "role": "user", "agent": body["agent"],
            "model": body["model"], "time": {"created": now}}
    user_part = {"id": "prt_" + user["id"][4:] + "_0", "sessionID": sid, "messageID": user["id"],
                 "type": "text", "text": body["parts"][0]["text"]}
    assistant = {"id": user["id"] + "_a", "sessionID": sid, "role": "assistant", "parentID": user["id"],
                 "providerID": body["model"]["providerID"], "modelID": body["model"]["modelID"],
                 "agent": body["agent"], "mode": body["agent"], "path": {"cwd": directory, "root": directory},
                 "time": {"created": now + 1, "completed": now + 2}, "finish": "stop", "cost": 0,
                 "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}}
    text = {"id": "prt_" + user["id"][4:] + "_1", "messageID": assistant["id"], "sessionID": sid,
            "type": "text", "text": "Reply to " + user_part["text"], "time": {"start": now + 1, "end": now + 2}}
    tool = {"id": "prt_" + user["id"][4:] + "_2", "messageID": assistant["id"], "sessionID": sid,
            "type": "tool", "tool": "bash", "callID": "call_" + user["id"],
            "state": {"status": "completed", "input": {"command": "printf synthetic"}, "output": "Private history tool output",
                      "metadata": {"retainedNativeID": user["id"]}, "title": "Private command", "time": {"start": now + 1, "end": now + 2}}}
    with database() as state:
        session = state["sessions"][sid]
        session["messages"].extend([{"info": user, "parts": [user_part]}, {"info": assistant, "parts": [text, tool]}])
        if not state.get("hasCompaction"):
            # Exact native internal compaction shape from compaction.ts create.
            internal = copy.deepcopy(user)
            internal["id"] = user["id"] + "_c"
            internal["time"] = {"created": now + 3}
            compact = {"id": "prt_" + user["id"][4:] + "_3", "messageID": internal["id"], "sessionID": sid,
                       "type": "compaction", "auto": False, "overflow": False, "tail_start_id": user["id"]}
            summary = copy.deepcopy(assistant)
            summary.update(id=user["id"] + "_d", parentID=internal["id"], summary=True, agent="compaction", mode="compaction")
            summary["time"] = {"created": now + 4, "completed": now + 5}
            summary_part = {"id": "prt_" + user["id"][4:] + "_4", "messageID": summary["id"], "sessionID": sid,
                            "type": "text", "text": "Private native summary", "time": {"start": now + 4, "end": now + 5}}
            session["messages"].extend([{"info": internal, "parts": [compact]}, {"info": summary, "parts": [summary_part]}])
            state["hasCompaction"] = True
    emit("message.updated", sid, {"info": user})
    emit("session.status", sid, {"status": {"type": "busy"}})
    live_assistant = copy.deepcopy(assistant)
    live_assistant["time"].pop("completed")
    emit("message.updated", sid, {"info": live_assistant})
    emit("message.part.updated", sid, {"part": dict(text, text="discarded delta")})
    emit("message.part.delta", sid, {"messageID": assistant["id"], "partID": text["id"], "field": "text", "delta": " stale"})
    emit("message.part.updated", sid, {"part": text})
    emit("message.part.updated", sid, {"part": tool})
    emit("message.updated", sid, {"info": assistant})
    record("input-observed", sessionID=sid, inputID=user["id"])
    while not stop.wait(.005):
        if (root / ("finish-" + user["id"])).exists():
            with database() as state:
                state["sessions"][sid]["active"] = False
            emit("session.status", sid, {"status": {"type": "idle"}})
            emit("session.idle", sid)
            marker("terminal-" + user["id"])
            return


def candidate_gate(sid):
    with database() as state:
        candidate = state["sessions"].get(sid, {}).get("candidate", False)
        policy_applied = state["sessions"].get(sid, {}).get("policyApplied", False)
    if candidate:
        record("candidate-proof", sessionID=sid)
        marker("candidate-proof-entered", sessionID=sid)
        while options().get("holdCandidateProof") and not stop.wait(.005):
            pass
        return not (options().get("dropCandidateRead") or options().get("dropCandidateProofAfterPolicy") and policy_applied)
    return True


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, address):
        error = sys.exc_info()[1]
        if not isinstance(error, (BrokenPipeError, ConnectionResetError)):
            name = type(error).__name__
            fixed = name if name in {"ValueError", "TypeError", "AttributeError", "KeyError", "NameError", "OSError", "OverflowError"} else "OtherError"
            frames = []
            trace = sys.exc_info()[2]
            while trace is not None and len(frames) < 12:
                frames.append({"file": pathlib.Path(trace.tb_frame.f_code.co_filename).name,
                               "function": trace.tb_frame.f_code.co_name, "line": trace.tb_lineno})
                trace = trace.tb_next
            record("fixture-handler-failed", exceptionKind=fixed, frames=frames)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, value=None, cursor=None):
        payload = b"" if status == 204 else json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        if status != 204:
            self.send_header("Content-Type", "application/json; charset=utf-8")
        if cursor:
            self.send_header("X-Next-Cursor", cursor)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if payload:
            self.wfile.write(payload)
        self.wfile.flush()

    def drop(self):
        self.close_connection = True
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.connection.close()

    def route(self):
        value = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(value.query, strict_parsing=True) if value.query else {}
        valid = value.path == "/global/health" and not query or query.get("directory") == [directory]
        authenticated = self.headers.get("Authorization") == expected_auth
        record("request", method=self.command, path=value.path, authenticated=authenticated, directoryMatched=valid)
        if not valid or not authenticated:
            self.reply(400 if authenticated else 401, {"error": "invalid private request"})
            return None
        return value, query

    def body(self):
        count = int(self.headers.get("Content-Length", "0"))
        if not 0 <= count <= 1048576:
            raise ValueError("Invalid private request body")
        return json.loads(self.rfile.read(count)) if count else {}

    def do_GET(self):
        routed = self.route()
        if routed is None:
            return
        url, query = routed
        if url.path == "/global/health":
            self.reply(200, {"healthy": True, "version": "1.14.19"}); return
        if url.path == "/provider":
            self.reply(200, {"all": [{"id": "synthetic", "name": "Synthetic", "models": {model_id: model}}],
                             "default": {"synthetic": model_id}, "connected": ["synthetic"]}); return
        if url.path == "/agent":
            self.reply(200, agents); return
        if url.path in ("/permission", "/question"):
            self.reply(200, []); return
        if url.path == "/event":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            subscribed.set()
            try:
                self.wfile.write(b": connected\r\n\r\n"); self.wfile.flush()
                while not stop.is_set():
                    try:
                        frame = frames.get(timeout=.05)
                    except queue.Empty:
                        frame = b": heartbeat\r\n\r\n"
                    for offset in range(0, len(frame), 11):
                        self.wfile.write(frame[offset:offset + 11])
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                stream_closed.set(); self.close_connection = True
            return
        parts = url.path.strip("/").split("/")
        if len(parts) >= 2 and parts[0] == "session" and parts[1] != "status":
            if not candidate_gate(parts[1]):
                self.drop(); return
        with database() as state:
            if parts == ["session", "status"]:
                self.reply(200, {sid: {"type": "busy"} for sid, row in state["sessions"].items() if row["active"]}); return
            if len(parts) >= 2 and parts[0] == "session" and parts[1] in state["sessions"]:
                sid, session = parts[1], state["sessions"][parts[1]]
                if options().get("staleTail") and not state.get("tailChanged"):
                    for entry in reversed(session["messages"]):
                        if entry["info"]["role"] == "assistant":
                            entry["parts"][0]["text"] += " external same-head tail"
                            state["tailChanged"] = True
                            break
                if len(parts) == 2:
                    self.reply(200, session["info"]); return
                if parts[2:] == ["children"]:
                    self.reply(200, []); return
                if parts[2:] == ["message"]:
                    if set(query) - {"directory", "limit", "before"} or "before" in query and "limit" not in query:
                        self.reply(400, {"error": "invalid page query"}); return
                    entries = session["messages"]
                    # Ordinary session resume reads full snapshots. History uses
                    # limit and ONLY opaque X-Next-Cursor for older chunks.
                    if "limit" not in query:
                        self.reply(200, entries); return
                    end = len(entries)
                    if "before" in query:
                        key = json.loads(base64.urlsafe_b64decode(query["before"][0] + "==="))
                        end = next(i for i, row in enumerate(entries) if row["info"]["id"] == key["id"])
                    start = max(0, end - min(3, int(query["limit"][0])))
                    page = entries[start:end]
                    cursor = base64.urlsafe_b64encode(json.dumps({"id": page[0]["info"]["id"], "time": page[0]["info"]["time"]["created"]}).encode()).decode().rstrip("=") if start else None
                    record("history-page", sessionID=sid, before="before" in query, count=len(page), ids=[row["info"]["id"] for row in page], hasOlder=bool(cursor))
                    self.reply(200, page, cursor=cursor); return
                if len(parts) == 4 and parts[2] == "message":
                    entry = next((row for row in session["messages"] if row["info"]["id"] == parts[3]), None)
                    self.reply(200, entry) if entry else self.reply(404, {"error": "missing message"})
                    return
        self.reply(404, {"error": "missing private resource"})

    def do_POST(self):
        routed = self.route()
        if routed is None:
            return
        url, _ = routed
        body, opts = self.body(), options()
        with database() as state:
            if url.path == "/session":
                sid = mint(state, "ses_")
                info = {"id": sid, "directory": directory, "projectID": "private-project", "workspaceID": "private-workspace",
                        "title": "Private conversation", "version": "1.14.19", "time": {"created": 1, "updated": 1}, "permission": body["permission"]}
                state["sessions"][sid] = {"info": info, "messages": [], "active": False}
                record("create", sessionID=sid)
                self.reply(200, info); return
            parts = url.path.strip("/").split("/")
            if len(parts) != 3 or parts[0] != "session" or parts[1] not in state["sessions"]:
                self.reply(404, {"error": "missing private session"}); return
            sid, action = parts[1:]
            session = state["sessions"][sid]
            if action == "prompt_async":
                if session["active"] or not subscribed.is_set():
                    self.reply(409, {"error": "busy private session"}); return
                session["active"] = True
                record("prompt", sessionID=sid, inputID=body["messageID"], text=body["parts"][0]["text"],
                       model=body["model"], variant=body.get("variant"), agent=body["agent"], permission=session["info"]["permission"])
            elif action == "fork":
                cut = body.get("messageID")
                copied = []
                for entry in session["messages"]:
                    if cut is not None and entry["info"]["id"] >= cut:
                        break
                    copied.append(copy.deepcopy(entry))
                target = mint(state, "ses_")
                mapping = {row["info"]["id"]: mint(state, "msg_") for row in copied}
                for row in copied:
                    original = row["info"]["id"]
                    row["info"].update(id=mapping[original], sessionID=target)
                    if row["info"]["role"] == "assistant":
                        row["info"]["parentID"] = mapping[row["info"]["parentID"]]
                    for part in row["parts"]:
                        part.update(id=mint(state, "prt_"), messageID=row["info"]["id"], sessionID=target)
                if opts.get("badCopy") == "same-count" and copied:
                    copied[-1]["parts"][0]["text"] = "Foreign content with the same message count"
                if opts.get("badCopy") == "reused-part" and copied:
                    copied[0]["parts"][0]["id"] = session["messages"][0]["parts"][0]["id"]
                info = {"id": target, "directory": directory, "projectID": session["info"]["projectID"],
                        "workspaceID": session["info"]["workspaceID"], "title": "Private copied conversation", "version": "1.14.19",
                        "time": {"created": state["counter"], "updated": state["counter"]}}
                state["sessions"][target] = {"info": info, "messages": copied, "active": False, "candidate": True}
                record("fork", sessionID=sid, targetID=target, cut=cut, copied=len(copied))
            elif action == "abort":
                was_active = session["active"]
                session["active"] = False
                record("abort", sessionID=sid, wasActive=was_active)
                self.reply(200, True)
                if was_active:
                    emit("session.error", sid, {"error": {"name": "MessageAbortedError", "data": {"message": "Private interruption"}}})
                    emit("session.idle", sid)
                return
            else:
                # In particular, native revert/unrevert must NEVER be called.
                record("unsupported-mutation", sessionID=sid, action=action)
                self.reply(404, {"error": "unsupported private operation"}); return
        if action == "prompt_async":
            self.reply(204)
            background(lambda: run_input(sid, body))
        else:
            marker("fork-created", sessionID=sid, targetID=target)
            while options().get("holdForkACK") and not stop.wait(.005):
                pass
            if opts.get("dropForkACK"):
                self.drop()
            else:
                self.reply(200, info)

    def do_PATCH(self):
        routed = self.route()
        if routed is None:
            return
        url, _ = routed
        parts, body = url.path.strip("/").split("/"), self.body()
        if len(parts) != 2 or parts[0] != "session" or not candidate_gate(parts[1]):
            self.drop(); return
        with database() as state:
            session = state["sessions"].get(parts[1])
            if session is None or set(body) != {"permission"}:
                self.reply(400, {"error": "invalid private permission update"}); return
            session["info"]["permission"] = body["permission"]
            session["policyApplied"] = True
            info = copy.deepcopy(session["info"])
        record("policy", sessionID=parts[1], permission=body["permission"])
        self.reply(200, info)


record("process", exactArguments=sys.argv[1:] == ["serve", "--hostname", "127.0.0.1", "--port", "0"], freshCredential=fresh,
       noInheritedService=not any(os.environ.get(k) for k in ["OPENCODE_PASSWORD", "OPENCODE_SERVER_URL", "OPENCODE_URL", "OPENCODE_PTY_HANDOFF"]))
server = Server(("127.0.0.1", 0), Handler)
server_worker = threading.Thread(target=lambda: server.serve_forever(poll_interval=.02), daemon=True)
server_worker.start()
signal.signal(signal.SIGTERM, lambda *_: stop.set())
def input_lifetime():
    sys.stdin.buffer.read()
    stop.set()
threading.Thread(target=input_lifetime, daemon=True).start()
print("opencode server listening on http://127.0.0.1:" + str(server.server_port), flush=True)
stop.wait()
server.shutdown(); server.server_close(); server_worker.join(timeout=.2)
for worker in workers:
    worker.join(timeout=.1)
stream_closed.wait(timeout=.4)
record("closed", streamClosed=stream_closed.is_set(), httpStopped=not server_worker.is_alive())
