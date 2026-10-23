import Foundation
import CSQLite
import Testing
@testable import CoincideCore

actor ContextTransferTestPeer {
    private(set) var inputs: [ProviderInput] = []
    private(set) var closes = 0
    var fail = false
    func configureFailure(_ value: Bool) { fail = value }
    func received(_ input: ProviderInput) throws {
        inputs.append(input)
        if fail { throw ProviderHistoryError(.outcomeUncertain) }
    }
    func closed() { closes += 1 }
}
actor ContextTransferTestSession: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    nonisolated let supportsAppMCP: Bool
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    let peer: ContextTransferTestPeer
    init(_ peer: ContextTransferTestPeer, supportsAppMCP: Bool = false) { self.peer = peer; self.supportsAppMCP = supportsAppMCP; (events, continuation) = AsyncStream.makeStream() }
    func configureAppMCP(_ connection: AppMCPConnection) async throws { guard supportsAppMCP else { throw MCPError(.unavailable) } }
    func models() async throws -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) async throws { try await send(input: .init(text: text), thread: thread) }
    func send(input: ProviderInput, thread: CodingThread) async throws {
        let id = try #require(thread.activeRun?.id)
        try await peer.received(input)
        for event in [ProviderEvent.thread(thread.providerThreadID ?? "portable-target"), .turn("turn-" + id.uuidString), .message(.init(role: .assistant, text: "Completed explicit input")), .completed(.idle)] {
            continuation.yield(.context(runID: id, event: event))
        }
    }
    func interrupt() async throws { }
    func respond(_ request: ApprovalRequest, allow: Bool) async throws { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) async throws { }
    func close() async { await peer.closed(); continuation.finish() }
}
struct ContextTransferCoreFixture {
    let root: URL, database: URL
    let engine: WorkspaceEngine, peer: ContextTransferTestPeer
    let native: HistoryEnginePeer
    let sourceID: UUID, runs: [UUID]
    static func make(nativeProvider: Bool = false, contextTools: Bool = false, supportsContextTools: Bool? = nil, giant: Bool = false) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-context-core-" + UUID().uuidString).standardizedFileURL.resolvingSymlinksInPath()
        var owned: WorkspaceEngine?
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var fixture = RunHistoryFixture(); let project = WorkspaceProject(path: root.path)
            fixture.snapshot.projects = [project]; fixture.snapshot.threads[0].projectID = project.id; fixture.snapshot.threads[0].workspacePath = root.path
            var ids: [UUID] = []
            for index in 1...3 {
                let id = UUID(); ids.append(id); try fixture.submit("Source prompt \(index)", id: id)
                if index == 1 { try fixture.connect(); try fixture.event(.thread("native-source")) }
                try fixture.event(.turn("native-\(index)"), runID: id)
                try fixture.event(.delta(id: "source-reply-\(index)", role: .assistant, text: giant && index == 1 ? String(repeating: "Archived public large body. ", count: 2_000) : "Source reply \(index)"), runID: id)
                try fixture.event(.completed(.idle), runID: id)
                let before = try ConversationHistoryFilesFixture.attempt(path: root.path, date: fixture.date)
                let after = try ConversationHistoryFilesFixture.attempt(path: root.path, date: fixture.date.addingTimeInterval(1))
                fixture.snapshot.threads[0].runHistory?[index - 1].checkpoints = .init(baseline: before, providerReleased: true)
                fixture.snapshot.threads[0].runHistory?[index - 1].checkpoints?.postRun = after
            }
            fixture.snapshot.threads[0].runtimeID = nil; fixture.snapshot.threads[0].draft = "Keep source composer"
            let database = root.appendingPathComponent("workspace.sqlite"), peer = ContextTransferTestPeer(), native = HistoryEnginePeer(workspace: root)
            try await WorkspaceDatabase(url: database).save(fixture.snapshot, event: "fixture")
            let engine = try WorkspaceEngine(url: database, contextMCPEnabled: contextTools, providerFactory: { thread in
                if nativeProvider { return HistoryEngineSession(peer: native, thread: thread) }
                return ContextTransferTestSession(peer, supportsAppMCP: supportsContextTools ?? contextTools)
            }, identityResolver: { _ in nil })
            owned = engine; _ = try await engine.load()
            return .init(root: root, database: database, engine: engine, peer: peer, native: native, sourceID: fixture.thread.id, runs: ids)
        } catch { await owned?.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }
    func source() async throws -> CodingThread { try #require(await engine.current().snapshot.threads.first { $0.id == sourceID }) }
    func portable(_ point: ContextTransferSourcePoint = .latestStable) async throws -> ContextTransferReview {
        let source = try await source(); var destination = ProviderConfiguration(thread: source)
        destination.provider = .opencode; destination.nativeThreadID = nil
        destination.openCodeConfiguration = .init(executable: "/offline-context-peer")
        destination.model = ""
        return try await engine.reviewContextTransfer(.init(sourceThreadID: source.id, expectedConfiguration: .init(thread: source), sourcePoint: point, intent: .fork(destination: destination)))
    }
    func close() async { await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}
func contextTransferEventually(_ operation: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try await !operation() { guard ContinuousClock.now < deadline else { throw CoincideError("Context transfer fixture did not reach its bounded durable state") }; await Task.yield() }
}

@Test func contextTransferLatestStableRequiresCurrentReadyAfterCheckpointAndExactOwnership() async throws {
    let f = try await ContextTransferCoreFixture.make()
    do {
        var snapshot = await f.engine.current().snapshot
        #expect(try snapshot.contextTransferSource(threadID: f.sourceID, point: .latestStable).runID == f.runs[2])
        let current = try #require(snapshot.threads[0].runHistory?[2].checkpoints?.postRun)
        let baseline = try #require(snapshot.threads[0].runHistory?[2].checkpoints?.baseline)
        #expect(throws: ContextTransferError.invalidSource) { try snapshot.contextTransferSource(threadID: f.sourceID, point: .checkpoint(runID: f.runs[2], attemptID: baseline.id, digest: ContextTransferProtocol.digest(baseline))) }
        #expect(try snapshot.contextTransferSource(threadID: f.sourceID, point: .checkpoint(runID: f.runs[2], attemptID: current.id, digest: ContextTransferProtocol.digest(current))).runID == f.runs[2])
        snapshot.threads[0].runHistory?[2].checkpoints?.previousPostRunAttempts = [current]
        snapshot.threads[0].runHistory?[2].checkpoints?.postRun = .init(workspacePath: f.root.path, phase: .failed)
        #expect(try snapshot.contextTransferSource(threadID: f.sourceID, point: .latestStable).runID == f.runs[1])
        #expect(throws: ContextTransferError.invalidSource) { try snapshot.contextTransferSource(threadID: f.sourceID, point: .checkpoint(runID: f.runs[2], attemptID: current.id, digest: ContextTransferProtocol.digest(current))) }
        snapshot.threads[0].runHistory?[2].status = .failed
        #expect(try snapshot.contextTransferSource(threadID: f.sourceID, point: .run(f.runs[2])).runID == f.runs[2])
        #expect(throws: ContextTransferError.invalidSource) { try snapshot.contextTransferSource(threadID: UUID(), point: .run(f.runs[2])) }
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1))) func contextTransferPortableCreationDoesNotSendAndOriginalUUIDCapturesOnlyNextExplicitInput() async throws {
    let f = try await ContextTransferCoreFixture.make()
    do {
        let review = try await f.portable(), id = UUID()
        let receipt = try await f.engine.acceptContextTransfer(reviewID: review.id, digest: review.digest, commandID: id)
        #expect(receipt.rejection == nil && receipt.commandID == id && id != review.id)
        #expect(try await f.engine.acceptContextTransfer(reviewID: review.id, digest: review.digest, commandID: id) == receipt)
        #expect(await f.peer.inputs.isEmpty)
        #expect(try await WorkspaceDatabase(url: f.database).receipt(review.id) == nil)
        let child = try #require(await f.engine.current().snapshot.threads.first { $0.id == review.targetThreadID })
        #expect(child.messages.isEmpty && child.runHistory == nil && child.activeRun == nil)
        #expect(child.contextTransferLineage?.basePoint == review.sourcePoint)
        #expect(try await f.source().draft == "Keep source composer")
        let laterModel = OpenCodeModelSelection(providerID: "offline", id: "later")
        _ = try await f.engine.dispatch(.editThread(child.id, .openCodeModel(.init(id: laterModel.catalogID, name: "Later chosen model", openCodeSelection: laterModel))))
        let inputID = UUID(); #expect(try await f.engine.dispatch(.submit(threadID: child.id, text: "Literal next input"), id: inputID).rejection == nil)
        try await contextTransferEventually { await f.engine.current().snapshot.contextTransfer(review.id)?.status == .consumed }
        let input = try #require(await f.peer.inputs.first)
        #expect(input.text == "Literal next input" && input.historicalContext?.transferIDs == [review.id])
        #expect(input.historicalContext?.selection.messages.contains { $0.text == "Source prompt 3" } == true)
        let saved = try #require(await f.engine.current().snapshot.threads.first { $0.id == child.id })
        #expect(saved.messages.first?.text == "Literal next input" && saved.runHistory?.first?.contextTransferIDs == [review.id])
        #expect(saved.runHistory?.first?.configuration.model == laterModel.catalogID)
        _ = try await f.engine.dispatch(.submit(threadID: child.id, text: "Second explicit input"))
        try await contextTransferEventually { await f.peer.inputs.count == 2 }
        #expect(await f.peer.inputs.last?.historicalContext == nil)
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func contextTransferUnknownDeliveryCannotReplayAndFreshContextPreservesAuditAndDraft(restart: Bool) async throws {
    let f = try await ContextTransferCoreFixture.make()
    var replacement: WorkspaceEngine?
    do {
        let review = try await f.portable(); _ = try await f.engine.acceptContextTransfer(reviewID: review.id, digest: review.digest)
        await f.peer.configureFailure(true)
        let inputID = UUID(); _ = try await f.engine.dispatch(.submit(threadID: review.targetThreadID, text: "Do not replay this"), id: inputID)
        try await contextTransferEventually { await f.engine.current().snapshot.contextTransfer(review.id)?.status == .uncertain }
        try await contextTransferEventually { await f.engine.current().snapshot.threads.first(where: { $0.id == review.targetThreadID })?.isBusy == false }
        let engine: WorkspaceEngine
        if restart {
            await f.engine.shutdown()
            let new = try WorkspaceEngine(url: f.database, providerFactory: { _ in ContextTransferTestSession(f.peer) }, identityResolver: { _ in nil })
            replacement = new; _ = try await new.load(); engine = new
        } else { engine = f.engine }
        #expect(await f.peer.inputs.count == 1)
        let refusedID = UUID()
        await #expect(throws: WorkspaceCommandError.self) { try await engine.dispatch(.submit(threadID: review.targetThreadID, text: "Blocked duplicate context"), id: refusedID) }
        #expect(try await WorkspaceDatabase(url: f.database).receipt(refusedID)?.rejection != nil)
        _ = try await engine.dispatch(.editThread(review.targetThreadID, .draft("Keep newest draft")))
        let uncertain = try #require(await engine.current().snapshot.contextTransfer(review.id)), delivery = try #require(uncertain.delivery)
        var captured = await engine.current().snapshot
        let targetIndex = try #require(captured.threads.firstIndex { $0.id == review.targetThreadID })
        var affected = review.targetConfiguration; affected.nativeThreadID = "retired-uncertain-native"
        var unrelated = affected; unrelated.nativeThreadID = "keep-other-native"
        var foreignProfile = affected; foreignProfile.openCodeConfiguration = .init(executable: "/different-owned-provider")
        captured.threads[targetIndex].providerThreadID = affected.nativeThreadID
        captured.threads[targetIndex].contextProviderBindings = [affected, unrelated, foreignProfile].map { .init(configuration: $0, knownItemIDs: [], updatedAt: Date()) }
        let fresh = try WorkspaceDecision.make(.client(.abandonContextTransfer(threadID: review.targetThreadID, deliveryID: delivery.id, expectedTransferIDs: [review.id])), id: UUID(), snapshot: captured, now: Date()).snapshot
        let keptBindings = fresh.threads[targetIndex].contextProviderBindings ?? []
        #expect(keptBindings.count == 2 && keptBindings.contains { ContextTransferProtocol.same($0.configuration, unrelated) })
        #expect(keptBindings.contains { ContextTransferProtocol.same($0.configuration, foreignProfile) })
        #expect(!keptBindings.contains { ContextTransferProtocol.same($0.configuration, affected) })
        await #expect(throws: WorkspaceCommandError.self) { try await engine.abandonContextTransfer(threadID: review.targetThreadID, deliveryID: UUID(), expectedTransferIDs: [review.id]) }
        let freshCommandID = UUID()
        let freshReceipt = try await engine.abandonContextTransfer(threadID: review.targetThreadID, deliveryID: delivery.id, expectedTransferIDs: [review.id], commandID: freshCommandID)
        #expect(freshReceipt.rejection == nil)
        let preserved = try #require(await engine.current().snapshot.contextTransfer(review.id))
        #expect(preserved.status == .uncertain && preserved.abandonedAt != nil && preserved.delivery?.authoredText == "Do not replay this")
        #expect(await engine.current().snapshot.threads.first { $0.id == review.targetThreadID }?.draft == "Keep newest draft")
        await f.peer.configureFailure(false)
        _ = try await engine.dispatch(.submit(threadID: review.targetThreadID, text: "Explicit fresh input"))
        try await contextTransferEventually { await f.peer.inputs.count == 2 }
        let sent = await f.peer.inputs
        #expect(sent.last?.text == "Explicit fresh input" && sent.last?.historicalContext == nil)
        let closesBeforeReceiptReplay = await f.peer.closes
        #expect(try await engine.abandonContextTransfer(threadID: review.targetThreadID, deliveryID: delivery.id, expectedTransferIDs: [review.id], commandID: freshCommandID) == freshReceipt)
        #expect(await f.peer.closes == closesBeforeReceiptReplay)
    } catch { await replacement?.shutdown(); await f.close(); throw error }
    await replacement?.shutdown(); await f.close()
}

@Test(.timeLimit(.minutes(1))) func contextTransferNativeForkIsDeferredUntilExplicitInputAndUsesExactSavedBoundary() async throws {
    let f = try await ContextTransferCoreFixture.make(nativeProvider: true)
    do {
        let source = try await f.source(); var destination = ProviderConfiguration(thread: source); destination.nativeThreadID = nil
        let review = try await f.engine.reviewContextTransfer(.init(sourceThreadID: source.id, expectedConfiguration: .init(thread: source), sourcePoint: .run(f.runs[0]), intent: .fork(destination: destination)))
        #expect(review.strategy == .nativeFork)
        #expect(await f.native.mutations.isEmpty); #expect(await f.native.sends.isEmpty)
        _ = try await f.engine.acceptContextTransfer(reviewID: review.id, digest: review.digest)
        #expect(await f.native.mutations.isEmpty); #expect(await f.native.sends.isEmpty)
        _ = try await f.engine.dispatch(.submit(threadID: review.targetThreadID, text: "Explicit fork input"))
        try await contextTransferEventually { await f.engine.current().snapshot.contextTransfer(review.id)?.status == .consumed }
        let mutations = await f.native.mutations, sends = await f.native.sends
        #expect(mutations.count == 1 && mutations.first?.boundary == .throughTurn("native-1"))
        #expect(await f.native.mutations.first?.owner == review.targetThreadID)
        #expect(sends.count == 1 && sends.first?.hasPrefix("native-fork-") == true)
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1))) func contextTransferMergeBackRequiresActualParentAndSupersedesOnlyUndeliveredOwnDelta() async throws {
    let f = try await ContextTransferCoreFixture.make()
    do {
        let fork = try await f.portable(); _ = try await f.engine.acceptContextTransfer(reviewID: fork.id, digest: fork.digest)
        let childInput = try await f.engine.dispatch(.submit(threadID: fork.targetThreadID, text: "Child-owned result")).commandID
        try await contextTransferEventually { await f.engine.current().snapshot.contextTransfer(fork.id)?.status == .consumed }
        try await contextTransferEventually { await f.engine.current().snapshot.threads.first(where: { $0.id == fork.targetThreadID })?.runHistory?.first(where: { $0.id == childInput })?.status == .completed }
        let child = try #require(await f.engine.current().snapshot.threads.first { $0.id == fork.targetThreadID }), parent = try await f.source()
        let childRun = childInput
        let request = ContextTransferReviewRequest(sourceThreadID: child.id, expectedConfiguration: .init(thread: child), sourcePoint: .run(childRun), intent: .mergeBack(targetConfiguration: .init(thread: parent)))
        let first = try await f.engine.reviewContextTransfer(request)
        #expect(first.strategy == .forkDeltaContext && first.targetThreadID == parent.id && first.basePoint == fork.sourcePoint)
        #expect(first.messages.contains { $0.text == "Child-owned result" })
        #expect(!first.messages.contains { $0.text == "Source prompt 1" || $0.text == "Source reply 3" })
        _ = try await f.engine.acceptContextTransfer(reviewID: first.id, digest: first.digest)
        var handoffDestination = ProviderConfiguration(thread: parent)
        handoffDestination.provider = .opencode; handoffDestination.nativeThreadID = nil; handoffDestination.model = ""
        handoffDestination.openCodeConfiguration = .init(executable: "/offline-context-peer")
        let capturedHandoff = try await f.engine.reviewContextTransfer(.init(sourceThreadID: parent.id, expectedConfiguration: .init(thread: parent), sourcePoint: .run(f.runs[2]), intent: .providerHandoff(destination: handoffDestination)))
        #expect(capturedHandoff.messages.contains { $0.text == "Child-owned result" })
        #expect(capturedHandoff.pendingSourceTransfers == [.init(id: first.id, digest: first.digest)])
        let newer = try await f.engine.reviewContextTransfer(request)
        _ = try await f.engine.acceptContextTransfer(reviewID: newer.id, digest: newer.digest)
        await #expect(throws: ContextTransferError.staleReview) { try await f.engine.acceptContextTransfer(reviewID: capturedHandoff.id, digest: capturedHandoff.digest) }
        #expect(try await f.source().provider == parent.provider)
        #expect(await f.engine.current().snapshot.contextTransfer(first.id)?.status == .superseded)
        #expect(await f.engine.current().snapshot.contextTransfer(newer.id)?.status == .pending)
        var foreign = ProviderConfiguration(thread: parent); foreign.model = "Wrong parent capture"
        await #expect(throws: ContextTransferError.unavailable) {
            try await f.engine.reviewContextTransfer(.init(sourceThreadID: child.id, expectedConfiguration: .init(thread: child), sourcePoint: .run(childRun), intent: .mergeBack(targetConfiguration: foreign)))
        }
        let before = await f.peer.inputs.count
        #expect(before == 1)
        _ = try await f.engine.dispatch(.submit(threadID: parent.id, text: "Explicit parent input"))
        try await contextTransferEventually { await f.engine.current().snapshot.contextTransfer(newer.id)?.status == .consumed }
        let input = try #require(await f.peer.inputs.last)
        #expect(input.text == "Explicit parent input" && input.historicalContext?.transferIDs == [newer.id])
        #expect(input.historicalContext?.selection.messages.contains { $0.text == "Child-owned result" } == true)
        #expect(input.historicalContext?.selection.messages.contains { $0.text == "Source prompt 1" } == false)
        #expect(await f.engine.current().snapshot.threads.first { $0.id == parent.id }?.providerThreadID == "native-source")
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1))) func contextTransferProviderHandoffStaysInSameConversationAndReturnsToKnownNativeContextWithDelta() async throws {
    let f = try await ContextTransferCoreFixture.make()
    do {
        let original = try await f.source(); var destination = ProviderConfiguration(thread: original)
        destination.provider = .opencode; destination.nativeThreadID = nil; destination.openCodeConfiguration = .init(executable: "/offline-context-peer")
        destination.model = ""
        let review = try await f.engine.reviewContextTransfer(.init(sourceThreadID: original.id, expectedConfiguration: .init(thread: original), intent: .providerHandoff(destination: destination)))
        #expect(review.targetThreadID == original.id && review.kind == .providerHandoff)
        _ = try await f.engine.acceptContextTransfer(reviewID: review.id, digest: review.digest)
        #expect(await f.engine.current().snapshot.threads.count == 1)
        #expect(try await f.source().draft == original.draft)
        #expect(await f.peer.inputs.isEmpty)
        let otherInput = try await f.engine.dispatch(.submit(threadID: original.id, text: "Other provider result")).commandID
        try await contextTransferEventually { await f.engine.current().snapshot.contextTransfer(review.id)?.status == .consumed }
        try await contextTransferEventually { await f.engine.current().snapshot.threads.first(where: { $0.id == original.id })?.runHistory?.first(where: { $0.id == otherInput })?.status == .completed }
        let other = try await f.source(), last = otherInput
        var returned = ProviderConfiguration(thread: original); returned.nativeThreadID = nil
        let returning = try await f.engine.reviewContextTransfer(.init(sourceThreadID: original.id, expectedConfiguration: .init(thread: other), sourcePoint: .run(last), intent: .providerHandoff(destination: returned)))
        #expect(returning.strategy == .deltaContext && returning.targetConfiguration.nativeThreadID == "native-source")
        #expect(returning.messages.contains { $0.text == "Other provider result" })
        #expect(!returning.messages.contains { $0.text == "Source prompt 1" })
        _ = try await f.engine.acceptContextTransfer(reviewID: returning.id, digest: returning.digest)
        _ = try await f.engine.dispatch(.submit(threadID: original.id, text: "Return explicitly"))
        try await contextTransferEventually { await f.engine.current().snapshot.contextTransfer(returning.id)?.status == .consumed }
        #expect(try await f.source().providerThreadID == "native-source")
        #expect(await f.engine.current().snapshot.threads.count == 1)
    } catch { await f.close(); throw error }; await f.close()
}

@Test(.timeLimit(.minutes(1)), arguments: ["discard", "configuration", "bytes", "close"])
func contextTransferReviewsRefuseChangedAuthorityWithoutProviderWork(change: String) async throws {
    let f = try await ContextTransferCoreFixture.make()
    do {
        let review = try await f.portable()
        switch change {
        case "discard": await f.engine.discardContextTransferReview(id: review.id, digest: review.digest)
        case "configuration": _ = try await f.engine.dispatch(.editThread(f.sourceID, .model("New source model")))
        case "close": await f.engine.closeContextTransfers()
        default:
            var altered = review; altered.digest = String(repeating: "0", count: 64)
            #expect(throws: ContextTransferError.staleReview) { try WorkspaceSnapshot().validateContextTransferReview(altered) }
            await f.engine.discardContextTransferReview(id: review.id, digest: review.digest)
        }
        await #expect(throws: ContextTransferError.staleReview) { try await f.engine.prepareContextTransferAcceptance(reviewID: review.id, digest: review.digest) }
        #expect(await f.peer.inputs.isEmpty)
        #expect(await f.engine.current().snapshot.contextTransfers?.isEmpty != false)
    } catch { await f.close(); throw error }; await f.close()
}

private final class ContextTransferWriterGate: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: OpaquePointer?
    init(_ url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else { if let database { sqlite3_close(database) }; throw CoincideError("Cannot open private context writer gate") }
        connection = database
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { sqlite3_close(database); connection = nil; throw CoincideError("Cannot hold private context writer gate") }
    }
    func release() throws {
        try lock.withLock {
            guard let connection else { return }
            guard sqlite3_exec(connection, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw CoincideError("Cannot release private context writer gate") }
            sqlite3_close(connection); self.connection = nil
        }
    }
    deinit { if let connection { sqlite3_exec(connection, "ROLLBACK", nil, nil, nil); sqlite3_close(connection) } }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func contextTransferAcceptanceFenceRetainsExactArchiveAcrossBlockedCommitDiscardDuplicateAndClose(closeDuringCommit: Bool) async throws {
    let f = try await ContextTransferCoreFixture.make()
    var gate: ContextTransferWriterGate?, first: Task<WorkspaceCommandReceipt, any Error>?, second: Task<WorkspaceCommandReceipt, any Error>?, closing: Task<Void, Never>?
    do {
        let review = try await f.portable(), id = UUID()
        gate = try .init(f.database)
        let one = Task { try await f.engine.acceptContextTransfer(reviewID: review.id, digest: review.digest, commandID: id) }; first = one
        let two = Task { try await f.engine.acceptContextTransfer(reviewID: review.id, digest: review.digest, commandID: id) }; second = two
        try await contextTransferEventually {
            let state = await f.engine.contextTransferAdmissionState(reviewID: review.id)
            return state.acceptances == 2 && state.committing
        }
        await f.engine.discardContextTransferReview(id: review.id, digest: review.digest)
        #expect(try await f.engine.prepareContextTransferAcceptance(reviewID: review.id, digest: review.digest) == review)
        if closeDuringCommit {
            closing = Task { await f.engine.closeContextTransfers() }
            try await contextTransferEventually { await f.engine.contextTransferAdmissionState(reviewID: review.id).closing }
        }
        try gate?.release(); gate = nil
        let receipt = try await one.value, duplicate = try await two.value
        #expect(receipt.rejection == nil && duplicate == receipt)
        await closing?.value
        let snapshot = await f.engine.current().snapshot
        #expect(snapshot.contextTransfers?.count == 1 && snapshot.contextTransfer(review.id)?.review == review)
        #expect(snapshot.threads.filter { $0.id == review.targetThreadID }.count == 1)
        #expect(await f.peer.inputs.isEmpty)
    } catch {
        try? gate?.release(); first?.cancel(); second?.cancel(); _ = try? await first?.value; _ = try? await second?.value; await closing?.value; await f.close(); throw error
    }
    await f.close()
}

@Test(.timeLimit(.minutes(1))) func contextTransferFrozenPriorPointSurvivesUnrelatedLaterStreamingAndQueuedRemovalReleasesOnlyUnsentReservation() async throws {
    let f = try await ContextTransferCoreFixture.make()
    do {
        let review = try await f.portable(.run(f.runs[0]))
        var snapshot = await f.engine.current().snapshot
        let sourceIndex = try #require(snapshot.threads.firstIndex { $0.id == f.sourceID })
        let later = UUID(), active = ActiveRun(id: later, configuration: .init(thread: snapshot.threads[sourceIndex]), startedAt: Date())
        snapshot.threads[sourceIndex].activeRun = active; snapshot.threads[sourceIndex].state = .running
        snapshot.threads[sourceIndex].beginRunRecord(active, origin: .user, userMessageID: "later-user", attributesMessages: true)
        var message = ChatMessage(id: "later-user", role: .user, text: "Later unrelated input"); message.runReference = .init(threadID: f.sourceID, runID: later)
        snapshot.threads[sourceIndex].messages.append(message)
        try snapshot.validateContextTransferReview(review)
        let accepted = try WorkspaceDecision.make(.contextTransferAccepted(review: review, title: nil), id: UUID(), snapshot: snapshot, now: Date())
        let submitID = UUID(), queued = try WorkspaceDecision.make(.client(.submitFromAppMCP(threadID: review.targetThreadID, text: "/tmp/foo is literal input", queueEvenWhenIdle: true)), id: submitID, snapshot: accepted.snapshot, now: Date())
        let child = try #require(queued.snapshot.threads.first { $0.id == review.targetThreadID }), item = try #require(child.queuedTurns.first)
        #expect(item.text == "/tmp/foo is literal input" && item.contextTransferIDs == [review.id])
        #expect(item.contextDelivery?.selection.messages.contains { $0.text == "Source prompt 1" } == true)
        #expect(item.contextDelivery?.selection.messages.contains { $0.text == "Later unrelated input" } == false)
        let edited = try WorkspaceDecision.make(.client(.editQueued(threadID: child.id, queuedID: submitID)), id: UUID(), snapshot: queued.snapshot, now: Date())
        #expect(edited.snapshot.contextTransfer(review.id)?.status == .pending && edited.snapshot.contextTransfer(review.id)?.targetRunID == nil)
        #expect(edited.snapshot.threads.first { $0.id == child.id }?.draft == "/tmp/foo is literal input")
        var recovered = queued.snapshot; recovered.recoverInterruptedWork()
        #expect(recovered.contextTransfer(review.id)?.status == .uncertain)
        #expect(throws: ContextTransferError.staleReview) { try WorkspaceDecision.make(.client(.removeQueued(threadID: child.id, queuedID: submitID)), id: UUID(), snapshot: recovered, now: Date()) }
        #expect(recovered.threads.first { $0.id == child.id }?.queuedTurns.count == 1)
    } catch { await f.close(); throw error }; await f.close()
}
