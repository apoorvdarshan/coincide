import Foundation
import Testing
@testable import CoincideCore

private actor OwnedCodexGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; let saved = waiters; waiters = []; for waiter in saved { waiter.resume() } }
}

private actor OwnedCodexTrace {
    var entries: [String] = []
    var events: [ProviderEvent] = []
    func add(_ entry: String) { entries.append(entry) }
    func event(_ event: ProviderEvent) { events.append(event) }
    func contains(_ event: ProviderEvent) -> Bool { events.contains(event) }
}

private actor OwnedCodexPeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    nonisolated let supportsAppMCP: Bool
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    let name: String
    let trace: OwnedCodexTrace
    var calls: [String] = []
    var sends: [(ProviderInput, CodingThread)] = []
    var closeCount = 0
    var modelsGate: OwnedCodexGate?
    var closeGate: OwnedCodexGate?
    var appMCPGate: OwnedCodexGate?
    var appMCPConnections: [AppMCPConnection] = []
    var heldSends: [UUID: OwnedCodexGate] = [:]
    var failedSends: Set<UUID> = []
    var uncertainRevert = false
    init(_ name: String, trace: OwnedCodexTrace, supportsAppMCP: Bool = false) {
        self.name = name; self.trace = trace; self.supportsAppMCP = supportsAppMCP
        let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; continuation = pair.continuation
    }
    func holdModels(_ gate: OwnedCodexGate) { modelsGate = gate }
    func holdClose(_ gate: OwnedCodexGate) { closeGate = gate }
    func holdAppMCP(_ gate: OwnedCodexGate) { appMCPGate = gate }
    func configureAppMCP(_ connection: AppMCPConnection) async throws {
        calls.append("configure-mcp"); appMCPConnections.append(connection)
        await trace.add("configure-" + name)
        await appMCPGate?.wait() // Native setup can ignore Task cancellation until its owned process closes.
        guard closeCount == 0 else { throw CancellationError() }
    }
    func hasExactAppMCP(_ expected: AppMCPConnection) -> Bool {
        appMCPConnections.count == 1 && appMCPConnections.allSatisfy {
            $0.scopeID == expected.scopeID && $0.endpoint == expected.endpoint && $0.authorizationHeader == expected.authorizationHeader
        }
    }
    func holdSend(_ id: UUID, gate: OwnedCodexGate, fail: Bool = false) {
        heldSends[id] = gate; if fail { failedSends.insert(id) }
    }
    func makeRevertUncertain() { uncertainRevert = true }
    func emit(_ event: ProviderEvent) { continuation.yield(event) }
    func terminal(_ id: UUID) { emit(.context(runID: id, event: .completed(.idle))) }
    func endStream() { continuation.finish() }
    func models() async throws -> [ProviderModel] {
        await trace.add("models-" + name)
        calls.append("models"); await modelsGate?.wait()
        return [.init(id: "advertised-wire-model", name: "Advertised")]
    }
    func openCodeInventory() async throws -> OpenCodeMetadataSnapshot {
        calls.append("inventory"); throw CoincideError("Synthetic inventory is unavailable.")
    }
    func acpConnectionInfo() async throws -> ACPConnectionInfo {
        calls.append("acp"); return try .init(.object(["protocolVersion": .number(1)]))
    }
    func codexDefaultModelSelection() async throws -> CodexDefaultModelSelection {
        calls.append("defaults"); return try .init(workspacePath: "/owned-codex-fixture", model: "advertised-wire-model", reasoningEffort: "medium")
    }
    func codexAccountSnapshot() async throws -> CodexAccountSnapshot {
        calls.append("cli-account"); throw CoincideError("The native CLI account must not be read.")
    }
    func send(text: String, thread: CodingThread) async throws { try await send(input: .init(text: text), thread: thread) }
    func send(input: ProviderInput, thread: CodingThread) async throws {
        calls.append("send"); sends.append((input, thread)); await trace.add("send-" + name)
        let event: ProviderEvent = .thread("native-conversation")
        if let run = thread.activeRun {
            emit(.context(runID: run.id, event: event))
            emit(.context(runID: run.id, event: .turn("turn-" + run.id.uuidString)))
            await heldSends[run.id]?.wait()
            if failedSends.contains(run.id) { throw CoincideError("Synthetic lost acknowledgement.") }
        } else { emit(event) }
    }
    func steeringCapabilities() async -> ProviderSteeringCapabilities { calls.append("caps"); return .init(supportsActiveSteering: true) }
    func steer(input: ProviderInput, thread: CodingThread, expectedTurnID: String, clientMessageID: String) async throws -> ProviderSteeringReceipt {
        calls.append("steer"); return try .init(turnID: expectedTurnID)
    }
    func interrupt() async throws { calls.append("stop") }
    func interrupt(expectedRunID: UUID) async throws { calls.append("stop-" + expectedRunID.uuidString) }
    func respond(_ request: ApprovalRequest, allow: Bool) async throws { calls.append("respond") }
    func answer(_ request: ApprovalRequest, answers: [String: String]) async throws { calls.append("answer") }
    func selectAnswers(_ request: ApprovalRequest, selections: [String: [String]]) async throws { calls.append("select") }
    func selectAnswers(_ request: ApprovalRequest, selections: [String: [String]], notes: [String: String]) async throws { calls.append("notes") }
    func choose(_ request: ApprovalRequest, optionID: String) async throws { calls.append("choose") }
    func historyCapabilities(threadID: String) async throws -> ProviderHistoryCapabilities {
        calls.append("history-caps")
        return .init(reference: try .init(provider: .codex, nativeThreadID: threadID), historyMode: .legacy,
                     canRead: true, canForkHead: true, unavailableReason: "Synthetic old profile cannot revert.")
    }
    func conversationSnapshot(threadID: String) async throws -> ProviderConversationSnapshot {
        calls.append("snapshot"); return try snapshot(threadID)
    }
    func historyPage(threadID: String, cursor: String?, limit: Int) async throws -> ProviderHistoryPage {
        calls.append("page"); return try .init(reference: .init(provider: .codex, nativeThreadID: threadID), turns: [])
    }
    func forkConversation(source: ProviderConversationReference, boundary: ProviderHistoryBoundary, configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot {
        calls.append("fork"); return try snapshot("native-fork")
    }
    func revertConversation(thread: ProviderConversationReference, beforeTurnID: String, expectedHeadTurnID: String) async throws -> ProviderConversationSnapshot {
        calls.append("revert"); if uncertainRevert { throw ProviderHistoryError(.outcomeUncertain) }
        return try snapshot(thread.nativeThreadID)
    }
    private func snapshot(_ id: String) throws -> ProviderConversationSnapshot {
        try .init(reference: .init(provider: .codex, nativeThreadID: id), workspacePath: "/owned-codex-fixture", historyMode: .legacy)
    }
    func close() async {
        closeCount += 1; await trace.add("close-" + name)
        await appMCPGate?.release()
        await closeGate?.wait(); for gate in heldSends.values { await gate.release() }
        continuation.finish()
    }
}

private actor OwnedCodexBroker {
    let trace: OwnedCodexTrace
    var revision: UUID
    var peers: [UUID: OwnedCodexPeer]
    var acquires = 0
    var resolves = 0
    var ticketReleases: [UUID: Int] = [:]
    var resourceReleases: [UUID: Int] = [:]
    var used: Set<UUID> = []
    var acquireGate: OwnedCodexGate?
    var resolveGate: OwnedCodexGate?
    init(revision: UUID, peer: OwnedCodexPeer, trace: OwnedCodexTrace) {
        self.revision = revision; peers = [revision: peer]; self.trace = trace
    }
    func rotate(_ revision: UUID, peer: OwnedCodexPeer) { self.revision = revision; peers[revision] = peer }
    func holdAcquire(_ gate: OwnedCodexGate) { acquireGate = gate }
    func holdResolve(_ gate: OwnedCodexGate) { resolveGate = gate }
    func acquire() async throws -> CodexOwnedSessionAccess {
        acquires += 1
        let id = UUID(), revision = revision
        await acquireGate?.wait() // Deliberately ignores cancellation, as a late credential dependency can.
        return .init(credentialRevision: revision, resolve: { try await self.resolve(id, revision: revision) },
                     release: { await self.releaseTicket(id) })
    }
    private func resolve(_ id: UUID, revision: UUID) async throws -> CodexOwnedSessionResource {
        guard used.insert(id).inserted, let peer = peers[revision] else { throw CodexAccountError.staleAccount }
        resolves += 1; await trace.add("resolve-" + peer.name)
        await resolveGate?.wait()
        return .init(session: peer, credentialRevision: revision, release: { await self.releaseResource(id) })
    }
    private func releaseTicket(_ id: UUID) { ticketReleases[id, default: 0] += 1 }
    private func releaseResource(_ id: UUID) { resourceReleases[id, default: 0] += 1 }
}

private struct OwnedCodexFixture: Sendable {
    let configuration = CodexRuntimeConfiguration(homeDirectory: "/owned-codex-home", authenticationMode: .ownedChatGPT,
        accountBinding: .init(profileID: UUID(), generation: UUID()))
    let cwd = URL(fileURLWithPath: "/owned-codex-fixture")
    let trace = OwnedCodexTrace()
    let peer: OwnedCodexPeer
    let broker: OwnedCodexBroker
    let wrapper: CodexOwnedSession
    init(supportsAppMCP: Bool = false) {
        let peer = OwnedCodexPeer("first", trace: trace, supportsAppMCP: supportsAppMCP); self.peer = peer
        let broker = OwnedCodexBroker(revision: UUID(), peer: peer, trace: trace); self.broker = broker
        wrapper = CodexOwnedSession(configuration: configuration, cwd: cwd, acquireAccess: { try await broker.acquire() },
            accountSnapshot: {
                .init(identity: .init(kind: .chatgpt, requiresOpenAIAuth: true),
                      usage: .available(.init(buckets: [.init(id: "not-owned-usage")], ordinaryUsageAllowed: true)))
            })
    }
    func thread(runID: UUID = UUID()) -> CodingThread {
        var value = CodingThread(project: .init(path: cwd.path), model: "captured-model")
        value.codexRuntimeConfiguration = configuration; value.reasoningEffort = "high"; value.permission = .supervised
        value.activeRun = .init(id: runID, configuration: .init(thread: value), startedAt: .now)
        return value
    }
    func record() -> Task<Void, Never> {
        let stream = wrapper.events, trace = trace
        return Task { for await event in stream { await trace.event(event) } }
    }
    func waitFor(_ event: ProviderEvent) async throws { try await ownedCodexEventually { await trace.contains(event) } }
    func close(_ reader: Task<Void, Never>? = nil) async { await wrapper.close(); await reader?.value }
}

private func ownedCodexEventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The owned Codex fixture did not reach its exact boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test func codexOwnedSessionIsInertAndDoesNotLaunchForControlsOrOwnedAccountMetadata() async throws {
    let fixture = OwnedCodexFixture()
    do {
        let caps = await fixture.wrapper.steeringCapabilities(); #expect(!caps.supportsActiveSteering)
        try await fixture.wrapper.interrupt()
        let request = ApprovalRequest(id: .string("approval"), method: "test", params: .object([:]))
        await #expect(throws: CodexAccountError.signInRequired) { try await fixture.wrapper.respond(request, allow: true) }
        await #expect(throws: ProviderSteeringError(.staleTarget)) { try await fixture.wrapper.interrupt(expectedRunID: UUID()) }
        let account = try await fixture.wrapper.codexAccountSnapshot()
        #expect(account.identity.kind == .chatgpt && account.usage == .unsupported)
        let acquires = await fixture.broker.acquires, calls = await fixture.peer.calls
        #expect(acquires == 0 && calls.isEmpty)
        #expect(Mirror(reflecting: fixture.wrapper).children.isEmpty)
        #expect(String(reflecting: fixture.wrapper) == "CodexOwnedSession(redacted)")
    } catch { await fixture.close(); throw error }
    await fixture.close()
}

@Test func codexOwnedSessionCoalescesLaunchAndForwardsEveryReadAndResponseMethod() async throws {
    let fixture = OwnedCodexFixture(), gate = OwnedCodexGate()
    await fixture.broker.holdResolve(gate)
    let first = Task { try await fixture.wrapper.models() }, second = Task { try await fixture.wrapper.models() }
    do {
        try await ownedCodexEventually { await fixture.broker.resolves == 1 }
        await gate.release()
        let rows = try await first.value, other = try await second.value
        #expect(rows == other && rows.first?.id == "advertised-wire-model")
        let defaults = try await fixture.wrapper.codexDefaultModelSelection(), info = try await fixture.wrapper.acpConnectionInfo()
        #expect(defaults.reasoningEffort == "medium" && info.protocolVersion == 1)
        await #expect(throws: CoincideError.self) { try await fixture.wrapper.openCodeInventory() }
        let caps = try await fixture.wrapper.historyCapabilities(threadID: "native-conversation")
        #expect(caps.canRead && caps.canForkHead && !caps.canForkFromTurn && !caps.canRevertBeforeTurn && caps.historyMode == .legacy)
        _ = try await fixture.wrapper.conversationSnapshot(threadID: "native-conversation")
        _ = try await fixture.wrapper.historyPage(threadID: "native-conversation", cursor: nil, limit: 3)
        let request = ApprovalRequest(id: .string("approval"), method: "test", params: .object([:]))
        try await fixture.wrapper.respond(request, allow: true)
        try await fixture.wrapper.answer(request, answers: ["q": "a"])
        try await fixture.wrapper.selectAnswers(request, selections: ["q": ["a"]])
        try await fixture.wrapper.selectAnswers(request, selections: ["q": ["a"]], notes: ["q": "note"])
        try await fixture.wrapper.choose(request, optionID: "once")
        let calls = await fixture.peer.calls, count = await fixture.broker.acquires
        #expect(Set(["defaults", "acp", "inventory", "history-caps", "snapshot", "page", "respond", "answer", "select", "notes", "choose"]).isSubset(of: Set(calls)))
        #expect(!calls.contains("cli-account") && count == 1)
    } catch { await gate.release(); _ = await first.result; _ = await second.result; await fixture.close(); throw error }
    await fixture.close()
    let tickets = await fixture.broker.ticketReleases, resources = await fixture.broker.resourceReleases, closes = await fixture.peer.closeCount
    #expect(tickets.values.allSatisfy { $0 == 1 } && resources.values.allSatisfy { $0 == 1 } && resources.count == 1 && closes == 1)
}

@Test func codexOwnedSessionRenewsOnlyIdleChildAndRetainsCapturedSettingsAndNativeConversation() async throws {
    let fixture = OwnedCodexFixture(), reader = fixture.record(), drain = OwnedCodexGate()
    let first = fixture.thread(), secondPeer = OwnedCodexPeer("second", trace: fixture.trace)
    var successor: Task<Void, any Error>?
    do {
        try await fixture.wrapper.send(input: .init(text: "first"), thread: first)
        let turn = "turn-" + first.activeRun!.id.uuidString
        try await fixture.waitFor(.context(runID: first.activeRun!.id, event: .turn(turn)))
        await fixture.broker.rotate(UUID(), peer: secondPeer)
        await #expect(throws: CoincideError.self) { try await fixture.wrapper.send(text: "duplicate", thread: fixture.thread()) }
        let caps = await fixture.wrapper.steeringCapabilities(); #expect(caps.supportsActiveSteering)
        var steerThread = first; steerThread.activeRun?.nativeTurnID = turn; steerThread.providerThreadID = "native-conversation"
        _ = try await fixture.wrapper.steer(input: .init(text: "steer"), thread: steerThread, expectedTurnID: turn, clientMessageID: "user-steer")
        let activeAcquires = await fixture.broker.acquires, activeCloses = await fixture.peer.closeCount
        #expect(activeAcquires == 1 && activeCloses == 0)
        await fixture.peer.terminal(first.activeRun!.id)
        try await fixture.waitFor(.context(runID: first.activeRun!.id, event: .completed(.idle)))
        var second = fixture.thread()
        second.model = "future-header"; second.reasoningEffort = "low"; second.permission = .fullAccess
        second.codexRuntimeConfiguration = .init(homeDirectory: "/future-header-home", authenticationMode: .ownedChatGPT,
                                                accountBinding: .init(profileID: UUID(), generation: UUID()))
        let capturedSecond = second
        await fixture.peer.holdClose(drain)
        successor = Task { try await fixture.wrapper.send(text: "second", thread: capturedSecond) }
        try await ownedCodexEventually { await fixture.trace.entries.contains("close-first") }
        let beforeDrain = await fixture.broker.resolves; #expect(beforeDrain == 1)
        await drain.release(); try await successor?.value
        let sends = await secondPeer.sends, order = await fixture.trace.entries
        let presented = try #require(sends.first?.1)
        #expect(presented.model == "captured-model" && presented.reasoningEffort == "high" && presented.permission == .supervised)
        #expect(presented.codexRuntimeConfiguration == fixture.configuration)
        #expect(presented.providerThreadID == "native-conversation" && presented.activeRun?.id == second.activeRun?.id)
        let closed = try #require(order.firstIndex(of: "close-first")), resolved = try #require(order.firstIndex(of: "resolve-second"))
        #expect(closed < resolved)
        await fixture.peer.emit(.context(runID: second.activeRun!.id, event: .failure("Old retired actor must be ignored.")))
        await secondPeer.terminal(second.activeRun!.id)
        try await fixture.waitFor(.context(runID: second.activeRun!.id, event: .completed(.idle)))
        try await fixture.wrapper.send(text: "third", thread: fixture.thread())
        let total = await fixture.broker.acquires, resolves = await fixture.broker.resolves
        #expect(total == 3 && resolves == 2)
    } catch { await drain.release(); _ = await successor?.result; await fixture.close(reader); throw error }
    await fixture.close(reader)
}

@Test(arguments: [false, true]) func codexOwnedSessionCloseJoinsCancellationResistantLateStartup(afterResolve: Bool) async throws {
    let fixture = OwnedCodexFixture(), gate = OwnedCodexGate(), done = OwnedCodexTrace()
    if afterResolve { await fixture.broker.holdResolve(gate) } else { await fixture.broker.holdAcquire(gate) }
    let pending = Task { try await fixture.wrapper.models() }
    var closing: Task<Void, Never>?
    do {
        try await ownedCodexEventually {
            let resolves = await fixture.broker.resolves, acquires = await fixture.broker.acquires
            return afterResolve ? resolves == 1 : acquires == 1
        }
        closing = Task { await fixture.wrapper.close(); await done.add("closed") }
        try await ownedCodexEventually { if case .failure = await pending.result { return true }; return false }
        let early = await done.entries; #expect(early.isEmpty)
        await gate.release(); await closing?.value
        let count = await fixture.broker.resolves, closes = await fixture.peer.closeCount
        let tickets = await fixture.broker.ticketReleases, resources = await fixture.broker.resourceReleases
        #expect(count == (afterResolve ? 1 : 0) && closes == (afterResolve ? 1 : 0))
        #expect(tickets.count == 1 && tickets.values.allSatisfy { $0 == 1 })
        #expect(resources.count == (afterResolve ? 1 : 0) && resources.values.allSatisfy { $0 == 1 })
        await fixture.wrapper.close()
    } catch { await gate.release(); _ = await pending.result; await fixture.close(); await closing?.value; throw error }
}

@Test func codexOwnedSessionStopDuringPreparationIsExactAndCannotSendAfterDrain() async throws {
    let fixture = OwnedCodexFixture(), gate = OwnedCodexGate(), thread = fixture.thread()
    await fixture.broker.holdResolve(gate)
    let pending = Task { try await fixture.wrapper.send(text: "must stay unsent", thread: thread) }
    var stop: Task<Void, any Error>?
    do {
        try await ownedCodexEventually { await fixture.broker.resolves == 1 }
        await #expect(throws: ProviderSteeringError(.staleTarget)) { try await fixture.wrapper.interrupt(expectedRunID: UUID()) }
        stop = Task { try await fixture.wrapper.interrupt(expectedRunID: thread.activeRun!.id) }
        _ = await pending.result
        await gate.release(); try await stop?.value
        let sends = await fixture.peer.sends, closes = await fixture.peer.closeCount
        #expect(sends.isEmpty && closes == 1)
    } catch { await gate.release(); _ = await pending.result; _ = await stop?.result; await fixture.close(); throw error }
    await fixture.close()
}

@Test func codexOwnedSessionLateOldSendFailureCannotBlockOrCloseSuccessor() async throws {
    let fixture = OwnedCodexFixture(), gate = OwnedCodexGate(), reader = fixture.record()
    let first = fixture.thread(), second = fixture.thread()
    await fixture.peer.holdSend(first.activeRun!.id, gate: gate, fail: true)
    let pending = Task { try await fixture.wrapper.send(text: "first", thread: first) }
    do {
        try await fixture.waitFor(.context(runID: first.activeRun!.id, event: .turn("turn-" + first.activeRun!.id.uuidString)))
        await fixture.peer.terminal(first.activeRun!.id)
        try await fixture.waitFor(.context(runID: first.activeRun!.id, event: .completed(.idle)))
        try await fixture.wrapper.send(text: "second", thread: second)
        await gate.release(); await #expect(throws: CoincideError.self) { try await pending.value }
        let caps = await fixture.wrapper.steeringCapabilities(), closes = await fixture.peer.closeCount
        #expect(caps.supportsActiveSteering && closes == 0)
        try await fixture.wrapper.interrupt(expectedRunID: second.activeRun!.id)
        await fixture.peer.terminal(second.activeRun!.id)
        try await fixture.waitFor(.context(runID: second.activeRun!.id, event: .completed(.idle)))
        try await fixture.wrapper.send(text: "third", thread: fixture.thread())
        let sends = await fixture.peer.sends; #expect(sends.count == 3)
    } catch { await gate.release(); _ = await pending.result; await fixture.close(reader); throw error }
    await fixture.close(reader)
}

@Test func codexOwnedSessionUncertainHistoryNeverRotatesAwayOrReplaysMutation() async throws {
    let fixture = OwnedCodexFixture()
    do {
        let source = try ProviderConversationReference(provider: .codex, nativeThreadID: "native-conversation")
        _ = try await fixture.wrapper.forkConversation(source: source, boundary: .head, configuration: .init(thread: fixture.thread()))
        await fixture.peer.makeRevertUncertain()
        await #expect(throws: ProviderHistoryError(.outcomeUncertain)) {
            try await fixture.wrapper.revertConversation(thread: source, beforeTurnID: "old", expectedHeadTurnID: "head")
        }
        await fixture.broker.rotate(UUID(), peer: OwnedCodexPeer("must-not-launch", trace: fixture.trace))
        await #expect(throws: ProviderHistoryError(.outcomeUncertain)) {
            try await fixture.wrapper.revertConversation(thread: source, beforeTurnID: "old", expectedHeadTurnID: "head")
        }
        await #expect(throws: ProviderHistoryError(.outcomeUncertain)) { try await fixture.wrapper.send(text: "must not replay", thread: fixture.thread()) }
        _ = try await fixture.wrapper.conversationSnapshot(threadID: source.nativeThreadID)
        let calls = await fixture.peer.calls, count = await fixture.broker.acquires
        #expect(calls.filter { $0 == "revert" }.count == 1 && calls.filter { $0 == "fork" }.count == 1 && !calls.contains("send") && count == 2)
    } catch { await fixture.close(); throw error }
    await fixture.close()
}

@Test func codexOwnedSessionSessionRequestsAndBackgroundActivityPreventIdleReplacement() async throws {
    let fixture = OwnedCodexFixture(), reader = fixture.record()
    do {
        _ = try await fixture.wrapper.models()
        let request = ApprovalRequest(id: .string("background"), method: "test", params: .object([:]))
        await fixture.peer.emit(.sessionApproval(request)); try await fixture.waitFor(.sessionApproval(request))
        await #expect(throws: CoincideError.self) { try await fixture.wrapper.send(text: "held", thread: fixture.thread()) }
        try await fixture.wrapper.respond(request, allow: true)
        await fixture.peer.emit(.sessionApprovalDismissed(request.id)); try await fixture.waitFor(.sessionApprovalDismissed(request.id))
        let activity = ProviderActivity(id: UUID(), state: .running)
        await fixture.peer.emit(.activity(activity)); try await fixture.waitFor(.activity(activity))
        await #expect(throws: CoincideError.self) { try await fixture.wrapper.send(text: "held", thread: fixture.thread()) }
        let idle = ProviderActivity(id: activity.id, state: .idle)
        await fixture.peer.emit(.activity(idle)); try await fixture.waitFor(.activity(idle))
        try await fixture.wrapper.send(text: "released", thread: fixture.thread())
        let count = await fixture.broker.acquires; #expect(count == 2)
    } catch { await fixture.close(reader); throw error }
    await fixture.close(reader)
}

@Test func codexOwnedSessionRejectsStaleCapturedAccountBeforeAccessAndPreservesExactInput() async throws {
    let fixture = OwnedCodexFixture()
    do {
        var stale = fixture.thread()
        stale.activeRun?.configuration.codexRuntimeConfiguration = .init(homeDirectory: "/other-account-home",
            authenticationMode: .ownedChatGPT, accountBinding: .init(profileID: UUID(), generation: UUID()))
        let staleInput = stale
        await #expect(throws: CodexAccountError.staleAccount) { try await fixture.wrapper.send(text: "stale", thread: staleInput) }
        let before = await fixture.broker.acquires; #expect(before == 0)
        let input = ProviderInput(text: "exact\noriginal input", images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))])
        try await fixture.wrapper.send(input: input, thread: fixture.thread())
        let actual = await fixture.peer.sends.first?.0; #expect(actual == input)
        let revision = UUID()
        let resource = CodexOwnedSessionResource(session: fixture.peer, credentialRevision: revision, release: {})
        let access = CodexOwnedSessionAccess(credentialRevision: revision, resolve: { resource }, release: {})
        #expect(Mirror(reflecting: resource).children.isEmpty && Mirror(reflecting: access).children.isEmpty)
        #expect(!String(reflecting: resource).contains(revision.uuidString) && !String(reflecting: access).contains(revision.uuidString))
    } catch { await fixture.close(); throw error }
    await fixture.close()
}

@Test func codexOwnedSessionUnexpectedStreamEndBlocksNewWritesWithoutCredentialRetry() async throws {
    let fixture = OwnedCodexFixture(), reader = fixture.record()
    do {
        try await fixture.wrapper.send(text: "one", thread: fixture.thread())
        await fixture.peer.endStream()
        try await fixture.waitFor(.connectionClosed("The owned Codex connection ended. No input was automatically resent."))
        await fixture.broker.rotate(UUID(), peer: OwnedCodexPeer("must-not-launch", trace: fixture.trace))
        await #expect(throws: CoincideError.self) { try await fixture.wrapper.send(text: "must remain unsent", thread: fixture.thread()) }
        let acquires = await fixture.broker.acquires, sends = await fixture.peer.sends
        #expect(acquires == 1 && sends.count == 1)
    } catch { await fixture.close(reader); throw error }
    await fixture.close(reader)
}

private func ownedCodexAppMCPConnection() throws -> AppMCPConnection {
    try .init(endpoint: URL(string: "http://127.0.0.1:1/mcp")!,
        authorizationHeader: "Bearer " + String(repeating: "B", count: 43), scopeID: UUID())
}

@Test func codexOwnedSessionAppMCPSetterIsInertOneUseAndDoesNotAcquireCredentials() async throws {
    let f = OwnedCodexFixture(supportsAppMCP: true), connection = try ownedCodexAppMCPConnection()
    do {
        #expect(f.wrapper.supportsAppMCP)
        try await f.wrapper.configureAppMCP(connection)
        let acquired = await f.broker.acquires, resolved = await f.broker.resolves
        let calls = await f.peer.calls, handoffs = await f.peer.appMCPConnections
        #expect(acquired == 0 && resolved == 0 && calls.isEmpty && handoffs.isEmpty)
        await #expect(throws: CoincideError.self) { try await f.wrapper.configureAppMCP(connection) }
        let afterDuplicate = await f.broker.acquires
        #expect(afterDuplicate == 0)
        await f.close()
        let tickets = await f.broker.ticketReleases, resources = await f.broker.resourceReleases
        let childCloses = await f.peer.closeCount
        #expect(tickets.isEmpty && resources.isEmpty && childCloses == 0)
        await #expect(throws: CoincideError.self) { try await f.wrapper.configureAppMCP(connection) }
    } catch { await f.close(); throw error }
}

@Test func codexOwnedSessionAppMCPForwardsExactConnectionBeforeMetadataAndEveryNewCredentialChild() async throws {
    let f = OwnedCodexFixture(supportsAppMCP: true), connection = try ownedCodexAppMCPConnection(), reader = f.record()
    let next = OwnedCodexPeer("rotated", trace: f.trace, supportsAppMCP: true)
    do {
        try await f.wrapper.configureAppMCP(connection)
        #expect(try await f.wrapper.models().map(\.id) == ["advertised-wire-model"])
        let originalHandoff = await f.peer.hasExactAppMCP(connection)
        #expect(originalHandoff)
        let first = f.thread(), firstID = try #require(first.activeRun?.id)
        try await f.wrapper.send(text: "First input on original credential child", thread: first)
        await f.peer.terminal(firstID)
        try await f.waitFor(.context(runID: firstID, event: .completed(.idle)))
        await f.broker.rotate(UUID(), peer: next)
        let second = f.thread(), secondID = try #require(second.activeRun?.id)
        try await f.wrapper.send(text: "New input after explicit idle credential rotation", thread: second)
        let rotatedHandoff = await next.hasExactAppMCP(connection)
        #expect(rotatedHandoff)
        let firstCalls = await f.peer.calls, nextCalls = await next.calls
        #expect(firstCalls.filter { $0 == "configure-mcp" }.count == 1 && nextCalls.filter { $0 == "configure-mcp" }.count == 1)
        let order = await f.trace.entries
        let configureFirst = try #require(order.firstIndex(of: "configure-first"))
        let modelsFirst = try #require(order.firstIndex(of: "models-first"))
        let closeFirst = try #require(order.firstIndex(of: "close-first"))
        let configureNext = try #require(order.firstIndex(of: "configure-rotated"))
        let sendNext = try #require(order.firstIndex(of: "send-rotated"))
        #expect(configureFirst < modelsFirst && closeFirst < configureNext && configureNext < sendNext)
        let presented = await next.sends.first?.1
        #expect(presented?.providerThreadID == "native-conversation" && presented?.activeRun?.id == secondID)
        await next.terminal(secondID)
        try await f.waitFor(.context(runID: secondID, event: .completed(.idle)))
        await f.close(reader)
        let firstCloses = await f.peer.closeCount, nextCloses = await next.closeCount
        let tickets = await f.broker.ticketReleases, resources = await f.broker.resourceReleases
        #expect(firstCloses == 1 && nextCloses == 1)
        #expect(tickets.count == 3 && tickets.values.allSatisfy { $0 == 1 })
        #expect(resources.count == 2 && resources.values.allSatisfy { $0 == 1 })
    } catch { await f.close(reader); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func codexOwnedSessionAppMCPCloseDrainsBlockedChildConfigurationWithExactlyOneCloseAndRelease(sendInsteadOfModels: Bool) async throws {
    let f = OwnedCodexFixture(supportsAppMCP: true), setup = OwnedCodexGate(), drain = OwnedCodexGate(), done = OwnedCodexTrace()
    await f.peer.holdAppMCP(setup); await f.peer.holdClose(drain)
    try await f.wrapper.configureAppMCP(ownedCodexAppMCPConnection())
    let pending = Task {
        if sendInsteadOfModels { try await f.wrapper.send(text: "Must never reach the child", thread: f.thread()) }
        else { _ = try await f.wrapper.models() }
    }
    var closing: Task<Void, Never>?
    do {
        try await ownedCodexEventually { await f.peer.calls.contains("configure-mcp") }
        closing = Task { await f.wrapper.close(); await done.add("closed") }
        try await ownedCodexEventually { await f.trace.entries.contains("close-first") }
        let beforeDrain = await done.entries, resourcesBeforeDrain = await f.broker.resourceReleases
        let callsBeforeDrain = await f.peer.calls, sendsBeforeDrain = await f.peer.sends
        #expect(beforeDrain.isEmpty && resourcesBeforeDrain.isEmpty)
        #expect(callsBeforeDrain == ["configure-mcp"] && sendsBeforeDrain.isEmpty)
        await drain.release(); await closing?.value
        await #expect(throws: (any Error).self) { try await pending.value }
        await f.wrapper.close()
        let closes = await f.peer.closeCount, calls = await f.peer.calls
        let tickets = await f.broker.ticketReleases, resources = await f.broker.resourceReleases
        #expect(closes == 1 && calls == ["configure-mcp"])
        #expect(tickets.count == 1 && tickets.values.allSatisfy { $0 == 1 })
        #expect(resources.count == 1 && resources.values.allSatisfy { $0 == 1 })
    } catch { await setup.release(); await drain.release(); _ = await pending.result; await f.close(); await closing?.value; throw error }
}

@Test(arguments: [false, true])
func codexOwnedSessionAppMCPUnsupportedChildIsDisposedBeforeModelOrUserCalls(sendInsteadOfModels: Bool) async throws {
    let f = OwnedCodexFixture()
    do {
        #expect(!f.peer.supportsAppMCP)
        try await f.wrapper.configureAppMCP(ownedCodexAppMCPConnection())
        await #expect(throws: MCPError(.unavailable)) {
            if sendInsteadOfModels { try await f.wrapper.send(text: "Must not be delivered", thread: f.thread()) }
            else { _ = try await f.wrapper.models() }
        }
        let calls = await f.peer.calls, sends = await f.peer.sends
        let closes = await f.peer.closeCount, tickets = await f.broker.ticketReleases, resources = await f.broker.resourceReleases
        #expect(calls.isEmpty && sends.isEmpty && closes == 1)
        #expect(tickets.count == 1 && tickets.values.allSatisfy { $0 == 1 })
        #expect(resources.count == 1 && resources.values.allSatisfy { $0 == 1 })
        await f.close()
        let finalCloses = await f.peer.closeCount, finalResources = await f.broker.resourceReleases
        #expect(finalCloses == 1 && finalResources == resources)
    } catch { await f.close(); throw error }
}
