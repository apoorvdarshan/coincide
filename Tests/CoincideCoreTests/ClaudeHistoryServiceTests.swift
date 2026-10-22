import Darwin
import Foundation
import Testing
@testable import CoincideCore

private struct ClaudeHistoryFixture: Sendable {
    let root: URL, workspace: URL, config: URL, project: URL
    let sessionID = UUID().uuidString.lowercased()
    let runIDs = (0..<3).map { _ in UUID() }
    let assistantIDs = (0..<3).map { _ in UUID().uuidString.lowercased() }
    let interimAssistantID = UUID().uuidString.lowercased()
    let steerMessageID = "user-steering-" + UUID().uuidString
    let runtime: ClaudeRuntimeConfiguration
    var snapshot: WorkspaceSnapshot
    var records: [JSONValue]
    var thread: CodingThread { snapshot.threads[0] }
    var sourceURL: URL { project.appendingPathComponent(sessionID + ".jsonl") }

    init(steering: Bool = false) throws {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let pointer = requested.path.withCString({ realpath($0, nil) }) else { throw CoincideError("The private history fixture is unavailable.") }
        root = URL(fileURLWithPath: String(cString: pointer)); free(pointer)
        workspace = root.appendingPathComponent("Workspace 工作 😀")
        config = root.appendingPathComponent("Native Configuration")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        project = config.appendingPathComponent("projects").appendingPathComponent(try ClaudeTranscriptStore.projectDirectoryName(forPhysicalWorkspacePath: workspace.path))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        runtime = .init(executable: root.appendingPathComponent("not-executed-claude").path, configurationDirectory: config.path, workspacePath: workspace.path)
        let workspaceProject = WorkspaceProject(path: workspace.path)
        var thread = CodingThread(project: workspaceProject, model: "captured-native-model")
        thread.workspacePath = workspace.path; thread.provider = .claude; thread.providerThreadID = sessionID
        thread.claudeRuntimeConfiguration = runtime; thread.checkpointPolicy = .disabled
        thread.draft = "Latest unsent text 工作 😀"; thread.permission = .supervised; thread.isPinned = true
        var native: [JSONValue] = [], operations: [PromptSteeringOperation] = []
        var parent: String?
        for index in runIDs.indices {
            let runID = runIDs[index], inputID = ClaudeInputIdentity.opening(runID: runID), userID = "user-\(runID)"
            let configuration = ProviderConfiguration(thread: thread), now = Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            let active = ActiveRun(id: runID, configuration: configuration, startedAt: now)
            var record = ThreadRunRecord(run: active, origin: .user, userMessageID: userID)
            record.status = .completed; record.endedAt = now; record.endReason = .providerCompleted; record.messageAttributionVersion = 1
            var evidence = try ClaudeRunHistoryEvidence(runID: runID, runtimeIdentity: runtime.runtimeIdentity, nativeSessionID: sessionID)
            var user = ChatMessage(id: userID, role: .user, text: "Original input \(index) 工作")
            user.runReference = .init(threadID: thread.id, runID: runID)
            thread.messages.append(user)
            native.append(Self.record(id: inputID, parent: parent, kind: "user", text: user.text, sessionID: sessionID, cwd: workspace.path))
            try evidence.observe(nativeSessionID: sessionID, inputIDs: [inputID])
            parent = inputID
            if index == 0 && steering {
                native.append(Self.record(id: interimAssistantID, parent: parent, kind: "assistant", text: "Before steering", sessionID: sessionID, cwd: workspace.path)); parent = interimAssistantID
                try evidence.observe(nativeSessionID: sessionID, rootAssistantMessageID: interimAssistantID)
                let steer = try ClaudeSteeringInputEvidence(messageID: steerMessageID)
                try evidence.registerSteering(messageID: steerMessageID)
                let queued = QueuedTurn(id: UUID(), text: "Exact literal steer Ω 😀", configuration: configuration, createdAt: now)
                var operation = PromptSteeringOperation(threadID: thread.id, projectID: workspaceProject.id, sourceIncarnation: UUID(), runtimeID: UUID(),
                    runID: runID, nativeThreadID: sessionID, nativeTurnID: "captured-adapter-turn", input: queued, messageID: steerMessageID, configuration: configuration)
                operation.phase = .delivered; operation.receipt = try .init(turnID: "captured-adapter-turn", delivery: .acknowledged)
                operations.append(operation)
                var row = ChatMessage(id: steerMessageID, role: .user, text: queued.text)
                row.runReference = user.runReference; row.promptSteeringID = operation.id; thread.messages.append(row)
                native.append(Self.record(id: steer.nativeInputID, parent: parent, kind: "user", text: queued.text, sessionID: sessionID, cwd: workspace.path)); parent = steer.nativeInputID
                try evidence.observe(nativeSessionID: sessionID, inputIDs: [steer.nativeInputID])
            }
            native.append(Self.record(id: assistantIDs[index], parent: parent, kind: "assistant", text: "Root assistant \(index)", sessionID: sessionID, cwd: workspace.path))
            parent = assistantIDs[index]
            try evidence.observe(nativeSessionID: sessionID, rootAssistantMessageID: assistantIDs[index]); try evidence.finish(.completed)
            record.claude = evidence
            if thread.runHistory == nil { thread.runHistory = [] }; thread.runHistory?.append(record)
            var reply = ChatMessage(id: "reply-\(runID)", role: .assistant, text: "Root assistant \(index)"); reply.runReference = user.runReference
            thread.messages.append(reply)
        }
        records = native; snapshot = .init(); snapshot.projects = [workspaceProject]; snapshot.threads = [thread]; snapshot.promptSteerings = operations.isEmpty ? nil : operations
        try write()
    }

    static func record(id: String, parent: String?, kind: String, text: String, sessionID: String, cwd: String) -> JSONValue {
        .object(["type": .string(kind), "uuid": .string(id), "sessionId": .string(sessionID), "parentUuid": parent.map(JSONValue.string) ?? .null,
                 "cwd": .string(cwd), "isSidechain": .bool(false), "timestamp": .string("2026-10-23T00:00:00.000Z"),
                 "message": .object(["role": .string(kind), "content": .string(text)])])
    }
    func write(_ values: [JSONValue]? = nil) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for record in values ?? records { data.append(try encoder.encode(record)); data.append(10) }
        try data.write(to: sourceURL); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceURL.path)
    }
    func service() throws -> ClaudeHistoryService { try .init(configuration: runtime) }
    func evidence(_ kind: ConversationHistoryKind, index: Int, selection: ClaudeResumeSelection? = nil) throws -> ClaudeHistoryReviewEvidence {
        let source = try service().snapshot(sessionID: sessionID, selection: selection)
        return try .make(source: source, snapshot: snapshot, thread: thread, runID: runIDs[index], kind: kind)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private actor ClaudeHistoryReservationLog {
    var publications: [ClaudeTranscriptPublication] = []
    func append(_ value: ClaudeTranscriptPublication) { publications.append(value) }
    func values() -> [ClaudeTranscriptPublication] { publications }
}

@Test func claudeHistoryForkReservesBeforeWriteAndReadOnlyRestartInspectsExactTargetWithSteeredWholeRun() async throws {
    let fixture = try ClaudeHistoryFixture(steering: true); defer { fixture.cleanup() }
    let service = try fixture.service(), review = try fixture.evidence(.forkAfterRun, index: 0)
    let sourceBytes = try Data(contentsOf: fixture.sourceURL), target = UUID().uuidString.lowercased()
    let plan = try service.prepareFork(review: review, targetSessionID: target), log = ClaudeHistoryReservationLog()
    #expect(review.boundary == .throughMessage(fixture.assistantIDs[0]))
    #expect(review.inputs[0].steeringInputs.count == 1 && review.inputs[0].rootAssistantMessageIDs.count == 2)
    #expect(try service.inspectFork(review: review, publication: plan.publication) == .notStarted)
    let result = try await service.publishFork(plan) { reservation in
        #expect(!FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent(target + ".jsonl").path))
        await log.append(reservation)
    }
    let reservations = await log.values(); #expect(reservations == [plan.publication])
    #expect(result.reference.nativeThreadID == target && result.publication == plan.publication)
    #expect(result.inheritedHead?.cursor == plan.publication.headMessageID && result.selection == nil)
    #expect(try Data(contentsOf: fixture.sourceURL) == sourceBytes)
    let reserved = try JSONDecoder().decode(ClaudeTranscriptPublication.self, from: JSONEncoder().encode(plan.publication))
    #expect(try fixture.service().inspectFork(review: review, publication: reserved) == .ready(result))
    try review.validateResult(result)
    #expect(throws: (any Error).self) { _ = try service.prepareFork(review: review, targetSessionID: fixture.sessionID) }
}

@Test func claudeHistoryReservationFailureOrChangedSourceCannotPublishAndForeignPartialTargetIsNeverRemoved() async throws {
    let fixture = try ClaudeHistoryFixture(); defer { fixture.cleanup() }
    let service = try fixture.service(), review = try fixture.evidence(.forkAfterRun, index: 1)
    let plan = try service.prepareFork(review: review, targetSessionID: UUID().uuidString.lowercased())
    do { _ = try await service.publishFork(plan) { _ in throw CoincideError("Fixed injected reservation failure") }; Issue.record("A rejected reservation published.") }
    catch { }
    #expect(try service.inspectFork(review: review, publication: plan.publication) == .notStarted)
    let target = fixture.project.appendingPathComponent(plan.publication.target.sessionID + ".jsonl")
    let partial = Data("owned but incomplete\n".utf8); try partial.write(to: target)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    #expect(try service.inspectFork(review: review, publication: plan.publication) == .incomplete)
    #expect(try Data(contentsOf: target) == partial)
    var changed = fixture.records
    var last = changed[changed.count - 1].object!; last["message"] = .object(["role": .string("assistant"), "content": .string("Changed after review")]); changed[changed.count - 1] = .object(last)
    try fixture.write(changed)
    #expect(throws: (any Error).self) { _ = try service.prepareFork(review: review, targetSessionID: UUID().uuidString) }
    #expect(throws: (any Error).self) { _ = try service.inspectFork(review: review, publication: plan.publication) }
    #expect(try Data(contentsOf: target) == partial)
}

@Test func claudeHistoryRewindIsDeferredAndRepeatedSelectionUsesEffectivePrefixWithoutDeletingNativeSuffix() throws {
    var fixture = try ClaudeHistoryFixture(); defer { fixture.cleanup() }
    let service = try fixture.service(), original = try Data(contentsOf: fixture.sourceURL)
    let review = try fixture.evidence(.rewindBeforeRun, index: 2), selectionID = UUID()
    let result = try service.prepareRewind(review: review, selectionID: selectionID)
    let selection = try #require(result.selection)
    #expect(selection.id == selectionID && selection.cursor == fixture.assistantIDs[1])
    #expect(selection.discardedInputID == ClaudeInputIdentity.opening(runID: fixture.runIDs[2]))
    #expect(result.reference.nativeThreadID == fixture.sessionID)
    #expect(try Data(contentsOf: fixture.sourceURL) == original)
    let operationID = UUID()
    fixture.snapshot.threads[0].claudeResumeSelection = selection
    fixture.snapshot.threads[0].runHistory?[2].removedByHistoryOperationID = operationID
    for index in fixture.snapshot.threads[0].messages.indices where fixture.snapshot.threads[0].messages[index].runReference?.runID == fixture.runIDs[2] {
        fixture.snapshot.threads[0].messages[index].removedByHistoryOperationID = operationID
    }
    let effective = try service.snapshot(sessionID: fixture.sessionID, selection: selection)
    #expect(effective.sourceRevision == review.source.sourceRevision && effective.records == review.source.records)
    #expect(effective.selectedMessageIDs.last == fixture.assistantIDs[1] && !effective.selectedMessageIDs.contains(fixture.assistantIDs[2]))
    let earlier = try ClaudeHistoryReviewEvidence.make(source: effective, snapshot: fixture.snapshot, thread: fixture.thread,
                                                       runID: fixture.runIDs[1], kind: .rewindBeforeRun)
    #expect(earlier.boundary == .throughMessage(fixture.assistantIDs[0]))
    let next = try service.prepareRewind(review: earlier, selectionID: UUID())
    #expect(next.selection?.cursor == fixture.assistantIDs[0])
    #expect(try Data(contentsOf: fixture.sourceURL) == original)
}

@Test func claudeHistoryBeforeFirstLocalRunResetsFreshUnlessVerifiedInheritedHeadExists() throws {
    var fixture = try ClaudeHistoryFixture(); defer { fixture.cleanup() }
    let service = try fixture.service(), first = try fixture.evidence(.rewindBeforeRun, index: 0)
    guard case .freshSession(let reserved) = first.boundary else { Issue.record("First local rewind should reserve a new session."); return }
    let result = try service.prepareRewind(review: first, selectionID: UUID()), selection = try #require(result.selection)
    #expect(selection.kind == .freshSession && result.reference.nativeThreadID == reserved)
    #expect(selection.reviewedLocation == nil && selection.cursor == nil)
    let empty = try service.snapshot(sessionID: reserved, selection: selection)
    #expect(empty.selectedMessages.isEmpty && empty.sourceRevision == nil)
    let alternate = try fixture.evidence(.rewindBeforeRun, index: 0)
    #expect(first.sameLogicalBoundary(as: alternate))
    var inherited = fixture.records
    let inheritedID = UUID().uuidString.lowercased()
    let prefix = ClaudeHistoryFixture.record(id: inheritedID, parent: nil, kind: "assistant", text: "Verified copied parent context", sessionID: fixture.sessionID, cwd: fixture.workspace.path)
    var opening = inherited[0].object!; opening["parentUuid"] = .string(inheritedID); inherited[0] = .object(opening); inherited.insert(prefix, at: 0)
    try fixture.write(inherited)
    fixture.snapshot.threads[0].claudeInheritedHead = try .init(runtimeIdentity: fixture.runtime.runtimeIdentity, nativeSessionID: fixture.sessionID, cursor: inheritedID)
    let reset = try fixture.evidence(.rewindBeforeRun, index: 0)
    #expect(reset.boundary == .throughMessage(inheritedID) && reset.retainedMessageIDs == [inheritedID])
    #expect(try service.prepareRewind(review: reset, selectionID: UUID()).selection?.cursor == inheritedID)
}

@Test(arguments: [0, 1, 2, 3])
func claudeHistoryRefusesLegacyForeignSyntheticAndWrongAssistantEvidence(corruption: Int) throws {
    var fixture = try ClaudeHistoryFixture(); defer { fixture.cleanup() }
    switch corruption {
    case 0: fixture.snapshot.threads[0].runHistory?[1].claude = nil
    case 1: fixture.snapshot.threads[0].runHistory?[1].configuration.model = "different-captured-model" // Model is captured, but same native scope remains valid.
        let changedRuntime = ClaudeRuntimeConfiguration(executable: "/another/claude", configurationDirectory: fixture.config.path, workspacePath: fixture.workspace.path)
        fixture.snapshot.threads[0].runHistory?[1].configuration.claudeRuntimeConfiguration = changedRuntime
    case 2:
        var records = fixture.records, object = records[3].object!; object["isSidechain"] = .bool(true); records[3] = .object(object); try fixture.write(records)
    default:
        var evidence = try ClaudeRunHistoryEvidence(runID: fixture.runIDs[1], runtimeIdentity: fixture.runtime.runtimeIdentity, nativeSessionID: fixture.sessionID)
        try evidence.observe(nativeSessionID: fixture.sessionID, inputIDs: [evidence.openingInputID], rootAssistantMessageID: UUID().uuidString.lowercased()); try evidence.finish(.completed)
        fixture.snapshot.threads[0].runHistory?[1].claude = evidence
    }
    #expect(throws: (any Error).self) { _ = try fixture.evidence(.forkAfterRun, index: 1) }
}

@Test func claudeHistoryPublicationProofRejectsDifferentCutReservationAndTargetPayload() async throws {
    let fixture = try ClaudeHistoryFixture(); defer { fixture.cleanup() }
    let service = try fixture.service(), first = try fixture.evidence(.forkAfterRun, index: 0), later = try fixture.evidence(.forkAfterRun, index: 1)
    let plan = try service.prepareFork(review: later, targetSessionID: UUID().uuidString.lowercased())
    #expect(throws: (any Error).self) { try first.validatePublication(plan.publication) }
    let result = try await service.publishFork(plan) { _ in }
    #expect(throws: (any Error).self) { try first.validateResult(result) }
    #expect(try JSONDecoder().decode(ClaudeHistoryResult.self, from: JSONEncoder().encode(result)) == result)
    let targetURL = fixture.project.appendingPathComponent(result.reference.nativeThreadID + ".jsonl")
    var bytes = try Data(contentsOf: targetURL); bytes.append(Data(" \n".utf8)); try bytes.write(to: targetURL)
    #expect(try service.inspectFork(review: later, publication: plan.publication) == .incomplete)
}

@Test func claudeHistoryChangesWhileReservationIsJournaledPreventFirstExternalWrite() async throws {
    let fixture = try ClaudeHistoryFixture(); defer { fixture.cleanup() }
    let service = try fixture.service(), review = try fixture.evidence(.forkAfterRun, index: 1)
    let plan = try service.prepareFork(review: review, targetSessionID: UUID().uuidString.lowercased())
    let target = fixture.project.appendingPathComponent(plan.publication.target.sessionID + ".jsonl")
    do {
        _ = try await service.publishFork(plan) { _ in
            let appended = ClaudeHistoryFixture.record(id: UUID().uuidString.lowercased(), parent: fixture.assistantIDs.last,
                kind: "user", text: "Another native owner appended while admission was held", sessionID: fixture.sessionID, cwd: fixture.workspace.path)
            try fixture.write(fixture.records + [appended])
        }
        Issue.record("A stale reservation published native bytes.")
    } catch { }
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(throws: (any Error).self) { _ = try fixture.evidence(.forkAfterRun, index: 1) }
}
