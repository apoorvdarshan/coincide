#!/usr/bin/python3 -S
"""Private OpenCode SERVER 1.x TCP peer. No provider import or model call."""
import base64
import copy
import http.server
import json
import os
import pathlib
import queue
import signal
import sys
import threading
import time
import urllib.parse

os.umask(0o077)
root = pathlib.Path(__file__).resolve().parent
directory = json.loads((root / "fixture-directory.json").read_text(encoding="utf-8"))["directory"]
if not isinstance(directory, str) or not os.path.isabs(directory) or not os.path.samefile(directory, pathlib.Path.cwd()):
    raise ValueError("The private directory does not match the owned working directory")
password = os.environ.get("OPENCODE_SERVER_PASSWORD", "")
expected_auth = "Basic " + base64.b64encode(("opencode:" + password).encode()).decode()
try:
    fresh_credential = len(base64.b64decode(password, validate=True)) == 32
except ValueError:
    fresh_credential = False
exact_arguments = sys.argv[1:] == ["serve", "--hostname", "127.0.0.1", "--port", "0"]
no_inherited_service = not any(os.environ.get(key) for key in [
    "OPENCODE_PASSWORD", "OPENCODE_SERVER_URL", "OPENCODE_URL", "OPENCODE_PTY_HANDOFF"
])
stop = threading.Event()
subscribed = threading.Event()
stream_closed = threading.Event()
lock = threading.RLock()
frames = queue.Queue(maxsize=128)
sessions = {}
active = set()
workers = []
prompt_count = 0
model_id = "wire-model/with-slash"
model = {"id": model_id, "name": "Synthetic native 1 model", "variants": {"balanced": {}, "fast": {}},
         "modalities": {"input": ["text"], "output": ["text"]}, "toolcall": True}
plan_path = str(pathlib.Path(directory) / "plan.md")
agents = [
    {"name": "build", "mode": "primary", "hidden": False, "permission": []},
    {"name": "plan", "mode": "primary", "hidden": False,
     "permission": [{"permission": "edit", "pattern": plan_path, "action": "allow"}]}
]


def write_json(name, value):
    target = root / (name + ".partial")
    target.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    target.replace(root / name)


def record(kind, **values):
    # Only explicit synthetic semantic fields. No headers, credentials, URLs or
    # inherited config/environment are written even on a failed assertion.
    with lock:
        with (root / "wire.jsonl").open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(dict(kind=kind, **values), ensure_ascii=False) + "\n")


def emit(kind, sid, properties=None, marker=None, split=False):
    value = {"type": kind, "properties": dict(sessionID=sid, **(properties or {}))}
    wire = ("data: " + json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\r\n\r\n").encode("utf-8")
    frames.put_nowait((wire, marker, split))


def run_turn(sid, body, number):
    now = int(time.time() * 1000)
    user = {"id": body["messageID"], "sessionID": sid, "role": "user", "agent": body["agent"],
            "model": dict(body["model"], variant=body.get("variant")), "time": {"created": now}}
    assistant = {"id": "msg_native_assistant_" + str(number), "sessionID": sid, "role": "assistant",
                 "parentID": body["messageID"], "modelID": body["model"]["modelID"],
                 "providerID": body["model"]["providerID"], "agent": body["agent"], "mode": body["agent"],
                 "time": {"created": now}, "path": {"cwd": directory, "root": directory}, "cost": 0,
                 "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}}
    emit("message.updated", sid, {"info": user})
    emit("session.status", sid, {"status": {"type": "busy"}})
    emit("message.updated", sid, {"info": assistant})
    text = {"id": "part_text_" + str(number), "sessionID": sid, "messageID": assistant["id"],
            "type": "text", "text": "discarded incremental 工作 🌍", "time": {"start": now}}
    emit("message.part.updated", sid, {"part": text, "time": now}, split=True)
    emit("message.part.delta", sid, {"messageID": assistant["id"], "partID": text["id"], "field": "text", "delta": " plus stale"})
    final = dict(text, text=" authoritative first 工作 🌍 " if number == 1 else " authoritative second FIFO ",
                 time={"start": now, "end": now + 1})
    emit("message.part.updated", sid, {"part": final, "time": now + 1}, split=True)
    assistant["time"]["completed"] = now + 1
    emit("message.updated", sid, {"info": assistant})
    tool = {"id": "part_tool_" + str(number), "sessionID": sid, "messageID": assistant["id"],
            "type": "tool", "tool": "bash", "callID": "call_native_" + str(number),
            "state": {"status": "completed", "input": {"command": "printf synthetic"},
                      "output": "Synthetic native 1 output " + str(number), "title": "Synthetic command",
                      "metadata": {}, "time": {"start": now, "end": now + 1}}}
    emit("message.part.updated", sid, {"part": tool, "time": now + 1}, marker="assistant-completed-" + str(number))
    if number == 1:
        while not stop.wait(0.01):
            if (root / "release-first").exists():
                with lock:
                    if sid not in active:
                        return
                    active.remove(sid)
                    emit("session.status", sid, {"status": {"type": "idle"}})
                    emit("session.idle", sid)
                return


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        if isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            return
        record("fixture-handler-failed")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, value=None):
        body = b"" if status == 204 else json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        if status != 204:
            self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)
        self.wfile.flush()

    def route(self):
        url = urllib.parse.urlsplit(self.path)
        authenticated = self.headers.get("Authorization") == expected_auth
        matched = url.path == "/global/health" and not url.query or urllib.parse.parse_qs(url.query, strict_parsing=True) == {"directory": [directory]}
        record("request", method=self.command, path=url.path, authenticated=authenticated, directoryMatched=matched)
        if not authenticated:
            self.reply(401, {"error": "unauthorized"})
            return None
        if not matched:
            self.reply(400, {"error": "invalid private directory"})
            return None
        return url

    def body(self):
        count = int(self.headers.get("Content-Length", "0"))
        if not 0 < count <= 1048576:
            raise ValueError("The private request body is outside its bound")
        return json.loads(self.rfile.read(count))

    def do_GET(self):
        url = self.route()
        if url is None:
            return
        if url.path == "/global/health":
            self.reply(200, {"healthy": True, "version": "1.14.19"})
            return
        if url.path == "/provider":
            self.reply(200, {"all": [{"id": "synthetic", "name": "Synthetic", "models": {model_id: model}}],
                             "default": {"synthetic": model_id}, "connected": ["synthetic"]})
            return
        if url.path == "/agent":
            self.reply(200, agents)
            return
        if url.path == "/event":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            try:
                self.wfile.write(b": subscribed\r\n\r\n")
                self.wfile.flush()
                subscribed.set()
                while not stop.is_set():
                    try:
                        wire, marker, split = frames.get(timeout=0.05)
                    except queue.Empty:
                        self.wfile.write(b": heartbeat\r\n\r\n")
                        self.wfile.flush()
                        continue
                    if split:
                        for offset in range(0, len(wire), 3):
                            self.wfile.write(wire[offset:offset + 3])
                            self.wfile.flush()
                    else:
                        self.wfile.write(wire)
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
        with lock:
            if parts == ["session", "status"]:
                self.reply(200, {sid: {"type": "busy"} for sid in active})
            elif len(parts) >= 2 and parts[0] == "session" and parts[1] in sessions:
                if len(parts) == 2:
                    self.reply(200, sessions[parts[1]])
                elif parts[2:] in [["message"], ["children"]]:
                    self.reply(200, [])
                else:
                    self.reply(404, {"error": "unsupported private route"})
            else:
                self.reply(404, {"error": "missing private session"})

    def do_POST(self):
        global prompt_count
        url = self.route()
        if url is None:
            return
        body = self.body()
        with lock:
            if url.path == "/session":
                if sessions or set(body) != {"permission"}:
                    self.reply(409, {"error": "invalid private create"})
                    return
                sid = "ses_server_generated_native_1"
                sessions[sid] = {"id": sid, "directory": directory, "permission": body["permission"]}
                record("create", sessionID=sid, serverGenerated=True, noCallerID="id" not in body, noTitle="title" not in body)
                self.reply(200, sessions[sid])
                return
            parts = url.path.strip("/").split("/")
            if len(parts) != 3 or parts[0] != "session" or parts[1] not in sessions:
                self.reply(404, {"error": "missing private route"})
                return
            sid, action = parts[1:]
            if action == "prompt_async":
                text = "".join(part.get("text", "") for part in body["parts"] if part["type"] == "text")
                if sid in active or text not in ["wire-v1-first 工作 🌍", "wire-v1-second FIFO"] or not subscribed.is_set():
                    self.reply(409, {"error": "invalid private prompt"})
                    return
                prompt_count += 1
                record("prompt", number=prompt_count, sessionID=sid, inputID=body["messageID"], text=text,
                       model=body["model"], variant=body.get("variant"), agent=body["agent"],
                       permissions=copy.deepcopy(sessions[sid]["permission"]), streamWasReady=subscribed.is_set())
                active.add(sid)
                self.reply(204)
                worker = threading.Thread(target=run_turn, args=(sid, copy.deepcopy(body), prompt_count), daemon=True)
                workers.append(worker)
                worker.start()
            elif action == "abort":
                was_active = sid in active
                record("abort", sessionID=sid, wasActive=was_active)
                if was_active:
                    active.remove(sid)
                    emit("session.error", sid, {"error": {"name": "MessageAbortedError", "data": {"message": "Synthetic interruption"}}})
                    emit("session.idle", sid)
                self.reply(200, True)
            else:
                self.reply(404, {"error": "unsupported private route"})

    def do_PATCH(self):
        url = self.route()
        if url is None:
            return
        body = self.body()
        parts = url.path.strip("/").split("/")
        with lock:
            if len(parts) == 2 and parts[0] == "session" and parts[1] in sessions and set(body) == {"permission"}:
                sessions[parts[1]]["permission"] = body["permission"]
                self.reply(200, sessions[parts[1]])
            else:
                self.reply(404, {"error": "unsupported private update"})


write_json("process.json", {"pid": os.getpid(), "exactArguments": exact_arguments,
           "freshCredential": fresh_credential, "noInheritedService": no_inherited_service, "directoryAliasVerified": True})
server = Server(("127.0.0.1", 0), Handler)
worker = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.02), daemon=True)
worker.start()
signal.signal(signal.SIGTERM, lambda *_: stop.set())


def stdin_lifetime():
    sys.stdin.buffer.read()
    stop.set()


threading.Thread(target=stdin_lifetime, daemon=True).start()
print("opencode server listening on http://127.0.0.1:" + str(server.server_port), flush=True)
stop.wait()
server.shutdown()
server.server_close()
worker.join(timeout=0.2)
for owned_worker in workers:
    owned_worker.join(timeout=0.1)
stream_closed.wait(timeout=0.4)
write_json("closed-owned-process", {"streamClosed": stream_closed.is_set(), "httpStopped": not worker.is_alive()})
