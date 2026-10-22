import Darwin
import Foundation
import Testing
@testable import CoincideCore

@Test(.timeLimit(.minutes(1)))
func openCodeHTTPIntegrationOwnsRealLoopbackIdentityCatalogAndIndependentStreamLifetimes() async throws {
    let fixture = try OpenCodeLoopbackFixture()
    do {
        let connection = try await fixture.open()
        let identity = try await connection.metadata.identify()
        #expect(identity.generation == .v2)
        #expect(identity.version == OpenCodeVersion(major: 2, minor: 1, patch: 2))
        #expect(identity.processIdentifier == connection.endpoint.processIdentifier)

        try await openCodeLoopbackEventually { await connection.events.values.count == 1 }
        let inventory = try await connection.metadata.inventory(directory: fixture.workspace)
        #expect(inventory.directory == fixture.workspace.path)
        #expect(inventory.server == identity)
        #expect(inventory.models.map(\.selection) == [.init(providerID: "synthetic", id: "wire-model")])
        #expect(inventory.models.first?.variants == ["balanced", "new-advertised-variant"])
        #expect(inventory.agents.map(\.id) == ["build"])
        #expect(inventory.defaults == [.init(providerID: "synthetic", id: "wire-model")])

        // The peer checks exact argv, fresh credentials and encoded directory at the
        // real HTTP boundary. Its response contains booleans, never header values.
        let probe = try await connection.client.request(path: ["api", "probe"])
        let proof = try JSONDecoder().decode(JSONValue.self, from: probe.body)
        #expect(probe.status == 200)
        #expect(proof["exactArguments"] == .bool(true))
        #expect(proof["freshCredential"] == .bool(true))
        #expect(proof["noInheritedService"] == .bool(true))
        #expect(proof["directoryMatched"] == .bool(true))

        await connection.metadata.close()
        // This event does not exist until after the metadata owner has closed.
        try Data().write(to: fixture.releaseEvent)
        try await openCodeLoopbackEventually { await connection.events.values.count == 2 }
        let events = await connection.events.values
        #expect(events.first?.data == "{\"type\":\"server.connected\"}")
        let frame = try #require(events.last)
        #expect(frame.id == "fixture-frame")
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(frame.data.utf8))
        #expect(payload["delta"] == .string("TCP 工作 🌍"))
        let stillReadable = try await connection.client.request(path: ["api", "info"])
        #expect(stillReadable.status == 200)

        await connection.stream.close()
        try await openCodeLoopbackEventually { await connection.events.finished }
        let afterStreamClose = try await connection.client.request(path: ["api", "info"])
        #expect(afterStreamClose.status == 200)
        let readerFailed = await connection.events.failed
        #expect(!readerFailed)

        // Exercise rejection over TCP as well; no ambient login or provider is used.
        let unauthorizedStatus = try await fixture.unauthorizedStatus(origin: connection.endpoint.origin)
        #expect(unauthorizedStatus == 401)

        await fixture.close()
        let processGone = Darwin.kill(connection.endpoint.processIdentifier, 0) == -1 && errno == ESRCH
        #expect(processGone)
        #expect(FileManager.default.fileExists(atPath: fixture.closedMarker.path))
        try fixture.removeFiles()
    } catch {
        await fixture.close()
        try? fixture.removeFiles()
        throw error
    }
}

private actor OpenCodeLoopbackEvents {
    var values: [OpenCodeSSEEvent] = []
    var finished = false
    var failed = false
    func append(_ event: OpenCodeSSEEvent) { values.append(event) }
    func finish(failed: Bool) { self.failed = failed; finished = true }
}

private struct OpenCodeLoopbackConnection: Sendable {
    let endpoint: OpenCodeOwnedServerEndpoint
    let client: OpenCodeHTTPClient
    let metadata: OpenCodeMetadataConnection
    let stream: OpenCodeSSEConnection
    let events: OpenCodeLoopbackEvents
}

private actor OpenCodeLoopbackFixture {
    nonisolated let root: URL
    nonisolated let workspace: URL
    nonisolated let releaseEvent: URL
    nonisolated let closedMarker: URL
    private let owner: OpenCodeOwnedServer
    private var client: OpenCodeHTTPClient?
    private var anonymous: OpenCodeHTTPClient?
    private var metadata: OpenCodeMetadataConnection?
    private var stream: OpenCodeSSEConnection?
    private var consumer: Task<Void, Never>?

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-opencode-http-\(UUID().uuidString)")
        workspace = root.appendingPathComponent("checkout's 工作 & space", isDirectory: true)
        releaseEvent = root.appendingPathComponent("release-event")
        closedMarker = root.appendingPathComponent("closed-after-eof")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("http-peer")
        try Data(Self.peer.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        owner = OpenCodeOwnedServer(executable: executable, generation: .v2, cwd: workspace, environment: [
            "PATH": "/usr/bin:/bin", "PYTHONUTF8": "1",
            "COINCIDE_HTTP_FIXTURE_ROOT": root.path,
            "COINCIDE_HTTP_FIXTURE_DIRECTORY": workspace.path,
            "OPENCODE_PASSWORD": "inherited-synthetic-fixture-value",
            "OPENCODE_SERVER_PASSWORD": "inherited-legacy-fixture-value",
            "OPENCODE_SERVER_URL": "http://127.0.0.1:1"
        ])
    }

    func open() async throws -> OpenCodeLoopbackConnection {
        let endpoint = try await owner.start()
        let client = try OpenCodeHTTPClient(origin: endpoint.origin, credential: endpoint.credential)
        self.client = client
        let metadata = OpenCodeMetadataConnection(client: client, expectedGeneration: .v2,
                                                  ownedProcessIdentifier: endpoint.processIdentifier)
        self.metadata = metadata
        let stream = try await OpenCodeSSEConnection.open(client: client, generation: .v2, directory: workspace)
        self.stream = stream
        let events = OpenCodeLoopbackEvents()
        consumer = Task {
            do {
                for try await event in stream.events { await events.append(event) }
                await events.finish(failed: false)
            } catch { await events.finish(failed: true) }
        }
        return .init(endpoint: endpoint, client: client, metadata: metadata, stream: stream, events: events)
    }

    func unauthorizedStatus(origin: URL) async throws -> Int {
        let anonymous = try OpenCodeHTTPClient(origin: origin)
        self.anonymous = anonymous
        let response = try await anonymous.request(path: ["api", "info"])
        await anonymous.close()
        self.anonymous = nil
        return response.status
    }

    func close() async {
        await stream?.close()
        await metadata?.close()
        await anonymous?.close()
        await client?.close()
        await owner.close()
        await consumer?.value
    }

    nonisolated func removeFiles() throws { try FileManager.default.removeItem(at: root) }

    private static let peer = #"""
#!/usr/bin/python3 -S
import base64, http.server, json, os, pathlib, sys, threading, time, urllib.parse

root = pathlib.Path(os.environ["COINCIDE_HTTP_FIXTURE_ROOT"])
directory = os.environ["COINCIDE_HTTP_FIXTURE_DIRECTORY"]
password = os.environ.get("OPENCODE_PASSWORD", "")
expected_auth = "Basic " + base64.b64encode(("opencode:" + password).encode()).decode()
exact_arguments = sys.argv[1:] == ["serve", "--stdio", "--hostname", "127.0.0.1", "--port", "0"]
fresh_credential = bool(password) and password != "inherited-synthetic-fixture-value"
no_inherited_service = not any(os.environ.get(key) for key in ["OPENCODE_SERVER_URL", "OPENCODE_SERVER_PASSWORD", "OPENCODE_URL", "OPENCODE_PTY_HANDOFF"])
stop = threading.Event()
directory_matched = threading.Event()
model = {"id":"wire-model", "modelID":"different-backend-id", "providerID":"synthetic", "name":"Synthetic 🌍", "enabled":True,
         "variants":[{"id":"balanced"},{"id":"new-advertised-variant"}], "capabilities":{"tools":True,"input":["text","image"],"output":["text"]}}

class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def handle_error(self, request, client_address):
        pass

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args):
        pass
    def reply(self, status, value):
        data = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()
    def do_GET(self):
        if self.headers.get("Authorization") != expected_auth:
            self.reply(401, {"error":"unauthorized"})
            return
        url = urllib.parse.urlsplit(self.path)
        if url.path == "/api/info" and not url.query:
            self.reply(200, {"version":"2.1.2", "pid":os.getpid()})
        elif url.path == "/api/probe" and not url.query:
            self.reply(200, {"exactArguments":exact_arguments,"freshCredential":fresh_credential,
                             "noInheritedService":no_inherited_service,"directoryMatched":directory_matched.is_set()})
        elif url.path in ["/api/model", "/api/agent", "/api/model/default"]:
            query = urllib.parse.parse_qs(url.query, strict_parsing=True)
            if query != {"location[directory]":[directory]}:
                self.reply(400, {"error":"invalid directory"})
                return
            directory_matched.set()
            data = [model] if url.path == "/api/model" else model
            if url.path == "/api/agent":
                data = [{"id":"build","name":"Build","mode":"primary","hidden":False}]
            self.reply(200, {"location":{"directory":directory},"data":data})
        elif url.path == "/api/event" and not url.query:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            try:
                self.wfile.write(b'data: {"type":"server.connected"}\r\n\r\n')
                self.wfile.flush()
                emitted = False
                while not stop.wait(0.03):
                    if not emitted and (root / "release-event").exists():
                        payload = json.dumps({"delta":"TCP 工作 🌍"}, ensure_ascii=False, separators=(",", ":"))
                        frame = ("id: fixture-frame\r\ndata: " + payload + "\r\n\r\n").encode("utf-8")
                        for offset in range(0, len(frame), 3):
                            self.wfile.write(frame[offset:offset + 3])
                            self.wfile.flush()
                            time.sleep(0.001)
                        emitted = True
                    self.wfile.write(b": heartbeat\n\n")
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self.reply(404, {"error":"not found"})

server = Server(("127.0.0.1", 0), Handler)
worker = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.02), daemon=True)
worker.start()
print(json.dumps({"url":"http://127.0.0.1:" + str(server.server_port)}), flush=True)
sys.stdin.buffer.read()
stop.set()
server.shutdown()
server.server_close()
worker.join(timeout=2)
(root / "closed-after-eof").write_text("closed", encoding="utf-8")
"""#
}

private func openCodeLoopbackEventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private HTTP fixture did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
