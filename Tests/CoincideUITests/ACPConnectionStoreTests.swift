import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private func connectionInfo(name: String = "Fixture Agent") throws -> ACPConnectionInfo {
    try ACPConnectionInfo(.object([
        "protocolVersion": .number(1),
        "agentInfo": .object(["name": .string(name), "version": .string("1.2.3")]),
        "agentCapabilities": .object([
            "loadSession": .bool(true),
            "promptCapabilities": .object(["image": .bool(true)])
        ]),
        "authMethods": .array([.object(["id": .string("existing-login"), "name": .string("CLI sign-in")])])
    ]))
}

private actor ConnectionReadGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var entered = false
    private(set) var calls = 0
    func wait() async {
        calls += 1; entered = true
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        released = true
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

@MainActor private final class ConnectionDrainProbe {
    var started = false
    var finished = false
}

@MainActor private func connectionEventually(_ predicate: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The owned connection check did not reach its gate.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func acpConnectionCheckIsExplicitExactConfigurationBoundAndKeepsErrorsPrivate() async throws {
    let store = ACPConnectionStore(), agent = ACPIntegration.cursor.configuration()
    let first = try connectionInfo()
    store.invalidate(validAgents: [agent])
    #expect(store.observation(for: agent) == nil && !store.isRefreshing(agent: agent))
    await store.refresh(agent: agent) { first }
    let observation = try #require(store.observation(for: agent))
    #expect(observation.agent == agent && observation.info == first)
    #expect(observation.info.supportsResume && observation.info.supportsImages)
    await store.refresh(agent: agent) { throw CoincideError("private credential-bearing server diagnostic") }
    #expect(store.observation(for: agent) == observation && !store.isRefreshing(agent: agent))
    #expect(store.errorMessage(for: agent) != nil)
    #expect(store.errorMessage(for: agent)?.contains("credential-bearing") == false)
    var changed = agent; changed.executable = "/opt/fixture/bin/agent"
    #expect(store.observation(for: changed) == nil && store.errorMessage(for: changed) == nil)
    store.invalidate(validAgents: [changed])
    #expect(store.observation(for: agent) == nil && store.observation(for: changed) == nil)
    #expect(store.errorMessage(for: changed) == nil)
    await store.refresh(agent: changed) { first }
    #expect(store.observation(for: changed)?.agent == changed)
    #expect(store.observation(for: agent) == nil)
    await store.cancel()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func acpConnectionReplacementCannotPublishLateAndShutdownDrainsOlderCanceledRead() async throws {
    let store = ACPConnectionStore(), gate = ConnectionReadGate(), probe = ConnectionDrainProbe()
    let agent = ACPIntegration.copilot.configuration()
    let oldInfo = try connectionInfo(name: "Old"), newInfo = try connectionInfo(name: "New")
    store.invalidate(validAgents: [agent])
    let old = Task { await store.refresh(agent: agent) { await gate.wait(); return oldInfo } }
    do {
        try await connectionEventually { await gate.entered }
        #expect(store.isRefreshing(agent: agent))
        await store.refresh(agent: agent) { newInfo }
        #expect(store.observation(for: agent)?.info == newInfo && !store.isRefreshing(agent: agent))
        let close = Task { probe.started = true; await store.cancel(); probe.finished = true }
        try await connectionEventually { probe.started }
        for _ in 0..<10 { await Task.yield() }
        #expect(!probe.finished, "Shutdown must still own the older canceled read after the replacement completed.")
        await gate.release(); await old.value; await close.value
        #expect(probe.finished && store.observation(for: agent)?.info == newInfo)
    } catch { await gate.release(); await old.value; await store.cancel(); throw error }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func acpConnectionSnapshotInvalidationImmediatelyHidesChangedConfigAndPruneDrainsIt() async throws {
    let store = ACPConnectionStore(), gate = ConnectionReadGate(), probe = ConnectionDrainProbe()
    let agent = ACPIntegration.cursor.configuration(), info = try connectionInfo()
    var changed = agent; changed.experimentalV2 = true
    store.invalidate(validAgents: [agent])
    await store.refresh(agent: agent) { info }
    let old = Task { await store.refresh(agent: agent) { await gate.wait(); return info } }
    do {
        try await connectionEventually { await gate.entered }
        store.invalidate(validAgents: [changed])
        #expect(!store.isRefreshing(agent: agent) && !store.isRefreshing(agent: changed))
        #expect(store.observation(for: agent) == nil && store.observation(for: changed) == nil)
        let prune = Task { probe.started = true; await store.prune(validAgents: [changed]); probe.finished = true }
        try await connectionEventually { probe.started }
        for _ in 0..<10 { await Task.yield() }
        #expect(!probe.finished)
        await store.refresh(agent: changed) { info }
        await gate.release(); await old.value; await prune.value
        #expect(probe.finished && store.observation(for: changed)?.agent == changed)
        #expect(store.observation(for: agent) == nil)
        store.invalidate(validAgents: [])
        #expect(store.observation(for: changed) == nil && store.errorMessage(for: changed) == nil)
        let forbidden = ConnectionReadGate()
        await forbidden.release()
        await store.refresh(agent: changed) { await forbidden.wait(); return info }
        #expect(await forbidden.calls == 0, "A deleted invocation must not start a new connection check.")
        #expect(store.observation(for: changed) == nil)
        await store.cancel()
    } catch { await gate.release(); await old.value; await store.cancel(); throw error }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func acpConnectionCanceledCheckPreservesLastObservationAndOtherAgentsRemainIndependent() async throws {
    let store = ACPConnectionStore(), gate = ConnectionReadGate()
    let first = ACPIntegration.cursor.configuration(), second = ACPIntegration.copilot.configuration()
    let info = try connectionInfo(), laterInfo = try connectionInfo(name: "Later")
    store.invalidate(validAgents: [first, second])
    await store.refresh(agent: first) { info }
    let previous = store.observation(for: first)
    let read = Task { await store.refresh(agent: first) { await gate.wait(); return laterInfo } }
    do {
        try await connectionEventually { await gate.entered }
        await store.refresh(agent: second) { laterInfo }
        #expect(store.observation(for: second)?.info == laterInfo && store.isRefreshing(agent: first))
        read.cancel(); await gate.release(); await read.value
        #expect(store.observation(for: first) == previous && !store.isRefreshing(agent: first))
        #expect(store.errorMessage(for: first) == nil)
        #expect(store.observation(for: second)?.info == laterInfo)
        await store.cancel()
    } catch { await gate.release(); await read.value; await store.cancel(); throw error }
}
