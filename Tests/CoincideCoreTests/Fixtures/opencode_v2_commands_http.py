#!/usr/bin/python3 -S
"""Private native command HTTP/SSE peer; no model, auth flow or provider fallback."""
import base64
import copy
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
# Darwin Foundation preserves /var aliases while pathlib resolves them to
# /private/var. Protocol locations are exact strings, not physical-file IDs.
# Retain the native caller's spelling only after proving it names our own cwd.
directory = json.loads((root / "fixture-directory.json").read_text(encoding="utf-8"))["directory"]
if not isinstance(directory, str) or not os.path.isabs(directory) or not os.path.samefile(directory, pathlib.Path.cwd()):
    raise ValueError("Fixture directory does not name the owned working directory")
password = os.environ.get("OPENCODE_PASSWORD", "")
expected_auth = "Basic " + base64.b64encode(("opencode:" + password).encode()).decode()
exact_arguments = sys.argv[1:] == ["serve", "--stdio", "--hostname", "127.0.0.1", "--port", "0"]
try:
    fresh_credential = len(base64.b64decode(password, validate=True)) == 32
except ValueError:
    fresh_credential = False
no_inherited_service = not any(os.environ.get(key) for key in [
    "OPENCODE_SERVER_PASSWORD", "OPENCODE_SERVER_URL", "OPENCODE_URL", "OPENCODE_PTY_HANDOFF"
])
stop = threading.Event()
subscribed = threading.Event()
stream_closed = threading.Event()
lock = threading.RLock()
frames = queue.Queue(maxsize=128)
workers = []
sessions = {}
messages = {}
inbox_items = {}
command_sessions = set()
command_history_postread = set()
active = set()
delivered = set()
prompt_count = 0
event_count = 0
sequence = 0
mode = json.loads((root / "fixture-mode.json").read_text())["mode"]
if mode not in ["success", "terminal-before-ack", "ambiguous-root", "dropped-no-root"]:
    raise ValueError("Invalid private command fixture mode")
second_marker = "queued normal $native-review-id 工作"
command_arguments = "literal 工作 $native-review-id\nsecond line"
model = {"id": "wire-model", "modelID": "backend-is-not-the-wire-id", "providerID": "synthetic",
         "name": "Synthetic TCP model", "enabled": True,
         "variants": [{"id": "balanced"}, {"id": "fast"}],
         "capabilities": {"tools": True, "input": ["text"], "output": ["text"]}}
plan_path = str(pathlib.Path(directory) / "plan.md")
agents = [
    {"id": "build", "name": "Build", "mode": "primary", "hidden": False, "permissions": []},
    {"id": "plan", "name": "Plan", "mode": "primary", "hidden": False,
     "permissions": [{"action": "edit", "resource": plan_path, "effect": "allow"}]}
]


def write_json(name, value):
    temporary = root / (name + ".partial")
    temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    temporary.replace(root / name)


def record(kind, **values):
    # Explicit semantic fields only: credentials, headers, environment, and URLs
    # are never written to disk, even when reporting a failed assertion.
    with lock:
        with (root / "wire.jsonl").open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(dict(kind=kind, **values), ensure_ascii=False) + "\n")


def emit(kind, sid, fields=None, ephemeral=False, version=1, marker=None, split=False):
    global event_count, sequence
    with lock:
        event_count += 1
        data = dict(sessionID=sid, **(fields or {}))
        value = {"id": "evt_tcp_" + str(event_count), "created": int(time.time() * 1000),
                 "type": kind, "location": {"directory": directory}, "data": data}
        if not ephemeral:
            sequence += 1
            value["durable"] = {"aggregateID": sid, "seq": sequence, "version": version}
        frame = ("id: " + value["id"] + "\r\ndata: " +
                 json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\r\n\r\n").encode("utf-8")
        frames.put_nowait((frame, marker, split))


def run_turn(sid, admission, number, captured):
    assistant = "msg_tcp_assistant_" + str(number)
    input_id = admission["id"]
    if number == 1:
        while not stop.wait(0.01):
            if (root / "release-command-inbox").exists():
                break
        if stop.is_set():
            return
    with lock:
        inbox_items[sid][input_id] = copy.deepcopy(admission)
    emit("session.inbox.enqueued", sid, {"inboxID": input_id, "item": admission})
    if number == 1 and mode == "ambiguous-root":
        foreign = dict(admission, id="msg_command_second_root")
        with lock:
            inbox_items[sid][foreign["id"]] = copy.deepcopy(foreign)
        emit("session.inbox.enqueued", sid, {"inboxID": foreign["id"], "item": foreign})
        write_json("ambiguous-roots-emitted", {"count": 2})
        return
    emit("session.execution.started", sid)
    with lock:
        delivered.add(input_id)
        inbox_items[sid].pop(input_id)
        messages[sid].append({"id": input_id, "type": "user", "text": admission["payload"]["text"],
                              "time": copy.deepcopy(admission["time"])})
    emit("session.inbox.delivered", sid, {"inboxID": input_id})
    emit("session.step.started", sid, {"assistantMessageID": assistant, "agent": captured["agent"],
         "model": captured["model"], "started": int(time.time() * 1000)})
    text_fields = {"assistantMessageID": assistant, "ordinal": 0}
    emit("session.text.started", sid, text_fields)
    emit("session.text.delta", sid, dict(text_fields, delta="discarded incremental 工作 🌍"), ephemeral=True, split=True)
    final_text = " authoritative first 工作 🌍 " if number == 1 else " authoritative second FIFO "
    emit("session.text.ended", sid, dict(text_fields, text=final_text), split=True)
    tool_fields = {"assistantMessageID": assistant, "id": "call_tcp_" + str(number)}
    emit("session.tool.input.started", sid, dict(tool_fields, name="shell"))
    emit("session.tool.called", sid, dict(tool_fields, input={"command": "printf synthetic-" + str(number)}, executed=True))
    emit("session.step.ended", sid, {"assistantMessageID": assistant, "finish": "stop", "cost": 0,
         "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}})
    # The completed tool snapshot follows step.ended. Observing it in Engine is
    # a deterministic barrier proving step.ended did not drain the FIFO.
    emit("session.tool.success", sid, dict(tool_fields, executed=True,
         content=[{"type": "text", "text": "Synthetic TCP output " + str(number)}]),
         version=2, marker="step-ended-" + str(number))
    if number in [1, 2]:
        while not stop.wait(0.01):
            if number == 2 or (root / "release-first").exists():
                with lock:
                    if sid not in active:
                        return
                    active.remove(sid)
                    sessions[sid]["outcome"] = "succeeded"
                    sessions[sid]["time"]["idle"] = int(time.time() * 1000)
                    emit("session.execution.succeeded", sid)
                    if number == 1 and mode == "terminal-before-ack":
                        emit("session.tool.success", sid, dict(tool_fields, executed=True,
                             content=[{"type": "text", "text": "Native terminal before callback acknowledgement"}]),
                             version=3, marker="terminal-before-ack-observed")
                return


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # URLSession can reset an idle HTTP keepalive socket during shutdown.
        # That normal transport teardown is distinct from an invalid fixture
        # route/body or failed event generator.
        if isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            return
        record("fixture-handler-failed")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, value=None):
        data = b"" if status == 204 else json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        if status != 204:
            self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)
        self.wfile.flush()

    def route(self):
        authenticated = self.headers.get("Authorization") == expected_auth
        url = urllib.parse.urlsplit(self.path)
        record("request", method=self.command, path=url.path, authenticated=authenticated)
        if not authenticated:
            self.reply(401, {"error": "unauthorized"})
            return None
        return url

    def body(self):
        count = int(self.headers.get("Content-Length", "0"))
        if count <= 0 or count > 1048576:
            raise ValueError("Invalid fixture body size")
        return json.loads(self.rfile.read(count))

    def do_GET(self):
        url = self.route()
        if url is None:
            return
        if url.path == "/api/info" and not url.query:
            self.reply(200, {"version": "2.1.2", "pid": os.getpid()})
            return
        if url.path in ["/api/model", "/api/agent", "/api/model/default", "/api/command", "/api/skill"]:
            matched = urllib.parse.parse_qs(url.query, strict_parsing=True) == {"location[directory]": [directory]}
            record("catalog-location", matched=matched)
            if not matched:
                self.reply(400, {"error": "invalid location"})
                return
            data = [model] if url.path == "/api/model" else agents if url.path == "/api/agent" else model
            if url.path == "/api/command":
                data = [{"name": "inspect", "description": "Inspect native command"}]
            elif url.path == "/api/skill":
                data = [{"id": "native-review-id", "name": "Friendly display must not be sent", "path": directory + "/native/SKILL.md"}]
            self.reply(200, {"location": {"directory": directory}, "data": data})
            return
        if url.path == "/api/event" and not url.query:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            try:
                self.wfile.write(b": subscribed\n\n")
                self.wfile.flush()
                subscribed.set()
                record("subscribed")
                while not stop.is_set():
                    try:
                        frame, marker, split = frames.get(timeout=0.05)
                    except queue.Empty:
                        self.wfile.write(b": heartbeat\n\n")
                        self.wfile.flush()
                        continue
                    if split:
                        for offset in range(0, len(frame), 3):
                            self.wfile.write(frame[offset:offset + 3])
                            self.wfile.flush()
                    else:
                        self.wfile.write(frame)
                        self.wfile.flush()
                    if marker:
                        write_json(marker, {"flushed": True})
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                stream_closed.set()
                self.close_connection = True
            return
        parts = url.path.strip("/").split("/")
        if len(parts) == 4 and parts[:2] == ["api", "session"] and parts[3] == "message":
            if urllib.parse.parse_qs(url.query) != {"limit": ["200"], "order": ["asc"]}:
                self.reply(400, {"error": "invalid command history page"}); return
            with lock:
                sid = parts[2]
                if sid not in messages:
                    self.reply(404, {"error": "missing session"}); return
                after = sid in command_sessions
                if after:
                    command_history_postread.add(sid)
                record("command-history-after" if after else "command-history-before", sessionID=sid, limit=200, order="asc")
                self.reply(200, {"data": copy.deepcopy(messages[sid]), "cursor": {}})
            return
        with lock:
            if url.path == "/api/session/active" and not url.query:
                self.reply(200, {"data": {sid: {"type": "running"} for sid in active}})
                return
            parts = url.path.strip("/").split("/")
            if len(parts) >= 3 and parts[:2] == ["api", "session"] and not url.query:
                sid = parts[2]
                if sid not in sessions:
                    self.reply(404, {"error": "missing session"})
                elif len(parts) == 3:
                    self.reply(200, {"data": sessions[sid]})
                elif parts[3:] == ["inbox"]:
                    if sid in command_history_postread:
                        record("command-inbox-after", sessionID=sid)
                        command_history_postread.remove(sid)
                    self.reply(200, {"data": list(copy.deepcopy(inbox_items[sid]).values())})
                else:
                    self.reply(404, {"error": "unsupported route"})
                return
        self.reply(404, {"error": "unsupported route"})

    def do_POST(self):
        global prompt_count
        url = self.route()
        if url is None:
            return
        body = self.body()
        if url.query:
            self.reply(400, {"error": "unexpected query"})
            return
        with lock:
            if url.path == "/api/session":
                if body.get("location") != {"directory": directory} or not body.get("id", "").startswith("ses_coincide_"):
                    self.reply(400, {"error": "invalid session owner"})
                    return
                sid = body["id"]
                if sid in sessions:
                    self.reply(409, {"error": "duplicate session"})
                    return
                value = copy.deepcopy(body)
                value["time"] = {"created": int(time.time() * 1000), "updated": int(time.time() * 1000)}
                sessions[sid] = value
                messages[sid] = [{"id": "msg_prior_command_root", "type": "user", "text": "A prior native input",
                                  "time": {"created": value["time"]["created"]}}]
                inbox_items[sid] = {}
                record("create", sessionID=sid, exactLocation=True)
                self.reply(200, {"data": value})
                return
            parts = url.path.strip("/").split("/")
            if len(parts) != 4 or parts[:2] != ["api", "session"] or parts[2] not in sessions:
                self.reply(404, {"error": "unsupported route"})
                return
            sid, action = parts[2:]
            if action == "agent":
                sessions[sid]["agent"] = body["agent"]
                self.reply(204)
            elif action == "model":
                sessions[sid]["model"] = body["model"]
                self.reply(204)
            elif action == "command":
                if sid in active or not subscribed.is_set() or set(body) != {"name", "text", "delivery", "skills"} or body["name"] != "inspect" or body["text"] != command_arguments or body["delivery"] != "queue" or body["skills"] != [{"id": "native-review-id"}]:
                    self.reply(400, {"error": "invalid native command body"}); return
                captured = copy.deepcopy(sessions[sid])
                command_sessions.add(sid)
                record("command", sessionID=sid, body=body, model=captured["model"], agent=captured["agent"], permissions=captured["permissions"])
                write_json("command-posted", {"held": True})
                admission = {"id": "msg_native_command_root", "sessionID": sid, "type": "user", "delivery": "queue",
                             "time": {"created": int(time.time() * 1000)}, "payload": {"text": "Expanded native command input"}}
                active.add(sid)
                if mode == "terminal-before-ack":
                    worker = threading.Thread(target=run_turn, args=(sid, admission, 1, captured), daemon=True)
                    workers.append(worker); worker.start()
                # Release this request only after the test has saved a FIFO successor.
                # Do not hold the shared lock while waiting for the owned marker.
                lock.release()
                try:
                    while not stop.wait(0.01):
                        if (root / "release-command-response").exists():
                            break
                finally:
                    lock.acquire()
                if stop.is_set():
                    return
                if mode == "dropped-no-root":
                    record("command-reply-lost", nativeRootObserved=False)
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                self.reply(204)
                write_json("command-acknowledged", {"nativeInputID": admission["id"]})
                if mode != "terminal-before-ack":
                    worker = threading.Thread(target=run_turn, args=(sid, admission, 1, captured), daemon=True)
                    workers.append(worker); worker.start()
            elif action == "prompt":
                if sid in active or body.get("text") != second_marker or not subscribed.is_set():
                    self.reply(409, {"error": "invalid fixture admission"})
                    return
                if body.get("skills") != [{"id": "native-review-id"}]:
                    self.reply(400, {"error": "invalid native skill IDs"}); return
                prompt_count += 1
                number = prompt_count + 1
                admission = {"id": body["id"], "sessionID": sid, "type": "user", "delivery": body["delivery"],
                             "time": {"created": int(time.time() * 1000)}, "payload": {"text": body["text"]}}
                captured = copy.deepcopy(sessions[sid])
                record("prompt", number=number, sessionID=sid, inputID=body["id"], text=body["text"], skills=body["skills"],
                       delivery=body["delivery"], resume=body.get("resume"), agent=captured["agent"],
                       model=captured["model"], permissions=captured["permissions"], streamWasReady=subscribed.is_set())
                active.add(sid)
                self.reply(200, {"data": admission})
                worker = threading.Thread(target=run_turn, args=(sid, admission, number, captured), daemon=True)
                workers.append(worker)
                worker.start()
            elif action == "interrupt":
                interrupted = sid in active
                record("interrupt", sessionID=sid, interrupted=interrupted)
                if interrupted:
                    active.remove(sid)
                    sessions[sid]["outcome"] = "interrupted"
                    sessions[sid]["time"]["idle"] = int(time.time() * 1000)
                    emit("session.execution.interrupted", sid, {"reason": "user"})
                self.reply(200, {"interrupted": interrupted})
            else:
                self.reply(404, {"error": "unsupported route"})

    def do_PATCH(self):
        url = self.route()
        if url is None:
            return
        body = self.body()
        parts = url.path.strip("/").split("/")
        with lock:
            if len(parts) == 3 and parts[:2] == ["api", "session"] and parts[2] in sessions and not url.query:
                sessions[parts[2]]["permissions"] = body["permissions"]
                self.reply(204)
            else:
                self.reply(404, {"error": "unsupported route"})

    def do_DELETE(self):
        url = self.route()
        if url is None:
            return
        parts = url.path.strip("/").split("/")
        with lock:
            if len(parts) == 5 and parts[:2] == ["api", "session"] and parts[2] in sessions and parts[3] == "inbox" and not url.query:
                record("cancel-inbox", sessionID=parts[2], inputID=parts[4], wasDelivered=parts[4] in delivered)
                self.reply(204)  # Native cancellation is a no-op after delivery.
            else:
                self.reply(404, {"error": "unsupported route"})


write_json("process.json", {"pid": os.getpid(), "exactArguments": exact_arguments,
           "freshCredential": fresh_credential, "noInheritedService": no_inherited_service,
           "directoryAliasVerified": True})
server = Server(("127.0.0.1", 0), Handler)
worker = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.02), daemon=True)
worker.start()
print(json.dumps({"url": "http://127.0.0.1:" + str(server.server_port)}), flush=True)
sys.stdin.buffer.read()
stop.set()
server.shutdown()
server.server_close()
worker.join(timeout=0.2)
for owned_worker in workers:
    owned_worker.join(timeout=0.1)
stream_closed.wait(timeout=0.4)
write_json("closed-after-eof", {"stdinEOF": True, "streamClosed": stream_closed.is_set(), "httpStopped": not worker.is_alive()})
