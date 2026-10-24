import Foundation
import Testing
@testable import CoincideCore

private final class MCPRegistryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}
private actor MCPRegistryGate {
    private var entered = false, released = false
    private var entrants: [CheckedContinuation<Void, Never>] = [], releases: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered = true
        let pending = entrants; entrants = []; for waiter in pending { waiter.resume() }
        if !released { await withCheckedContinuation { releases.append($0) } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entrants.append($0) } }
    }
    func release() {
        released = true
        let pending = releases; releases = []; for waiter in pending { waiter.resume() }
        let waiting = entrants; entrants = []; for waiter in waiting { waiter.resume() }
    }
}
private actor MCPRegistryCompletions {
    private var values: Set<Int> = []
    func mark(_ value: Int) { values.insert(value) }
    func has(_ value: Int) -> Bool { values.contains(value) }
}
private func registryScope(threadID: UUID = UUID(), sessionID: UUID = UUID(), capabilities: Set<MCPCapability> = [.orchestration]) -> MCPInvocationScope {
    .init(sessionID: sessionID, threadID: threadID, projectID: UUID(), provider: .codex, runtimeID: UUID(), incarnation: UUID(),
          providerInstanceID: UUID(), workspacePath: "/private/tmp/synthetic-mcp-workspace", permission: .supervised, capabilities: capabilities)
}
private func registryInitialize(_ registry: MCPSessionRegistry, credential: MCPSessionCredential) async throws {
    _ = try await registry.initialize(sessionID: credential.sessionID, requestedVersion: "2025-06-18")
    try await registry.initialized(sessionID: credential.sessionID, version: "2025-06-18")
}
private func registryEventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("Synthetic MCP registry milestone was not reached") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test func mcpRegistryIssuesIndependentRedactedCredentialsAndOnlyTrustedTouchRevivesLiveness() async throws {
    let clock = MCPRegistryClock(), registry = MCPSessionRegistry(livenessWindow: 10, now: { clock.now() })
    let firstScope = registryScope(), otherScope = registryScope()
    let first = try await registry.issue(scope: firstScope), other = try await registry.issue(scope: otherScope)
    let different = first.authorizationHeader != other.authorizationHeader
    #expect(different)
    #expect(first.authorizationHeader.utf8.count == 50)
    #expect(String(reflecting: first) == "MCPSessionCredential(redacted)")
    #expect(Mirror(reflecting: first).children.isEmpty)
    #expect(try await registry.authenticate(first.authorizationHeader) == firstScope)
    clock.advance(9)
    #expect(try await registry.authenticate(first.authorizationHeader) == firstScope)
    clock.advance(2)
    await #expect(throws: MCPError(.unauthorized)) { _ = try await registry.authenticate(first.authorizationHeader) }
    await registry.touch(sessionID: first.sessionID)
    #expect(try await registry.authenticate(first.authorizationHeader) == firstScope)
    await #expect(throws: MCPError(.unauthorized)) { _ = try await registry.authenticate(other.authorizationHeader) }
    await registry.revoke(sessionID: first.sessionID)
    await registry.touch(sessionID: first.sessionID)
    await #expect(throws: MCPError(.unauthorized)) { _ = try await registry.authenticate(first.authorizationHeader) }
    await registry.shutdown()
}

@Test func mcpRegistryNegotiatesPinnedVersionsRejectsReplayAndLimitsExactCapability() async throws {
    let registry = MCPSessionRegistry(), credential = try await registry.issue(scope: registryScope())
    do {
        await #expect(throws: MCPError(.notReady)) { try await registry.ready(sessionID: credential.sessionID, version: "2025-06-18") }
        let selected = try await registry.initialize(sessionID: credential.sessionID, requestedVersion: "unrecognized")
        #expect(selected == "2025-11-25")
        await #expect(throws: MCPError(.notReady)) { try await registry.initialized(sessionID: credential.sessionID, version: "2025-06-18") }
        try await registry.initialized(sessionID: credential.sessionID, version: selected)
        try await registry.ready(sessionID: credential.sessionID, version: selected)
        try await registry.claim(sessionID: credential.sessionID, requestID: .text("once"))
        await #expect(throws: MCPError(.invalidRequest)) { try await registry.claim(sessionID: credential.sessionID, requestID: .text("once")) }
        await #expect(throws: MCPError(.unavailable)) {
            _ = try await registry.invoke(sessionID: credential.sessionID, requestID: .integer(2), capability: .worktree) { _ in
                Issue.record("A missing capability reached the callback"); return .init(content: [])
            }
        }
        await registry.shutdown()
    } catch { await registry.shutdown(); throw error }
}

@Test func mcpRegistryConcurrentRevokesAndShutdownJoinAlreadyRemovedCancellationResistantCalls() async throws {
    let registry = MCPSessionRegistry(), scope = registryScope(), gate = MCPRegistryGate(), completions = MCPRegistryCompletions()
    let credential = try await registry.issue(scope: scope)
    try await registryInitialize(registry, credential: credential)
    let call = Task {
        try await registry.invoke(sessionID: scope.sessionID, requestID: .integer(3), capability: .orchestration) { _ in
            await gate.hold() // Deliberately ignores cancellation until the explicit native drain gate.
            return .init(content: ["drained"])
        }
    }
    let safety = Task { try? await Task.sleep(for: .seconds(3)); await gate.release() }
    do {
        await gate.waitUntilEntered()
        let first = Task { await registry.revoke(sessionID: scope.sessionID); await completions.mark(1) }
        try await registryEventually { do { _ = try await registry.authenticate(credential.authorizationHeader); return false } catch { return true } }
        let second = Task { await registry.revoke(threadID: scope.threadID); await completions.mark(2) }
        let shutdown = Task { await registry.shutdown(); await completions.mark(3) }
        // The task is intentionally cancellation-resistant. A second revoke
        // cannot treat the removed credential record as a completed drain.
        try await Task.sleep(for: .milliseconds(60))
        let firstEarly = await completions.has(1), secondEarly = await completions.has(2), shutdownEarly = await completions.has(3)
        let prematurelyReturned = firstEarly || secondEarly || shutdownEarly
        #expect(!prematurelyReturned)
        await gate.release()
        await first.value; await second.value; await shutdown.value
        let firstDone = await completions.has(1), secondDone = await completions.has(2), shutdownDone = await completions.has(3)
        let allReturned = firstDone && secondDone && shutdownDone
        #expect(allReturned)
        do { _ = try await call.value; Issue.record("A revoked call returned a successful result") } catch { }
        safety.cancel(); await safety.value
    } catch {
        await gate.release(); safety.cancel(); await safety.value; _ = await call.result; await registry.shutdown(); throw error
    }
}

@Test func mcpRegistryCancellationIsScopedToCredentialAndExactStringOrIntegerID() async throws {
    let registry = MCPSessionRegistry(), first = try await registry.issue(scope: registryScope()), second = try await registry.issue(scope: registryScope())
    let firstGate = MCPRegistryGate(), secondGate = MCPRegistryGate()
    let firstCall = Task { try await registry.invoke(sessionID: first.sessionID, requestID: .integer(1), capability: .orchestration) { _ in await firstGate.hold(); try Task.checkCancellation(); return .init(content: ["first"]) } }
    let secondCall = Task { try await registry.invoke(sessionID: second.sessionID, requestID: .integer(1), capability: .orchestration) { _ in await secondGate.hold(); try Task.checkCancellation(); return .init(content: ["second"]) } }
    let safety = Task { try? await Task.sleep(for: .seconds(3)); await firstGate.release(); await secondGate.release() }
    await firstGate.waitUntilEntered(); await secondGate.waitUntilEntered()
    await registry.cancel(sessionID: first.sessionID, requestID: .text("1"))
    await registry.cancel(sessionID: first.sessionID, requestID: .integer(1))
    await firstGate.release(); await secondGate.release()
    do { _ = try await firstCall.value; Issue.record("The exact cancelled call succeeded") } catch let error as MCPError { #expect(error.kind == .cancelled) } catch { Issue.record("Cancellation did not use a fixed safe error") }
    #expect(try await secondCall.value.content == ["second"])
    safety.cancel(); await safety.value; await registry.shutdown()
}
