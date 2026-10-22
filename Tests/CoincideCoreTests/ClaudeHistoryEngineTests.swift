import Darwin
import Foundation
import Testing
@testable import CoincideCore

private final class ClaudeHistoryEngineLaunches: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func reject(_ thread: CodingThread) throws -> any ProviderSession {
        lock.withLock { calls += 1 }
        throw CoincideError("Offline native history must not construct a provider runtime.")
    }
}

private struct ClaudeHistoryEngineFixture: Sendable {
    let root: URL, workspace: URL, nativeProject: URL, database: URL, sourceFile: URL
    let runtime: ClaudeRuntimeConfiguration
    let nativeID: String
    let runIDs: [UUID]
    let assistantIDs: [String]
    let inheritedID: String?
    let source: CodingThread
    let initial: WorkspaceSnapshot
    let originalBytes: Data
    let launches: ClaudeHistoryEngineLaunches
    let engine: WorkspaceEngine

    init(inherited: Bool = false, competingAlias: Bool = false) async throws {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-history-engine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let pointer = requested.path.withCString({ realpath($0, nil) }) else { throw CoincideError("The private Engine fixture root is unavailable.") }
        let root = URL(fileURLWithPath: String(cString: pointer)); free(pointer)
        self.root = root
        do {
            workspace = root.appendingPathComponent("Workspace 工作 😀")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let config = root.appendingPathComponent("Private Claude Configuration")
            let runtime = ClaudeRuntimeConfiguration(executable: root.appendingPathComponent("claude-never-executed").path,
                configurationDirectory: config.path, workspacePath: workspace.path)
            self.runtime = runtime
            nativeProject = config.appendingPathComponent("projects").appendingPathComponent(runtime.projectKey)
            try FileManager.default.createDirectory(at: nativeProject, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let nativeID = UUID().uuidString.lowercased(); self.nativeID = nativeID
            sourceFile = nativeProject.appendingPathComponent(nativeID + ".jsonl")
            runIDs = (0..<3).map { _ in UUID() }; assistantIDs = (0..<3).map { _ in UUID().uuidString.lowercased() }
            let project = WorkspaceProject(path: workspace.path)
            var thread = CodingThread(project: project, model: "current-model")
            thread.workspacePath = workspace.path
            thread.provider = .claude; thread.providerThreadID = nativeID; thread.claudeRuntimeConfiguration = runtime
            var records: [JSONValue] = [], parent: String?
            var inheritedSnapshot: WorkspaceSnapshot?
            if inherited {
                let seeded = try await Self.forkedBase(project: project, workspace: workspace, runtime: runtime,
                    targetThreadID: thread.id, targetSessionID: nativeID)
                inheritedSnapshot = seeded.snapshot; thread = seeded.thread; records = seeded.records
                parent = seeded.head; inheritedID = seeded.head
            } else {
                inheritedID = nil
            }
            thread.model = "current-model"; thread.permission = .auto
            thread.draft = "Latest unsent source draft 工作 😀"; thread.isPinned = true
            thread.checkpointPolicy = .disabled; thread.queuePaused = true
            for index in runIDs.indices {
                let runID = runIDs[index], opening = ClaudeInputIdentity.opening(runID: runID)
                let now = Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 10))
                var configuration = ProviderConfiguration(thread: thread)
                configuration.model = "historical-model-\(index)"; configuration.permission = .supervised
                let active = ActiveRun(id: runID, configuration: configuration, startedAt: now)
                var run = ThreadRunRecord(run: active, origin: .user, userMessageID: "input-\(runID)")
                run.status = .completed; run.endedAt = now.addingTimeInterval(1); run.endReason = .providerCompleted; run.messageAttributionVersion = 1
                var observed = try #require(run.claude)
                try observed.observe(nativeSessionID: nativeID, inputIDs: [opening], rootAssistantMessageID: assistantIDs[index])
                try observed.finish(.completed); run.claude = observed
                if thread.runHistory == nil { thread.runHistory = [] }; thread.runHistory?.append(run)
                var input = ChatMessage(id: "input-\(runID)", role: .user, text: "Original prompt \(index) 工作")
                var reply = ChatMessage(id: "reply-\(runID)", role: .assistant, text: "Original answer \(index)")
                input.runReference = .init(threadID: thread.id, runID: runID); reply.runReference = input.runReference
                thread.messages += [input, reply]
                records.append(Self.record(id: opening, parent: parent, role: "user", text: input.text, session: nativeID, cwd: workspace.path))
                records.append(Self.record(id: assistantIDs[index], parent: opening, role: "assistant", text: reply.text, session: nativeID, cwd: workspace.path))
                parent = assistantIDs[index]
            }
            source = thread
            var snapshot = inheritedSnapshot ?? WorkspaceSnapshot(); snapshot.projects = [project]
            snapshot.threads.removeAll { $0.id == thread.id }; snapshot.threads.append(thread)
            if competingAlias {
                let alias = root.appendingPathComponent("Alias Workspace")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: workspace)
                var other = CodingThread(project: project); other.provider = .claude; other.workspacePath = alias.path
                other.providerThreadID = nativeID.uppercased(); other.checkpointPolicy = .disabled
                other.claudeRuntimeConfiguration = .init(executable: root.appendingPathComponent("another-never-executed-launcher").path,
                    configurationDirectory: runtime.configurationDirectory, workspacePath: runtime.workspacePath,
                    registeredWorkspacePath: alias.path)
                snapshot.threads.append(other)
            }
            initial = snapshot
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var bytes = Data()
            for record in records { bytes.append(try encoder.encode(record)); bytes.append(10) }
            originalBytes = bytes
            try bytes.write(to: sourceFile); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceFile.path)
            database = root.appendingPathComponent("workspace.sqlite")
            try await WorkspaceDatabase(url: database).save(snapshot, event: "offline.claude.history.engine.fixture")
            let launches = ClaudeHistoryEngineLaunches(); self.launches = launches
            engine = try Self.makeEngine(database: database, launches: launches)
            _ = try await engine.load()
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    static func record(id: String, parent: String?, role: String, text: String, session: String, cwd: String) -> JSONValue {
        .object(["type": .string(role), "uuid": .string(id), "sessionId": .string(session),
            "parentUuid": parent.map(JSONValue.string) ?? .null, "cwd": .string(cwd), "isSidechain": .bool(false),
            "timestamp": .string("2026-10-23T00:00:00.000Z"),
            "message": .object(["role": .string(role), "content": .string(text)])])
    }
    /// An inherited cursor is valid only with its applied native fork lineage.
    /// Build that fixture with the real service and reducer before adding any
    /// target-owned runs; a manually assigned head would not prove ownership.
    static func forkedBase(project: WorkspaceProject, workspace: URL, runtime: ClaudeRuntimeConfiguration,
                           targetThreadID: UUID, targetSessionID: String) async throws ->
        (snapshot: WorkspaceSnapshot, thread: CodingThread, records: [JSONValue], head: String) {
        let nativeID = UUID().uuidString.lowercased(), runID = UUID(), head = UUID().uuidString.lowercased()
        let opening = ClaudeInputIdentity.opening(runID: runID), now = Date(timeIntervalSince1970: 1_699_999_000)
        var ancestor = CodingThread(project: project)
        ancestor.workspacePath = workspace.path; ancestor.provider = .claude
        ancestor.providerThreadID = nativeID; ancestor.claudeRuntimeConfiguration = runtime; ancestor.checkpointPolicy = .disabled
        let configuration = ProviderConfiguration(thread: ancestor)
        var run = ThreadRunRecord(run: .init(id: runID, configuration: configuration, startedAt: now),
            origin: .user, userMessageID: "ancestor-input-\(runID)")
        run.status = .completed; run.endedAt = now.addingTimeInterval(1); run.endReason = .providerCompleted; run.messageAttributionVersion = 1
        var observed = try #require(run.claude)
        try observed.observe(nativeSessionID: nativeID, inputIDs: [opening], rootAssistantMessageID: head)
        try observed.finish(.completed); run.claude = observed; ancestor.runHistory = [run]
        var user = ChatMessage(id: "ancestor-input-\(runID)", role: .user, text: "Original inherited seed")
        var reply = ChatMessage(id: "ancestor-reply-\(runID)", role: .assistant, text: "Inherited native context")
        user.runReference = .init(threadID: ancestor.id, runID: runID); reply.runReference = user.runReference
        ancestor.messages = [user, reply]
        let rows = [record(id: opening, parent: nil, role: "user", text: user.text, session: nativeID, cwd: workspace.path),
                    record(id: head, parent: opening, role: "assistant", text: reply.text, session: nativeID, cwd: workspace.path)]
        let file = URL(fileURLWithPath: runtime.configurationDirectory).appendingPathComponent("projects")
            .appendingPathComponent(runtime.projectKey).appendingPathComponent(nativeID + ".jsonl")
        var bytes = Data()
        for row in rows { bytes.append(try JSONEncoder().encode(row)); bytes.append(10) }
        try bytes.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [ancestor]
        let service = try ClaudeHistoryService(configuration: runtime), nativeSource = try service.snapshot(sessionID: nativeID)
        let evidence = try ClaudeHistoryReviewEvidence.make(source: nativeSource, snapshot: snapshot, thread: ancestor,
            runID: runID, kind: .forkAfterRun)
        let incarnation = UUID()
        let review = try ConversationHistoryReview(kind: .forkAfterRun, sourceThreadID: ancestor.id, projectID: project.id,
            runID: runID, sourceIncarnation: incarnation, sourceConfiguration: configuration, targetConfiguration: configuration,
            sourceReference: nativeSource.reference, reviewedHeadTurnID: nil, boundary: evidence.boundary.providerBoundary,
            expectedResultHeadTurnID: nil, prefix: ancestor.messages, removedRunIDs: [], removedMessageIDs: [],
            sourceFingerprint: snapshot.historySourceFingerprint(threadID: ancestor.id), targetThreadID: targetThreadID,
            suggestedTitle: "Verified inherited native context", claude: evidence)
        snapshot = try WorkspaceDecision.make(.conversationHistoryAccepted(review: review, title: nil),
            id: review.id, snapshot: snapshot, now: now).snapshot
        snapshot = try WorkspaceDecision.make(.conversationHistoryDispatching(threadID: ancestor.id,
            operationID: review.id, incarnation: incarnation), id: UUID(), snapshot: snapshot, now: now).snapshot
        let plan = try service.prepareFork(review: evidence, targetSessionID: targetSessionID)
        snapshot = try WorkspaceDecision.make(.conversationHistoryClaudeForkReserved(operationID: review.id,
            publication: plan.publication, incarnation: incarnation), id: UUID(), snapshot: snapshot, now: now).snapshot
        let reserved = snapshot
        let result = try await service.publishFork(plan) { publication in
            guard reserved.conversationHistoryOperation(review.id)?.claudeForkPublication == publication else {
                throw CoincideError("The inherited fixture publication has no exact reducer reservation.")
            }
        }
        let providerResult = try ProviderConversationSnapshot(reference: result.reference, workspacePath: result.workspacePath,
            historyMode: .nativeTranscript, claude: result)
        snapshot = try WorkspaceDecision.make(.conversationHistoryEffectResult(.conversationHistory(threadID: ancestor.id,
            operationID: review.id), .conversationHistoryConfirmed(providerResult), incarnation: incarnation),
            id: UUID(), snapshot: snapshot, now: now).snapshot
        let target = try #require(snapshot.threads.first { $0.id == targetThreadID })
        let inherited = try #require(target.claudeInheritedHead)
        let store = try ClaudeTranscriptStore(configurationDirectory: URL(fileURLWithPath: runtime.configurationDirectory), workspace: workspace,
            projectDirectoryName: runtime.projectDirectoryName)
        let published = try store.read(sessionID: targetSessionID)
        return (snapshot, target, published.transcript.records, inherited.cursor)
    }
    static func makeEngine(database: URL, launches: ClaudeHistoryEngineLaunches) throws -> WorkspaceEngine {
        try .init(url: database, providerFactory: { try launches.reject($0) }, identityResolver: { _ in nil })
    }
    func operation(_ id: UUID) async -> ConversationHistoryOperation? { await engine.current().snapshot.conversationHistoryOperation(id) }
    func thread() async throws -> CodingThread {
        let snapshot = await engine.current().snapshot
        return try #require(snapshot.threads.first { $0.id == source.id })
    }
    func finish() async { await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}

private func waitClaudeHistoryEngine(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The offline Claude Engine boundary did not settle.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func claudeHistoryEngineForkPersistsReservedNativePublicationAndInheritedHeadWithoutProviderLaunch() async throws {
    let fixture = try await ClaudeHistoryEngineFixture()
    do {
        let review = try await fixture.engine.reviewConversationHistory(threadID: fixture.source.id, runID: fixture.runIDs[1], kind: .forkAfterRun)
        #expect(review.boundary == .throughClaudeMessage(fixture.assistantIDs[1]))
        #expect(fixture.launches.count == 0 && FileManager.default.fileExists(atPath: fixture.sourceFile.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.nativeProject.path) == [fixture.nativeID + ".jsonl"])
        try await fixture.engine.dispatch(.editThread(fixture.source.id, .draft("Newer source draft while reviewing")))
        let sourceBefore = try await fixture.thread()
        let receipt = try await fixture.engine.beginConversationHistory(review, title: "Verified Claude fork")
        #expect(receipt.commandID == review.id)
        try await waitClaudeHistoryEngine { await fixture.operation(review.id)?.phase == .applied }
        let snapshot = await fixture.engine.current().snapshot
        let operation = try #require(snapshot.conversationHistoryOperation(review.id)), publication = try #require(operation.claudeForkPublication)
        let target = try #require(snapshot.threads.first { $0.id == review.targetThreadID })
        #expect(target.providerThreadID == publication.target.sessionID && target.providerThreadID != fixture.nativeID)
        #expect(target.claudeInheritedHead?.cursor == publication.headMessageID && target.claudeInheritedHead == operation.result?.claude?.inheritedHead)
        #expect(target.claudeRuntimeConfiguration == fixture.runtime && target.claudeResumeSelection == nil)
        #expect(target.model == "historical-model-1" && target.permission == .supervised && target.draft.isEmpty)
        #expect(target.title == "Verified Claude fork" && target.messages == review.prefix && target.runHistory == nil)
        #expect(try await fixture.thread() == sourceBefore)
        #expect(try Data(contentsOf: fixture.sourceFile) == fixture.originalBytes && fixture.launches.count == 0)
        let database = try WorkspaceDatabase(url: fixture.database)
        let durable = try await database.load(), journal = try await database.journal(limit: 1_000)
        let versions = journal.compactMap { row -> ConversationHistoryOperation? in
            guard case .conversationHistoryOperationsReplaced(let operations) = row.event else { return nil }
            return operations?.first { $0.id == review.id }
        }
        let reserved = try #require(versions.firstIndex { $0.phase == .dispatching && $0.claudeForkPublication == publication })
        let applied = try #require(versions.firstIndex { $0.phase == .applied })
        #expect(reserved < applied && durable.conversationHistoryOperation(review.id)?.claudeForkPublication == publication)
        let fork = try ClaudeHistoryService(configuration: fixture.runtime).snapshot(sessionID: publication.target.sessionID)
        #expect(fork.headMessageID == target.claudeInheritedHead?.cursor && fork.selectedMessages.count == 4)
        let rebuilt = try await database.rebuildProjection().snapshot
        #expect(rebuilt == snapshot)
        try WorkspaceJournal.validate(snapshot)
    } catch { await fixture.finish(); throw error }
    await fixture.finish()
}

@Test(.timeLimit(.minutes(1)), arguments: ["fresh", "resume", "inherited"])
func claudeHistoryEngineRewindSavesDeferredContextAndKeepsNativeBytesSettingsAndLatestDraft(shape: String) async throws {
    let fixture = try await ClaudeHistoryEngineFixture(inherited: shape == "inherited")
    do {
        let index = shape == "resume" ? 1 : 0
        let review = try await fixture.engine.reviewConversationHistory(threadID: fixture.source.id, runID: fixture.runIDs[index], kind: .rewindBeforeRun)
        try await fixture.engine.dispatch(.editThread(fixture.source.id, .draft("Latest user text, never sent 工作 😀")))
        try await fixture.engine.beginConversationHistory(review)
        try await waitClaudeHistoryEngine { await fixture.operation(review.id)?.phase == .applied }
        let thread = try await fixture.thread(), observedOperation = await fixture.operation(review.id)
        let operation = try #require(observedOperation)
        let selection = try #require(thread.claudeResumeSelection)
        #expect(operation.result?.claude?.selection == selection && selection.id == review.id)
        #expect(thread.model == fixture.source.model && thread.permission == fixture.source.permission && thread.isPinned)
        #expect(thread.draft == "Latest user text, never sent 工作 😀" && thread.activeRun == nil && thread.claudeResumeConsumerRunID == nil)
        #expect(thread.visibleMessages == review.prefix && thread.runHistory?.count == 3)
        #expect(thread.runHistory?.map(\.configuration) == fixture.source.runHistory?.map(\.configuration))
        if shape == "fresh" {
            #expect(selection.kind == .freshSession && thread.providerThreadID == selection.nativeSessionID && selection.nativeSessionID != fixture.nativeID)
            #expect(selection.cursor == nil && !FileManager.default.fileExists(atPath: fixture.nativeProject.appendingPathComponent(selection.nativeSessionID + ".jsonl").path))
        } else {
            #expect(selection.kind == .resumeAt && thread.providerThreadID == fixture.nativeID)
            #expect(selection.cursor == (shape == "inherited" ? fixture.inheritedID : fixture.assistantIDs[0]))
            #expect(selection.discardedInputID == ClaudeInputIdentity.opening(runID: fixture.runIDs[index]))
        }
        #expect(try Data(contentsOf: fixture.sourceFile) == fixture.originalBytes && fixture.launches.count == 0)
        let native = try ClaudeHistoryService(configuration: fixture.runtime).snapshot(sessionID: fixture.nativeID)
        #expect(native.selectedMessages.count == (shape == "inherited" ? 8 : 6))
        try WorkspaceJournal.validate(await fixture.engine.current().snapshot)
    } catch { await fixture.finish(); throw error }
    await fixture.finish()
}

@Test(.timeLimit(.minutes(1)))
func claudeHistoryEngineRepeatedRewindBeforeExplicitSuccessorUsesEffectivePendingPrefix() async throws {
    let fixture = try await ClaudeHistoryEngineFixture()
    do {
        let first = try await fixture.engine.reviewConversationHistory(threadID: fixture.source.id, runID: fixture.runIDs[2], kind: .rewindBeforeRun)
        try await fixture.engine.beginConversationHistory(first)
        try await waitClaudeHistoryEngine { await fixture.operation(first.id)?.phase == .applied }
        let firstThread = try await fixture.thread()
        let initialSelection = try #require(firstThread.claudeResumeSelection)
        let second = try await fixture.engine.reviewConversationHistory(threadID: fixture.source.id, runID: fixture.runIDs[1], kind: .rewindBeforeRun)
        #expect(second.claude?.source.selection == initialSelection && second.claude?.source.records.count == 6)
        #expect(second.claude?.source.selectedMessages.count == 4 && second.boundary == .throughClaudeMessage(fixture.assistantIDs[0]))
        try await fixture.engine.beginConversationHistory(second)
        try await waitClaudeHistoryEngine { await fixture.operation(second.id)?.phase == .applied }
        let secondThread = try await fixture.thread()
        let selected = try #require(secondThread.claudeResumeSelection)
        #expect(selected.id == second.id && selected.id != initialSelection.id && selected.cursor == fixture.assistantIDs[0])
        #expect(try Data(contentsOf: fixture.sourceFile) == fixture.originalBytes && fixture.launches.count == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.nativeProject.path) == [fixture.nativeID + ".jsonl"])
        try WorkspaceJournal.validate(await fixture.engine.current().snapshot)
    } catch { await fixture.finish(); throw error }
    await fixture.finish()
}

@Test(.timeLimit(.minutes(1)))
func claudeHistoryEngineRefusesASecondHeaderWithTheSamePhysicalNativeScopeEvenThroughAliases() async throws {
    let fixture = try await ClaudeHistoryEngineFixture(competingAlias: true)
    do {
        await #expect(throws: (any Error).self) {
            _ = try await fixture.engine.reviewConversationHistory(threadID: fixture.source.id, runID: fixture.runIDs[1], kind: .forkAfterRun)
        }
        let current = await fixture.engine.current()
        #expect(fixture.launches.count == 0 && current.snapshot.conversationHistoryOperations == nil)
        #expect(try Data(contentsOf: fixture.sourceFile) == fixture.originalBytes)
    } catch { await fixture.finish(); throw error }
    await fixture.finish()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func claudeHistoryEngineRestartInspectsItsReservedForkWithoutPublishingAgain(publishedBeforeCrash: Bool) async throws {
    let fixture = try await ClaudeHistoryEngineFixture()
    var restarted: WorkspaceEngine?
    do {
        let review = try await fixture.engine.reviewConversationHistory(threadID: fixture.source.id,
            runID: fixture.runIDs[1], kind: .forkAfterRun)
        await fixture.engine.shutdown()
        let database = try WorkspaceDatabase(url: fixture.database)
        // Persist the real reducer's admission/dispatch/reservation transitions,
        // then simulate loss before the native result could reach the journal.
        func commit(_ command: EngineCommand, id: UUID = UUID()) async throws {
            let before = try await database.load()
            let decision = try WorkspaceDecision.make(command, id: id, snapshot: before, now: Date())
            _ = try await database.commit(decision.snapshot, event: "offline.claude.history.crash-window",
                commandID: id, effects: decision.effects)
        }
        try await commit(.conversationHistoryAccepted(review: review, title: "Recovered exact fork"), id: review.id)
        try await commit(.conversationHistoryDispatching(threadID: fixture.source.id,
            operationID: review.id, incarnation: review.sourceIncarnation))
        let service = try ClaudeHistoryService(configuration: fixture.runtime), evidence = try #require(review.claude)
        let plan = try service.prepareFork(review: evidence, targetSessionID: UUID().uuidString.lowercased())
        try await commit(.conversationHistoryClaudeForkReserved(operationID: review.id,
            publication: plan.publication, incarnation: review.sourceIncarnation))
        let target = fixture.nativeProject.appendingPathComponent(plan.publication.target.sessionID + ".jsonl")
        if publishedBeforeCrash {
            _ = try await service.publishFork(plan) { reservation in
                let saved = try await database.load()
                #expect(saved.conversationHistoryOperation(review.id)?.claudeForkPublication == reservation)
                #expect(!FileManager.default.fileExists(atPath: target.path), "Native bytes require an already durable exact reservation.")
            }
        }
        let bytesBefore: Data?
        if publishedBeforeCrash { bytesBefore = try Data(contentsOf: target) } else { bytesBefore = nil }
        let engine = try ClaudeHistoryEngineFixture.makeEngine(database: fixture.database, launches: fixture.launches)
        restarted = engine
        let recovered = try await engine.load()
        #expect(recovered.conversationHistoryOperation(review.id)?.phase == .unconfirmed)
        #expect(recovered.conversationHistoryOperation(review.id)?.claudeForkPublication == plan.publication)
        #expect(recovered.threads.count == fixture.initial.threads.count && fixture.launches.count == 0)
        let effects = try await database.effects()
        #expect(!effects.isEmpty && effects.allSatisfy { $0.status != .pending && $0.status != .running })
        try await engine.reconcileConversationHistory(operationID: review.id)
        let snapshot = await engine.current().snapshot, operation = try #require(snapshot.conversationHistoryOperation(review.id))
        #expect(operation.phase == (publishedBeforeCrash ? .applied : .failed))
        #expect(operation.claudeForkPublication == plan.publication && fixture.launches.count == 0)
        if publishedBeforeCrash {
            let adopted = try #require(snapshot.threads.first { $0.id == review.targetThreadID })
            #expect(adopted.providerThreadID == plan.publication.target.sessionID && adopted.claudeInheritedHead?.cursor == plan.publication.headMessageID)
            #expect(try Data(contentsOf: target) == bytesBefore)
        } else {
            #expect(!FileManager.default.fileExists(atPath: target.path) && !snapshot.threads.contains { $0.id == review.targetThreadID })
        }
        #expect(try Data(contentsOf: fixture.sourceFile) == fixture.originalBytes)
        try WorkspaceJournal.validate(snapshot)
    } catch { await restarted?.shutdown(); await fixture.finish(); throw error }
    await restarted?.shutdown(); await fixture.finish()
}
