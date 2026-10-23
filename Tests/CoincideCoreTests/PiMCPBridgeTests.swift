import Darwin
import Foundation
import Testing
@testable import CoincideCore

private let piMCPTestScope = UUID(uuidString: "3A04D527-3D55-45AE-88F3-3638B60D419D")!
private let piMCPTestAuthorization = "Bearer synthetic-private-fixture-only"

private func piMCPPrivateRoot() throws -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pi-mcp-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return URL(fileURLWithPath: try PiRuntimeConfiguration.physical(path.path))
}

@Test func piMCPBridgePrivateSidecarKeepsCredentialOutOfSourceAndRemovesOnlyItsOwnedFile() throws {
    let root = try piMCPPrivateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sidecar = try PiMCPBridge.materialize(endpoint: URL(string: "http://127.0.0.1:32145/mcp")!,
        authorizationHeader: piMCPTestAuthorization, scopeID: piMCPTestScope, directory: root)
    let raw = try Data(contentsOf: sidecar.configurationPath)
    let json = try JSONDecoder().decode(JSONValue.self, from: raw)
    #expect(json["authorizationHeader"] == .string(piMCPTestAuthorization))
    #expect(json["scopeID"] == .string(piMCPTestScope.uuidString.lowercased()))
    var info = stat()
    #expect(lstat(sidecar.configurationPath.path, &info) == 0 && info.st_mode & 0o7777 == 0o600 && info.st_nlink == 1)
    let source = try PiMCPBridge.extensionFragment(configurationPath: sidecar.configurationPath.path,
        extensionPath: root.appendingPathComponent("permission.ts").path)
    #expect(!source.contains(piMCPTestAuthorization) && !source.contains("32145"))
    #expect(source.contains("method === \"tools/call\" ? 3660000 : 10000"))
    #expect(!String(describing: sidecar).contains(root.path) && Mirror(reflecting: sidecar).children.isEmpty)
    #expect(throws: PiMCPBridgeError.invalidConfiguration) {
        try PiMCPBridge.materialize(endpoint: URL(string: "http://127.0.0.1:32145/mcp")!,
            authorizationHeader: piMCPTestAuthorization, scopeID: piMCPTestScope, directory: root)
    }
    let other = root.appendingPathComponent("keep.txt")
    try Data("owned sibling must remain".utf8).write(to: other)
    try sidecar.remove(); try sidecar.remove()
    #expect(!FileManager.default.fileExists(atPath: sidecar.configurationPath.path))
    #expect(try String(contentsOf: other, encoding: .utf8) == "owned sibling must remain")
}

@Test(arguments: ["http://example.invalid:1234/mcp", "https://127.0.0.1:1234/mcp", "http://localhost:1234/mcp",
                  "http://127.0.0.1:1234/mcp?token=synthetic", "http://user:secret@127.0.0.1:1234/mcp", "http://127.0.0.1:1234/a/%2E%2E/mcp"])
func piMCPBridgeRejectsForeignCredentialBearingAndAliasedEndpointsWithoutWriting(endpoint: String) throws {
    let root = try piMCPPrivateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: PiMCPBridgeError.invalidConfiguration) {
        try PiMCPBridge.materialize(endpoint: URL(string: endpoint)!, authorizationHeader: piMCPTestAuthorization,
            scopeID: piMCPTestScope, directory: root)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func piMCPBridgePreservesForeignReplacementAndRejectsDirectorySymlinksOrNonprivateRoots() throws {
    let root = try piMCPPrivateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("private")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let sidecar = try PiMCPBridge.materialize(endpoint: URL(string: "http://127.0.0.1:1234/mcp")!,
        authorizationHeader: piMCPTestAuthorization, scopeID: piMCPTestScope, directory: directory)
    let retained = directory.appendingPathComponent("retained.json")
    try FileManager.default.moveItem(at: sidecar.configurationPath, to: retained)
    try Data("foreign replacement".utf8).write(to: sidecar.configurationPath)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.configurationPath.path)
    #expect(throws: PiMCPBridgeError.ownershipLost) { try sidecar.remove() }
    #expect(try String(contentsOf: sidecar.configurationPath, encoding: .utf8) == "foreign replacement")
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
    for target in [alias, root] {
        if target == root { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        #expect(throws: PiMCPBridgeError.invalidConfiguration) {
            try PiMCPBridge.materialize(endpoint: URL(string: "http://127.0.0.1:1234/mcp")!,
                authorizationHeader: piMCPTestAuthorization, scopeID: UUID(), directory: target)
        }
    }
}

@Test func piMCPBridgeComposesOneAwaitedFactoryWithoutReplacingPermissionAndInputHistoryHooks() throws {
    let plain = PiProtocol.permissionExtension(.supervised)
    #expect(plain.contains("pi.on(\"tool_call\"") && !plain.contains("coincideMCP"))
    let source = try PiProtocol.permissionExtension(.supervised, reservationPath: "/private/fixture/input-reservation.json", processEpoch: UUID(),
        mcpConfigurationPath: "/private/fixture/mcp-" + piMCPTestScope.uuidString.lowercased() + ".json",
        mcpExtensionPath: "/private/fixture/permission.ts")
    #expect(source.components(separatedBy: "export default async function(pi)").count == 2)
    #expect(source.contains("const cibPath") && source.contains("coincideMCPReadOnlyTool(event.toolName)"))
    #expect(source.contains("await coincideMCPRequest(\"initialize\"") && source.contains("ctx.ui.confirm"))
    #expect(!source.contains(piMCPTestAuthorization))
}

/// Exercises generated bridge statements over real loopback HTTP. This peer
/// implements only Pi's extension surface; full native Pi/model/Engine proof is
/// a separate opt-in acceptance, not implied by this isolated contract test.
private func piMCPJavaScript(_ mode: String) async throws -> JSONValue {
    let root = try piMCPPrivateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("mcp-" + piMCPTestScope.uuidString.lowercased() + ".json")
    let executable = root.appendingPathComponent("peer.mjs")
    let fragment = try PiMCPBridge.extensionFragment(configurationPath: config.path, extensionPath: executable.path)
    let encode = JSONEncoder()
    let modeLiteral = String(decoding: try encode.encode(mode), as: UTF8.self)
    let scopeLiteral = String(decoding: try encode.encode(piMCPTestScope.uuidString.lowercased()), as: UTF8.self)
    let tokenLiteral = String(decoding: try encode.encode(piMCPTestAuthorization), as: UTF8.self)
    let script = #"""
    import * as coincideMCPFS from "node:fs";
    import * as coincideMCPPath from "node:path";
    import http from "node:http";
    import assert from "node:assert/strict";
    const CoincideMCPType = { Unsafe: (schema) => schema };
    const mode = \#(modeLiteral), scope = \#(scopeLiteral), auth = \#(tokenLiteral);
    const root = process.argv[2], config = coincideMCPPath.join(root, "mcp-" + scope + ".json");
    let calls = 0, lists = 0, redirects = 0, cancelNotifications = 0, authOK = true, protocolOK = true, cancelled = false;
    let entered, closed;
    const toolEntered = new Promise((resolve) => { entered = resolve; });
    const toolClosed = new Promise((resolve) => { closed = resolve; });
    const server = http.createServer(async (request, response) => {
      try {
        if (request.url === "/redirect-target") { redirects++; response.writeHead(500); response.end(); return; }
        assert.equal(request.url, "/mcp"); assert.equal(request.method, "POST");
        authOK &&= request.headers.authorization === auth;
        protocolOK &&= request.headers["mcp-protocol-version"] === "2025-06-18";
        let data = "";
        for await (const chunk of request) { data += chunk; assert.ok(Buffer.byteLength(data) < 1048576); }
        const value = JSON.parse(data);
        assert.equal(value.jsonrpc, "2.0");
        if (value.method !== "initialize") assert.equal(request.headers["mcp-session-id"], "owned-session");
        const send = (result, id = value.id) => {
          const envelope = JSON.stringify({ jsonrpc: "2.0", id, result });
          if (mode === "sse" && value.method === "tools/call") {
            response.writeHead(200, { "content-type": "text/event-stream" });
            const body = ": heartbeat\r\ndata: " + envelope + "\r\n\r\n";
            const bytes = Buffer.from(body);
            for (let index = 0; index < bytes.length; index += 3) response.write(bytes.subarray(index, index + 3));
            response.end();
          } else {
            response.writeHead(200, { "content-type": "application/json", "mcp-session-id": "owned-session" });
            response.end(envelope);
          }
        };
        if (value.method === "initialize") {
          send({ protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "coincide", version: "1" } }, mode === "wrong-id" ? 999 : value.id);
        } else if (value.method === "notifications/initialized") { response.writeHead(202); response.end(); }
        else if (value.method === "notifications/cancelled") {
          cancelNotifications++; assert.equal(typeof value.params.requestId, "number");
          response.writeHead(202); response.end();
        } else if (value.method === "tools/list") {
          lists++;
          if (value.params.cursor === undefined) send({ tools: [{ name: "read_scope", description: "Read synthetic scope",
            inputSchema: { type: "object", properties: { marker: { type: "string" } }, required: ["marker"] },
            annotations: { readOnlyHint: true } }], nextCursor: "second-page" });
          else { assert.equal(value.params.cursor, "second-page"); send({ tools: [{ name: "write_scope", inputSchema: { type: "object" }, annotations: { readOnlyHint: false } }] }); }
        } else if (value.method === "tools/call") {
          calls++; assert.equal(value.params.name, "read_scope"); assert.deepEqual(value.params.arguments, { marker: "native-argument" });
          if (mode === "redirect") { response.writeHead(302, { location: "http://127.0.0.1:" + server.address().port + "/redirect-target" }); response.end(); }
          else if (mode === "failure") { response.writeHead(500, { "content-type": "application/json" }); response.end('{"error":"PRIVATE UPSTREAM CANARY"}'); }
          else if (mode === "cancel") { response.once("close", () => { cancelled = true; closed(); }); entered(); }
          else send({ content: [{ type: "text", text: "Owned MCP response 工作 🌍" }], structuredContent: { marker: "script-value" }, _meta: { ignored: true } });
        } else { response.writeHead(400); response.end(); }
      } catch { response.writeHead(500); response.end(); }
    });
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    const endpoint = "http://127.0.0.1:" + server.address().port + "/mcp";
    const nativeFetch = globalThis.fetch;
    globalThis.fetch = (url, options) => { assert.equal(url, endpoint); return nativeFetch(url, options); };
    coincideMCPFS.writeFileSync(config, JSON.stringify({ version: 1, scopeID: scope, endpoint, authorizationHeader: auth }), { flag: "wx", mode: 0o600 });
    const hooks = new Map(), tools = [], notices = [];
    let sources = [];
    const pi = { on: (name, callback) => { const rows = hooks.get(name) ?? []; rows.push(callback); hooks.set(name, rows); },
      registerTool: (tool) => { tools.push(tool); sources.push({ name: tool.name, sourceInfo: { path: process.argv[1] } }); },
      getAllTools: () => sources };
    const ctx = { ui: { notify: (message, type) => notices.push({ message, type }) } };
    async function install() {
      \#(fragment)
      for (const callback of hooks.get("session_start") ?? []) await callback({}, ctx);
      if (mode === "wrong-id") {
        assert.equal(coincideMCPReady, false); assert.equal(tools.length, 0);
        assert.deepEqual(await hooks.get("input")[0]({}, ctx), { action: "handled" });
        assert.equal(notices[0].message, "coincide-pi-mcp-failed:" + scope);
      } else {
        assert.equal(coincideMCPReady, true); assert.equal(tools.length, 2);
        assert.equal(notices[0].message, "coincide-pi-mcp-ready:" + scope);
        assert.equal(coincideMCPReadOnlyTool("mcp__coincide__read_scope"), true);
        assert.equal(coincideMCPReadOnlyTool("mcp__coincide__write_scope"), false);
        const owned = sources;
        sources = [{ name: "mcp__coincide__read_scope", sourceInfo: { path: config } }];
        assert.equal(coincideMCPReadOnlyTool("mcp__coincide__read_scope"), false);
        sources = [...owned, owned[0]];
        assert.equal(coincideMCPReadOnlyTool("mcp__coincide__read_scope"), false); sources = owned;
        const signal = new AbortController();
        const operation = tools[0].execute("native-call-id", { marker: "native-argument" }, signal.signal);
        if (mode === "cancel") { await toolEntered; signal.abort(); }
        if (["failure", "redirect", "cancel"].includes(mode)) {
          await assert.rejects(operation, (error) => error.message === coincideMCPFailure);
          if (mode === "cancel") await toolClosed;
        } else {
          const result = await operation;
          assert.deepEqual(result.content, [{ type: "text", text: "Owned MCP response 工作 🌍" }]);
          assert.deepEqual(result.details, { server: "coincide", tool: "read_scope" });
          assert.equal(JSON.stringify(result).includes("_meta"), false);
        }
      }
      for (const callback of hooks.get("session_shutdown") ?? []) await callback({}, ctx);
    }
    try {
      await install();
      assert.equal(authOK, true); assert.equal(protocolOK, true); assert.equal(redirects, 0);
      assert.equal(calls, mode === "wrong-id" ? 0 : 1); assert.equal(lists, mode === "wrong-id" ? 0 : 2);
      assert.equal(cancelNotifications, mode === "cancel" ? 1 : 0);
      console.log(JSON.stringify({ calls, lists, redirects, authOK, protocolOK, cancelled, cancelNotifications, ready: mode !== "wrong-id" }));
    } finally { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); }
    """#
    try Data(script.utf8).write(to: executable)
    let node = try #require(ProcessChannel.findExecutable("node"))
    let process = try ProcessChannel(executable: node, arguments: [executable.path, root.path], cwd: root,
        environment: ["HOME": root.path, "TMPDIR": root.path, "PATH": ProcessChannel.environment()["PATH"] ?? "/usr/bin:/bin"])
    let deadline = Task {
        do { try await Task.sleep(for: .seconds(10)); process.stop() } catch { }
    }
    var bytes = Data(), status: Int32?
    do {
        for await event in process.events {
            try Task.checkCancellation()
            switch event {
            case .stdout(let data):
                guard bytes.count + data.count <= 1_048_576 else { throw MCPError(.limitExceeded) }
                bytes.append(data)
            case .stderr: break
            case .exited(let code): status = code
            }
        }
        _ = await process.stopAndDrain(); deadline.cancel(); await deadline.value
    } catch {
        process.stop(); _ = await process.stopAndDrain(); deadline.cancel(); await deadline.value; throw error
    }
    #expect(status == 0)
    guard status == 0, !process.outputOverflowed else { throw CoincideError("The private Pi MCP bridge peer rejected its contract.") }
    return try JSONDecoder().decode(JSONValue.self, from: bytes)
}

@Test(.timeLimit(.minutes(1)), arguments: ["json", "sse", "wrong-id", "failure", "redirect", "cancel"])
func piMCPBridgeGeneratedToolsUseRealAuthenticatedHTTPWithExactCorrelationNoRetryAndOriginBoundReadOnly(mode: String) async throws {
    let result = try await piMCPJavaScript(mode)
    #expect(result["authOK"] == .bool(true) && result["protocolOK"] == .bool(true) && result["redirects"] == .number(0))
    #expect(result["calls"] == .number(mode == "wrong-id" ? 0 : 1))
    #expect(result["ready"] == .bool(mode != "wrong-id"))
    if mode == "cancel" { #expect(result["cancelled"] == .bool(true) && result["cancelNotifications"] == .number(1)) }
}
