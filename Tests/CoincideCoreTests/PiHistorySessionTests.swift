import Darwin
import Foundation
import Testing
@testable import CoincideCore

private actor PiOperationEvents {
    var requests: [ApprovalRequest] = []
    var barriers: [UUID] = []
    var proofs: [PiRunHistoryEvidence] = []
    var completed = 0
    func receive(_ event: ProviderEvent) {
        switch event {
        case .context(_, let nested): receive(nested)
        case .sessionApproval(let request): requests.append(request)
        case .sessionApprovalDismissed(let id): requests.removeAll { $0.id == id }
        case .piHistoryBarrier(let id): barriers.append(id)
        case .piHistoryEvidence(let proof): proofs.append(proof)
        case .completed: completed += 1
        default: break
        }
    }
}

private actor PiOperationCandidates {
    var values: [PiHistoryCandidate] = []
    var entered = false
    var gate: CheckedContinuation<Void, Never>?
    let heldStage: PiHistoryCandidate.Stage?
    init(heldStage: PiHistoryCandidate.Stage? = nil) { self.heldStage = heldStage }
    func record(_ value: PiHistoryCandidate) async {
        values.append(value)
        if value.stage == heldStage {
            entered = true
            await withCheckedContinuation { gate = $0 }
        }
    }
    func release() { gate?.resume(); gate = nil }
}

private struct PiOperationPeer {
    let root: URL
    let executable: URL
    let runtime: PiRuntimeConfiguration
    let configuration: PiConfiguration
    let session: PiSession
    let source: PiHistorySnapshot
    let workspace: WorkspaceSnapshot
    let thread: CodingThread
    let sourceBytes: Data
    let observed = PiOperationEvents()

    init(options: [String: JSONValue] = [:], metadataBeforeOpening: Bool = false) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pi-native-operations-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        root = URL(fileURLWithPath: try PiRuntimeConfiguration.physical(temporary.path))
        executable = root.appendingPathComponent("pi-history-peer")
        let fixture = try #require(Bundle.module.url(forResource: "pi_history_operations_rpc_server", withExtension: "py", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: fixture, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try JSONEncoder().encode(JSONValue.object(options)).write(to: root.appendingPathComponent("operations-options.json"))
        let instanceID = UUID()
        runtime = try .capture(workspacePath: root.path, executable: executable.path, instanceID: instanceID,
            environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"])
        configuration = .init(instanceID: instanceID, executable: executable.path, runtime: runtime)
        session = .init(executable: executable, cwd: root, configuration: configuration,
            historyWorkerRootURL: root.appendingPathComponent("workers"))
        let directory = root.appendingPathComponent("native")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("source.jsonl")
        let header: JSONValue = .object(["type": .string("session"), "version": .number(3), "id": .string("source-session"),
            "cwd": .string(root.path), "timestamp": .string("2026-01-01T00:00:00.000Z")])
        var entries: [JSONValue] = [], ends: [Int] = [], starts: [Int] = []
        func append(_ type: String, _ fields: [String: JSONValue]) {
            var value = fields
            value["type"] = .string(type); value["id"] = .string(String(format: "%08x", entries.count + 1))
            value["parentId"] = entries.last?["id"] ?? .null
            value["timestamp"] = .string("2026-01-01T00:00:00.000Z")
            entries.append(.object(value))
        }
        if metadataBeforeOpening { append("model_change", ["provider": .string("native"), "modelId": .string("baseline")]) }
        for ordinal in 1...3 {
            starts.append(entries.count)
            append("message", ["message": .object(["role": .string("user"), "content": .string("input \(ordinal)"), "timestamp": .number(1)])])
            append("message", ["message": .object(["role": .string("assistant"), "content": .string("answer \(ordinal)"), "stopReason": .string("stop"), "timestamp": .number(1)])])
            ends.append(entries.count)
            if ordinal == 1 { append("label", ["targetId": entries.last?["id"] ?? .null, "label": .string("original label")]) }
        }
        let firstAssistantID = entries[ends[0] - 1]["id"]
        append("label", ["targetId": firstAssistantID, "label": .string("updated label")])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = Data()
        for row in [header] + entries { bytes.append(try encoder.encode(row)); bytes.append(10) }
        try bytes.write(to: path); sourceBytes = bytes
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let graph = try PiHistoryGraph(header: header, entries: entries, leafID: entries.last?["id"].string)
        let observation = try PiRuntimeEntryObservation(nativeSessionFile: path.path, nativeSessionID: "source-session", leafID: graph.leafID,
            entries: graph.entries.map(PiHistoryEntryDescriptor.init))
        source = try PiHistoryService(configuration: runtime).snapshot(observation: observation, observedVersion: "0.80.5")
        let project = WorkspaceProject(path: root.path)
        var thread = CodingThread(project: project)
        thread.workspacePath = root.path; thread.provider = .pi; thread.piConfiguration = configuration
        thread.providerThreadID = path.path; thread.permission = .supervised; thread.checkpointPolicy = .disabled
        thread.runHistory = []
        for ordinal in 0..<3 {
            let runID = UUID(), messageID = "opening-\(runID.uuidString.lowercased())"
            let input = try PiHistoryInputEvidence(clientMessageID: messageID, inputDigest: PiHistoryInputEvidence.digest(.init(text: "input \(ordinal + 1)")), kind: .opening)
            let before = try PiRuntimeEntryObservation(nativeSessionFile: path.path, nativeSessionID: "source-session",
                leafID: starts[ordinal] == 0 ? nil : graph.entries[starts[ordinal] - 1].id,
                entries: Array(graph.entries.prefix(starts[ordinal])).map(PiHistoryEntryDescriptor.init))
            let after = try PiRuntimeEntryObservation(nativeSessionFile: path.path, nativeSessionID: "source-session",
                leafID: graph.entries[ends[ordinal] - 1].id, entries: Array(graph.entries.prefix(ends[ordinal])).map(PiHistoryEntryDescriptor.init))
            let preparation = try PiRunHistoryPreparation(runID: runID, runtimeIdentity: configuration.runtimeIdentity,
                observedVersion: "0.80.5", openingInput: input, baseline: before)
            let userID = graph.entries[starts[ordinal]].id
            var mapped = input; mapped.nativeUserEntryID = userID
            let proof = try PiRunHistoryEvidence(preparation: preparation, inputs: [mapped], finalObservation: after,
                openingUserEntryID: userID, nativeUserEntryIDs: [userID], captureStatus: .proven, terminalStatus: .completed)
            var record = ThreadRunRecord(run: .init(id: runID, configuration: .init(thread: thread), startedAt: .now), origin: .user, userMessageID: messageID)
            record.status = .completed; record.endedAt = .now; record.endReason = .providerCompleted
            record.pi = proof; record.messageAttributionVersion = 1
            thread.runHistory!.append(record)
            var row = ChatMessage(id: messageID, role: .user, text: "input \(ordinal + 1)")
            row.runReference = .init(threadID: thread.id, runID: runID); thread.messages.append(row)
        }
        self.thread = thread
        var workspace = WorkspaceSnapshot(); workspace.projects = [project]; workspace.threads = [thread]
        self.workspace = workspace
    }
    func review(kind: ConversationHistoryKind, selected: Int, operationID: UUID = UUID()) throws -> PiHistoryReviewEvidence {
        let review = try PiHistoryReviewEvidence.make(source: source, snapshot: workspace, thread: thread,
            runID: thread.runHistory![selected].id, kind: kind, operationID: operationID)
        try review.validateLedger(snapshot: workspace, thread: thread)
        return review
    }
    func frames() throws -> [JSONValue] {
        let path = root.appendingPathComponent("operations-wire.jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let bytes = try Data(contentsOf: path)
        guard let end = bytes.lastIndex(of: 10) else { return [] }
        return try bytes[...end].split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func set(_ key: String, _ value: JSONValue) throws {
        let path = root.appendingPathComponent("operations-options.json")
        var object = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: path)).object ?? [:]
        object[key] = value; try JSONEncoder().encode(JSONValue.object(object)).write(to: path, options: .atomic)
    }
    func assertDrained() throws {
        for row in try frames() where row["kind"] == .string("launch") {
            guard case .number(let raw) = row["pid"], let pid = Int32(exactly: raw) else { throw PiHistoryGraphError(.invalidGraph) }
            #expect(kill(pid, 0) != 0 && errno == ESRCH)
        }
    }
}

private func piOperationEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(6)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The private native Pi history peer did not reach its exact gate.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func withPiOperationPeer(_ options: [String: JSONValue] = [:], metadataBeforeOpening: Bool = false,
    _ body: (PiOperationPeer) async throws -> Void) async throws {
    let peer = try PiOperationPeer(options: options, metadataBeforeOpening: metadataBeforeOpening)
    let reader = Task { for await event in peer.session.events { await peer.observed.receive(event) } }
    do {
        try await body(peer)
        await peer.session.close(); await reader.value; try peer.assertDrained()
        #expect(try Data(contentsOf: URL(fileURLWithPath: peer.source.reference.nativeThreadID)) == peer.sourceBytes)
        try FileManager.default.removeItem(at: peer.root)
    } catch {
        await peer.session.close(); await reader.value
        try? FileManager.default.removeItem(at: peer.root); throw error
    }
}

@Test func piHistoryNativeHistoricalForkPublishesEveryCandidateBeforeFurtherNativeReadsAndDefersSelection() async throws {
    try await withPiOperationPeer { peer in
        let review = try peer.review(kind: .forkAfterRun, selected: 0)
        let candidates = PiOperationCandidates(heldStage: .initialClone)
        let operation = Task { try await peer.session.applyPiHistory(review: review, configuration: .init(thread: peer.thread), operationID: review.operationID) {
            await candidates.record($0)
        } }
        do {
            try await piOperationEventually { await candidates.entered }
            let frames = try peer.frames()
            #expect(!frames.contains { $0["type"] == .string("get_entries") || $0["type"] == .string("fork") })
            let stages = await candidates.values.map(\.stage)
            #expect(stages == [.reserved, .initialClone])
            await candidates.release()
            let result = try await operation.value
            let pi = try #require(result.pi)
            #expect(pi.candidates.map(\.stage) == [.reserved, .initialClone, .finalBranch])
            #expect(pi.inputs.map(\.runID) == [peer.thread.runHistory![0].id])
            #expect(pi.snapshot.reference != peer.source.reference)
            let targetGraph = try PiHistoryFileReader().read(filePath: pi.reference.nativeThreadID, expectedWorkspacePath: peer.runtime.workspacePath).graph
            #expect(targetGraph.entries.filter { $0.kind == .label }.count == 1)
            #expect(targetGraph.entries.last?.raw["label"] == .string("updated label"))
            let finalFrames = try peer.frames()
            #expect(finalFrames.filter { $0["type"] == .string("fork") }.count == 1)
            #expect(!finalFrames.contains { [.string("prompt"), .string("set_model"), .string("set_thinking_level")].contains($0["type"]) })
            let marker = UUID(); try await peer.session.piHistoryEventBarrier(marker)
            try await piOperationEventually { await peer.observed.barriers.contains(marker) }
            let recovered = try PiHistoryService(configuration: peer.runtime, workerRootURL: peer.root.appendingPathComponent("workers"))
                .inspectCandidate(review: review, candidate: pi.candidates.last!, configuration: .init(thread: peer.thread))
            #expect(recovered == pi)
        } catch { await candidates.release(); operation.cancel(); _ = try? await operation.value; throw error }
    }
}

@Test func piHistoryNativeHeadForkCopiesFullAppendInventoryAndPureLedgerNeverRereadsNativeFiles() async throws {
    try await withPiOperationPeer { peer in
        let review = try peer.review(kind: .forkAfterRun, selected: 2)
        let result = try await peer.session.applyPiHistory(review: review, configuration: .init(thread: peer.thread), operationID: review.operationID) { _ in }
        let pi = try #require(result.pi)
        #expect(pi.candidates.map(\.stage) == [.reserved, .initialClone])
        #expect(pi.snapshot.entries == peer.source.entries)
        let source = URL(fileURLWithPath: peer.source.reference.nativeThreadID)
        let saved = source.appendingPathExtension("held")
        try FileManager.default.moveItem(at: source, to: saved)
        do { try review.validateLedger(snapshot: peer.workspace, thread: peer.thread) }
        catch { try FileManager.default.moveItem(at: saved, to: source); throw error }
        try FileManager.default.moveItem(at: saved, to: source)
        var changed = peer.thread; changed.messages[0].text = "different authored input"
        #expect(throws: (any Error).self) { try review.validateLedger(snapshot: peer.workspace, thread: changed) }
    }
}

@Test(arguments: [false, true]) func piHistoryNativeRewindRoutesLifecycleDialogAndVetoWithoutPromptRecall(_ allow: Bool) async throws {
    try await withPiOperationPeer(["forkDialog": .bool(true)]) { peer in
        let review = try peer.review(kind: .rewindBeforeRun, selected: 1)
        let candidates = PiOperationCandidates()
        let operation = Task { try await peer.session.applyPiHistory(review: review, configuration: .init(thread: peer.thread), operationID: review.operationID) {
            await candidates.record($0)
        } }
        do {
            try await piOperationEventually { await peer.observed.requests.count == 1 }
            let request = try #require(await peer.observed.requests.first)
            #expect(try PiExtensionRequest.presentation(request).method == .confirm)
            #expect(await candidates.values.isEmpty)
            try await peer.session.respond(request, allow: allow)
            if allow {
                let result = try await operation.value
                #expect(result.pi?.candidates.map(\.stage) == [.finalBranch])
                #expect(result.pi?.inputs.count == 1)
            } else {
                do { _ = try await operation.value; Issue.record("A vetoed native fork was adopted.") }
                catch let error as ProviderHistoryError { #expect(error.kind == .boundaryUnavailable) }
                #expect(await candidates.values.isEmpty)
            }
            let frames = try peer.frames()
            #expect(!frames.contains { $0["kind"] == .string("cliClone") || $0["type"] == .string("prompt") })
            #expect(frames.filter { $0["type"] == .string("extension_ui_response") }.count == 1)
        } catch { operation.cancel(); await peer.session.close(); _ = try? await operation.value; throw error }
    }
}

@Test(arguments: ["loseForkACK", "wakeBeforeForkACK"]) func piHistoryNativeLostForkReplyOrWakeStaysUnconfirmedAndNeverRetries(_ mode: String) async throws {
    try await withPiOperationPeer([mode: .bool(true)]) { peer in
        let review = try peer.review(kind: .forkAfterRun, selected: 0)
        let candidates = PiOperationCandidates()
        do {
            _ = try await peer.session.applyPiHistory(review: review, configuration: .init(thread: peer.thread), operationID: review.operationID) {
                await candidates.record($0)
            }
            Issue.record("A lost or woken native history mutation was adopted.")
        } catch let error as ProviderHistoryError { #expect(error.kind == .outcomeUncertain) }
        #expect(await candidates.values.map(\.stage) == [.reserved, .initialClone])
        let frames = try peer.frames()
        #expect(frames.filter { $0["type"] == .string("fork") }.count == 1)
        do {
            _ = try await peer.session.applyPiHistory(review: review, configuration: .init(thread: peer.thread), operationID: review.operationID) { _ in }
            Issue.record("An uncertain native history operation was repeated.")
        } catch { }
        #expect(try peer.frames().filter { $0["type"] == .string("fork") }.count == 1)
    }
}

@Test func piHistoryNativeFirstUserResetRetainsEmptyIntentThenBindsActualMissingFileReopenBeforePrompt() async throws {
    try await withPiOperationPeer { peer in
        let review = try peer.review(kind: .rewindBeforeRun, selected: 0)
        let result = try await peer.session.applyPiHistory(review: review, configuration: .init(thread: peer.thread), operationID: review.operationID) { _ in }
        let pi = try #require(result.pi), intent = try #require(pi.freshIntent)
        #expect(pi.snapshot.entries.isEmpty && pi.snapshot.leafID == nil)
        #expect(!FileManager.default.fileExists(atPath: intent.nativeSessionFile))
        await peer.session.close()
        let session = PiSession(executable: peer.executable, cwd: peer.root, configuration: peer.configuration, freshIntent: intent)
        let observed = PiOperationEvents()
        let reader = Task { for await event in session.events { await observed.receive(event) } }
        do {
            var thread = CodingThread(project: .init(path: peer.root.path))
            thread.workspacePath = peer.root.path; thread.provider = .pi; thread.piConfiguration = peer.configuration
            thread.providerThreadID = intent.nativeSessionFile; thread.permission = .supervised; thread.piFreshSessionIntent = intent
            let id = UUID(), messageID = "fresh-opening-\(id.uuidString.lowercased())"
            var configuration = ProviderConfiguration(thread: thread); configuration.piFreshSessionIntent = intent
            thread.activeRun = .init(id: id, configuration: configuration, startedAt: .now); thread.piFreshConsumerRunID = id
            thread.messages = [.init(id: messageID, role: .user, text: "new empty-context input")]
            thread.beginRunRecord(thread.activeRun!, origin: .user, userMessageID: messageID)
            let input = ProviderInput(text: "new empty-context input")
            let preparation = try await session.preparePiRun(input: input, thread: thread)
            #expect(preparation.freshIntentID == intent.id)
            #expect(preparation.freshEmptyObservation?.entries.isEmpty == true)
            #expect(preparation.nativeSessionID != intent.originalNativeSessionID)
            thread.providerThreadID = preparation.nativeSessionFile
            thread.runHistory![0].providerThreadID = preparation.nativeSessionFile; thread.runHistory![0].pi = try .init(preparation: preparation)
            try await session.sendPreparedPi(input: input, thread: thread, preparation: preparation)
            try await piOperationEventually { await observed.completed == 1 }
            let terminal = try #require(await observed.proofs.last)
            #expect(terminal.captureStatus == .proven)
            #expect(terminal.persistedFileRevision?.sessionID == preparation.nativeSessionID)
            let inspected = try PiHistoryService(configuration: peer.runtime).inspectFresh(intent: intent, consumer: terminal)
            let revision = try #require(terminal.persistedFileRevision)
            #expect(inspected == .persisted(revision))
            await session.close(); await reader.value
        } catch { await session.close(); await reader.value; throw error }
    }
}

@Test func piHistoryNativeHeadForkRefusesAFileWhoseReloadWouldChangeTheObservedLiveLeaf() async throws {
    try await withPiOperationPeer { peer in
        let second = try #require(peer.thread.runHistory?[1].pi?.finalObservation)
        let observed = try PiRuntimeEntryObservation(nativeSessionFile: peer.source.reference.nativeThreadID,
            nativeSessionID: peer.source.observation.nativeSessionID, leafID: second.leafID, entries: peer.source.entries)
        let source = try PiHistorySnapshot(reference: peer.source.reference, runtimeIdentity: peer.source.runtimeIdentity,
            observedVersion: peer.source.observedVersion, fileRevision: peer.source.fileRevision, observation: observed)
        var thread = peer.thread; thread.runHistory = Array(thread.runHistory!.prefix(2)); thread.messages = Array(thread.messages.prefix(2))
        var snapshot = peer.workspace; snapshot.threads = [thread]
        #expect(throws: (any Error).self) {
            _ = try PiHistoryReviewEvidence.make(source: source, snapshot: snapshot, thread: thread,
                runID: thread.runHistory![1].id, kind: .forkAfterRun, operationID: UUID())
        }
        #expect(try peer.frames().isEmpty)
    }
}

@Test func piHistoryNativeNoInputRewindProvesNoNativeChangeWithoutForkOrPrompt() async throws {
    try await withPiOperationPeer { peer in
        var thread = peer.thread
        let runID = UUID(), messageID = "handled-\(runID.uuidString.lowercased())"
        let opening = try PiHistoryInputEvidence(clientMessageID: messageID,
            inputDigest: PiHistoryInputEvidence.digest(.init(text: "/status")), kind: .opening)
        let preparation = try PiRunHistoryPreparation(runID: runID, runtimeIdentity: peer.configuration.runtimeIdentity,
            observedVersion: "0.80.5", openingInput: opening, baseline: peer.source.observation)
        let proof = try PiRunHistoryEvidence(preparation: preparation, inputs: [opening], finalObservation: peer.source.observation,
            openingUserEntryID: nil, nativeUserEntryIDs: [], captureStatus: .noNativeChange, terminalStatus: .completed)
        var run = ThreadRunRecord(run: .init(id: runID, configuration: .init(thread: thread), startedAt: .now), origin: .user, userMessageID: messageID)
        run.pi = proof; run.status = .completed; run.endedAt = .now; run.endReason = .providerCompleted; run.messageAttributionVersion = 1
        thread.runHistory!.append(run)
        var row = ChatMessage(id: messageID, role: .user, text: "/status"); row.runReference = .init(threadID: thread.id, runID: runID)
        thread.messages.append(row)
        var snapshot = peer.workspace; snapshot.threads = [thread]
        let review = try PiHistoryReviewEvidence.make(source: peer.source, snapshot: snapshot, thread: thread,
            runID: runID, kind: .rewindBeforeRun, operationID: UUID())
        try review.validateLedger(snapshot: snapshot, thread: thread)
        let result = try await peer.session.applyPiHistory(review: review, configuration: .init(thread: thread), operationID: review.operationID) { _ in
            Issue.record("An unchanged native rewind published a candidate.")
        }
        #expect(result.pi?.snapshot == peer.source)
        #expect(result.pi?.candidates.isEmpty == true)
        #expect(try peer.frames().allSatisfy { $0["kind"] == .string("launch") && $0["argv"] == .array([.string("--version")]) })
    }
}

@Test func piHistoryNativeNonemptyUnpersistedCutRefusesEmptyAdoptionAndColdOriginalRefusesUnpersistedLeaf() async throws {
    try await withPiOperationPeer(metadataBeforeOpening: true) { peer in
        let review = try peer.review(kind: .rewindBeforeRun, selected: 0)
        #expect(review.retainedEntries.count == 1)
        do {
            _ = try await peer.session.applyPiHistory(review: review, configuration: .init(thread: peer.thread), operationID: review.operationID) { _ in }
            Issue.record("A nonempty native context without an artifact was treated as empty.")
        } catch let error as ProviderHistoryError { #expect(error.kind == .outcomeUncertain) }
        let old = try PiRuntimeEntryObservation(nativeSessionFile: peer.source.reference.nativeThreadID,
            nativeSessionID: peer.source.observation.nativeSessionID, leafID: peer.source.entries[1].id, entries: peer.source.entries)
        let source = try PiHistorySnapshot(reference: peer.source.reference, runtimeIdentity: peer.source.runtimeIdentity,
            observedVersion: peer.source.observedVersion, fileRevision: peer.source.fileRevision, observation: old)
        #expect(throws: (any Error).self) { _ = try PiHistoryService(configuration: peer.runtime).inspectOriginal(expected: source) }
    }
}
