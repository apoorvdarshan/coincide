import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct OpenCodeOwnerFixture: Sendable {
    let root: URL
    let server: OpenCodeOwnedServer
    var log: URL { root.appendingPathComponent("observations.jsonl") }
    var gate: URL { root.appendingPathComponent("ready.gate") }
    var floodGate: URL { root.appendingPathComponent("flood.gate") }
    var exitReason: URL { root.appendingPathComponent("exit.reason") }
    func observations() throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        let bytes = try Data(contentsOf: log)
        guard let newline = bytes.lastIndex(of: 10) else { return [] }
        return try bytes[...newline].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func release() throws { try Data().write(to: gate) }
    func pid() throws -> Int32? {
        guard let observation = try observations().first, case .number(let pid) = observation["pid"] else { return nil }
        return Int32(exactly: pid)
    }
}

private func withOpenCodeOwner(_ mode: String = "ready", generation: OpenCodeGeneration = .v2,
                               readiness: String? = nil, startupTimeout: Duration = .seconds(10),
                               body: (OpenCodeOwnerFixture) async throws -> Void) async throws {
    let root = try temporaryWorkspace()
    let script = root.appendingPathComponent("owned-server-peer")
    do {
        try Data(openCodeOwnedServerPeer.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var environment = [
            "PATH": "/usr/bin:/bin", "PYTHONUTF8": "1", "COINCIDE_OWNED_SERVER_MODE": mode,
            "COINCIDE_OWNED_SERVER_ROOT": root.path,
            "OPENCODE_PASSWORD": "synthetic-inherited-current-password",
            "OPENCODE_SERVER_PASSWORD": "synthetic-inherited-legacy-password",
            "OPENCODE_SERVER_USERNAME": "synthetic-other-user",
            "OPENCODE_SERVER_URL": "http://example.invalid/existing-service",
            "OPENCODE_URL": "http://example.invalid/another-existing-service",
            "OPENCODE_PTY_HANDOFF": "synthetic-unrelated-pty",
            "COINCIDE_KEEP_LITERAL": "an unrelated environment value"
        ]
        if let readiness { environment["COINCIDE_OWNED_SERVER_READINESS"] = readiness }
        let server = OpenCodeOwnedServer(executable: script, generation: generation, cwd: root,
                                         environment: environment, startupTimeout: startupTimeout)
        let fixture = OpenCodeOwnerFixture(root: root, server: server)
        do { try await body(fixture) }
        catch { await server.close(); throw error }
        await server.close()
        if let pid = try fixture.pid() { #expect(openCodeOwnerProcessGone(pid)) }
        try FileManager.default.removeItem(at: root)
    } catch {
        // Every launched peer is closed by the inner catch before its files go.
        try? FileManager.default.removeItem(at: root)
        throw error
    }
}

private func openCodeOwnerEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The owned OpenCode fixture did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func openCodeOwnerProcessGone(_ pid: Int32) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }
private actor OpenCodeOwnerFlag {
    var value = false
    func finish() { value = true }
}

@Test(.timeLimit(.minutes(1)), arguments: [OpenCodeGeneration.v1, .v2])
func openCodeOwnedServerUsesLiteralGenerationSpecificInvocationAndEphemeralCredentials(_ generation: OpenCodeGeneration) async throws {
    try await withOpenCodeOwner(generation: generation) { fixture in
        async let first = fixture.server.start()
        async let second = fixture.server.start()
        let endpoints = try await (first, second)
        let observations = try fixture.observations()
        let observation = try #require(observations.first)
        let arguments = observation["arguments"].array?.compactMap(\.string)
        let expected = ["serve"] + (generation == .v2 ? ["--stdio"] : []) + ["--hostname", "127.0.0.1", "--port", "0"]
        #expect(arguments == expected)
        #expect(observations.count == 1)
        #expect(observation["pid"] == .number(Double(endpoints.0.processIdentifier)))
        #expect(endpoints.0.processIdentifier == endpoints.1.processIdentifier)
        #expect(endpoints.0.origin.absoluteString == "http://127.0.0.1:41873")
        let observedCwd = try #require(observation["cwd"].string)
        #expect(WorkspaceProject(path: observedCwd).path == WorkspaceProject(path: fixture.root.path).path)
        #expect(observation["username"].string == "opencode")
        #expect(observation["legacyPasswordPresent"] == .bool(generation == .v1))
        #expect(observation["currentPasswordPresent"] == .bool(generation == .v2))
        #expect(observation["inheritedURLPresent"] == .bool(false))
        #expect(observation["handoffPresent"] == .bool(false))
        #expect(observation["keptLiteral"].string == "an unrelated environment value")
        let encoded = String(endpoints.0.credential.authorizationHeader.dropFirst("Basic ".count))
        guard let decoded = Data(base64Encoded: encoded), let plaintext = String(data: decoded, encoding: .utf8),
              let split = plaintext.firstIndex(of: ":") else {
            throw CoincideError("The synthetic owned credential could not be decoded.")
        }
        let password = String(plaintext[plaintext.index(after: split)...])
        let digest = SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
        // Only booleans enter assertions; generated credentials must never be
        // printed by Swift Testing when a synthetic check fails.
        let credentialMatches = observation["passwordDigest"].string == digest
        let credentialIsFresh = password != "synthetic-inherited-current-password" && password != "synthetic-inherited-legacy-password" && password.count >= 40
        let descriptionsAreRedacted = !String(describing: endpoints.0).contains(password) && !String(reflecting: endpoints.0.credential).contains(password)
        #expect(credentialMatches)
        #expect(credentialIsFresh)
        #expect(descriptionsAreRedacted)
        await fixture.server.close()
        await fixture.server.close()
        let reason = try String(contentsOf: fixture.exitReason, encoding: .utf8)
        #expect(reason == (generation == .v2 ? "eof" : "term"))
    }
}

@Test(.timeLimit(.minutes(1)))
func openCodeOwnedServerCancellationDetachesOnlyItsWaiterFromOneSharedLaunch() async throws {
    try await withOpenCodeOwner("held") { fixture in
        let finished = OpenCodeOwnerFlag()
        let first = Task {
            do { let value = try await fixture.server.start(); await finished.finish(); return value }
            catch { await finished.finish(); throw error }
        }
        let second = Task { try await fixture.server.start() }
        try await openCodeOwnerEventually { await fixture.server.pendingStartCount == 2 }
        try await openCodeOwnerEventually { try fixture.pid() != nil }
        first.cancel()
        try await openCodeOwnerEventually { await finished.value }
        do { _ = try await first.value; Issue.record("A cancelled startup waiter succeeded.") }
        catch is CancellationError { /* The surviving caller still owns startup. */ }
        #expect(await fixture.server.pendingStartCount == 1)
        let pid = try #require(try fixture.pid())
        #expect(!openCodeOwnerProcessGone(pid))
        try fixture.release()
        let endpoint = try await second.value
        let observations = try fixture.observations()
        #expect(endpoint.processIdentifier == pid)
        #expect(observations.count == 1)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func openCodeOwnedServerLastWaiterCancellationOrExplicitCloseDrainsUnreadyChild(_ explicitClose: Bool) async throws {
    try await withOpenCodeOwner("held") { fixture in
        let start = Task { try await fixture.server.start() }
        try await openCodeOwnerEventually {
            let pid = try fixture.pid()
            let count = await fixture.server.pendingStartCount
            return pid != nil && count == 1
        }
        let pid = try #require(try fixture.pid())
        if explicitClose {
            async let first: Void = fixture.server.close()
            async let second: Void = fixture.server.close()
            _ = await (first, second)
        } else { start.cancel() }
        do { _ = try await start.value; Issue.record("A closed startup succeeded.") }
        catch is CancellationError { #expect(!explicitClose) }
        catch let error as OpenCodeOwnedServerError { #expect(explicitClose && error == .closed) }
        #expect(openCodeOwnerProcessGone(pid))
        do { _ = try await fixture.server.start(); Issue.record("A closed owner relaunched itself.") }
        catch let error as OpenCodeOwnedServerError { #expect(error == .closed) }
        let observations = try fixture.observations()
        #expect(observations.count == 1)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["early-exit", "held"])
func openCodeOwnedServerEarlyExitAndStartupDeadlineFailWithoutLeakingOutputOrChild(_ mode: String) async throws {
    try await withOpenCodeOwner(mode, startupTimeout: .seconds(1)) { fixture in
        do { _ = try await fixture.server.start(); Issue.record("An unready server was accepted.") }
        catch let error as OpenCodeOwnedServerError {
            #expect(error == (mode == "early-exit" ? .exited : .startupTimedOut))
            let messageIsFixed = !error.localizedDescription.contains("fixture-private-output")
            #expect(messageIsFixed)
        }
        if let pid = try fixture.pid() { #expect(openCodeOwnerProcessGone(pid)) }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [
    "http://0.0.0.0:41873", "http://localhost:41873", "http://[::1]:41873", "https://127.0.0.1:41873",
    "http://user:pass@127.0.0.1:41873", "http://127.0.0.1:41873?password=synthetic",
    "http://127.0.0.1:41873#fragment", "http://127.0.0.1:41873/other", "http://127.0.0.1:41873/%2F",
    "http://127.0.0.1:0", "http://127.0.0.1:65536"
])
func openCodeOwnedServerNeverAcceptsUnownedOrCredentialBearingPrintedEndpoints(_ readiness: String) async throws {
    try await withOpenCodeOwner(readiness: readiness) { fixture in
        do { _ = try await fixture.server.start(); Issue.record("An unsafe printed endpoint was accepted.") }
        catch let error as OpenCodeOwnedServerError { #expect(error == .invalidReadiness) }
        let pid = try #require(try fixture.pid())
        #expect(openCodeOwnerProcessGone(pid))
    }
}

@Test(.timeLimit(.minutes(1)))
func openCodeOwnedServerBoundsStartupOutputAndDrainsTheOwnedChild() async throws {
    try await withOpenCodeOwner("flood-before") { fixture in
        do { _ = try await fixture.server.start(); Issue.record("An overflowing startup was accepted.") }
        catch let error as OpenCodeOwnedServerError { #expect(error == .outputLimit) }
        if let pid = try fixture.pid() { #expect(openCodeOwnerProcessGone(pid)) }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["drain-stdout", "drain-stderr"])
func openCodeOwnedServerDrainsLargePostReadyLogsWithoutALifetimeOutputCap(_ mode: String) async throws {
    try await withOpenCodeOwner(mode) { fixture in
        let endpoint = try await fixture.server.start()
        try Data().write(to: fixture.floodGate)
        try await openCodeOwnerEventually {
            FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("drain.finished").path)
        }
        let repeated = try await fixture.server.start()
        #expect(repeated.processIdentifier == endpoint.processIdentifier)
        #expect(!openCodeOwnerProcessGone(endpoint.processIdentifier))
        let observations = try fixture.observations()
        #expect(observations.count == 1)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["invalid-json", "oversized-line"])
func openCodeOwnedServerRejectsMalformedOrUnboundedStartupLines(_ mode: String) async throws {
    try await withOpenCodeOwner(mode) { fixture in
        do { _ = try await fixture.server.start(); Issue.record("Malformed startup output was accepted.") }
        catch let error as OpenCodeOwnedServerError { #expect(error == .invalidReadiness || error == .outputLimit) }
        if let pid = try fixture.pid() { #expect(openCodeOwnerProcessGone(pid)) }
    }
}

private let openCodeOwnedServerPeer = #"""
#!/usr/bin/python3 -S
import hashlib, json, os, select, signal, sys, time

root = os.environ["COINCIDE_OWNED_SERVER_ROOT"]
mode = os.environ["COINCIDE_OWNED_SERVER_MODE"]
v2 = "--stdio" in sys.argv[1:]
password = os.environ.get("OPENCODE_PASSWORD" if v2 else "OPENCODE_SERVER_PASSWORD", "")
observation = {
    "pid": os.getpid(), "arguments": sys.argv[1:], "cwd": os.getcwd(),
    "username": os.environ.get("OPENCODE_SERVER_USERNAME"),
    "passwordDigest": hashlib.sha256(password.encode()).hexdigest(),
    "legacyPasswordPresent": "OPENCODE_SERVER_PASSWORD" in os.environ,
    "currentPasswordPresent": "OPENCODE_PASSWORD" in os.environ,
    "inheritedURLPresent": any(key in os.environ for key in ["OPENCODE_SERVER_URL", "OPENCODE_URL"]),
    "handoffPresent": "OPENCODE_PTY_HANDOFF" in os.environ,
    "keptLiteral": os.environ.get("COINCIDE_KEEP_LITERAL")
}
fd = os.open(os.path.join(root, "observations.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
os.write(fd, (json.dumps(observation) + "\n").encode()); os.close(fd)

def finish(reason):
    fd = os.open(os.path.join(root, "exit.reason"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, reason.encode()); os.close(fd)
    sys.exit(0)

signal.signal(signal.SIGTERM, lambda *_: finish("term"))

def eof_wait(timeout):
    if v2 and select.select([sys.stdin], [], [], timeout)[0]:
        if not os.read(0, 4096): finish("eof")
    elif not v2:
        time.sleep(timeout)

def flood(fd):
    payload = b"bounded synthetic log line\n" * 2048
    while True: os.write(fd, payload)

if mode == "early-exit":
    os.write(2, b"fixture-private-output must not reach errors\n")
    sys.exit(7)
if mode == "held":
    while not os.path.exists(os.path.join(root, "ready.gate")): eof_wait(0.01)
if mode == "flood-before": flood(1)
if mode == "invalid-json":
    os.write(1, b'{"url": invalid-json}\n')
elif mode == "oversized-line":
    os.write(1, b"x" * 200000)
else:
    # Split a multibyte log character and the actual readiness frame across writes.
    preamble = "synthetic 工作 log\n".encode()
    os.write(1, preamble[:11]); os.write(1, preamble[11:12]); os.write(1, preamble[12:])
    url = os.environ.get("COINCIDE_OWNED_SERVER_READINESS", "http://127.0.0.1:41873")
    line = ((json.dumps({"url": url}) if v2 else "opencode server listening on " + url) + "\n").encode()
    os.write(1, line[:8]); os.write(1, line[8:17]); os.write(1, line[17:])
if mode in ["drain-stdout", "drain-stderr"]:
    while not os.path.exists(os.path.join(root, "flood.gate")): eof_wait(0.01)
    destination = 1 if mode == "drain-stdout" else 2
    # More than 1 MiB total is healthy after readiness; pace it below the bounded
    # transport queue so this tests retention rather than a stalled consumer.
    payload = b"bounded synthetic log line\n" * 512
    for _ in range(100):
        os.write(destination, payload)
        time.sleep(0.002)
    os.write(destination, b'{"url": invalid-post-ready-log}\n')
    fd = os.open(os.path.join(root, "drain.finished"), os.O_WRONLY | os.O_CREAT, 0o600)
    os.close(fd)
while True: eof_wait(0.05)
"""#
