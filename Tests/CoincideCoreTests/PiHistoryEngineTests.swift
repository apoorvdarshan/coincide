import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct PiNativeHistoryTrace: Sendable {
    var mutations = 0
    var promptSends = 0
    var candidateInspections = 0
    var originalInspections = 0
    var closedSessions = Set<UUID>()
    var durableCandidates: [PiHistoryCandidate] = []
    var advancedPastCandidates: [PiHistoryCandidate.Stage] = []
    var answeredRequests: [JSONValue] = []
    var responseEnteredRequests: [JSONValue] = []
}

/// Synthetic native state; Engine, SQLite admission and recovery are real. No
/// process, CLI, user namespace, credential or model is involved in these tests.
private actor PiNativeHistoryWorld {
    let root: URL
    let database: URL
    let runtime: PiRuntimeConfiguration
    private var graphs: [String: PiHistoryGraph]
    private var freshIntents: [String: PiFreshSessionIntent] = [:]
    private var results: [String: PiHistoryResult] = [:]
    private var trace = PiNativeHistoryTrace()
    private var mode = "normal"
    private var gateReleased = false
    private var held: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var requests: [UUID: (ApprovalRequest, CheckedContinuation<Void, any Error>, AsyncStream<ProviderEvent>.Continuation)] = [:]
    init(root: URL, database: URL, runtime: PiRuntimeConfiguration, graph: PiHistoryGraph, sourceFile: URL) {
        self.root = root; self.database = database; self.runtime = runtime; graphs = [sourceFile.path: graph]
    }
    func configure(_ value: String) { mode = value }
    func observations() -> PiNativeHistoryTrace { trace }
    func release() { gateReleased = true; let pending = held; held = [:]; for waiter in pending.values { waiter.resume() } }
    func snapshot(_ path: String) throws -> PiHistorySnapshot {
        guard let graph = graphs[path] else { throw ProviderHistoryError(.boundaryUnavailable) }
        return try makeSnapshot(graph, path: path, intent: freshIntents[path])
    }
    private func makeSnapshot(_ graph: PiHistoryGraph, path: String, intent: PiFreshSessionIntent? = nil) throws -> PiHistorySnapshot {
        let observation = try PiRuntimeEntryObservation(nativeSessionFile: path, nativeSessionID: graph.header.sessionID,
            leafID: graph.leafID, entries: graph.entries.map(PiHistoryEntryDescriptor.init))
        return try PiHistoryService(configuration: runtime, workerRootURL: root.appendingPathComponent("workers"))
            .snapshot(observation: observation, observedVersion: "0.80.5", freshIntent: intent)
    }
    private func durable(_ value: PiHistoryCandidate) async throws {
        let saved = try await WorkspaceDatabase(url: database).load()
        guard let operation = saved.conversationHistoryOperation(value.operationID), operation.phase == .dispatching,
              operation.piCandidates?.last == value,
              saved.threads.first(where: { $0.id == operation.review.sourceThreadID })?.providerThreadID == operation.review.sourceReference.nativeThreadID,
              operation.review.targetThreadID.map({ target in !saved.threads.contains(where: { $0.id == target }) }) ?? true else {
            throw CoincideError("A synthetic Pi provider step ran before its exact durable candidate.")
        }
        trace.durableCandidates.append(value)
    }
    private func hold(_ session: UUID) async throws {
        try Task.checkCancellation()
        guard !gateReleased else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { held[session] = $0 }
        } onCancel: { Task { await self.cancel(session) } }
        try Task.checkCancellation()
    }
    private func ask(_ session: UUID, sink: AsyncStream<ProviderEvent>.Continuation) async throws {
        let request = ApprovalRequest(id: .string("history-confirm-\(session)"), method: "pi/extension",
            params: .object(["method": .string("confirm"), "title": .string("Synthetic native fork confirmation"),
                "message": .string("This request belongs to this history worker only.")]))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requests[session] = (request, continuation, sink); sink.yield(.sessionApproval(request))
            }
        } onCancel: { Task { await self.cancel(session) } }
    }
    func respond(session: UUID, request: ApprovalRequest, allow: Bool) async throws {
        guard let pending = requests[session], pending.0 == request else { throw ProviderHistoryError(.invalidRequest) }
        trace.responseEnteredRequests.append(request.id)
        if mode == "question-held-response" {
            try await hold(session)
            guard requests[session]?.0 == request else { throw CancellationError() }
        }
        requests.removeValue(forKey: session)
        trace.answeredRequests.append(request.id); pending.2.yield(.sessionApprovalDismissed(request.id))
        if allow { pending.1.resume() } else { pending.1.resume(throwing: ProviderHistoryError(.outcomeUncertain)) }
    }
    func cancel(_ session: UUID) {
        held.removeValue(forKey: session)?.resume(throwing: CancellationError())
        if let pending = requests.removeValue(forKey: session) {
            pending.2.yield(.sessionApprovalDismissed(pending.0.id)); pending.1.resume(throwing: CancellationError())
        }
    }
    func close(_ session: UUID) { trace.closedSessions.insert(session); cancel(session) }
    func sent() { trace.promptSends += 1 }

    func apply(review: PiHistoryReviewEvidence, configuration: ProviderConfiguration, operationID: UUID,
               session: UUID, sink: AsyncStream<ProviderEvent>.Continuation,
               candidate callback: @escaping @Sendable (PiHistoryCandidate) async throws -> Void) async throws -> ProviderConversationSnapshot {
        try review.validate()
        guard review.operationID == operationID, let source = graphs[review.source.reference.nativeThreadID],
              try snapshot(review.source.reference.nativeThreadID) == review.source else { throw ProviderHistoryError(.historyChanged) }
        trace.mutations += 1
        if mode == "question" || mode == "question-held-response" { try await ask(session, sink: sink) }
        var candidates: [PiHistoryCandidate] = []
        let identity = configuration.piConfiguration?.runtimeIdentity ?? review.source.runtimeIdentity
        var parent = review.source.reference.nativeThreadID
        var operationDirectory: URL?
        if review.kind == .forkAfterRun {
            let directory = root.appendingPathComponent("worker-" + operationID.uuidString.lowercased())
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            operationDirectory = directory
            let candidateIdentity: PiRuntimeIdentity
            if mode == "foreign-runtime" {
                let foreign = try PiRuntimeConfiguration(instanceID: UUID(), executable: runtime.executable,
                    requestedExecutable: runtime.requestedExecutable, workspacePath: runtime.workspacePath,
                    registeredWorkspacePath: runtime.registeredWorkspacePath, homeDirectory: runtime.homeDirectory,
                    agentDirectory: runtime.agentDirectory, agentDirectorySelection: runtime.agentDirectorySelection)
                candidateIdentity = .init(instanceID: foreign.instanceID, executable: foreign.requestedExecutable, runtime: foreign)
            } else { candidateIdentity = identity }
            let reservation = try PiHistoryCandidate(operationID: operationID, stage: .reserved, runtimeIdentity: candidateIdentity,
                operationDirectory: directory.path, expectedParentSessionPath: parent,
                sourceInventoryDigest: mode == "forged-digest" ? String(repeating: "f", count: 64) : review.source.inventoryDigest,
                semanticDigest: review.semanticDigest)
            try await callback(reservation); try await durable(reservation)
            candidates.append(reservation); trace.advancedPastCandidates.append(.reserved)
            let initial = try create(source: source, mode: .cliFork, leaf: source.leafID, parent: parent, directory: directory,
                                     identity: identity, review: review)
            let learned = try PiHistoryCandidate(operationID: operationID, stage: .initialClone, runtimeIdentity: identity,
                operationDirectory: directory.path, nativeSessionFile: initial.reference.nativeThreadID,
                nativeSessionID: initial.observation.nativeSessionID, expectedParentSessionPath: parent,
                sourceInventoryDigest: review.source.inventoryDigest, semanticDigest: review.semanticDigest)
            try await callback(learned); try await durable(learned); candidates.append(learned)
            if mode == "hold-candidate" { try await hold(session) }
            trace.advancedPastCandidates.append(.initialClone); parent = initial.reference.nativeThreadID
        }
        let final: PiHistorySnapshot
        if review.cutUserEntryID != nil {
            let transformMode: PiHistoryForkTransform.Mode = review.retainedLeafID == nil ? .fresh : .branched
            let graph = try #require(graphs[parent])
            let next = try create(source: graph, mode: transformMode, leaf: review.retainedLeafID, parent: parent,
                directory: operationDirectory ?? root.appendingPathComponent("native"), identity: identity, review: review)
            let learned = try PiHistoryCandidate(operationID: operationID, stage: .finalBranch, runtimeIdentity: identity,
                operationDirectory: operationDirectory?.path, nativeSessionFile: next.reference.nativeThreadID,
                nativeSessionID: next.observation.nativeSessionID, expectedParentSessionPath: parent,
                sourceInventoryDigest: review.source.inventoryDigest, semanticDigest: review.semanticDigest)
            try await callback(learned); try await durable(learned); candidates.append(learned)
            if mode == "hold-final" { try await hold(session) }
            trace.advancedPastCandidates.append(.finalBranch); final = next
        } else { final = try snapshot(parent) }
        let selected = try #require(review.inputs.firstIndex { $0.runID == review.runID })
        let count = review.kind == .forkAfterRun ? selected + 1 : selected
        let result = try PiHistoryResult(operationID: operationID, source: review.source, snapshot: final,
            inputs: Array(review.inputs.prefix(count)), candidates: candidates, semanticDigest: review.semanticDigest)
        try review.validateResult(result); results[final.reference.nativeThreadID] = result
        if mode == "lost-result" { throw ProviderHistoryError(.outcomeUncertain) }
        return try .init(reference: result.reference, workspacePath: result.workspacePath, historyMode: .entryTree, pi: result)
    }
    private func create(source: PiHistoryGraph, mode: PiHistoryForkTransform.Mode, leaf: String?, parent: String,
                        directory: URL, identity: PiRuntimeIdentity, review: PiHistoryReviewEvidence) throws -> PiHistorySnapshot {
        let id = "synthetic-native-" + UUID().uuidString.lowercased(), file = directory.appendingPathComponent(id + ".jsonl")
        let rows: [JSONValue]
        switch mode {
        case .cliFork: rows = source.entries.map(\.raw)
        case .fresh: rows = []
        case .branched:
            guard let leaf else { throw ProviderHistoryError(.invalidRequest) }
            let branch = try source.branch(through: leaf)
            // This Engine peer has no labels. Label transforms are independently
            // compared with original source in PiHistoryForkTransformTests.
            guard branch.allSatisfy({ $0.kind != .label }) else { throw ProviderHistoryError(.invalidResponse) }
            rows = branch.map(\.raw)
        }
        let header: JSONValue = .object(["type": .string("session"), "version": .number(3), "id": .string(id),
            "timestamp": .string("2026-10-23T00:00:00.000Z"), "cwd": .string(runtime.workspacePath), "parentSession": .string(parent)])
        let graph = try PiHistoryGraph(header: header, entries: rows, leafID: rows.last?["id"].string)
        let transform = try PiHistoryForkTransform(source: source, mode: mode, retainedLeafID: leaf)
        try transform.validate(candidate: graph, expectedWorkspacePath: runtime.workspacePath, expectedParentSessionPath: parent)
        let intent: PiFreshSessionIntent?
        if mode == .fresh {
            guard case .freshSession(let intentID) = review.boundary else { throw ProviderHistoryError(.invalidRequest) }
            intent = try .init(id: intentID, operationID: review.operationID, runtimeIdentity: identity, nativeSessionFile: file.path,
                sourceNativeSessionFile: review.source.reference.nativeThreadID, originalNativeSessionID: id,
                sourceInventoryDigest: review.source.inventoryDigest, semanticDigest: review.semanticDigest)
        } else { intent = nil }
        if transform.requiresPersistedFile { try piEngineWrite([header] + rows, to: file) }
        graphs[file.path] = graph; freshIntents[file.path] = intent
        return try makeSnapshot(graph, path: file.path, intent: intent)
    }
    func inspect(review: PiHistoryReviewEvidence, candidate: PiHistoryCandidate, configuration: ProviderConfiguration) throws -> ProviderConversationSnapshot {
        trace.candidateInspections += 1
        guard mode != "unprovable-candidate", let path = candidate.nativeSessionFile,
              let result = results[path], result.candidates.last == candidate,
              try snapshot(review.source.reference.nativeThreadID) == review.source,
              try snapshot(path) == result.snapshot else { throw ProviderHistoryError(.historyChanged) }
        try review.validateResult(result)
        return try .init(reference: result.reference, workspacePath: result.workspacePath, historyMode: .entryTree, pi: result)
    }
    func inspectOriginal(_ expected: PiHistorySnapshot) throws -> PiHistorySnapshot {
        trace.originalInspections += 1
        return try PiHistoryService(configuration: runtime).inspectOriginal(expected: expected)
    }
}

private actor PiNativeHistorySession: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private let world: PiNativeHistoryWorld
    private let id = UUID()
    private var closed = false
    init(world: PiNativeHistoryWorld) { self.world = world; (events, sink) = AsyncStream.makeStream() }
    func models() -> [ProviderModel] { [] }
    func piHistoryEventBarrier(_ id: UUID) { sink.yield(.piHistoryBarrier(id)) }
    func piHistorySnapshot(threadID: String) async throws -> PiHistorySnapshot { try await world.snapshot(threadID) }
    func applyPiHistory(review: PiHistoryReviewEvidence, configuration: ProviderConfiguration, operationID: UUID,
        candidate: @escaping @Sendable (PiHistoryCandidate) async throws -> Void) async throws -> ProviderConversationSnapshot {
        try await world.apply(review: review, configuration: configuration, operationID: operationID, session: id, sink: sink, candidate: candidate)
    }
    func inspectPiHistoryCandidate(review: PiHistoryReviewEvidence, candidate: PiHistoryCandidate,
                                  configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot {
        try await world.inspect(review: review, candidate: candidate, configuration: configuration)
    }
    func inspectPiHistoryOriginal(expected: PiHistorySnapshot) async throws -> PiHistorySnapshot { try await world.inspectOriginal(expected) }
    func send(text: String, thread: CodingThread) async throws { await world.sent(); throw ProviderHistoryError(.unsupported) }
    func interrupt() async throws { await world.cancel(id) }
    func respond(_ request: ApprovalRequest, allow: Bool) async throws { try await world.respond(session: id, request: request, allow: allow) }
    func answer(_ request: ApprovalRequest, answers: [String: String]) async throws { throw ProviderHistoryError(.invalidRequest) }
    func close() async { guard !closed else { return }; closed = true; await world.close(id); sink.finish() }
}

private final class PiHistoryFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private struct PiNativeHistoryFixture {
    let root: URL
    let database: URL
    let nativeFile: URL
    let runtime: PiRuntimeConfiguration
    let originalBytes: Data
    let source: CodingThread
    let runIDs: [UUID]
    let openingIDs: [String]
    let world: PiNativeHistoryWorld
    let factoryCount: PiHistoryFactoryCounter
    let engine: WorkspaceEngine

    init(legacy: Bool = false, competingAlias: Bool = false, canonicalRegistration: Bool = false) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pi-history-engine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        root = URL(fileURLWithPath: try PiRuntimeConfiguration.physical(folder.path)); database = root.appendingPathComponent("workspace.sqlite")
        let native = root.appendingPathComponent("native")
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let sessionID = "original-native-" + UUID().uuidString.lowercased(); nativeFile = native.appendingPathComponent(sessionID + ".jsonl")
        let instance = UUID()
        // A registered app workspace follows Foundation's canonical spelling;
        // Pi's captured native cwd keeps its independently verified realpath.
        let registeredPath = canonicalRegistration ? root.standardizedFileURL.resolvingSymlinksInPath().path : root.path
        runtime = try .init(instanceID: instance, executable: root.appendingPathComponent("never-executed-pi").path,
            workspacePath: root.path, registeredWorkspacePath: registeredPath, homeDirectory: root.path, agentDirectory: root.appendingPathComponent(".pi/agent").path,
            agentDirectorySelection: .defaultHome(homeDirectory: root.path))
        let config = PiConfiguration(instanceID: instance, executable: runtime.requestedExecutable,
            model: .init(provider: "fixture", modelID: "current-model"), thinkingLevel: "high", runtime: legacy ? nil : runtime)
        let project = WorkspaceProject(path: registeredPath)
        var thread = CodingThread(project: project)
        thread.provider = .pi; thread.workspacePath = registeredPath; thread.providerThreadID = nativeFile.path
        thread.piConfiguration = config; thread.model = config.model?.catalogID ?? ""; thread.permission = .supervised
        thread.checkpointPolicy = .disabled; thread.isPinned = true; thread.draft = "Unsent latest draft 工作 😀"
        var rows: [JSONValue] = [], records: [ThreadRunRecord] = [], messages: [ChatMessage] = [], ids: [UUID] = [], openings: [String] = []
        var steerings: [PromptSteeringOperation] = []
        var parent: String?
        let identity = config.runtimeIdentity
        for index in 0..<3 {
            let id = UUID(), userID = "user-" + id.uuidString.lowercased(), nativeUser = "native-user-\(index)"
            let text = "Exact authored opening \(index) 工作", input = ProviderInput(text: text)
            ids.append(id); openings.append(nativeUser)
            let baseline = try PiRuntimeEntryObservation(nativeSessionFile: nativeFile.path, nativeSessionID: sessionID,
                leafID: parent, entries: rows.map { PiHistoryEntryDescriptor(try PiHistoryEntry(raw: $0)) })
            rows.append(piEngineMessage(id: nativeUser, parent: parent, role: "user", text: text)); parent = nativeUser
            let assistant = "native-assistant-\(index)"
            rows.append(piEngineMessage(id: assistant, parent: parent, role: "assistant", text: "Native answer \(index)")); parent = assistant
            var user = ChatMessage(id: userID, role: .user, text: text)
            user.runReference = .init(threadID: thread.id, runID: id); messages.append(user)
            var reply = ChatMessage(id: "reply-" + id.uuidString, role: .assistant, text: "Native answer \(index)")
            reply.runReference = user.runReference; messages.append(reply)
            let opening = try PiHistoryInputEvidence(clientMessageID: userID, inputDigest: PiHistoryInputEvidence.digest(input), kind: .opening)
            var mapped = [try PiHistoryInputEvidence(clientMessageID: userID, inputDigest: opening.inputDigest, kind: .opening, nativeUserEntryID: nativeUser)]
            if index == 0 {
                let steeringText = "Exact first-run steering 工作", steeringID = "steering-local-0", nativeSteer = "native-steering-0"
                rows.append(piEngineMessage(id: nativeSteer, parent: parent, role: "user", text: steeringText)); parent = nativeSteer
                rows.append(piEngineMessage(id: "native-steering-answer-0", parent: parent, role: "assistant", text: "Steering answer")); parent = "native-steering-answer-0"
                mapped.append(try .init(clientMessageID: steeringID, inputDigest: PiHistoryInputEvidence.digest(.init(text: steeringText)), kind: .steering, nativeUserEntryID: nativeSteer))
                var steer = ChatMessage(id: steeringID, role: .user, text: steeringText); steer.runReference = user.runReference; messages.append(steer)
                var answer = ChatMessage(id: "steering-reply-0", role: .assistant, text: "Steering answer"); answer.runReference = user.runReference; messages.append(answer)
            }
            var captured = ProviderConfiguration(thread: thread)
            captured.piConfiguration = .init(instanceID: instance, executable: runtime.requestedExecutable,
                model: .init(provider: "fixture", modelID: "historical-\(index)"), thinkingLevel: "low", runtime: legacy ? nil : runtime)
            captured.model = captured.piConfiguration?.model?.catalogID ?? ""
            if index == 0 {
                let steeringInput = QueuedTurn(id: UUID(), text: "Exact first-run steering 工作", configuration: captured,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_001), checkpointPolicy: .disabled)
                var operation = PromptSteeringOperation(threadID: thread.id, projectID: thread.projectID,
                    sourceIncarnation: UUID(), runtimeID: UUID(), runID: id, nativeThreadID: nativeFile.path,
                    target: .adapterRun(id), input: steeringInput, messageID: "steering-local-0",
                    configuration: captured, createdAt: steeringInput.createdAt, phase: .delivered)
                operation.receipt = try .init(target: .adapterRun(id))
                let rowIndex = try #require(messages.firstIndex { $0.id == operation.messageID })
                messages[rowIndex].promptSteeringID = operation.id
                messages[rowIndex].createdAt = steeringInput.createdAt
                steerings.append(operation)
            }
            var record = ThreadRunRecord(run: .init(id: id, configuration: captured, startedAt: Date(timeIntervalSince1970: Double(1_700_000_000 + index * 10))),
                origin: .user, userMessageID: userID)
            record.status = .completed; record.endedAt = record.startedAt.addingTimeInterval(1); record.endReason = .providerCompleted
            record.messageAttributionVersion = 1
            if !legacy {
                let preparation = try PiRunHistoryPreparation(runID: id, runtimeIdentity: identity, observedVersion: "0.80.5", openingInput: opening, baseline: baseline)
                let final = try PiRuntimeEntryObservation(nativeSessionFile: nativeFile.path, nativeSessionID: sessionID,
                    leafID: parent, entries: rows.map { PiHistoryEntryDescriptor(try PiHistoryEntry(raw: $0)) })
                record.pi = try .init(preparation: preparation, inputs: mapped, finalObservation: final, openingUserEntryID: nativeUser,
                    nativeUserEntryIDs: mapped.compactMap(\.nativeUserEntryID), captureStatus: .proven, terminalStatus: .completed)
            }
            records.append(record)
        }
        thread.messages = messages; thread.runHistory = records
        let header: JSONValue = .object(["type": .string("session"), "version": .number(3), "id": .string(sessionID),
            "cwd": .string(runtime.workspacePath), "timestamp": .string("2026-10-23T00:00:00.000Z")])
        try piEngineWrite([header] + rows, to: nativeFile)
        originalBytes = try Data(contentsOf: nativeFile)
        let graph = try PiHistoryGraph(header: header, entries: rows, leafID: parent)
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]; snapshot.promptSteerings = steerings
        if competingAlias {
            var alias = CodingThread(project: project)
            alias.provider = .pi; alias.piConfiguration = config; alias.model = thread.model; alias.providerThreadID = nativeFile.path
            alias.workspacePath = thread.workspacePath; alias.checkpointPolicy = .disabled; snapshot.threads.append(alias)
        }
        let db = try WorkspaceDatabase(url: database); _ = try await db.commit(snapshot, event: "offline.pi.history.seed", commandID: UUID())
        source = thread; runIDs = ids; openingIDs = openings
        world = .init(root: root, database: database, runtime: runtime, graph: graph, sourceFile: nativeFile)
        factoryCount = .init()
        let world = world, count = factoryCount
        engine = try WorkspaceEngine(url: database, providerFactory: { _ in count.increment(); return PiNativeHistorySession(world: world) }, identityResolver: { _ in nil })
        _ = try await engine.load()
    }
    func reopen() throws -> WorkspaceEngine {
        let world = world, count = factoryCount
        return try .init(url: database, providerFactory: { _ in count.increment(); return PiNativeHistorySession(world: world) }, identityResolver: { _ in nil })
    }
    func operation(_ id: UUID) async -> ConversationHistoryOperation? { await engine.current().snapshot.conversationHistoryOperation(id) }
    func currentSource() async throws -> CodingThread {
        let snapshot = await engine.current().snapshot
        return try #require(snapshot.threads.first { $0.id == source.id })
    }
    func finish() async { await engine.shutdown(); try? FileManager.default.removeItem(at: root) }
}

private func piEngineWrite(_ rows: [JSONValue], to file: URL) throws {
    var bytes = Data()
    for row in rows { bytes.append(try JSONEncoder().encode(row)); bytes.append(10) }
    try bytes.write(to: file, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
}
private func piEngineMessage(id: String, parent: String?, role: String, text: String) -> JSONValue {
    .object(["type": .string("message"), "id": .string(id), "parentId": parent.map(JSONValue.string) ?? .null,
        "timestamp": .string("2026-10-23T00:00:00.000Z"),
        "message": .object(["role": .string(role), "content": .string(text), "timestamp": .number(1_700_000_000_000)])])
}
private func piNativeHistoryEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private Pi history Engine boundary did not settle.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func piHistoryEnginePersistsEveryCandidateBeforeLaterProviderWorkAndForksTheWholeSteeredRunWithoutSending() async throws {
    let f = try await PiNativeHistoryFixture()
    do {
        await f.world.configure("hold-candidate")
        let review = try await f.engine.reviewConversationHistory(threadID: f.source.id, runID: f.runIDs[0], kind: .forkAfterRun)
        #expect(review.boundary == .beforePiUserEntry(f.openingIDs[1]) && review.reviewedHeadTurnID == nil && review.expectedResultHeadTurnID == nil)
        let evidence = try #require(review.pi)
        #expect(evidence.inputs.first?.nativeUserEntryIDs == [f.openingIDs[0], "native-steering-0"])
        try await f.engine.beginConversationHistory(review, title: "A whole Pi run")
        try await piNativeHistoryEventually { await f.world.observations().durableCandidates.count == 2 }
        let stored = try await WorkspaceDatabase(url: f.database).load()
        let pending = try #require(stored.conversationHistoryOperation(review.id)), initial = try #require(pending.piCandidates?.last)
        #expect(pending.phase == .dispatching && pending.piCandidates?.map(\.stage) == [.reserved, .initialClone])
        #expect(!stored.threads.contains { $0.id == review.targetThreadID } && initial.nativeSessionFile != f.nativeFile.path)
        let trace = await f.world.observations()
        #expect(trace.advancedPastCandidates == [.reserved] && trace.promptSends == 0)
        let latestDraft = "New draft while the exact native clone is held"
        try await f.engine.dispatch(.editThread(f.source.id, .draft(latestDraft)))
        let project = try #require(stored.projects.first)
        for path in [f.nativeFile.path, try #require(initial.nativeSessionFile)] {
            var alias = CodingThread(project: project)
            alias.provider = .pi; alias.piConfiguration = f.source.piConfiguration; alias.model = f.source.model
            alias.workspacePath = f.source.workspacePath; alias.providerThreadID = path; alias.checkpointPolicy = .disabled
            let proposed = alias
            await #expect(throws: WorkspaceCommandError.self) { try await f.engine.dispatch(.createThread(proposed)) }
        }
        await f.world.release()
        try await piNativeHistoryEventually { await f.operation(review.id)?.phase == .applied }
        let final = await f.engine.current().snapshot, operation = try #require(final.conversationHistoryOperation(review.id))
        let target = try #require(final.threads.first { $0.id == review.targetThreadID }), source = try await f.currentSource()
        #expect(operation.piCandidates?.map(\.stage) == [.reserved, .initialClone, .finalBranch] && operation.piControls == nil)
        #expect(target.providerThreadID == operation.result?.reference.nativeThreadID && target.providerThreadID != f.nativeFile.path)
        #expect(target.messages == review.prefix && target.messages.contains { $0.text == "Exact first-run steering 工作" })
        #expect(target.draft.isEmpty && target.activeRun == nil && target.queuedTurns.isEmpty && target.runHistory == nil)
        #expect(target.piConfiguration == review.targetConfiguration.piConfiguration && target.model == review.targetConfiguration.model)
        #expect(source.providerThreadID == f.nativeFile.path && source.messages == f.source.messages && source.runHistory == f.source.runHistory)
        #expect(source.draft == latestDraft)
        #expect(try Data(contentsOf: f.nativeFile) == f.originalBytes)
        let after = await f.world.observations()
        #expect(after.durableCandidates == operation.piCandidates && after.promptSends == 0 && after.mutations == 1)
        let db = try WorkspaceDatabase(url: f.database), rebuilt = try await db.rebuildProjection().snapshot
        #expect(rebuilt == final)
        let journal = try await db.journal(limit: 1_000)
        let versions = journal.compactMap { row -> ConversationHistoryOperation? in
            guard case .conversationHistoryOperationsReplaced(let values) = row.event else { return nil }
            return values?.first { $0.id == review.id }
        }
        let learned = try #require(versions.firstIndex { $0.piCandidates?.count == 3 && $0.phase == .dispatching })
        let applied = try #require(versions.firstIndex { $0.phase == .applied })
        #expect(learned < applied)
        try WorkspaceJournal.validate(final)
    } catch { await f.finish(); throw error }
    await f.finish()
}

@Test(.timeLimit(.minutes(1)))
func piHistoryEngineRepeatedNativeAdoptionPreservesImmutableOriginAndEntireOpeningPlusSteeringPrefix() async throws {
    let f = try await PiNativeHistoryFixture()
    var reopened: WorkspaceEngine?
    do {
        let first = try await f.engine.reviewConversationHistory(threadID: f.source.id, runID: f.runIDs[2], kind: .rewindBeforeRun)
        try await f.engine.beginConversationHistory(first)
        try await piNativeHistoryEventually { await f.operation(first.id)?.phase == .applied }
        let b = try await f.currentSource(), bID = try #require(b.providerThreadID)
        #expect(bID != f.nativeFile.path && b.activeHistoryRuns.map(\.id) == Array(f.runIDs.prefix(2)))
        #expect(b.runHistory?.allSatisfy { $0.providerThreadID == f.nativeFile.path && $0.turnIDs.isEmpty } == true)
        let bBytes = try Data(contentsOf: URL(fileURLWithPath: bID))
        let second = try await f.engine.reviewConversationHistory(threadID: f.source.id, runID: f.runIDs[1], kind: .rewindBeforeRun)
        let secondProof = try #require(second.pi)
        #expect(secondProof.source.reference.nativeThreadID == bID && secondProof.inputs.first?.nativeSessionFile == f.nativeFile.path)
        #expect(secondProof.inputs.first?.nativeUserEntryIDs == [f.openingIDs[0], "native-steering-0"])
        try await f.engine.beginConversationHistory(second)
        try await piNativeHistoryEventually { await f.operation(second.id)?.phase == .applied }
        let c = try await f.currentSource(), cID = try #require(c.providerThreadID)
        #expect(cID != bID && cID != f.nativeFile.path && c.activeHistoryRuns.map(\.id) == [f.runIDs[0]])
        #expect(c.draft == f.source.draft && c.piConfiguration == f.source.piConfiguration && c.permission == f.source.permission && c.isPinned)
        #expect(c.visibleMessages.map(\.text) == second.prefix.map(\.text))
        #expect(try Data(contentsOf: f.nativeFile) == f.originalBytes && Data(contentsOf: URL(fileURLWithPath: bID)) == bBytes)
        let third = try await f.engine.reviewConversationHistory(threadID: f.source.id, runID: f.runIDs[0], kind: .forkAfterRun)
        #expect(third.boundary == .head && third.pi?.inputs.first?.nativeSessionFile == f.nativeFile.path)
        try await f.engine.beginConversationHistory(third)
        try await piNativeHistoryEventually { await f.operation(third.id)?.phase == .applied }
        let saved = await f.engine.current().snapshot
        let target = try #require(saved.threads.first { $0.id == third.targetThreadID })
        #expect(target.messages == third.prefix && target.draft.isEmpty && target.activeRun == nil)
        let after = await f.world.observations(); #expect(after.mutations == 3 && after.promptSends == 0)
        await f.engine.shutdown()
        let restoredEngine = try f.reopen(); reopened = restoredEngine; let restored = try await restoredEngine.load()
        #expect(restored.threads.first { $0.id == f.source.id }?.providerThreadID == cID)
        #expect(restored.threads.first { $0.id == f.source.id }?.runHistory == c.runHistory)
        #expect(restored.conversationHistoryOperations == saved.conversationHistoryOperations)
        await restoredEngine.shutdown()
        let last = await f.world.observations(); #expect(last.mutations == 3 && last.promptSends == 0)
    } catch { await reopened?.shutdown(); await f.finish(); throw error }
    await f.finish()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func piHistoryEngineLostResultRestartNeverReplaysAndRequiresExactReadOnlyCandidateOrExplicitOriginal(keepOriginal: Bool) async throws {
    let f = try await PiNativeHistoryFixture()
    var reopened: WorkspaceEngine?
    do {
        await f.world.configure("lost-result")
        let review = try await f.engine.reviewConversationHistory(threadID: f.source.id, runID: f.runIDs[2], kind: .rewindBeforeRun)
        try await f.engine.beginConversationHistory(review)
        try await piNativeHistoryEventually { await f.operation(review.id)?.phase == .unconfirmed }
        let old = await f.operation(review.id), candidate = try #require(old?.piCandidates?.last), path = try #require(candidate.nativeSessionFile)
        let candidateBytes = try Data(contentsOf: URL(fileURLWithPath: path))
        await f.engine.shutdown()
        let engine = try f.reopen(); reopened = engine
        let recovered = try await engine.load(), before = await f.world.observations()
        #expect(recovered.conversationHistoryOperation(review.id)?.phase == .unconfirmed && recovered.conversationHistoryOperation(review.id)?.piControls == nil)
        #expect(recovered.threads.first { $0.id == f.source.id }?.providerThreadID == f.nativeFile.path && before.mutations == 1 && before.promptSends == 0)
        if keepOriginal {
            await f.world.configure("unprovable-candidate")
            await #expect(throws: (any Error).self) { try await engine.reconcileConversationHistory(operationID: review.id) }
            let original = try await engine.inspectPiOriginal(operationID: review.id)
            try await engine.keepPiOriginal(operationID: review.id, expected: original)
            let state = await engine.current().snapshot
            #expect(state.conversationHistoryOperation(review.id)?.phase == .failed && state.conversationHistoryOperation(review.id)?.error == ConversationHistoryOperation.piNotAdoptedMessage)
            #expect(state.threads.first { $0.id == f.source.id }?.providerThreadID == f.nativeFile.path)
            #expect(state.conversationHistoryOperation(review.id)?.piCandidates == old?.piCandidates)
            #expect(state.isPiHistoryScopeLocked(configuration: .init(thread: f.source), nativeThreadID: path))
        } else {
            await f.world.configure("normal")
            try await engine.reconcileConversationHistory(operationID: review.id)
            let state = await engine.current().snapshot
            #expect(state.conversationHistoryOperation(review.id)?.phase == .applied && state.threads.first { $0.id == f.source.id }?.providerThreadID == path)
            #expect(state.threads.first { $0.id == f.source.id }?.runHistory?.first?.pi == f.source.runHistory?.first?.pi)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == candidateBytes && Data(contentsOf: f.nativeFile) == f.originalBytes)
        let final = await f.world.observations(); #expect(final.mutations == 1 && final.promptSends == 0 && final.candidateInspections == 1)
        await engine.shutdown()
    } catch { await reopened?.shutdown(); await f.finish(); throw error }
    await f.finish()
}

@Test(.timeLimit(.minutes(1)), arguments: ["answer", "cancel", "shutdown"])
func piHistoryEngineLifecycleControlsStayOnExactWorkerAndCancelOrShutdownDrainsWithoutReplay(_ resolution: String) async throws {
    let f = try await PiNativeHistoryFixture()
    do {
        await f.world.configure("question")
        let review = try await f.engine.reviewConversationHistory(threadID: f.source.id, runID: f.runIDs[2], kind: .forkAfterRun)
        try await f.engine.beginConversationHistory(review)
        try await piNativeHistoryEventually { await f.operation(review.id)?.piControls?.requests.count == 1 }
        let pending = await f.operation(review.id), controls = try #require(pending?.piControls), request = try #require(controls.requests.first)
        let before = try await f.currentSource()
        #expect(before.runtimeRequests.isEmpty && before.activeRun == nil && before.providerThreadID == f.nativeFile.path)
        await #expect(throws: WorkspaceCommandError.self) {
            try await f.engine.respondPiHistory(operationID: review.id, sessionID: UUID(), requestID: request.id, response: .decision(true))
        }
        await #expect(throws: WorkspaceCommandError.self) {
            try await f.engine.respondPiHistory(operationID: review.id, sessionID: controls.sessionID, requestID: .string("foreign-request"), response: .decision(true))
        }
        await #expect(throws: WorkspaceCommandError.self) {
            try await f.engine.respondPiHistory(operationID: review.id, sessionID: controls.sessionID, requestID: request.id, response: .answers(["value": "not a confirm response"]))
        }
        let preAnswer = await f.world.observations(); #expect(preAnswer.answeredRequests.isEmpty && preAnswer.durableCandidates.isEmpty)
        if resolution == "answer" {
            try await f.engine.respondPiHistory(operationID: review.id, sessionID: controls.sessionID, requestID: request.id, response: .decision(true))
            try await piNativeHistoryEventually { await f.operation(review.id)?.phase == .applied }
            let after = await f.world.observations(); #expect(after.answeredRequests == [request.id] && after.promptSends == 0)
        } else if resolution == "cancel" {
            try await f.engine.cancelPiHistory(operationID: review.id)
            let cancelled = await f.operation(review.id), after = await f.world.observations()
            #expect(cancelled?.phase == .unconfirmed && cancelled?.piControls == nil && cancelled?.result == nil)
            #expect(!after.closedSessions.isEmpty && after.durableCandidates.isEmpty && after.answeredRequests.isEmpty)
        } else {
            await f.engine.shutdown()
            let restarted = try f.reopen(), recovered = try await restarted.load()
            #expect(recovered.conversationHistoryOperation(review.id)?.phase == .unconfirmed && recovered.conversationHistoryOperation(review.id)?.piControls == nil)
            await #expect(throws: WorkspaceCommandError.self) {
                try await restarted.respondPiHistory(operationID: review.id, sessionID: controls.sessionID, requestID: request.id, response: .decision(true))
            }
            await restarted.shutdown()
        }
        #expect(try Data(contentsOf: f.nativeFile) == f.originalBytes)
        let final = await f.world.observations(); #expect(final.mutations == 1 && final.promptSends == 0)
    } catch { await f.finish(); throw error }
    await f.finish()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func remoteHistoryPiWorkerResponseUsesOriginalReceiptAndHeldNativeIOStillAllowsExactCancel(holdResponse: Bool) async throws {
    let f = try await PiNativeHistoryFixture(canonicalRegistration: true)
    var workspace: RemoteWorkspaceService?, history: RemoteHistoryService?
    do {
        await f.world.configure(holdResponse ? "question-held-response" : "question")
        let hostRoot = f.root.appendingPathComponent("RemoteHost")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let environmentID = UUID(), files = try RemoteWorkspaceService(environmentID: environmentID, engine: f.engine, dataDirectory: hostRoot)
        workspace = files
        let source = try await f.currentSource()
        #expect(source.id == f.source.id && source.projectID == f.source.projectID)
        #expect(source.workspacePath.utf8.elementsEqual(URL(fileURLWithPath: source.workspacePath).standardizedFileURL.resolvingSymlinksInPath().path.utf8))
        let target = try await files.bindHistoryTarget(.init(environmentID: environmentID, projectID: source.projectID,
            threadID: source.id, configuration: .init(thread: source)))
        let service = RemoteHistoryService(environmentID: environmentID, engine: f.engine, workspace: files); history = service
        func request(_ action: RemoteHistoryAction) -> RemoteEnvironmentCommandRequest {
            .init(environmentID: environmentID, command: .history(target: target, action: action))
        }
        func perform(_ request: RemoteEnvironmentCommandRequest) async throws -> WorkspaceCommandReceipt {
            if let existing = try await f.engine.remoteEnvironmentReceipt(request) { await f.engine.awaitRemoteHistoryCompletion(request); return existing }
            let captured = try await service.prepare(request.command)
            if case .history(let value) = captured { try await files.admitHistoryScope(value.scope) }
            let receipt = try await f.engine.dispatchRemoteEnvironment(request, preparation: captured)
            if receipt.rejection == nil { await f.engine.awaitRemoteHistoryCompletion(request) }
            return receipt
        }
        let review = try await service.review(.init(target: target, runID: f.runIDs[2], kind: .forkAfterRun))
        let begin = request(.begin(reviewID: review.id, digest: review.digest, title: "Remote Pi fork")), accepted = try await perform(begin)
        #expect(accepted.commandID == begin.id && accepted.rejection == nil && begin.id != review.id)
        try await piNativeHistoryEventually { await f.operation(review.id)?.piControls?.requests.count == 1 }
        let read = try await service.read(.init(target: target, query: .operation(operationID: review.id)))
        guard case .operation(let operation) = read.value else { throw CoincideError("Missing remote Pi worker state") }
        let sessionID = try #require(operation.piSessionID), reference = try #require(operation.piRequests)
        let document = try await service.read(.init(target: target, query: .content(binding: operation.binding, reference: reference, offset: 0, cursor: nil)))
        guard case .content(let chunk) = document.value, chunk.complete else { throw CoincideError("Missing bounded worker question document") }
        let questions = try JSONDecoder().decode([RuntimeRequest].self, from: chunk.data), question = try #require(questions.first)
        #expect(questions.count == 1 && operation.operation.actions["respondPi"]?.allowed == true)
        await #expect(throws: RemoteHistoryFailure(.invalidTarget)) {
            _ = try await service.prepare(request(.respondPi(operationID: review.id, sessionID: UUID(), request: question.request, response: .decision(true))).command)
        }
        let foreign = ApprovalRequest(id: .string("foreign-request"), method: question.request.method, params: question.request.params)
        await #expect(throws: RemoteHistoryFailure(.invalidTarget)) {
            _ = try await service.prepare(request(.respondPi(operationID: review.id, sessionID: sessionID, request: foreign, response: .decision(true))).command)
        }
        let response = request(.respondPi(operationID: review.id, sessionID: sessionID, request: question.request, response: .decision(true)))
        let receipt = try await perform(response)
        #expect(receipt.commandID == response.id && receipt.rejection == nil)
        #expect(try await perform(response) == receipt)
        try await piNativeHistoryEventually { await f.world.observations().responseEnteredRequests == [question.id] }
        if holdResponse {
            let before = await f.world.observations()
            #expect(before.answeredRequests.isEmpty && before.durableCandidates.isEmpty)
            let saved = try await WorkspaceDatabase(url: f.database).load()
            #expect(saved.conversationHistoryOperation(review.id)?.piControls?.requests.first?.responding == true)
            let cancel = request(.cancelPi(operationID: review.id)), cancelled = try await perform(cancel)
            #expect(cancelled.commandID == cancel.id && cancelled.rejection == nil)
            #expect(try await perform(cancel) == cancelled)
            let after = await f.world.observations(), state = await f.operation(review.id)
            #expect(state?.phase == .unconfirmed && state?.piControls == nil && state?.result == nil)
            #expect(after.closedSessions.count > before.closedSessions.count && after.answeredRequests.isEmpty && after.durableCandidates.isEmpty)
            #expect(after.responseEnteredRequests == [question.id])
        } else {
            try await piNativeHistoryEventually { await f.operation(review.id)?.phase == .applied }
            let after = await f.world.observations()
            #expect(after.answeredRequests == [question.id] && after.responseEnteredRequests == [question.id])
        }
        #expect(try Data(contentsOf: f.nativeFile) == f.originalBytes)
        let trace = await f.world.observations(); #expect(trace.promptSends == 0 && trace.mutations == 1)
        #expect(try await WorkspaceDatabase(url: f.database).receipt(review.id) == nil)
        await service.close(); await files.close()
    } catch { await history?.close(); await workspace?.close(); await f.finish(); throw error }
    await f.finish()
}

@Test(.timeLimit(.minutes(1)))
func piHistoryEngineCancelAfterDurableCandidateStopsBeforeNextNativeStepAndKeepsKnownOrphan() async throws {
    let f = try await PiNativeHistoryFixture()
    do {
        await f.world.configure("hold-candidate")
        let review = try await f.engine.reviewConversationHistory(threadID: f.source.id, runID: f.runIDs[0], kind: .forkAfterRun)
        try await f.engine.beginConversationHistory(review)
        try await piNativeHistoryEventually { await f.world.observations().durableCandidates.count == 2 }
        try await f.engine.cancelPiHistory(operationID: review.id)
        let operation = await f.operation(review.id), trace = await f.world.observations()
        let learned = try #require(operation?.piCandidates?.last), path = try #require(learned.nativeSessionFile)
        #expect(operation?.phase == .unconfirmed && operation?.result == nil && operation?.piControls == nil)
        #expect(trace.advancedPastCandidates == [.reserved] && trace.durableCandidates.count == 2 && trace.promptSends == 0)
        #expect(!trace.closedSessions.isEmpty && FileManager.default.fileExists(atPath: path))
        let source = try await f.currentSource()
        #expect(source.providerThreadID == f.nativeFile.path && source.messages == f.source.messages && source.draft == f.source.draft)
        #expect(try Data(contentsOf: f.nativeFile) == f.originalBytes)
    } catch { await f.finish(); throw error }
    await f.finish()
}

@Test(.timeLimit(.minutes(1)), arguments: ["forged-digest", "foreign-runtime"])
func piHistoryEngineRefusesUntrustedCandidateBeforeFurtherProviderWorkWithoutInfrastructureFailure(_ mode: String) async throws {
    let f = try await PiNativeHistoryFixture()
    do {
        await f.world.configure(mode)
        let review = try await f.engine.reviewConversationHistory(threadID: f.source.id, runID: f.runIDs[0], kind: .forkAfterRun)
        try await f.engine.beginConversationHistory(review)
        try await piNativeHistoryEventually { await f.operation(review.id)?.isPending == false }
        let state = await f.engine.current(), operation = try #require(state.snapshot.conversationHistoryOperation(review.id)), trace = await f.world.observations()
        #expect(operation.result == nil && operation.piCandidates == nil && state.error == nil)
        #expect(trace.durableCandidates.isEmpty && trace.advancedPastCandidates.isEmpty && trace.promptSends == 0)
        let source = try await f.currentSource()
        #expect(source.providerThreadID == f.nativeFile.path && source.messages == f.source.messages && source.runHistory == f.source.runHistory)
        #expect(try Data(contentsOf: f.nativeFile) == f.originalBytes)
    } catch { await f.finish(); throw error }
    await f.finish()
}

@Test(.timeLimit(.minutes(1)), arguments: ["legacy", "alias"])
func piHistoryEngineLegacyProofAndCompetingNativeAliasAreRefusedBeforeAnyProviderConstruction(_ shape: String) async throws {
    let f = try await PiNativeHistoryFixture(legacy: shape == "legacy", competingAlias: shape == "alias")
    do {
        await #expect(throws: (any Error).self) {
            _ = try await f.engine.reviewConversationHistory(threadID: f.source.id, runID: f.runIDs[1], kind: .rewindBeforeRun)
        }
        let state = await f.engine.current(), trace = await f.world.observations()
        #expect(state.snapshot.conversationHistoryOperations == nil && state.error == nil && f.factoryCount.count == 0)
        #expect(trace.mutations == 0 && trace.promptSends == 0)
        #expect(try Data(contentsOf: f.nativeFile) == f.originalBytes)
    } catch { await f.finish(); throw error }
    await f.finish()
}

@Test(.timeLimit(.minutes(1)))
func piHistoryEngineFirstRunRewindRetainsExplicitFreshIntentAndRecallNeverAutoSendsOrOverwritesLatestDraft() async throws {
    let f = try await PiNativeHistoryFixture()
    do {
        let review = try await f.engine.reviewConversationHistory(threadID: f.source.id, runID: f.runIDs[0], kind: .rewindBeforeRun, recallPromptOnSuccess: true)
        guard case .freshPiSession(let intentID) = review.boundary else { Issue.record("The native first-user cut did not retain explicit empty context."); await f.finish(); return }
        let latest = "A later draft must survive this native rewind"
        try await f.engine.dispatch(.editThread(f.source.id, .draft(latest)))
        try await f.engine.beginConversationHistory(review)
        try await piNativeHistoryEventually { await f.operation(review.id)?.phase == .applied }
        let source = try await f.currentSource(), operation = await f.operation(review.id)
        let intent = try #require(source.piFreshSessionIntent)
        #expect(intent.id == intentID && intent.operationID == review.id && intent.sourceNativeSessionFile == f.nativeFile.path)
        #expect(source.providerThreadID == intent.nativeSessionFile && source.piFreshConsumerRunID == nil && source.activeRun == nil)
        #expect(!FileManager.default.fileExists(atPath: intent.nativeSessionFile) && source.visibleMessages.isEmpty)
        #expect(source.draft == latest && operation?.needsPromptRecall == true && operation?.recalledAt == nil)
        #expect(source.runHistory?.allSatisfy { $0.providerThreadID == f.nativeFile.path && $0.turnIDs.isEmpty } == true)
        try await f.engine.dispatch(.recallConversationHistoryPrompt(operationID: review.id))
        let recalled = try await f.currentSource(), recalledOperation = await f.operation(review.id)
        #expect(recalled.draft == latest + "\n\nExact authored opening 0 工作" && recalled.activeRun == nil && recalled.queuedTurns.isEmpty)
        #expect(recalledOperation?.recalledAt != nil && recalled.piFreshSessionIntent == intent)
        let trace = await f.world.observations(); #expect(trace.promptSends == 0 && trace.mutations == 1)
        #expect(try Data(contentsOf: f.nativeFile) == f.originalBytes)
    } catch { await f.finish(); throw error }
    await f.finish()
}
