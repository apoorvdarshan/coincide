"""Opt-in extension of the synthetic native HTTP peers. No vendor or model.

Only synthetic semantic evidence is written. The real ephemeral app bearer
arrives by native HTTP registration and remains exclusively in process memory.
"""
import copy
import http.client
import json
import pathlib
import time
import urllib.parse


class AppMCPFixture:
    def __init__(self, root, directory, generation, record, stopped):
        self.options = json.loads((root / "fixture-app-mcp.json").read_text(encoding="utf-8"))
        self.root, self.directory, self.generation = root, directory, generation
        self.record, self.stopped = record, stopped
        self.remote, self.next_id, self.registrations = None, 0, 0
        self.foreign = {"t3-code": {"status": "connected"}, "user-server": {"status": "disabled"}}
        self.servers = copy.deepcopy(self.foreign)
        self.mode = self.options.get("mode", "normal")
        if self.mode == "collision":
            self.servers["CoInCiDe"] = {"status": "connected"}
        elif self.mode == "prefix-collision":
            self.servers["coincide_extra"] = {"status": "connected"}

    def result(self):
        if self.generation == 1:
            return self.servers
        return {"location": {"directory": self.directory},
                "data": [{"name": name, "status": status} for name, status in self.servers.items()]}

    def rpc(self, method, params, notification=False):
        url = urllib.parse.urlsplit(self.remote["url"])
        if url.scheme != "http" or url.hostname != "127.0.0.1" or not url.port or url.path != "/mcp" or url.query:
            raise ValueError("Invalid synthetic app endpoint")
        self.next_id += 1
        body = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notification:
            body["id"] = self.next_id
        connection = http.client.HTTPConnection("127.0.0.1", url.port, timeout=4)
        try:
            connection.request("POST", "/mcp", json.dumps(body).encode(), {
                "Authorization": self.remote["headers"]["Authorization"], "MCP-Protocol-Version": "2025-06-18",
                "Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
            response = connection.getresponse()
            data = response.read(1048577)
            if len(data) > 1048576 or response.status != (202 if notification else 200):
                raise ValueError("Synthetic app RPC refused")
            if notification:
                if data:
                    raise ValueError("Unexpected notification body")
                return None
            result = json.loads(data)
            if result.get("id") != self.next_id or "error" in result:
                raise ValueError("Unexpected app RPC response")
            return result["result"]
        finally:
            connection.close()

    def route(self, handler, url, body=None):
        prefix = "/mcp" if self.generation == 1 else "/api/experimental/mcp/coincide"
        listing = "/mcp" if self.generation == 1 else "/api/mcp"
        if url.path not in [prefix, listing, "/mcp/coincide/disconnect"]:
            return False
        expected_query = {"directory" if self.generation == 1 else "location[directory]": [self.directory]}
        if urllib.parse.parse_qs(url.query) != expected_query:
            handler.reply(400, {"error": "incorrect synthetic location"})
            return True
        if handler.command == "GET" and url.path == listing:
            self.record("mcp-status", owned="coincide" in self.servers)
            handler.reply(200, self.result())
            return True
        if handler.command in ["POST", "PUT"] and url.path == prefix:
            self.record("mcp-registration", generation=self.generation,
                        exactShape=(set(body) == ({"name", "config"} if self.generation == 1 else {"config"})),
                        foreignPreserved=all(self.servers.get(k) == v for k, v in self.foreign.items()))
            if self.mode == "held":
                (self.root / "registration-entered").touch(mode=0o600)
                while not self.stopped.wait(0.01) and not (self.root / "release-registration").exists():
                    pass
            config = body["config"]
            if config.get("type") != "remote" or config.get("oauth") is not False or set(config.get("headers", {})) != {"Authorization"}:
                handler.reply(400, {"error": "invalid remote config"})
                return True
            timeout = 660000 if self.generation == 1 else {"startup": 10000, "catalog": 10000, "execution": 660000}
            if config.get("timeout") != timeout:
                handler.reply(400, {"error": "app tool execution timeout is not reachable"})
                return True
            if self.generation == 1 and body.get("name") != "coincide":
                handler.reply(400, {"error": "invalid server name"})
                return True
            self.remote = config
            self.registrations += 1
            if self.mode == "rejected":
                handler.reply(400, {"error": config["headers"]["Authorization"]})
                return True
            if self.mode != "failed":
                self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                    "clientInfo": {"name": "Synthetic OpenCode", "version": "1"}})
                self.rpc("notifications/initialized", {}, notification=True)
                catalog = self.rpc("tools/list", {})
                self.record("mcp-catalog", readAdvertised=any(t["name"] == "t3_thread_read" for t in catalog["tools"]))
            self.servers["coincide"] = {"status": "failed" if self.mode == "failed" else "connected"}
            if self.generation == 1:
                handler.reply(200, self.result())
            else:
                handler.reply(204)
            return True
        if (handler.command == "DELETE" and self.generation == 2) or (handler.command == "POST" and url.path.endswith("/disconnect")):
            self.servers.pop("coincide", None)
            self.record("mcp-remove", foreignPreserved=self.servers == self.foreign)
            handler.reply(200, True) if self.generation == 1 else handler.reply(204)
            return True
        handler.reply(404, {"error": "unsupported synthetic MCP route"})
        return True

    def invoke(self, number):
        if not self.remote or self.servers.get("coincide", {}).get("status") != "connected":
            raise ValueError("Prompt raced MCP registration")
        read = self.rpc("tools/call", {"name": "t3_thread_read", "arguments": {
            "threadId": self.options["appThreadID"], "limit": 5, "maxCharsPerItem": 50}})
        rename = self.rpc("tools/call", {"name": "t3_thread_update", "arguments": {
            "action": "rename", "title": self.options["renamedTitle"], "clientRequestId": "opencode-fixture-rename-" + str(number)}})
        self.record("mcp-invocation", readSucceeded=not read.get("isError"), renameSucceeded=not rename.get("isError"))
        if read.get("isError") or rename.get("isError"):
            raise ValueError("Synthetic app operation failed")
        # Exercise both header and bare-token echoes, including split SSE writes.
        secret = self.remote["headers"]["Authorization"]
        return "APP_MCP_READY " + secret + " " + secret.removeprefix("Bearer ")
