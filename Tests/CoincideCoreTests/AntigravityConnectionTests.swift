import Darwin
import Foundation
import Testing
@testable import CoincideCore

private actor AntigravityWireRecord {
    var order: [String] = []
    var failures: [AntigravityWireError] = []
    var requests: [JSONValue] = []
    var authorizations: [AntigravityAuthorizationURL] = []
    var closed: AntigravityWireError?
    var didClose = false
    var heldBarrier = false
    func holdBarrier() { heldBarrier = true }
    func receive(_ event: AntigravityWireEvent, connection: AntigravityConnection) async throws {
        switch event {
        case .notification(let method, let params):
            order.append(method)
            if method == "session/update" { #expect(params["update"]["content"]["text"] == .string("工作🌍")) }
        case .serverRequest(let id, _, _): requests.append(id); try await connection.respond(id: id, result: .object(["content": .string("synthetic")]))
        case .authorizationURL(let value): authorizations.append(value)
        case .callback(let callback): await callback()
        case .closed(let error): didClose = true; closed = error
        }
    }
    func callback(_ result: Result<JSONValue, AntigravityWireError>, label: String = "callback") {
        order.append(label); if case .failure(let error) = result { failures.append(error) }
    }
}

@Test func antigravityConnectionUsesRecordedFlatNativeInitializeAndExactDirectionalIDs() async throws {
    let fixture = try AntigravityWireFixture(mode: "requests"), runtime = try fixture.runtime(), record = AntigravityWireRecord()
    let connection = try AntigravityConnection(runtime: runtime)
    let reader = Task { for await event in connection.events { try await record.receive(event, connection: connection) } }
    do {
        let value = try await connection.initialize(clientCapabilities: .object(["fs": .object(["readTextFile": .bool(true), "writeTextFile": .bool(true)]), "terminal": .bool(false)]))
        #expect(value["agentInfo"]["version"] == .string("agy_acp_server_1.1.1"))
        #expect(value["agentCapabilities"]["sessionCapabilities"]["resume"].object != nil)
        _ = try await connection.request("session/new", params: .object(["cwd": .string(fixture.cwd.path), "mcpServers": .array([])]))
        try await antigravityEventually { fixture.proof(runtime.processIdentifier)["acks"].array?.count == 2 }
        let ids = await record.requests
        #expect(ids == [.number(1), .string("1")])
        await connection.close(); try await reader.value
    } catch { await connection.close(); _ = try? await reader.value; fixture.cleanup(); throw error }
    fixture.cleanup()
}

@Test(arguments: ["stdout-auth", "stderr-auth"])
func antigravityConnectionCapturesOnlyExplicitOwnedAuthorizationWithoutOpeningBrowser(_ mode: String) async throws {
    let fixture = try AntigravityWireFixture(mode: mode), runtime = try fixture.runtime(), record = AntigravityWireRecord()
    let connection = try AntigravityConnection(runtime: runtime, allowAuthorizationURLs: true)
    let reader = Task { for await event in connection.events { try await record.receive(event, connection: connection) } }
    do {
        _ = try await connection.initialize(); _ = try await connection.request("authenticate", params: .object(["methodId": .string("oauth-personal")]))
        try await connection.flushEvents()
        let values = await record.authorizations
        #expect(values.count == 1 && values[0].redirectURI.absoluteString == "http://127.0.0.1:48123/")
        #expect(values[0].state == "synthetic-private-state")
        #expect(!String(describing: values[0]).contains("synthetic-private-state"))
        await connection.close(); try await reader.value
    } catch { await connection.close(); _ = try? await reader.value; fixture.cleanup(); throw error }
    fixture.cleanup()
}

@Test func antigravityConnectionMetadataRefusesInteractiveAuthAndRemoteErrorsNeverExposePrivateBodies() async throws {
    for mode in ["stdout-auth", "remote"] {
        let fixture = try AntigravityWireFixture(mode: mode), runtime = try fixture.runtime()
        let connection = try AntigravityConnection(runtime: runtime)
        do {
            _ = try await connection.initialize()
            do { _ = try await connection.request("authenticate", params: .object(["methodId": .string("oauth-personal")])); Issue.record("Unexpected auth acceptance") }
            catch let error as AntigravityWireError {
                #expect(error.kind == (mode == "remote" ? .remoteFailure : .signInRequired))
                #expect(!String(describing: error).contains("synthetic-private") && !error.localizedDescription.contains("accounts.google.com"))
                if mode == "remote" { #expect(error.code == -32000) }
            }
        } catch { await connection.close(); fixture.cleanup(); throw error }
        await connection.close(); fixture.cleanup()
    }
}

@Test(arguments: ["nested", "malformed", "partial", "string-id", "invalid-auth", "oversize"])
func antigravityConnectionMalformedWireCannotBeSilentlyFilteredOrMisCorrelated(_ mode: String) async throws {
    let fixture = try AntigravityWireFixture(mode: mode), runtime = try fixture.runtime()
    let connection = try AntigravityConnection(runtime: runtime, allowAuthorizationURLs: true)
    do {
        do {
            _ = try await connection.initialize()
            if mode == "invalid-auth" { _ = try await connection.request("authenticate") }
            else { _ = try await connection.request("session/new") }
            Issue.record("Malformed native wire was accepted")
        } catch let error as AntigravityWireError { #expect(error.kind == (mode == "oversize" ? .overflow : .protocolViolation)) }
    }
    await connection.close(); fixture.cleanup()
}

@Test func antigravityConnectionSplitUnicodeAndLargeUntrustedStderrRemainSeparate() async throws {
    for mode in ["split", "stderr-noise"] {
        let fixture = try AntigravityWireFixture(mode: mode), runtime = try fixture.runtime(), record = AntigravityWireRecord()
        let connection = try AntigravityConnection(runtime: runtime)
        let reader = Task { for await event in connection.events { try await record.receive(event, connection: connection) } }
        do {
            _ = try await connection.initialize()
            _ = try await connection.request("session/new")
            _ = try await connection.request("session/prompt", params: .object(["sessionId": .string("synthetic-session"), "prompt": .array([])]), onResponse: { await record.callback($0) })
            try await connection.flushEvents()
            let ordered = await record.order
            #expect(ordered == ["session/update", "callback"])
            await connection.close(); try await reader.value
        } catch { await connection.close(); _ = try? await reader.value; fixture.cleanup(); throw error }
        fixture.cleanup()
    }
}

@Test func antigravityConnectionPausedConsumerPreservesNativeBeforeCancellationAndLateReply() async throws {
    let fixture = try AntigravityWireFixture(mode: "held"), runtime = try fixture.runtime(), record = AntigravityWireRecord()
    let connection = try AntigravityConnection(runtime: runtime)
    var reader: Task<Void, any Error>?, prompt: Task<JSONValue, any Error>?
    do {
        _ = try await connection.initialize()
        let pending = Task { try await connection.request("session/prompt", onResponse: { await record.callback($0) }) }; prompt = pending
        // Same-pipe response barrier proves the earlier native notification was decoded.
        try await antigravityEventually { fixture.proof(runtime.processIdentifier)["prompts"] == .number(1) }
        _ = try await connection.request("session/new")
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Cancelled native prompt accepted") }
        catch let error as AntigravityWireError { #expect(error.kind == .cancelled) }
        reader = Task { for await event in connection.events { try await record.receive(event, connection: connection) } }
        try await antigravityEventually { await record.failures.count == 1 }
        let failures = await record.failures
        #expect(failures.map(\.kind) == [.cancelled])
        _ = try await connection.request("session/list")
        try await connection.flushEvents()
        let finalOrder = await record.order
        #expect(finalOrder == ["session/update", "callback"])
        await connection.close(); try await reader?.value
    } catch { prompt?.cancel(); await connection.close(); _ = try? await prompt?.value; _ = try? await reader?.value; fixture.cleanup(); throw error }
    fixture.cleanup()
}

@Test func antigravityConnectionLocalAndPreCancelledFailuresAreOrderedOnceWithoutWriting() async throws {
    let fixture = try AntigravityWireFixture(), runtime = try fixture.runtime(), record = AntigravityWireRecord()
    let connection = try AntigravityConnection(runtime: runtime)
    var reader: Task<Void, any Error>?
    do {
        _ = try await connection.initialize()
        do { _ = try await connection.request("initialize", onResponse: { await record.callback($0, label: "reserved") }); Issue.record("Reserved method accepted") }
        catch let error as AntigravityWireError { #expect(error.kind == .invalidRequest) }
        do { _ = try await connection.request("session/new", params: .array([]), onResponse: { await record.callback($0, label: "params") }); Issue.record("Invalid parameters accepted") }
        catch let error as AntigravityWireError { #expect(error.kind == .invalidRequest) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await connection.request("session/new", onResponse: { await record.callback($0, label: "cancelled") })
        }
        do { _ = try await cancelled.value; Issue.record("Pre-cancelled query accepted") }
        catch let error as AntigravityWireError { #expect(error.kind == .cancelled) }
        #expect(fixture.proof(runtime.processIdentifier)["queries"] == .number(0))
        let before = await record.order; #expect(before.isEmpty)
        reader = Task { for await event in connection.events { try await record.receive(event, connection: connection) } }
        try await connection.flushEvents()
        let ordered = await record.order, failures = await record.failures
        #expect(ordered == ["reserved", "params", "cancelled"] && failures.count == 3)
        _ = try await connection.request("session/new")
        await connection.close(); try await reader?.value
    } catch { await connection.close(); _ = try? await reader?.value; fixture.cleanup(); throw error }
    fixture.cleanup()
}

@Test func antigravityConnectionPreCancelledNotificationNeverSendsSessionCancel() async throws {
    let fixture = try AntigravityWireFixture(), runtime = try fixture.runtime()
    let connection = try AntigravityConnection(runtime: runtime)
    do {
        _ = try await connection.initialize()
        let notification = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await connection.notify("session/cancel", params: .object(["sessionId": .string("synthetic-session")]))
        }
        do { try await notification.value; Issue.record("Pre-cancelled notification was sent") }
        catch let error as AntigravityWireError { #expect(error.kind == .cancelled) }
        _ = try await connection.request("session/new")
        #expect(fixture.proof(runtime.processIdentifier)["cancels"] == .number(0))
    } catch { await connection.close(); fixture.cleanup(); throw error }
    await connection.close(); fixture.cleanup()
}

@Test func antigravityConnectionCancelsNativeQueuedNotificationWithoutTruncatingAnAlreadyStartedFrame() async throws {
    let fixture = try AntigravityWireFixture(mode: "writer-blocked"), runtime = try fixture.runtime()
    let connection = try AntigravityConnection(runtime: runtime)
    var payload: Task<Void, any Error>?, notification: Task<Void, any Error>?
    do {
        _ = try await connection.initialize()
        _ = try await connection.request("session/new")
        var bytes = try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "method": .string("fixture/payload"), "params": .object(["text": .string(String(repeating: "x", count: 8 * 1_024 * 1_024))])]))
        bytes.append(10)
        let body = bytes
        let writing = Task { try await runtime.write(body) }; payload = writing
        // The peer reads only a prefix, then holds the pipe: the first native
        // write is demonstrably started and cannot complete until released.
        try await antigravityEventually { fixture.proof(runtime.processIdentifier)["writerPrefix"] == .bool(true) }
        let queued = Task { try await connection.notify("session/cancel", params: .object(["sessionId": .string("synthetic-session")])) }; notification = queued
        try await antigravityEventually { runtime.pendingWriteCount == 2 }
        queued.cancel(); writing.cancel()
        try Data().write(to: fixture.cwd.appendingPathComponent("release-writer"))
        try await writing.value // Claimed frame finishes, preserving the stream.
        do { try await queued.value; Issue.record("Cancelled queued notification was sent") }
        catch let error as AntigravityWireError { #expect(error.kind == .cancelled) }
        _ = try await connection.request("session/list")
        let proof = fixture.proof(runtime.processIdentifier)
        #expect(proof["largeFrames"] == .number(1) && proof["cancels"] == .number(0))
        await connection.close()
        #expect(runtime.pendingWriteCount == 0)
    } catch {
        notification?.cancel(); payload?.cancel(); await connection.close()
        _ = try? await notification?.value; _ = try? await payload?.value
        fixture.cleanup(); throw error
    }
    await connection.close(); fixture.cleanup()
}

@Test func antigravityConnectionOverflowAndCloseSettlePendingBarriersWithoutConsumerDrain() async throws {
    let fixture = try AntigravityWireFixture(mode: "flood"), runtime = try fixture.runtime()
    let connection = try AntigravityConnection(runtime: runtime, eventBufferLimit: 8)
    do {
        _ = try await connection.initialize()
        do { _ = try await connection.request("session/prompt") } catch let error as AntigravityWireError { #expect(error.kind == .overflow) }
        await connection.close()
        var notifications = 0, closed: AntigravityWireError?
        for await event in connection.events {
            if case .notification = event { notifications += 1 }
            if case .closed(let error) = event { closed = error }
        }
        #expect(notifications > 0 && notifications <= 7 && closed?.kind == .overflow)
    } catch { await connection.close(); fixture.cleanup(); throw error }
    fixture.cleanup()
    let another = try AntigravityWireFixture(mode: "held"), owned = try another.runtime(), record = AntigravityWireRecord()
    let host = try AntigravityConnection(runtime: owned)
    do {
        _ = try await host.initialize()
        let prompt = Task { try await host.request("session/prompt", onResponse: { await record.callback($0) }) }
        try await antigravityEventually { another.proof(owned.processIdentifier)["prompts"] == .number(1) }
        let barrier = Task { try await host.flushEvents() }
        let holder = Task {
            for await event in host.events {
                if case .callback = event { await record.holdBarrier(); return }
            }
        }
        try await antigravityEventually { await record.heldBarrier }
        await holder.value
        async let a: Void = host.close(); async let b: Void = host.close(); _ = await (a, b)
        do { try await barrier.value; Issue.record("Unconsumed barrier completed") }
        catch let error as AntigravityWireError { #expect(error.kind == .closed) }
        do { _ = try await prompt.value; Issue.record("Closed native prompt completed") }
        catch let error as AntigravityWireError { #expect(error.kind == .closed) }
        let failures = await record.failures
        #expect(failures.isEmpty && !FileManager.default.fileExists(atPath: owned.temporaryDirectory.path))
    } catch { await host.close(); another.cleanup(); throw error }
    another.cleanup()
}

@Test func antigravityAuthorizationURLRejectsOffOriginAmbiguousAndUnsafeCallbacks() throws {
    let valid = "https://accounts.google.com/o/oauth2/v2/auth?response_type=code&state=synthetic&redirect_uri=http%3A%2F%2F127.0.0.1%3A48123%2F"
    _ = try AntigravityAuthorizationURL(valid)
    for invalid in [valid + "&state=another", valid + "#fragment", valid.replacingOccurrences(of: "accounts.google.com", with: "example.invalid"), valid.replacingOccurrences(of: "127.0.0.1", with: "localhost"), valid.replacingOccurrences(of: "48123", with: "80"), valid.replacingOccurrences(of: "48123", with: "99999")] {
        #expect(throws: AntigravityWireError.self) { try AntigravityAuthorizationURL(invalid) }
    }
}
