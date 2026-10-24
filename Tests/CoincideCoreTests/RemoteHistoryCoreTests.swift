import CSQLite
import Foundation
import Testing
@testable import CoincideCore

private struct RemoteHistoryCoreFixture {
    let root: URL, database: URL
    let target: RemoteWorkspaceTarget
    let runs: [UUID]
    let engine: WorkspaceEngine
    let workspace: RemoteWorkspaceService
    let service: RemoteHistoryService
    let peer: HistoryEnginePeer
    let files: RestoreEnginePeer
    static func make(giant: Bool = false, checkpoints: Bool = false) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("coincide-remote-history-core-\(UUID().uuidString)")
        var owned: WorkspaceEngine?
        do {
            for name in ["Main", "Workspace", "Host"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            let directory = root.appendingPathComponent("Workspace"), project = WorkspaceProject(path: root.appendingPathComponent("Main").path)
            var seed = RunHistoryFixture(); seed.snapshot.projects = [project]
            seed.snapshot.threads[0].projectID = project.id; seed.snapshot.threads[0].workspacePath = directory.path
            var runs: [UUID] = []
            for index in 1...3 {
                let id = UUID(); runs.append(id); try seed.submit("Prompt \(index)", id: id)
                if index == 1 { try seed.connect(); try seed.event(.thread("native-source")) }
                try seed.event(.turn("native-\(index)"), runID: id)
                try seed.event(.delta(id: "reply-\(index)", role: .assistant,
                    text: giant && index == 1 ? String(repeating: "\"\\\n🌍\0", count: 80_000) : "Reply \(index)"), runID: id)
                try seed.event(.completed(.idle), runID: id)
            }
            seed.snapshot.threads[0].runtimeID = nil; seed.snapshot.threads[0].draft = "Keep private draft"
            if checkpoints {
                for index in seed.snapshot.threads[0].runHistory!.indices {
                    let date = seed.snapshot.threads[0].runHistory![index].startedAt
                    let before = try ConversationHistoryFilesFixture.attempt(path: directory.path, date: date)
                    let after = try ConversationHistoryFilesFixture.attempt(path: directory.path, date: date.addingTimeInterval(1))
                    seed.snapshot.threads[0].runHistory![index].checkpoints = .init(baseline: before, providerReleased: true)
                    seed.snapshot.threads[0].runHistory![index].checkpoints?.postRun = after
                }
            }
            try WorkspaceJournal.validate(seed.snapshot)
            let database = root.appendingPathComponent("workspace.sqlite"), peer = HistoryEnginePeer(workspace: directory), files = RestoreEnginePeer()
            try await WorkspaceDatabase(url: database).save(seed.snapshot, event: "fixture")
            let engine = try WorkspaceEngine(url: database, providerFactory: { HistoryEngineSession(peer: peer, thread: $0) },
                identityResolver: { _ in nil }, checkpointFactory: { _ in files })
            owned = engine; _ = try await engine.load()
            let id = UUID(), workspace = try RemoteWorkspaceService(environmentID: id, engine: engine, dataDirectory: root.appendingPathComponent("Host"))
            let target = try await workspace.bind(.init(environmentID: id, projectID: project.id, threadID: seed.thread.id, configuration: .init(thread: seed.thread)))
            return .init(root: root, database: database, target: target, runs: runs, engine: engine, workspace: workspace,
                service: RemoteHistoryService(environmentID: id, engine: engine, workspace: workspace), peer: peer, files: files)
        } catch { await owned?.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }
    func request(_ action: RemoteHistoryAction) -> RemoteEnvironmentCommandRequest {
        .init(environmentID: target.environmentID, command: .history(target: target, action: action))
    }
    func perform(_ request: RemoteEnvironmentCommandRequest) async throws -> WorkspaceCommandReceipt {
        if let existing = try await engine.remoteEnvironmentReceipt(request) { return existing }
        let captured = try await service.prepare(request.command)
        if case .history(let value) = captured { try await workspace.admitHistoryScope(value.scope) }
        return try await engine.dispatchRemoteEnvironment(request, preparation: captured)
    }
    func close() async { await files.release(); await service.close(); await workspace.close(); await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}

private final class RemoteHistorySQLiteWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: OpaquePointer?
    init(_ url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }; throw CoincideError("Cannot open owned SQLite gate")
        }
        connection = database
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(database); connection = nil; throw CoincideError("Cannot hold owned SQLite writer gate")
        }
    }
    func release() throws {
        try lock.withLock {
            guard let database = connection else { return }
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw CoincideError("Cannot release owned SQLite writer gate") }
            sqlite3_close(database); connection = nil
        }
    }
    deinit { if let connection { sqlite3_exec(connection, "ROLLBACK", nil, nil, nil); sqlite3_close(connection) } }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func remoteHistoryAcceptanceFenceProtectsSealedScratchAcrossBlockedCommitDuplicateAndClose(closeDuringCommit: Bool) async throws {
    let f = try await RemoteHistoryCoreFixture.make(checkpoints: true)
    var gate: RemoteHistorySQLiteWriteGate?, first: Task<WorkspaceCommandReceipt, any Error>?, second: Task<WorkspaceCommandReceipt, any Error>?, close: Task<Void, Never>?
    do {
        await f.files.configure(.uncertainBefore)
        let review = try await f.service.review(.init(target: f.target, runID: f.runs[1], kind: .rewindBeforeRun, files: .restore))
        let request = f.request(.begin(reviewID: review.id, digest: review.digest, title: nil))
        let prepared = try await f.service.prepare(request.command)
        if case .history(let captured) = prepared { try await f.workspace.admitHistoryScope(captured.scope) }
        gate = try .init(f.database)
        let one = Task { try await f.engine.dispatchRemoteEnvironment(request, preparation: prepared) }; first = one
        let two = Task { try await f.engine.dispatchRemoteEnvironment(request, preparation: prepared) }; second = two
        try await historyEngineEventually {
            let state = await f.engine.remoteHistoryAdmissionState(reviewID: review.id)
            return state.acceptances == 2 && state.committing
        }
        #expect(await f.engine.current().snapshot.conversationHistoryOperation(review.id) == nil)
        #expect(try await !f.service.discard(.init(target: f.target, reviewID: review.id, digest: review.digest)).discarded)
        #expect(await f.files.discarded.isEmpty)
        if closeDuringCommit {
            close = Task { await f.service.close() }
            try await historyEngineEventually {
                do { _ = try await f.engine.captureRemoteHistory(f.target); return false }
                catch { return true }
            }
            #expect(await f.files.discarded.isEmpty)
        }
        try gate?.release(); gate = nil
        let receipt = try await one.value, duplicate = try await two.value
        #expect(receipt == duplicate && receipt.commandID == request.id && receipt.rejection == nil)
        await close?.value
        try await historyEngineEventually { await f.engine.current().snapshot.conversationHistoryOperation(review.id)?.files?.phase == .unconfirmed }
        let state = await f.engine.remoteHistoryAdmissionState(reviewID: review.id)
        #expect(state.acceptances == 0)
        #expect(await f.files.discarded.isEmpty)
        #expect(await f.files.calls.count == 1)
        #expect(try await WorkspaceDatabase(url: f.database).receipt(review.id) == nil)
    } catch {
        try? gate?.release(); _ = await first?.result; _ = await second?.result; await close?.value
        await f.close(); throw error
    }
    await f.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func remoteHistoryOriginalUUIDReconcilesLostNativeResultWithoutRepeatingTheMutation(mutated: Bool) async throws {
    let f = try await RemoteHistoryCoreFixture.make()
    do {
        await f.peer.configure(reply: mutated ? .lostAfterMutation : .lostBeforeMutation)
        let review = try await f.service.review(.init(target: f.target, runID: f.runs[1], kind: .rewindBeforeRun))
        let request = f.request(.begin(reviewID: review.id, digest: review.digest, title: nil)), receipt = try await f.perform(request)
        #expect(receipt.commandID == request.id && receipt.rejection == nil && request.id != review.id)
        try await historyEngineEventually { await f.engine.current().snapshot.conversationHistoryOperation(review.id)?.phase == .unconfirmed }
        #expect(try await WorkspaceDatabase(url: f.database).receipt(review.id) == nil)
        #expect(try await f.perform(request) == receipt)
        let inspect = f.request(.inspectProvider(operationID: review.id)), inspected = try await f.perform(inspect)
        #expect(inspected.commandID == inspect.id && inspected.rejection == nil)
        #expect(try await f.perform(inspect) == inspected)
        let mutations = await f.peer.mutations, sends = await f.peer.sends
        #expect(mutations.count == 1 && sends.isEmpty)
        #expect(await f.engine.current().snapshot.conversationHistoryOperation(review.id)?.phase == (mutated ? .applied : .failed))
        #expect(await f.engine.current().snapshot.threads[0].draft == "Keep private draft")
        let read = try await f.service.read(.init(target: f.target, query: .operation(operationID: review.id)))
        let json = String(decoding: try RemoteHistoryProtocol.payload(read), as: UTF8.self)
        #expect(!json.contains("sourceFingerprint") && !json.contains("reviewedHeadTurnID") && !json.contains("removedMessageIDs"))
        #expect(try await !f.service.discard(.init(target: f.target, reviewID: review.id, digest: review.digest)).discarded)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)), arguments: ["configuration", "discard", "payload"])
func remoteHistoryPreparedAdmissionRefusesStaleAuthorityWithoutNativeMutation(change: String) async throws {
    let f = try await RemoteHistoryCoreFixture.make()
    do {
        let review = try await f.service.review(.init(target: f.target, runID: f.runs[1], kind: .forkAfterRun))
        let original = f.request(.begin(reviewID: review.id, digest: review.digest, title: nil))
        let captured = try await f.service.prepare(original.command)
        var request = original
        switch change {
        case "configuration": _ = try await f.engine.dispatch(.editThread(f.target.threadID, .model("Changed capture")))
        case "discard": #expect(try await f.service.discard(.init(target: f.target, reviewID: review.id, digest: review.digest)).discarded)
        default: request = f.request(.begin(reviewID: review.id, digest: String(repeating: "0", count: 64), title: nil))
        }
        let receipt = try await f.engine.dispatchRemoteEnvironment(request, preparation: captured)
        #expect(receipt.commandID == request.id && receipt.rejection != nil)
        let mutations = await f.peer.mutations, sends = await f.peer.sends
        #expect(mutations.isEmpty && sends.isEmpty)
        #expect(await f.engine.current().snapshot.conversationHistoryOperations?.isEmpty != false)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteHistoryLeasedGiantPrefixIsExactBoundedQueryPinnedAndExplicitlyReleased() async throws {
    let f = try await RemoteHistoryCoreFixture.make(giant: true)
    do {
        let review = try await f.service.review(.init(target: f.target, runID: f.runs[1], kind: .forkAfterRun))
        #expect(try RemoteHistoryProtocol.payload(review).count <= RemoteHistoryProtocol.maximumResultBytes)
        let read = try await f.service.read(.init(target: f.target, query: .prefix(binding: review.binding, newestFirst: false, cursor: nil)))
        guard case .messages(let page) = read.value else { throw CoincideError("Missing bounded prefix") }
        #expect(page.items.count == 4 && page.totalCount == 4 && page.complete)
        let reference = try #require(page.items.first(where: { $0.id == "reply-1" })?.text.content)
        var bytes = Data(), cursor: UUID?
        repeat {
            let request = RemoteHistoryReadRequest(target: f.target, query: .content(binding: review.binding, reference: reference, offset: bytes.count, cursor: cursor))
            let result = try await f.service.read(request)
            #expect(try await f.service.read(request) == result)
            #expect(try RemoteHistoryProtocol.payload(result).count <= RemoteHistoryProtocol.maximumResultBytes)
            guard case .content(let chunk) = result.value else { throw CoincideError("Missing bounded content") }
            bytes.append(chunk.data); cursor = chunk.nextCursor
            if let cursor {
                await #expect(throws: RemoteHistoryFailure(.staleCursor)) {
                    _ = try await f.service.read(.init(target: f.target, query: .paths(binding: review.binding, cursor: cursor)))
                }
            }
        } while cursor != nil
        #expect(bytes == Data(String(repeating: "\"\\\n🌍\0", count: 80_000).utf8))
        #expect(RemoteProjectionProtocol.digest(bytes) == reference.digest)
        let released = try await f.service.read(.init(target: f.target, query: .release(binding: review.binding)))
        #expect(released.value == .released(true))
        await #expect(throws: RemoteHistoryFailure(.staleReview)) { _ = try await f.service.read(.init(target: f.target, query: .prefix(binding: review.binding, newestFirst: false, cursor: nil))) }
        let mutations = await f.peer.mutations, sends = await f.peer.sends
        #expect(mutations.isEmpty && sends.isEmpty)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteHistoryCloseJoinsLateSealedFileReviewAndDisposesOnlyUnusedScratch() async throws {
    let f = try await RemoteHistoryCoreFixture.make(checkpoints: true), gate = RestoreEngineGate()
    var reading: Task<RemoteHistoryReview, any Error>?, closing: Task<Void, Never>?
    do {
        await f.files.holdReview(gate)
        let read = Task { try await f.service.review(.init(target: f.target, runID: f.runs[1], kind: .rewindBeforeRun, files: .restore)) }; reading = read
        try await historyEngineEventually { await gate.entered }
        let close = Task { await f.service.close() }; closing = close
        try await historyEngineEventually {
            do { _ = try await f.engine.captureRemoteHistory(f.target); return false }
            catch { return true }
        }
        await gate.release()
        await #expect(throws: (any Error).self) { _ = try await read.value }
        await close.value
        let reviewed = await f.files.reviewed, discarded = await f.files.discarded
        let calls = await f.files.calls, mutations = await f.peer.mutations
        #expect(reviewed.count == 1 && discarded == reviewed)
        #expect(calls.isEmpty && mutations.isEmpty)
    } catch { await gate.release(); _ = await reading?.result; await closing?.value; await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteHistoryAcceptedFileProofSurvivesDiscardAndMissingFolderAcknowledgementNeverRepeatsRestore() async throws {
    let f = try await RemoteHistoryCoreFixture.make(checkpoints: true)
    do {
        await f.files.configure(.uncertainBefore)
        let review = try await f.service.review(.init(target: f.target, runID: f.runs[1], kind: .rewindBeforeRun, files: .restore))
        let request = f.request(.begin(reviewID: review.id, digest: review.digest, title: nil))
        #expect(try await f.perform(request).rejection == nil)
        try await historyEngineEventually { await f.engine.current().snapshot.conversationHistoryOperation(review.id)?.files?.phase == .unconfirmed }
        #expect(try await !f.service.discard(.init(target: f.target, reviewID: review.id, digest: review.digest)).discarded)
        #expect(await f.files.discarded.isEmpty)
        try FileManager.default.removeItem(atPath: f.target.workspacePath)
        let metadataTarget = RemoteWorkspaceTarget(environmentID: f.target.environmentID, projectID: f.target.projectID,
            threadID: f.target.threadID, configuration: f.target.configuration)
        let acknowledge = RemoteEnvironmentCommandRequest(environmentID: f.target.environmentID,
            command: .history(target: metadataTarget, action: .acknowledgeFiles(operationID: review.id)))
        #expect(try await f.perform(acknowledge).rejection == nil)
        let operation = try #require(await f.engine.current().snapshot.conversationHistoryOperation(review.id))
        #expect(operation.phase == .applied && operation.files?.phase == .unconfirmed && operation.files?.acknowledgedAt != nil && !operation.locksFiles)
        #expect(await f.files.calls.count == 1)
        #expect(try await f.perform(acknowledge).commandID == acknowledge.id)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteHistoryRecallPayloadRemainsReadableAfterExactOriginalCommandMergesHostDraftOnce() async throws {
    let f = try await RemoteHistoryCoreFixture.make()
    do {
        let review = try await f.service.review(.init(target: f.target, runID: f.runs[1], kind: .rewindBeforeRun, recallPromptOnSuccess: true))
        #expect(try await f.perform(f.request(.begin(reviewID: review.id, digest: review.digest, title: nil))).rejection == nil)
        try await historyEngineEventually { await f.engine.current().snapshot.conversationHistoryOperation(review.id)?.needsPromptRecall == true }
        let recall = f.request(.recallPrompt(operationID: review.id)), receipt = try await f.perform(recall)
        #expect(receipt.commandID == recall.id && receipt.rejection == nil)
        #expect(try await f.perform(recall) == receipt)
        #expect(await f.engine.current().snapshot.threads[0].draft == "Keep private draft\n\nPrompt 2")
        let value = try await f.service.read(.init(target: f.target, query: .recall(operationID: review.id)))
        guard case .recall(let payload) = value.value else { throw CoincideError("Missing original recall payload") }
        #expect(payload.operationID == review.id && payload.runID == f.runs[1] && payload.text.preview == "Prompt 2" && payload.text.complete)
        #expect(await f.peer.sends.isEmpty)
    } catch { await f.close(); throw error }
    await f.close()
}
