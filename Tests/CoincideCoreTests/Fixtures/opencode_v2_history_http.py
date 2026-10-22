#!/usr/bin/python3 -S
"""Owned loopback OpenCode 2.1.2 history peer; never imports a vendor SDK.

Wire shapes follow a517687 packages/{protocol,server,core}/session and native
T3 opencode2_fork/revert recordings. Native history persists across independently
owned metadata/chat processes. Fork regenerates IDs and remaps compaction keepID.
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
import socket
import sys
import threading
import time
import urllib.parse

os.umask(0o077)
root = pathlib.Path(__file__).resolve().parent
directory = json.loads((root / "fixture-directory.json").read_text())["directory"]
if not os.path.isabs(directory) or not os.path.samefile(directory, pathlib.Path.cwd()):
    raise ValueError("The fixture working directory is not owned")
password = os.environ.get("OPENCODE_PASSWORD", "")
authorization = "Basic " + base64.b64encode(("opencode:" + password).encode()).decode()
try:
    fresh = len(base64.b64decode(password, validate=True)) == 32
except ValueError:
    fresh = False
stop = threading.Event()
subscribed = threading.Event()
stream_closed = threading.Event()
frames = queue.Queue(maxsize=256)
threads = []
write_lock = threading.RLock()
model = {"id": "history-model", "providerID": "synthetic", "name": "Synthetic history model", "enabled": True,
         "variants": [{"id": "balanced"}, {"id": "fast"}],
         "capabilities": {"tools": True, "input": ["text"], "output": ["text"]}}
agents = [{"id": "build", "name": "Build", "mode": "primary", "hidden": False, "permissions": []},
          {"id": "plan", "name": "Plan", "mode": "primary", "hidden": False,
           "permissions": [{"action": "edit", "resource": directory + "/plan.md", "effect": "allow"}]}]


def options():
    try:
        return json.loads((root / "options.json").read_text())
    except (OSError, ValueError):
        return {}


def marker(name, value=None):
    with write_lock:
        path = root / name
        temporary = root / (name + ".partial-" + str(os.getpid()))
        temporary.write_text(json.dumps(value or {"observed": True}), encoding="utf8")
        temporary.replace(path)


def record(kind, **fields):
    # Only synthetic semantic fields; never headers, credentials or full URLs.
    with write_lock:
        with (root / "wire.jsonl").open("a", encoding="utf8") as out:
            fcntl.flock(out.fileno(), fcntl.LOCK_EX)
            out.write(json.dumps(dict(kind=kind, pid=os.getpid(), **fields), ensure_ascii=False) + "\n")
            out.flush()


@contextlib.contextmanager
def database():
    with (root / "native.lock").open("a+b") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        path = root / "native.json"
        state = json.loads(path.read_text()) if path.exists() else {"sessions": {}, "counter": 0}
        yield state
        temporary = root / ("native.partial-" + str(os.getpid()))
        temporary.write_text(json.dumps(state, ensure_ascii=False), encoding="utf8")
        temporary.replace(path)


def next_id(state, prefix="msg_history_"):
    state["counter"] += 1
    return prefix + str(state["counter"])


def message(state, kind, **fields):
    return dict(id=next_id(state), type=kind, time={"created": 1790657100000 + state["counter"]}, **fields)


def emit(kind, sid, fields=None, terminal=False):
    with database() as state:
        session = state["sessions"][sid]
        session["seq"] += 1
        event_id = "evt_history_" + str(os.getpid()) + "_" + str(session["seq"])
        created = 1790657200000 + session["seq"]
        if terminal:
            outcome = "interrupted" if kind.endswith("interrupted") else "succeeded"
            session["active"] = False
            session["info"]["outcome"] = outcome
            session["info"]["time"]["idle"] = created
            # Official message-updater/projectIdle records this even for an
            # empty clear execution. It is NOT an authored user/provider run.
            session["messages"].append({"id": event_id.replace("evt_", "msg_", 1), "type": "idle",
                                        "outcome": outcome, "time": {"created": created}})
        body = {"id": event_id, "type": kind, "created": created,
                "location": {"directory": directory}, "data": dict(sessionID=sid, **(fields or {})),
                "durable": {"aggregateID": sid, "seq": session["seq"], "version": 1}}
    frames.put_nowait(("id: " + event_id + "\r\ndata: " + json.dumps(body, ensure_ascii=False) + "\r\n\r\n").encode())
    return body


def child(worker):
    task = threading.Thread(target=worker, daemon=True)
    threads.append(task)
    task.start()


def run_input(sid, admission, captured, steering):
    emit("session.inbox.enqueued", sid, {"inboxID": admission["id"], "item": admission})
    if not steering:
        emit("session.execution.started", sid)
    emit("session.inbox.delivered", sid, {"inboxID": admission["id"]})
    with database() as state:
        session = state["sessions"][sid]
        session["inbox"] = [row for row in session["inbox"] if row["id"] != admission["id"]]
        answer = message(state, "assistant", agent=captured["agent"], model=captured["model"],
                         content=[{"type": "text", "text": "Reply to " + admission["payload"]["text"]}], finish="stop")
        answer["time"]["completed"] = answer["time"]["created"] + 1
        session["messages"].append(answer)
        if steering:
            session["messages"].append(message(state, "synthetic", text="Native synthetic tail after " + admission["payload"]["text"]))
            keep = session["messages"][0]["id"]
            session["messages"].append(message(state, "compaction", status="completed", reason="manual", summary="Retained synthetic summary",
                                                  metadata={"keepID": keep}, model=captured["model"]))
    assistant = answer["id"]
    emit("session.step.started", sid, {"assistantMessageID": assistant, "agent": captured["agent"], "model": captured["model"]})
    emit("session.text.started", sid, {"assistantMessageID": assistant, "ordinal": 0})
    emit("session.text.delta", sid, {"assistantMessageID": assistant, "ordinal": 0, "delta": "discarded incremental"})
    emit("session.text.ended", sid, {"assistantMessageID": assistant, "ordinal": 0, "text": answer["content"][0]["text"]})
    emit("session.step.ended", sid, {"assistantMessageID": assistant, "finish": "stop"})
    record("input-observed", sessionID=sid, inputID=admission["id"], assistantID=assistant)
    if steering:
        return
    while not stop.wait(.005):
        if (root / ("finish-" + admission["id"])).exists():
            emit("session.execution.succeeded", sid, terminal=True)
            marker("terminal-" + admission["id"])
            return


def clear_execution(sid):
    emit("session.execution.started", sid)
    record("clear-execution-started", sessionID=sid)
    marker("clear-started")
    while options().get("holdClearTerminal") and not stop.wait(.005):
        pass
    if stop.is_set():
        return
    if options().get("omitClearTerminal"):
        marker("clear-no-terminal")
        return
    event = emit("session.execution.succeeded", sid, terminal=True)
    record("clear-execution-terminal", sessionID=sid, idleMessageID=event["id"].replace("evt_", "msg_", 1))
    marker("clear-terminal")


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, address):
        if not isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            record("fixture-handler-failed")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, value=None):
        data = b"" if status == 204 else json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        if status != 204:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)
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
        authenticated = self.headers.get("Authorization") == authorization
        record("request", method=self.command, path=value.path, authenticated=authenticated)
        if not authenticated:
            self.reply(401, {"error": "unauthorized"})
            return None
        return value

    def body(self):
        count = int(self.headers.get("Content-Length", "0"))
        if count < 0 or count > 1048576:
            raise ValueError("Invalid owned fixture body")
        return json.loads(self.rfile.read(count)) if count else {}

    def do_GET(self):
        url = self.route()
        if url is None:
            return
        if url.path == "/api/info":
            self.reply(200, {"version": "2.1.2", "pid": os.getpid()})
            return
        if url.path in ("/api/model", "/api/agent", "/api/model/default"):
            valid = urllib.parse.parse_qs(url.query) == {"location[directory]": [directory]}
            record("catalog-location", matched=valid)
            if not valid:
                self.reply(400, {"error": "invalid location"})
                return
            self.reply(200, {"location": {"directory": directory}, "data": agents if url.path == "/api/agent" else [model] if url.path == "/api/model" else model})
            return
        if url.path == "/api/event":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            subscribed.set()
            record("subscribed")
            try:
                self.wfile.write(b": connected\n\n"); self.wfile.flush()
                while not stop.is_set():
                    try:
                        frame = frames.get(timeout=.05)
                    except queue.Empty:
                        frame = b": heartbeat\n\n"
                    for index in range(0, len(frame), 11):
                        self.wfile.write(frame[index:index + 11])
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                stream_closed.set()
                self.close_connection = True
            return
        parts = url.path.strip("/").split("/")
        with database() as state:
            if url.path == "/api/session":
                query = urllib.parse.parse_qs(url.query, strict_parsing=True)
                if not query.get("parentID") or set(query) - {"parentID", "limit", "cursor", "order"}:
                    self.reply(400, {"error": "expected scoped child query"})
                    return
                children = [row["info"] for row in state["sessions"].values()
                            if row["info"].get("parentID") == query["parentID"][0]]
                self.reply(200, {"data": children, "cursor": {}})
                return
            if url.path == "/api/session/active":
                self.reply(200, {"data": {sid: {"type": "running"} for sid, row in state["sessions"].items() if row["active"]}})
                return
            if len(parts) >= 3 and parts[:2] == ["api", "session"] and parts[2] in state["sessions"]:
                sid = parts[2]
                session = state["sessions"][sid]
                opts = options()
                if opts.get("changeTail") and not state.get("tailChanged"):
                    session["messages"].append(message(state, "synthetic", text="External tail with unchanged user head"))
                    state["tailChanged"] = True
                if len(parts) == 3:
                    self.reply(200, {"data": session["info"]})
                    return
                if parts[3:] in (["children"], ["form"], ["permission"]):
                    self.reply(200, {"data": []})
                    return
                if parts[3:] == ["inbox"]:
                    self.reply(200, {"data": session["inbox"]})
                    return
                if parts[3:] == ["message"]:
                    query = urllib.parse.parse_qs(url.query, strict_parsing=True)
                    if set(query) - {"limit", "order", "cursor"} or ("cursor" in query and "order" in query):
                        self.reply(400, {"error": "invalid cursor query"})
                        return
                    order = query.get("order", ["asc"])[0]
                    start = 0
                    if "cursor" in query:
                        decoded = json.loads(base64.urlsafe_b64decode(query["cursor"][0] + "==="))
                        order = decoded["order"]
                        ordered = list(session["messages"] if order == "asc" else reversed(session["messages"]))
                        start = next(index for index, row in enumerate(ordered) if row["id"] == decoded["id"]) + 1
                    ordered = list(session["messages"] if order == "asc" else reversed(session["messages"]))
                    page = ordered[start:start + min(3, int(query.get("limit", ["50"])[0]))]
                    def cursor(row):
                        return base64.urlsafe_b64encode(json.dumps({"id": row["id"], "order": order, "direction": "next"}).encode()).decode().rstrip("=")
                    record("history-page", sessionID=sid, cursorPresent="cursor" in query, orderPresent="order" in query, count=len(page))
                    self.reply(200, {"data": page, "cursor": {"next": cursor(page[-1])} if page else {}})
                    return
                if len(parts) == 5 and parts[3] == "message":
                    row = next((row for row in session["messages"] if row["id"] == parts[4]), None)
                    self.reply(200, {"data": row}) if row else self.reply(404, {"error": "missing message"})
                    return
        self.reply(404, {"error": "missing owned fixture resource"})

    def do_POST(self):
        url = self.route()
        if url is None:
            return
        body, opts = self.body(), options()
        parts = url.path.strip("/").split("/")
        if url.path == "/api/session":
            with database() as state:
                sid = body["id"]
                if body.get("location") != {"directory": directory} or sid in state["sessions"]:
                    self.reply(409, {"error": "invalid create"}); return
                info = dict(body, time={"created": 1790657100000, "updated": 1790657100000})
                history = [message(state, "location-switched", location=body["location"]),
                           message(state, "agent-switched", agent=body["agent"]), message(state, "model-switched", model=body["model"])]
                state["sessions"][sid] = {"info": info, "messages": history, "active": False, "inbox": [], "seq": 0}
            record("create", sessionID=sid)
            self.reply(200, {"data": info}); return
        with database() as state:
            if len(parts) < 4 or parts[:2] != ["api", "session"] or parts[2] not in state["sessions"]:
                self.reply(404, {"error": "missing session"}); return
            sid, action = parts[2], parts[3:]
            session = state["sessions"][sid]
            if action in (["model"], ["agent"]):
                key = action[0]
                if session["info"].get(key) != body[key]:
                    fields = {key: body[key], "previous": session["info"].get(key)}
                    session["messages"].append(message(state, key + "-switched", **fields))
                session["info"][key] = body[key]
                record("configure", sessionID=sid, setting=key)
                self.reply(204); return
            if action == ["prompt"]:
                steering = body.get("delivery") == "steer"
                if session["active"] != steering or not subscribed.is_set():
                    self.reply(409, {"error": "invalid prompt activity"}); return
                admission = {"id": body["id"], "sessionID": sid, "type": "user", "delivery": body["delivery"],
                             "time": {"created": 1790657100000 + state["counter"]}, "payload": {"text": body["text"]}}
                session["messages"].append(dict(id=body["id"], type="user", text=body["text"], time=admission["time"]))
                session["inbox"].append(admission)
                session["active"] = True
                if not steering:
                    session["opening"] = body["id"]
                captured = copy.deepcopy(session["info"])
                record("prompt", sessionID=sid, inputID=body["id"], delivery=body["delivery"], text=body["text"], model=captured["model"], agent=captured["agent"], permissions=captured["permissions"])
            elif action == ["fork"]:
                cut = body.get("before")
                end = next(index for index, row in enumerate(session["messages"]) if row["id"] == cut) if cut else len(session["messages"])
                copied = copy.deepcopy(session["messages"][:end])
                target = next_id(state, "ses_history_fork_")
                mapping = {row["id"]: "msg_fork_" + target + "_" + str(index) for index, row in enumerate(copied)}
                for row in copied:
                    row["id"] = mapping[row["id"]]
                    if row["type"] == "compaction" and row.get("metadata", {}).get("keepID") in mapping:
                        row["metadata"]["keepID"] = mapping[row["metadata"]["keepID"]]
                boundary = {"type": "before", "messageID": cut} if cut else {"type": "through", "messageID": session["messages"][-1]["id"]}
                info = copy.deepcopy(session["info"])
                info["id"] = target; info["fork"] = {"sessionID": sid, "boundary": boundary}
                info.pop("revert", None)
                state["sessions"][target] = {"info": info, "messages": copied, "active": False, "inbox": [], "seq": session["seq"]}
                record("fork", sessionID=sid, targetID=target, before=cut, copied=len(copied), regenerated=all(row["id"] != old["id"] for row, old in zip(copied, session["messages"])))
            elif action == ["revert", "stage"]:
                if body.get("files") is not False or session["info"].get("revert") or session["active"]:
                    self.reply(409, {"error": "unsafe stage"}); return
                if not any(row["id"] == body["messageID"] for row in session["messages"]):
                    self.reply(404, {"error": "missing cut"}); return
                if opts.get("dropStageBefore"):
                    record("stage", sessionID=sid, applied=False, files=False, cut=body["messageID"])
                    self.drop(); return
                stage = {"messageID": body["messageID"], "snapshot": "fixture-history-snapshot", "files": []}
                session["info"]["revert"] = stage
                record("stage", sessionID=sid, applied=True, files=body["files"], cut=body["messageID"])
            elif action == ["revert", "commit"]:
                stage = session["info"].get("revert")
                if stage:
                    end = next(index for index, row in enumerate(session["messages"]) if row["id"] == stage["messageID"])
                    session["messages"] = session["messages"][:end]
                    session["info"].pop("revert", None)
                record("commit", sessionID=sid, applied=bool(stage))
            elif action == ["interrupt"]:
                interrupted = session["active"]
                self.reply(200, {"interrupted": interrupted})
                if interrupted:
                    child(lambda: emit("session.execution.interrupted", sid, {"reason": "user"}, terminal=True))
                return
            else:
                self.reply(404, {"error": "unsupported owned operation"}); return
        if action == ["prompt"]:
            self.reply(200, {"data": admission})
            child(lambda: run_input(sid, admission, captured, steering))
        elif action == ["fork"]:
            self.reply(200, {"data": info})
        elif action == ["revert", "stage"]:
            emit("session.revert.staged", sid, {"revert": stage})
            marker("stage-applied")
            while options().get("holdStageACK") and not stop.wait(.005):
                pass
            if opts.get("dropStageACK"):
                self.drop()
            else:
                self.reply(200, {"data": stage})
        elif action == ["revert", "commit"]:
            if stage:
                emit("session.revert.committed", sid, {"to": stage["messageID"]})
            marker("commit-applied")
            if opts.get("dropCommitACK"):
                self.drop()
            else:
                self.reply(204)

    def do_PATCH(self):
        url = self.route()
        if url is None:
            return
        body = self.body()
        sid = url.path.strip("/").split("/")[-1]
        with database() as state:
            if sid not in state["sessions"]:
                self.reply(404, {"error": "missing session"}); return
            state["sessions"][sid]["info"]["permissions"] = body["permissions"]
        record("permissions", sessionID=sid)
        self.reply(204)

    def do_DELETE(self):
        url = self.route()
        if url is None:
            return
        parts, opts = url.path.strip("/").split("/"), options()
        if len(parts) == 5 and parts[:2] == ["api", "session"] and parts[3] == "inbox":
            self.reply(204); return
        if len(parts) != 4 or parts[:2] != ["api", "session"] or parts[3] != "revert":
            self.reply(404, {"error": "unsupported owned deletion"}); return
        sid = parts[2]
        record("clear", sessionID=sid, applied=not opts.get("failClear"))
        marker("clear-requested")
        if opts.get("failClear"):
            self.reply(500, {"error": "synthetic clear failure"}); return
        with database() as state:
            session = state["sessions"][sid]
            session["info"].pop("revert", None)
            session["active"] = True
        emit("session.revert.cleared", sid)
        if opts.get("clearACKFirst"):
            self.reply(204)
            child(lambda: clear_execution(sid))
            return
        clear_execution(sid)
        if opts.get("dropClearACK"):
            self.drop()
        else:
            self.reply(204)


record("process", exactArguments=sys.argv[1:] == ["serve", "--stdio", "--hostname", "127.0.0.1", "--port", "0"], freshCredential=fresh)
server = Server(("127.0.0.1", 0), Handler)
worker = threading.Thread(target=lambda: server.serve_forever(poll_interval=.02), daemon=True)
worker.start()
print(json.dumps({"url": "http://127.0.0.1:" + str(server.server_port)}), flush=True)
sys.stdin.buffer.read()
stop.set()
server.shutdown()
server.server_close()
worker.join(timeout=.3)
for task in threads:
    task.join(timeout=.1)
stream_closed.wait(timeout=.3)
record("closed", stdinEOF=True, streamClosed=stream_closed.is_set(), httpStopped=not worker.is_alive())
