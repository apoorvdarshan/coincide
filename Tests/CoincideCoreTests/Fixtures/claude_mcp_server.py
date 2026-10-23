"""Closed-world Claude stdin peer; only the registered private MCP port is reachable."""
import json
import os
import socket
import sys
import time
import urllib.parse
import urllib.request

ROOT = sys.argv[1]
with open(os.path.join(ROOT, "settings.json"), encoding="utf-8") as source:
    SETTINGS = json.load(source)
SCENARIO = SETTINGS["scenario"]
AUDIT = os.path.join(ROOT, "audit.jsonl")
SESSION_ID = "c67c1b9b-a7b2-4bde-988e-4456a661ae91"
endpoint = None
authorization = None
network_address = None
permission = None
turn = 0
rpc_id = 0
opening_id = None


def audit(kind, **fields):
    with open(AUDIT, "a", encoding="utf-8") as output:
        output.write(json.dumps(dict(kind=kind, **fields), ensure_ascii=False) + "\n")


def emit(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def response(ident, result=None):
    emit({"type": "control_response", "response": {
        "subtype": "success", "request_id": ident, "response": result if result is not None else {}}})


original_connect = socket.socket.connect


def private_connect(sock, address):
    if network_address is None or tuple(address) != network_address:
        raise RuntimeError("The peer only permits the registered loopback endpoint.")
    return original_connect(sock, address)


socket.socket.connect = private_connect


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        raise RuntimeError("The private MCP peer does not follow redirects.")


opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())


def mcp(method, params, notification=False):
    global rpc_id
    rpc_id += 1
    payload = {"jsonrpc": "2.0", "method": method, "params": params}
    if not notification:
        payload["id"] = rpc_id
    request = urllib.request.Request(endpoint, data=json.dumps(payload).encode(), method="POST", headers={
        "Authorization": authorization, "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream", "MCP-Protocol-Version": "2025-06-18"})
    with opener.open(request, timeout=5) as reply:
        data = reply.read(1048577)
        assert len(data) <= 1048576
        if notification:
            assert reply.status == 202 and not data
            return None
        result = json.loads(data)
        assert reply.status == 200 and result.get("id") == rpc_id and "error" not in result
        return result["result"]


def read_thread():
    value = mcp("tools/call", {"name": "t3_thread_read", "arguments": {"threadId": SETTINGS["threadID"]}})
    assert not value.get("isError", False)
    content = json.loads(value["content"][0]["text"])
    assert content["thread"]["threadId"] == SETTINGS["threadID"]
    audit("read", turn=turn, renamed=content["thread"]["title"] == SETTINGS["renamedTitle"])


def finish(text):
    assistant_id = "7c209cd4-83e3-441a-b2d9-5ada5335060" + str(turn)
    emit({"type": "assistant", "session_id": SESSION_ID, "uuid": assistant_id,
          "parent_tool_use_id": None, "user_message_uuid": opening_id,
          "message": {"id": assistant_id, "role": "assistant", "content": [{"type": "text", "text": text}]}})
    emit({"type": "result", "session_id": SESSION_ID, "user_message_uuid": opening_id,
          "is_error": False, "result": text})


def main():
    global endpoint, authorization, network_address, permission, turn, opening_id
    # Apple's /usr/bin/python3 launcher adds selected-toolchain paths even after
    # env -i. These are system discovery names, not inherited provider settings.
    audit("launch", pid=os.getpid(), privateEnvironment=set(os.environ) <= {
        "HOME", "PATH", "CLAUDE_CONFIG_DIR", "LC_CTYPE", "CPATH", "LIBRARY_PATH",
        "MANPATH", "SDKROOT", "__CF_USER_TEXT_ENCODING"},
        secretArgumentsAbsent=not any("Bearer " in arg or "--mcp-config" in arg for arg in sys.argv[2:]))
    for line in sys.stdin:
        frame = json.loads(line)
        if frame["type"] == "control_request":
            request, ident = frame["request"], frame["request_id"]
            subtype = request["subtype"]
            assert subtype in {"initialize", "mcp_status", "mcp_set_servers", "set_permission_mode", "set_model", "interrupt"}
            audit(subtype)
            if subtype == "initialize":
                response(ident, {"models": [{"value": "fixture-model", "displayName": "Synthetic Claude"}]})
            elif subtype == "mcp_status":
                if SCENARIO == "malformed-status":
                    response(ident, {"mcpServers": {}})
                elif SCENARIO == "collision":
                    response(ident, {"mcpServers": [{"name": "coincide", "status": "connected", "scope": "project"}]})
                elif SCENARIO == "dynamic":
                    response(ident, {"mcpServers": [{"name": "foreign-dynamic", "status": "connected", "source": "dynamic"}]})
                else:
                    response(ident, {"mcpServers": [
                        {"name": "foreign-settings", "status": "connected", "source": "project"},
                        {"name": "foreign-plugin", "status": "connected", "source": "plugin"}]})
            elif subtype == "mcp_set_servers":
                assert set(request) == {"subtype", "servers"} and set(request["servers"]) == {"coincide"}
                server = request["servers"]["coincide"]
                assert set(server) == {"type", "url", "headers", "timeout"}
                assert server["type"] == "http" and server["timeout"] == 3660000
                parsed = urllib.parse.urlparse(server["url"])
                assert parsed.scheme == "http" and parsed.hostname == "127.0.0.1" and parsed.path == "/mcp"
                assert parsed.port and not parsed.query and not parsed.fragment and not parsed.username and not parsed.password
                assert set(server["headers"]) == {"Authorization"}
                authorization = server["headers"]["Authorization"]
                assert authorization.startswith("Bearer ") and len(authorization) == 50
                endpoint, network_address = server["url"], ("127.0.0.1", parsed.port)
                audit("registration-ready", headerOnStdin=True,
                      noSecretOutsideStdin=all(authorization not in value and authorization[7:] not in value
                          for value in list(sys.argv) + list(os.environ.values())))
                if SCENARIO == "held-ack":
                    while not os.path.exists(os.path.join(ROOT, "release")):
                        time.sleep(.005)
                if SCENARIO == "error-ack":
                    # Deliberately hostile provider text. Never write it to disk.
                    secret = authorization + " " + authorization[7:]
                    emit({"type": "control_request", "request_id": "unsafe-echo", "request": {
                        "subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": secret}}})
                    emit({"type": "control_response", "response": {
                        "subtype": "error", "request_id": ident, "error": secret}})
                elif SCENARIO == "partial-ack":
                    response(ident, {"added": [], "removed": [], "errors": {"coincide": authorization}})
                elif SCENARIO == "removed-ack":
                    response(ident, {"added": ["coincide"], "removed": ["foreign-settings"], "errors": {}})
                elif SCENARIO == "unsupported":
                    emit({"type": "control_response", "response": {
                        "subtype": "error", "request_id": ident, "error": "Unsupported control request"}})
                else:
                    if SCENARIO == "workflow":
                        initialized = mcp("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                            "clientInfo": {"name": "synthetic-claude", "version": "1"}})
                        assert initialized["protocolVersion"] == "2025-06-18"
                        mcp("notifications/initialized", {}, notification=True)
                        tools = mcp("tools/list", {})["tools"]
                        assert {tool["name"] for tool in tools} >= {"t3_thread_read", "t3_thread_update"}
                    response(ident, {"added": ["coincide"], "removed": [], "errors": {}})
                    audit("registration-ack")
            elif subtype == "set_permission_mode":
                permission = request["mode"]
                response(ident)
            elif subtype == "set_model":
                assert request["model"] == "fixture-model"
                response(ident)
            else:
                response(ident)
                emit({"type": "result", "session_id": SESSION_ID, "is_error": True, "result": "Interrupted"})
        elif frame["type"] == "user":
            turn += 1
            opening_id = frame["uuid"]
            assert frame["message"]["role"] == "user" and permission in {"default", "bypassPermissions"}
            audit("prompt", turn=turn)
            emit({"type": "system", "subtype": "init", "session_id": SESSION_ID})
            emit(dict(frame, session_id=SESSION_ID))
            if SCENARIO != "workflow":
                finish("MCP_REGISTRATION_DONE")
            else:
                read_thread()
                if turn == 1 and permission == "default":
                    emit({"type": "control_request", "request_id": "rename-approval", "request": {
                        "subtype": "can_use_tool", "tool_name": "mcp__coincide__t3_thread_update", "input": {
                            "action": "rename", "title": SETTINGS["renamedTitle"], "clientRequestId": "synthetic-rename"}}})
                elif turn == 1:
                    rename()
                else:
                    finish("MCP_SECOND_DONE")
        elif frame["type"] == "control_response":
            assert frame["response"]["request_id"] == "rename-approval"
            decision = frame["response"]["response"]
            if decision["behavior"] == "allow":
                assert decision["updatedInput"]["title"] == SETTINGS["renamedTitle"]
                rename()
            else:
                assert decision["behavior"] == "deny"
                audit("declined")
                finish("MCP_DECLINED")
        else:
            raise RuntimeError("The peer received an unexpected frame.")


def rename():
    value = mcp("tools/call", {"name": "t3_thread_update", "arguments": {
        "action": "rename", "title": SETTINGS["renamedTitle"], "clientRequestId": "synthetic-rename"}})
    assert not value.get("isError", False)
    audit("renamed")
    finish("MCP_FIRST_DONE")


try:
    main()
except Exception:
    audit("peer-failed")
    # No traceback, request, URL, exception description or header may escape.
    sys.stderr.write("The synthetic Claude MCP peer refused its private contract.\n")
    sys.stderr.flush()
    sys.exit(78)
