"""Private stream-json consumer for a host-issued native Claude history choice."""
import json
import http.client
import os
from pathlib import Path
import signal
import sys
import uuid
import urllib.parse

root = Path(sys.argv[1]).resolve(strict=True)
assert root.name.startswith("coincide-remote-history-") and os.stat(root).st_mode & 0o077 == 0
workspace = root / "isolated"
assert Path.cwd().resolve() == workspace
assert Path(os.environ["CLAUDE_CONFIG_DIR"]).resolve() == root / "claude-home"
args = sys.argv[2:]
assert "--input-format" in args and "stream-json" in args
native = None; cursor = None
for index, value in enumerate(args):
    if value in ("--resume", "--session-id"):
        native = args[index + 1]
    if value.startswith("--resume-session-at="):
        cursor = value.split("=", 1)[1]
assert native is not None
uuid.UUID(native)
os.umask(0o077)
wire = root / "claude-wire.jsonl"


def record(kind, **fields):
    data = (json.dumps({"kind": kind, "pid": os.getpid(), **fields}) + "\n").encode()
    fd = os.open(wire, os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        assert os.write(fd, data) == len(data)
    finally:
        os.close(fd)


def emit(value):
    print(json.dumps(value), flush=True)


def verify_context_server(server):
    url = urllib.parse.urlsplit(server["url"])
    assert server["type"] == "http" and url.scheme == "http" and url.hostname == "127.0.0.1" and url.port
    assert url.path == "/mcp" and not (url.query or url.fragment or url.username or url.password)
    def request(method, params, identifier):
        client = http.client.HTTPConnection("127.0.0.1", url.port, timeout=4)
        try:
            value = {"jsonrpc": "2.0", "method": method, "params": params}
            if identifier is not None: value["id"] = identifier
            client.request("POST", "/mcp", body=json.dumps(value).encode(), headers={
                "Authorization": server["headers"]["Authorization"], "MCP-Protocol-Version": "2025-06-18",
                "Accept": "application/json, text/event-stream", "Content-Type": "application/json"})
            response = client.getresponse(); data = response.read(1048577)
            if identifier is None:
                assert response.status == 202 and not data
                return None
            if response.status != 200 or len(data) > 1048576:
                record("context-catalog-failure", method=method, status=response.status)
                raise AssertionError("Private context HTTP status or bound")
            frame = json.loads(data)
            if frame.get("id") != identifier or "error" in frame:
                record("context-catalog-failure", method=method, code=frame.get("error", {}).get("code"))
                raise AssertionError("Private context RPC identity or error")
            return frame["result"]
        finally:
            client.close()
    request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
        "clientInfo": {"name": "private-context-claude", "version": "1"}}, 1)
    request("notifications/initialized", {}, None)
    names = [tool["name"] for tool in request("tools/list", {}, 2)["tools"]]
    if names != ["t3_context_read"]:
        record("context-catalog-failure", names=names)
        raise AssertionError("Private context catalog scope")
    record("context-catalog", names=names)


exited = False


def finish(reason):
    global exited
    mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
    try:
        if not exited:
            record("exit", reason=reason)
            exited = True
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)


def terminated(_signal, _frame):
    finish("owned-signal")
    raise SystemExit(0)


signal.signal(signal.SIGTERM, terminated)
record("launch", nativeID=native, hasResumeCursor=cursor is not None)
try:
    for line in sys.stdin:
        frame = json.loads(line)
        if frame.get("type") == "control_request":
            method = frame["request"]["subtype"]
            assert method in ("initialize", "set_model", "set_permission_mode", "mcp_status", "mcp_set_servers")
            result = {"models": [{"value": "history-offline", "displayName": "Private history"}]} if method == "initialize" else {}
            if method == "mcp_status": result = {"mcpServers": []}
            elif method == "mcp_set_servers":
                assert list(frame["request"]["servers"]) == ["coincide"]
                verify_context_server(frame["request"]["servers"]["coincide"])
                result = {"added": ["coincide"], "removed": [], "errors": {}}
            emit({"type": "control_response", "response": {"subtype": "success", "request_id": frame["request_id"], "response": result}})
            if method == "initialize":
                emit({"type": "system", "subtype": "init", "session_id": native, "parent_tool_use_id": None, "claude_code_version": "2.1.276"})
        elif frame.get("type") == "user":
            assert frame["message"]["content"] == "Consume the explicit private history choice"
            files = list((root / "claude-home/projects").glob("*/" + native + ".jsonl"))
            assert len(files) == 1 and files[0].resolve().is_relative_to(root)
            path = files[0]
            records = [json.loads(x) for x in path.read_text().splitlines() if x]
            parent = cursor or records[-1]["uuid"]
            assert any(x.get("uuid") == parent for x in records)
            input_id = frame["uuid"]; answer_id = str(uuid.uuid4())
            payloads = [
                {"type": "user", "uuid": input_id, "sessionId": native, "parentUuid": parent, "cwd": str(workspace), "isSidechain": False,
                 "message": {"role": "user", "content": frame["message"]["content"]}},
                {"type": "assistant", "uuid": answer_id, "sessionId": native, "parentUuid": input_id, "cwd": str(workspace), "isSidechain": False,
                 "message": {"role": "assistant", "content": "Private history consumer complete"}}
            ]
            fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
            try:
                data = b"".join((json.dumps(x) + "\n").encode() for x in payloads)
                assert os.write(fd, data) == len(data)
                os.fsync(fd)
            finally:
                os.close(fd)
            record("input", inputID=input_id, parentID=parent)
            emit({"type": "assistant", "session_id": native, "parent_tool_use_id": None, "uuid": answer_id, "user_message_uuid": input_id,
                  "message": {"id": "private-history-api", "content": [{"type": "text", "text": "Private history consumer complete"}]}})
            emit({"type": "result", "session_id": native, "parent_tool_use_id": None, "is_error": False, "user_message_uuid": input_id})
        else:
            raise AssertionError("Unexpected private history consumer packet")
    finish("stdin-eof")
except BrokenPipeError:
    finish("owned-output-closed")
except Exception as error:
    record("fixture-error", errorType=type(error).__name__)
    finish("fixture-error")
    raise
