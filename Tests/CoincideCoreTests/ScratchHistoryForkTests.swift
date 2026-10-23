import Foundation
import Testing
@testable import CoincideCore

private final class ScratchHistoryFactoryCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private struct ScratchHistoryForkFixture {
    let root: URL, database: URL
    let source: CodingThread, runIDs: [UUID]
    let allocation: ScratchWorkspaceAllocation
    let peer: HistoryEnginePeer
    let factoryCalls: ScratchHistoryFactoryCalls
    let engine: WorkspaceEngine
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-scratch-history-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            _ = try RemoteEnvironmentIdentity.load(dataDirectory: root, expected: nil)
            var f = RunHistoryFixture()
            let allocation = try ScratchWorkspaceService(dataRoot: root).prepare(commandID: UUID(), threadID: f.threadID,
                namingText: "Keep original history files", now: f.date.addingTimeInterval(-10))
            let project = allocation.project
            var source = CodingThread(project: project, model: "controlled-model")
            source.id = f.threadID; source.createdAt = allocation.receipt.createdAt
            source.workspacePath = allocation.workspacePath; source.scratchWorkspace = allocation.receipt
            source.checkpointPolicy = .disabled; source.permission = .supervised
            source.codexRuntimeConfiguration = .init(selection: .custom, executable: "/usr/bin/false", homeDirectory: root.appendingPathComponent("PrivateCodexHome").path)
            f.snapshot.projects = [project]; f.snapshot.threads = [source]
            var runs: [UUID] = []
            for index in 1...3 {
                let runID = UUID(); runs.append(runID)
                try f.submit("Exact source prompt \(index)", id: runID)
                if index == 1 { try f.connect(); try f.event(.thread("native-source")) }
                try f.event(.turn("native-\(index)"), runID: runID)
                try f.event(.delta(id: "source-reply-\(index)", role: .assistant, text: "Exact source response \(index)"), runID: runID)
                try f.event(.completed(.idle), runID: runID)
            }
            f.snapshot.threads[0].runtimeID = nil
            f.snapshot.threads[0].draft = "  Keep source draft e\u{301}\n "
            f.snapshot.threads[0].draftAttachments = [.init(id: UUID(), name: "keep.txt", mimeType: "text/plain", byteCount: 1,
                digest: String(repeating: "a", count: 64), fileExtension: "txt")]
            let database = root.appendingPathComponent("workspace.sqlite")
            try await WorkspaceDatabase(url: database).save(f.snapshot, event: "fixture.scratch-history")
            let peer = HistoryEnginePeer(workspace: URL(fileURLWithPath: allocation.workspacePath))
            let factoryCalls = ScratchHistoryFactoryCalls()
            let engine = try WorkspaceEngine(url: database, providerFactory: { thread in
                factoryCalls.record(); return HistoryEngineSession(peer: peer, thread: thread)
            }, identityResolver: { _ in nil })
            _ = try await engine.load()
            return .init(root: root, database: database, source: f.thread, runIDs: runs, allocation: allocation, peer: peer, factoryCalls: factoryCalls, engine: engine)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func review() async throws -> ConversationHistoryReview {
        try await engine.reviewConversationHistory(threadID: source.id, runID: runIDs[1], kind: .forkAfterRun)
    }
    func close() async { await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@Test(.timeLimit(.minutes(1)))
func scratchHistoryForkPersistsRealGrantThroughNativeEffectAndRecoversOriginalReceiptWithoutForkReplay() async throws {
    let f = try await ScratchHistoryForkFixture.make(), gate = HistoryEngineGate()
    do {
        await f.peer.configure(gate: gate)
        let file = URL(fileURLWithPath: f.source.workspacePath).appendingPathComponent("original-code.txt")
        try Data("keep original code e\u{301}\n".utf8).write(to: file)
        let review = try await f.review(), targetID = try #require(review.targetThreadID)
        let receipt = try await f.engine.beginConversationHistory(review, title: "Native scratch history fork")
        try await historyEngineEventually { await gate.entered }
        let pending = try #require(await f.engine.current().snapshot.conversationHistoryOperation(review.id))
        let grant = try #require(pending.scratchFork)
        #expect(grant.operationID == review.id && grant.allocation.receipt.commandID == receipt.commandID)
        #expect(grant.source == f.allocation.receipt && grant.allocation.threadID == targetID)
        #expect(grant.allocation.receipt.sharedFrom == f.allocation.receipt.commandID && grant.heldAcknowledgment == nil)
        let duplicate = try await f.engine.beginConversationHistory(review, title: "Native scratch history fork")
        #expect(duplicate == receipt)
        var changedPayloadRefused = false
        do { _ = try await f.engine.beginConversationHistory(review, title: "Changed title") } catch { changedPayloadRefused = true }
        #expect(changedPayloadRefused)
        await gate.release()
        try await historyEngineEventually { await f.engine.current().snapshot.conversationHistoryOperation(review.id)?.phase == .applied }
        let snapshot = await f.engine.current().snapshot
        let target = try #require(snapshot.threads.first { $0.id == targetID })
        let original = try #require(snapshot.threads.first { $0.id == f.source.id })
        let operation = try #require(snapshot.conversationHistoryOperation(review.id))
        #expect(target.scratchWorkspace == grant.allocation.receipt && target.createdAt == grant.allocation.receipt.createdAt)
        #expect(target.workspacePath.utf8.elementsEqual(original.workspacePath.utf8) && original == f.source)
        #expect(target.providerThreadID == operation.result?.reference.nativeThreadID && target.forkedFromHistoryOperationID == review.id)
        #expect(target.messages == review.prefix && target.activeRun == nil && target.draft.isEmpty && target.draftAttachments.isEmpty)
        try ScratchWorkspaceService(dataRoot: f.root).validate(thread: target)
        let mutations = await f.peer.mutations, sends = await f.peer.sends
        #expect(mutations.count == 1 && sends.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep original code e\u{301}\n")
        await f.engine.shutdown()
        let reopened = try WorkspaceEngine(url: f.database, providerFactory: { HistoryEngineSession(peer: f.peer, thread: $0) }, identityResolver: { _ in nil })
        do {
            let recovered = try await reopened.beginConversationHistory(review, title: "Native scratch history fork")
            #expect(recovered == receipt)
            let after = await f.peer.mutations
            #expect(after.count == 1)
        } catch { await reopened.shutdown(); throw error }
        await reopened.shutdown()
    } catch { await gate.release(); await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func scratchHistoryForkHoldsActualNativeAcknowledgmentWhenFolderOwnershipChangesBeforePublication() async throws {
    let f = try await ScratchHistoryForkFixture.make(), gate = HistoryEngineGate()
    do {
        await f.peer.configure(gate: gate)
        let review = try await f.review(), receipt = try await f.engine.beginConversationHistory(review)
        try await historyEngineEventually { await gate.entered }
        try FileManager.default.moveItem(atPath: f.source.workspacePath, toPath: f.source.workspacePath + "-original-owned")
        try FileManager.default.createDirectory(atPath: f.source.workspacePath, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let foreign = URL(fileURLWithPath: f.source.workspacePath).appendingPathComponent("foreign.txt")
        try Data("foreign bytes".utf8).write(to: foreign)
        await gate.release()
        try await historyEngineEventually { await f.engine.current().snapshot.conversationHistoryOperation(review.id)?.phase == .unconfirmed }
        let current = await f.engine.current(), operation = try #require(current.snapshot.conversationHistoryOperation(review.id))
        let acknowledgment = try #require(operation.scratchFork?.heldAcknowledgment)
        try review.validateResult(acknowledgment)
        #expect(current.error == nil && current.snapshot.threads.count == 1 && operation.result == nil)
        let recoveries = try await f.engine.scratchWorkspaceRecoveries()
        #expect(recoveries.first { $0.id == receipt.commandID }?.phase == .acceptedHistoryPending)
        #expect(acknowledgment.reference.nativeThreadID != review.sourceReference.nativeThreadID)
        let duplicate = try await f.engine.beginConversationHistory(review)
        let mutations = await f.peer.mutations
        #expect(duplicate == receipt && mutations.count == 1)
        #expect(try Data(contentsOf: foreign) == Data("foreign bytes".utf8))
        await f.engine.shutdown()
        let reopened = try WorkspaceEngine(url: f.database, providerFactory: { HistoryEngineSession(peer: f.peer, thread: $0) }, identityResolver: { _ in nil })
        do {
            let recovered = try await reopened.beginConversationHistory(review)
            let persisted = await reopened.current().snapshot.conversationHistoryOperation(review.id)
            #expect(recovered == receipt && persisted?.scratchFork?.heldAcknowledgment == acknowledgment && persisted?.phase == .unconfirmed)
            let after = await f.peer.mutations
            #expect(after.count == 1)
        } catch { await reopened.shutdown(); throw error }
        await reopened.shutdown()
    } catch { await gate.release(); await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [HistoryEnginePeer.Reply.lostBeforeMutation, .lostAfterMutation])
func scratchHistoryForkLostReplyRemainsUnconfirmedAcrossRestartWithoutAutomaticForkReplay(reply: HistoryEnginePeer.Reply) async throws {
    let f = try await ScratchHistoryForkFixture.make()
    do {
        await f.peer.configure(reply: reply)
        let review = try await f.review(), receipt = try await f.engine.beginConversationHistory(review)
        try await historyEngineEventually { await f.engine.current().snapshot.conversationHistoryOperation(review.id)?.phase == .unconfirmed }
        let operation = try #require(await f.engine.current().snapshot.conversationHistoryOperation(review.id))
        #expect(operation.scratchFork != nil && operation.scratchFork?.heldAcknowledgment == nil)
        #expect(await f.engine.current().snapshot.threads.count == 1)
        await f.engine.shutdown()
        let reopened = try WorkspaceEngine(url: f.database, providerFactory: { HistoryEngineSession(peer: f.peer, thread: $0) }, identityResolver: { _ in nil })
        do {
            let recovered = try await reopened.beginConversationHistory(review)
            let mutations = await f.peer.mutations
            #expect(recovered == receipt && mutations.count == 1)
        } catch { await reopened.shutdown(); throw error }
        await reopened.shutdown()
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func scratchHistoryRemoteForkUsesOriginalOuterUUIDAndActualSameFolderGrantThroughRestart() async throws {
    let f = try await ScratchHistoryForkFixture.make()
    await f.engine.shutdown()
    let options = RemoteEnvironmentOptions(codexExecutable: "/usr/bin/false", codexHome: f.root.appendingPathComponent("PrivateCodexHome").path,
        claudeExecutable: "/usr/bin/false", claudeConfigurationDirectory: f.root.appendingPathComponent("UnusedClaudeHome").path,
        githubExecutable: "/usr/bin/false", githubConfigurationDirectory: f.root.appendingPathComponent("UnusedGitHubHome").path)
    var host: RemoteEnvironmentService?
    do {
        let service = try RemoteEnvironmentService(dataDirectory: f.root, options: options, providerFactory: { HistoryEngineSession(peer: f.peer, thread: $0) })
        host = service
        let initial = try await service.snapshot(.init(environmentID: service.environmentID))
        let source = try #require(initial.workspace.threads.first { $0.id == f.source.id })
        let target = try await service.bindHistoryWorkspace(.init(environmentID: service.environmentID, projectID: source.projectID,
            threadID: source.id, configuration: .init(thread: source)))
        let review = try await service.reviewHistory(.init(target: target, runID: f.runIDs[1], kind: .forkAfterRun))
        let request = RemoteEnvironmentCommandRequest(environmentID: service.environmentID, id: UUID(),
            command: .history(target: target, action: .begin(reviewID: review.id, digest: review.digest, title: "Remote native scratch fork")))
        let accepted = try await service.command(request)
        try await historyEngineEventually {
            let state = try await service.snapshot(.init(environmentID: service.environmentID))
            return state.workspace.conversationHistoryOperation(review.id)?.phase == .applied
        }
        let snapshot = try await service.snapshot(.init(environmentID: service.environmentID))
        let operation = try #require(snapshot.workspace.conversationHistoryOperation(review.id))
        let grant = try #require(operation.scratchFork), child = try #require(snapshot.workspace.threads.first { $0.id == review.value.targetThreadID })
        #expect(grant.allocation.receipt.commandID == request.id && grant.operationID == review.id)
        #expect(child.scratchWorkspace == grant.allocation.receipt && child.workspacePath.utf8.elementsEqual(source.workspacePath.utf8))
        #expect(child.providerThreadID == operation.result?.reference.nativeThreadID && child.messages == operation.review.prefix)
        try ScratchWorkspaceService(dataRoot: f.root).validate(thread: child)
        let duplicate = try await service.command(request)
        #expect(duplicate == accepted)
        await service.close(); host = nil
        let reopened = try RemoteEnvironmentService(dataDirectory: f.root, options: options, providerFactory: { HistoryEngineSession(peer: f.peer, thread: $0) })
        host = reopened
        let recovered = try await reopened.command(request), receipt = try await reopened.receipt(request)
        #expect(recovered == accepted && receipt.receipt == accepted.receipt)
        let mutations = await f.peer.mutations
        #expect(mutations.count == 1)
    } catch { await host?.close(); await f.close(); throw error }
    await host?.close(); await f.close()
}

@Test(arguments: ["source", "destination", "operation", "outer-command"])
func scratchHistoryForkRejectsReboundGrantAndKeepsFlatLegacyCodecWithoutAllocatingAChild(change: String) async throws {
    let f = try await ScratchHistoryForkFixture.make()
    do {
        let review = try await f.review(), grantValue = try await f.engine.prepareScratchHistoryFork(review, commandID: review.id)
        let grant = try #require(grantValue), service = ScratchWorkspaceService(dataRoot: f.root)
        let invalid: ScratchHistoryForkGrant
        switch change {
        case "source":
            let other = try service.prepare(commandID: UUID(), threadID: UUID(), namingText: "Other owned root")
            invalid = .init(operationID: review.id, source: other.receipt, allocation: grant.allocation)
        case "destination":
            let other = try service.reuse(source: f.allocation.receipt, commandID: UUID(), threadID: UUID())
            invalid = .init(operationID: review.id, source: grant.source, allocation: other)
        case "operation": invalid = .init(operationID: UUID(), source: grant.source, allocation: grant.allocation)
        default:
            let other = try service.reuse(source: f.allocation.receipt, commandID: UUID(), threadID: grant.allocation.threadID)
            invalid = .init(operationID: review.id, source: grant.source, allocation: other)
        }
        let before = await f.engine.current().snapshot
        #expect(throws: ScratchWorkspaceError.self) {
            _ = try WorkspaceDecision.make(.conversationHistoryAccepted(review: review, title: nil, scratchFork: invalid),
                id: review.id, snapshot: before, now: .now)
        }
        let mutations = await f.peer.mutations
        #expect(mutations.isEmpty && before.threads.count == 1)
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(grant))
        #expect(encoded["storage"] == .null && encoded["operationID"] == .string(review.id.uuidString))
        let legacy = ConversationHistoryOperation(review: review)
        var object = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(legacy)).object ?? [:]
        object.removeValue(forKey: "scratchFork")
        let restored = try JSONDecoder().decode(ConversationHistoryOperation.self, from: JSONEncoder().encode(JSONValue.object(object)))
        #expect(restored == legacy && restored.scratchFork == nil)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func scratchHistoryKeepFilesRewindRefusesASwappedOwnedFolderBeforeAnyMetadataFactoryOrNativeMutation() async throws {
    let f = try await ScratchHistoryForkFixture.make()
    do {
        let review = try await f.engine.reviewConversationHistory(threadID: f.source.id, runID: f.runIDs[1], kind: .rewindBeforeRun)
        let factoryCount = f.factoryCalls.count
        #expect(review.files == nil)
        try FileManager.default.moveItem(atPath: f.source.workspacePath, toPath: f.source.workspacePath + "-original-owned")
        try FileManager.default.createDirectory(atPath: f.source.workspacePath, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let sentinel = URL(fileURLWithPath: f.source.workspacePath).appendingPathComponent("foreign.txt")
        let bytes = Data("Keep the foreign replacement byte-for-byte".utf8)
        try bytes.write(to: sentinel)
        await #expect(throws: WorkspaceCommandError.self) { _ = try await f.engine.beginConversationHistory(review) }
        #expect(f.factoryCalls.count == factoryCount)
        #expect(await f.peer.mutations.isEmpty)
        #expect(await f.peer.sends.isEmpty)
        #expect(try Data(contentsOf: sentinel) == bytes)
        let current = await f.engine.current()
        #expect(current.error == nil)
        #expect(current.snapshot.conversationHistoryOperation(review.id) == nil)
        #expect(current.snapshot.threads.count == 1)
        #expect(current.snapshot.threads[0].messages == f.source.messages)
        _ = try await f.engine.dispatch(.editThread(f.source.id, .draft("The workspace remains usable")))
    } catch { await f.close(); throw error }
    await f.close()
}
