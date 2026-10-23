"""Offline Codex app-server peer. Native stdio -> real private loopback MCP.

This peer never loads a Codex installation, account, environment credential or
model service. Its wire evidence records safe shapes, never the bearer header.
"""
import copy
import http.client
import json
import os
import signal
import select
import sys
import threading
import time
import urllib.parse


options_path, wire_path = sys.argv[1:3]
with open(options_path, encoding="utf-8") as source:
    options = json.load(source)
output_lock = threading.Lock()
wire_lock = threading.Lock()
state_lock = threading.Lock()
stop = threading.Event()
workers = []
approval_waiters = {}
cancelled_turns = set()
completed_turns = set()
thread_id = "codex-mcp-thread"
turn_number = 0
connection = None
catalog = []
server_info = None
first_tool = None
foreign = copy.deepcopy(options.get("foreignServers", {"t3-code": {"preserved": True}, "user-server": {"preserved": True}}))
effective = copy.deepcopy(foreign)


def record(value):
    with wire_lock:
        with open(wire_path, "a", encoding="utf-8") as target:
            target.write(json.dumps(value, ensure_ascii=False) + "\n")


def emit(value):
    with output_lock:
        print(json.dumps(value, ensure_ascii=False), flush=True)


def reply(identifier, result):
    emit({"id": identifier, "result": result})


def notify(method, params):
    emit({"method": method, "params": {"threadId": thread_id, **params}})


def milestone(name):
    path = options.get(name)
    if path:
        with open(path, "w", encoding="utf-8") as target:
            target.write("observed")


def gate(name):
    path = options.get(name)
    deadline = time.monotonic() + 8
    while path and not os.path.exists(path):
        if stop.is_set() or time.monotonic() >= deadline:
            return False
        time.sleep(0.005)
    return not stop.is_set()


class MCP:
    def __init__(self, value):
        url = urllib.parse.urlsplit(value["url"])
        if url.scheme != "http" or url.hostname != "127.0.0.1" or not url.port or url.path != "/mcp" or url.query or url.fragment or url.username or url.password:
            raise ValueError("fixture endpoint")
        self.port = url.port
        self.authorization = value["http_headers"]["Authorization"]
        self.next_id = 0
        self.lock = threading.Lock()

    def request(self, method, params, notification=False):
        with self.lock:
            self.next_id += 1
            identifier = self.next_id
        value = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notification:
            value["id"] = identifier
        client = http.client.HTTPConnection("127.0.0.1", self.port, timeout=4)
        try:
            client.request("POST", "/mcp", body=json.dumps(value).encode("utf-8"), headers={
                "Authorization": self.authorization, "MCP-Protocol-Version": "2025-06-18",
                "Accept": "application/json, text/event-stream", "Content-Type": "application/json"})
            response = client.getresponse()
            data = response.read(1048577)
            if len(data) > 1048576 or response.status not in (200, 202):
                raise ValueError("fixture HTTP")
            if notification:
                if response.status != 202 or data:
                    raise ValueError("fixture notification")
                return None
            frame = json.loads(data)
            if frame.get("id") != identifier or "error" in frame:
                raise ValueError("fixture RPC")
            return frame["result"]
        finally:
            client.close()


def complete(native, status="completed"):
    with state_lock:
        if native in completed_turns:
            return
        completed_turns.add(native)
    notify("turn/completed", {"turn": {"id": native, "status": status}})


def tool_call(native, name, arguments, item_id):
    item = {"type": "mcpToolCall", "id": item_id, "server": "coincide", "tool": name,
            "status": "inProgress", "arguments": arguments, "result": None, "error": None,
            "appContext": None, "mcpAppUi": None, "pluginId": None, "readOnlyHint": name == "t3_thread_read", "durationMs": None}
    notify("item/started", {"turnId": native, "item": item})
    result = connection.request("tools/call", {"name": name, "arguments": arguments})
    item.update({"status": "failed" if result.get("isError") else "completed", "result": result, "durationMs": 1})
    notify("item/completed", {"turnId": native, "item": item})
    record({"kind": "mcpCall", "tool": name, "isError": bool(result.get("isError")), "turn": native})
    return item


def model_flow(native, number):
    global first_tool
    try:
        if number == 1 and options.get("invokeTools"):
            first_tool = tool_call(native, "t3_thread_read", {"threadId": options["appThreadID"], "limit": 5, "maxCharsPerItem": 50}, "native-mcp-read")
            milestone("readObserved")
            if options.get("approval"):
                identifier = 900 + number
                waiter = {"event": threading.Event(), "allowed": False}
                with state_lock:
                    approval_waiters[identifier] = waiter
                # An actual existing Codex command approval, not a fabricated
                # MCP approval protocol. The fixture's next tool follows it.
                emit({"id": identifier, "method": "item/commandExecution/requestApproval", "params": {
                    "threadId": thread_id, "turnId": native, "itemId": "native-command-decision", "kind": "command",
                    "startedAtMs": 1, "environmentId": None, "command": "synthetic-local-action", "cwd": options["cwd"],
                    "reason": "Offline approval transport acceptance"}})
                if not waiter["event"].wait(8) or stop.is_set():
                    return
                if not waiter["allowed"]:
                    record({"kind": "approvalDeclined"})
                    complete(native)
                    return
            if not stop.is_set():
                tool_call(native, "t3_thread_update", {"action": "rename", "title": options.get("renamedTitle", "Codex MCP renamed 工作"),
                    "clientRequestId": "native-fixture-rename"}, "native-mcp-write")
                milestone("writeObserved")
        elif number == 2 and first_tool and options.get("lateOriginalTool"):
            late = copy.deepcopy(first_tool)
            late["result"] = {"content": [{"type": "text", "text": "late original result"}], "structuredContent": {"lateOriginal": True}, "_meta": None}
            notify("item/completed", {"turnId": "codex-mcp-turn-1", "item": late})
        notify("item/agentMessage/delta", {"turnId": native, "itemId": "agent-" + native, "delta": "NATIVE_MCP_READY"})
        milestone("turnReady" + str(number))
        if not gate("releaseTurn" + str(number)):
            return
        with state_lock:
            cancelled = native in cancelled_turns
        if not cancelled:
            complete(native)
    except Exception:
        record({"kind": "flowFailure", "category": "fixedSyntheticFailure"})
        complete(native, "failed")


def input_lines():
    # TextIO may prefetch several frames; read the descriptor explicitly so a
    # signal can end an idle peer without waiting on a restarted readline.
    buffered = b""
    while not stop.is_set():
        ready, _, _ = select.select([sys.stdin.fileno()], [], [], 0.025)
        if not ready:
            continue
        data = os.read(sys.stdin.fileno(), 65536)
        if not data:
            return
        buffered += data
        while b"\n" in buffered:
            line, buffered = buffered.split(b"\n", 1)
            yield line.decode("utf-8")

signal.signal(signal.SIGTERM, lambda *_: stop.set())
record({"kind": "started", "pid": os.getpid()})
try:
    for line in input_lines():
        if stop.is_set():
            break
        frame = json.loads(line)
        method, identifier = frame.get("method"), frame.get("id")
        if method is None:
            with state_lock:
                waiter = approval_waiters.get(identifier)
            if waiter:
                waiter["allowed"] = (frame.get("result") or {}).get("decision") == "accept"
                record({"kind": "approvalResponse", "allowed": waiter["allowed"]})
                notify("serverRequest/resolved", {"requestId": identifier})
                waiter["event"].set()
            continue
        params = frame.get("params") or {}
        safe = {"kind": "request", "method": method, "keys": sorted(params)}
        for key in ["model", "effort", "approvalPolicy", "approvalsReviewer", "sandbox", "cwd", "threadId", "historyMode"]:
            if key in params:
                safe[key] = params[key]
        if method in ("thread/start", "thread/resume"):
            config = params.get("config") or {}
            slot = config.get("mcp_servers.coincide")
            safe["configKeys"] = sorted(config)
            if slot:
                connection = MCP(slot)
                safe["owned"] = {"keys": sorted(slot), "headerNames": sorted(slot.get("http_headers", {})),
                    "toolTimeout": slot.get("tool_timeout_sec"), "startupGrace": config.get("mcp_optional_startup_grace_ms"),
                    "headerInArguments": any(connection.authorization in arg for arg in sys.argv),
                    "headerInEnvironment": any(connection.authorization in value for value in os.environ.values())}
        if method == "turn/start":
            safe["input"] = params.get("input")
        record(safe)
        if method == "initialize":
            reply(identifier, {"userAgent": options.get("userAgent", "coincide/0.163.0")})
        elif method == "initialized":
            continue
        elif method == "model/list":
            reply(identifier, {"data": [{"id": "wire-model", "model": "wire-model", "isDefault": True,
                "supportedReasoningEfforts": [], "defaultReasoningEffort": None}], "nextCursor": None})
        elif method == "mcpServerStatus/list":
            if "threadId" not in params:
                names = sorted(foreign)
                if options.get("collision"):
                    names.append("coincide")
                reply(identifier, {"data": [{"name": name, "tools": {}} for name in names], "nextCursor": None})
            else:
                milestone("statusEntered")
                if not gate("releaseStatus"):
                    break
                if options.get("statusError"):
                    emit({"id": identifier, "error": {"code": -32603, "message": connection.authorization}})
                    continue
                row = {"name": "coincide", "tools": {tool["name"]: tool for tool in catalog}}
                if not options.get("minimalStatus"):
                    row.update({"runtimeStatus": "connected", "toolsError": None, "httpOrigin": "http://127.0.0.1:" + str(connection.port), "serverInfo": server_info})
                if options.get("missingTools"):
                    row["tools"] = {}
                if options.get("wrongOrigin"):
                    row["httpOrigin"] = "http://127.0.0.1:1"
                reply(identifier, {"data": [row], "nextCursor": None})
        elif method in ("thread/start", "thread/resume"):
            milestone("registrationEntered")
            if not gate("releaseRegistration"):
                break
            if options.get("registrationError"):
                emit({"id": identifier, "error": {"code": -32603, "message": connection.authorization + " / " + connection.authorization[7:]}})
                print(connection.authorization, file=sys.stderr, flush=True)
                continue
            if connection:
                initialized = connection.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                    "clientInfo": {"name": "synthetic-codex-native-mcp", "version": "1"}})
                server_info = initialized["serverInfo"]
                connection.request("notifications/initialized", {}, notification=True)
                catalog = connection.request("tools/list", {})["tools"]
                effective["coincide"] = {"owned": True}
                record({"kind": "foreignServers", "unchanged": all(effective.get(name) == value for name, value in foreign.items()), "names": sorted(foreign)})
            thread_id = params.get("threadId", thread_id)
            reply(identifier, {"thread": {"id": thread_id, "historyMode": params.get("historyMode", "legacy")}})
        elif method == "turn/start":
            turn_number += 1
            native = "codex-mcp-turn-" + str(turn_number)
            reply(identifier, {"turn": {"id": native}})
            notify("turn/started", {"turn": {"id": native}})
            worker = threading.Thread(target=model_flow, args=(native, turn_number), daemon=True)
            workers.append(worker)
            worker.start()
        elif method == "turn/interrupt":
            native = params["turnId"]
            with state_lock:
                cancelled_turns.add(native)
            reply(identifier, {})
            complete(native, "interrupted")
        elif identifier is not None:
            emit({"id": identifier, "error": {"code": -32601, "message": "Unsupported synthetic method"}})
finally:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    stop.set()
    with state_lock:
        pending = list(approval_waiters.values())
    for waiter in pending:
        waiter["event"].set()
    for worker in workers:
        worker.join(timeout=1)
    record({"kind": "closed", "pid": os.getpid(), "workersDrained": all(not worker.is_alive() for worker in workers)})
