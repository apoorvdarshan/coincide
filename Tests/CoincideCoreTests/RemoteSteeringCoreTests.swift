import Darwin
import Foundation
import Testing
@testable import CoincideCore

actor RemoteSteeringTestSession: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private(set) var sends: [String] = [], steers: [String] = [], steeredModels: [String] = []
    private var runID: UUID?, turnID: String?
    var uncertain = false
    private(set) var closes = 0
    private var holdClosing = false, closeStarted = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = [], closeObservers: [CheckedContinuation<Void, Never>] = []
    init() { let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) { send(input: .init(text: text), thread: thread) }
    func send(input: ProviderInput, thread: CodingThread) {
        runID = thread.activeRun?.id; turnID = "offline-turn-" + String(sends.count + 1); sends.append(input.text)
        emit(.thread("offline-steering-thread")); emit(.turn(turnID!))
    }
    private func emit(_ event: ProviderEvent) { if let runID { sink.yield(.context(runID: runID, event: event)) } }
    func steeringCapabilities() -> ProviderSteeringCapabilities { .init(supportsActiveSteering: runID != nil && turnID != nil) }
    func steer(input: ProviderInput, thread: CodingThread, expectedTurnID: String, clientMessageID: String) throws -> ProviderSteeringReceipt {
        guard thread.activeRun?.id == runID, expectedTurnID == turnID else { throw ProviderSteeringError(.staleTarget) }
        steers.append(input.text); steeredModels.append(thread.model)
        if uncertain { throw ProviderSteeringError(.outcomeUncertain) }
        return try .init(turnID: expectedTurnID)
    }
    func setUncertain() { uncertain = true }
    func finish() { emit(.completed(.idle)); runID = nil; turnID = nil }
    func interrupt() { emit(.completed(.interrupted)); runID = nil; turnID = nil }
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func holdClose() { holdClosing = true }
    func closingEntered() async { if !closeStarted { await withCheckedContinuation { closeObservers.append($0) } } }
    func releaseClose() { holdClosing = false; let values = closeWaiters; closeWaiters = []; values.forEach { $0.resume() } }
    func close() async {
        closes += 1; closeStarted = true; let values = closeObservers; closeObservers = []; values.forEach { $0.resume() }
        if holdClosing { await withCheckedContinuation { closeWaiters.append($0) } }; sink.finish()
    }
}
func remoteSteeringEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(try await predicate()) { guard ContinuousClock.now < deadline else { throw CoincideError("The private steering fixture did not reach its expected boundary.") }; try await Task.sleep(for: .milliseconds(5)) }
}
struct RemoteSteeringFixture {
    let root: URL, data: URL
    let service: RemoteEnvironmentService, session: RemoteSteeringTestSession
    let options: RemoteEnvironmentOptions
    let threadID: UUID
    static func make(keepingDraftAttachments: Bool = false) async throws -> Self {
        let candidate = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-remote-steering-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let path = realpath(candidate.path, nil) else { throw CancellationError() }; defer { free(path) }
        let root = URL(fileURLWithPath: String(cString: path)), data = root.appendingPathComponent("Host"), workspace = root.appendingPathComponent("Workspace")
        for directory in [data, workspace] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let options = RemoteEnvironmentOptions(codexExecutable: "/usr/bin/true", codexHome: root.appendingPathComponent("CodexHome").path,
            claudeExecutable: "/usr/bin/true", claudeConfigurationDirectory: root.appendingPathComponent("ClaudeHome").path,
            githubExecutable: "/usr/bin/true", githubConfigurationDirectory: root.appendingPathComponent("GhHome").path)
        let project = WorkspaceProject(path: workspace.path); var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled
        thread.codexRuntimeConfiguration = .init(selection: .custom, executable: "/usr/bin/true", homeDirectory: options.codexHome!)
        if keepingDraftAttachments {
            let attachments = try AttachmentStore(root: data.appendingPathComponent("Attachments", isDirectory: true))
            for index in 0..<2 {
                thread.draftAttachments.append(try await attachments.importData(Data("Private draft reference \(index)".utf8), name: "draft-\(index).txt"))
            }
        }
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        _ = try RemoteEnvironmentIdentity.load(dataDirectory: data, expected: nil)
        try await WorkspaceDatabase(url: data.appendingPathComponent("workspace.sqlite")).save(snapshot, event: "remote.steering.fixture")
        let session = RemoteSteeringTestSession()
        let service = try RemoteEnvironmentService(dataDirectory: data, options: options, providerFactory: { _ in session })
        let fixture = Self(root: root, data: data, service: service, session: session, options: options, threadID: thread.id)
        do {
            let current = try await fixture.thread()
            let opening: RemoteEnvironmentCommand
            if keepingDraftAttachments {
                let hostID = try #require(await service.descriptor().hostID)
                let saved = try await service.snapshot(.init(environmentID: service.environmentID)).workspace
                let sourceProject = try #require(saved.projects.first { $0.id == current.projectID })
                opening = .submitComposerDraft(.init(target: .init(environmentID: service.environmentID, projectID: current.projectID, threadID: current.id),
                    hostID: hostID, threadCreatedAt: current.createdAt, projectCreatedAt: sourceProject.createdAt, text: "Explicit opening input",
                    expectedConfiguration: .init(thread: current), expectedHostDraftDigest: RemoteComposerSubmission.textDigest(current.draft),
                    expectedDraftAttachments: current.draftAttachments, selectedDraftAttachmentIDs: [], uploadedAttachmentIDs: [],
                    selectionDigest: String(repeating: "a", count: 64), orderedAttachmentIDs: []))
            } else { opening = .submit(threadID: thread.id, text: "Explicit opening input", expectedConfiguration: .init(thread: current)) }
            let started = try await service.command(.init(environmentID: service.environmentID, command: opening))
            try #require(started.receipt.rejection == nil)
            try await remoteSteeringEventually { try await fixture.thread().activeRun?.nativeTurnID != nil }
            return fixture
        } catch { await service.close(); throw error }
    }
    func thread() async throws -> CodingThread { try #require(try await service.snapshot(.init(environmentID: service.environmentID)).workspace.threads.first { $0.id == threadID }) }
    func read() async throws -> RemoteSteeringReadResult {
        let value = try await thread()
        return try await service.readSteering(.init(target: .init(environmentID: service.environmentID, projectID: value.projectID, threadID: value.id, configuration: .init(thread: value))))
    }
    func upload(_ text: String) async throws -> ChatAttachment {
        let thread = try await thread(), bytes = Data(text.utf8)
        let request = RemoteAttachmentUploadRequest(target: .init(environmentID: service.environmentID, projectID: thread.projectID, threadID: thread.id), name: "queued-attachment.txt", byteCount: bytes.count, digest: RemoteProjectionProtocol.digest(bytes))
        _ = try await service.beginAttachmentUpload(request)
        _ = try await service.appendAttachmentChunk(.init(upload: request, index: 0, data: bytes, digest: request.digest))
        return try #require(try await service.finalizeAttachmentUpload(request).attachment)
    }
    func close() async { await service.close(); try? FileManager.default.removeItem(at: root) }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func remoteSteeringOriginalUUIDStartsOneNativeSteerAndNeverAnotherTurnOrRestartReplay(uncertain: Bool) async throws {
    let f = try await RemoteSteeringFixture.make()
    do {
        if uncertain { await f.session.setUncertain() }
        let initial = try await f.thread()
        let edited = try await f.service.command(.init(environmentID: f.service.environmentID, command: .editThread(threadID: initial.id, edit: .model("Future queued model"), expectedConfiguration: .init(thread: initial))))
        #expect(edited.receipt.rejection == nil)
        let read = try await f.read(), before = try await f.thread(), capture = read.page.capture
        #expect(read.canSteer && read.target.rootID != nil)
        let composer = RemoteComposerSubmission(target: .init(environmentID: f.service.environmentID, projectID: before.projectID, threadID: before.id),
            hostID: capture.binding.hostID, threadCreatedAt: before.createdAt, projectCreatedAt: capture.projectCreatedAt,
            text: "Exact active guidance 😀 e\u{301}", expectedConfiguration: .init(thread: before), expectedHostDraftDigest: RemoteComposerSubmission.textDigest(before.draft),
            expectedDraftAttachments: before.draftAttachments, selectedDraftAttachmentIDs: [], uploadedAttachmentIDs: [], selectionDigest: String(repeating: "a", count: 64), orderedAttachmentIDs: [])
        let command = RemoteEnvironmentCommand.promptSteering(target: read.target, action: .steerComposer(capture: capture, input: composer))
        let request = RemoteEnvironmentCommandRequest(environmentID: f.service.environmentID, id: UUID(), command: command)
        async let first = f.service.command(request); async let duplicate = f.service.command(request)
        let (a, b) = try await (first, duplicate)
        #expect(a == b && a.receipt.rejection == nil)
        let operationID = RemoteSteeringProtocol.operationID(request.id)
        try await remoteSteeringEventually {
            let snapshot = try await f.service.snapshot(.init(environmentID: f.service.environmentID)).workspace
            return snapshot.promptSteering(operationID)?.phase == (uncertain ? .unconfirmed : .delivered)
        }
        #expect(await f.session.steers == [composer.text])
        #expect(await f.session.steeredModels == [before.activeRun!.configuration.model])
        #expect(before.model == "Future queued model")
        #expect(await f.session.sends == ["Explicit opening input"])
        let after = try await f.thread()
        #expect(after.runHistory?.count == 1 && after.activeRun?.id == before.activeRun?.id)
        if uncertain {
            #expect(after.queuePaused)
            try FileManager.default.moveItem(atPath: after.workspacePath, toPath: after.workspacePath + "-retained")
            let recovery = try await f.read(), row = try #require(recovery.operationPage.operations.first)
            #expect(recovery.target.rootID == nil && row.phase == .unconfirmed)
            let ack = RemoteEnvironmentCommandRequest(environmentID: f.service.environmentID, id: UUID(), command: .promptSteering(target: recovery.target,
                action: .acknowledge(capture: recovery.page.capture, operationID: row.id, digest: row.digest)))
            let acknowledged = try await f.service.command(ack)
            #expect(acknowledged.receipt.rejection == nil)
            #expect(try await f.service.command(ack) == acknowledged)
            let recoverySnapshot = try await f.service.snapshot(.init(environmentID: f.service.environmentID)).workspace
            #expect(recoverySnapshot.promptSteering(operationID)?.acknowledgedAt != nil && recoverySnapshot.threads[0].queuePaused)
            #expect(await f.session.steers.count == 1)
        }
        await f.service.close()
        let reopened = try RemoteEnvironmentService(dataDirectory: f.data, expectedEnvironmentID: f.service.environmentID, options: f.options,
            providerFactory: { _ in Issue.record("Original receipt inspection cannot start a provider"); throw CancellationError() })
        do {
            #expect(try await reopened.command(request) == a)
            #expect(try await reopened.receipt(request).receipt == a.receipt)
            #expect(await f.session.steers.count == 1)
        } catch { await reopened.close(); throw error }
        await reopened.close()
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteQueuedInputEditReplacesTextAndSelectedReferencesInPlaceWithOneOriginalReceiptAndPreservesComposer() async throws {
    let f = try await RemoteSteeringFixture.make()
    do {
        let before = try await f.thread(), attachment = try await f.upload("Original immutable attachment")
        let host = try #require(await f.service.descriptor().hostID)
        let input = RemoteComposerSubmission(target: .init(environmentID: f.service.environmentID, projectID: before.projectID, threadID: before.id), hostID: host,
            threadCreatedAt: before.createdAt, projectCreatedAt: (try await f.read()).page.capture.projectCreatedAt, text: "Original queued text",
            expectedConfiguration: .init(thread: before), expectedHostDraftDigest: RemoteComposerSubmission.textDigest(before.draft), expectedDraftAttachments: before.draftAttachments,
            selectedDraftAttachmentIDs: [], uploadedAttachmentIDs: [attachment.id], selectionDigest: String(repeating: "a", count: 64), orderedAttachmentIDs: [attachment.id])
        #expect(try await f.service.command(.init(environmentID: f.service.environmentID, command: .submitComposerDraft(input))).receipt.rejection == nil)
        let current = try await f.thread()
        #expect(try await f.service.command(.init(environmentID: f.service.environmentID, command: .editThread(threadID: current.id, edit: .draft("Unsent active composer e\u{327}\u{301}"), expectedConfiguration: .init(thread: current)))).receipt.rejection == nil)
        let read = try await f.read(), queued = try #require(read.page.items.first), saved = try await f.thread()
        let extra = try await f.upload("Replacement attachment")
        let action = RemoteSteeringAction.editQueued(capture: read.page.capture, queuedID: queued.id, digest: queued.digest, text: "Edited in place e\u{301}\u{327}",
            selectedAttachmentIDs: [], uploadedAttachmentIDs: [extra.id], orderedAttachmentIDs: [extra.id])
        let request = RemoteEnvironmentCommandRequest(environmentID: f.service.environmentID, id: UUID(), command: .promptSteering(target: read.target, action: action))
        let receipt = try await f.service.command(request)
        #expect(receipt.receipt.rejection == nil)
        #expect(try await f.service.command(request) == receipt)
        let after = try await f.thread(), original = try #require(saved.queuedTurns.first), changed = try #require(after.queuedTurns.first)
        #expect(changed.id == original.id && changed.text.utf8.elementsEqual("Edited in place e\u{301}\u{327}".utf8))
        #expect(changed.attachments?.map(\.id) == [extra.id] && changed.configuration == original.configuration)
        #expect(after.draft.utf8.elementsEqual(saved.draft.utf8) && after.draftAttachments == saved.draftAttachments)
        #expect(await f.session.steers.isEmpty)
        let stale = try await f.service.command(.init(environmentID: f.service.environmentID, id: UUID(), command: request.command))
        let afterStale = try await f.thread()
        #expect(stale.receipt.rejection != nil && afterStale.queuedTurns == after.queuedTurns)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)), arguments: ["configuration", "run", "physical-root", "released-view"])
func remoteSteeringStaleCapturedScopeRefusesBeforeAnyNativeSteering(change: String) async throws {
    let f = try await RemoteSteeringFixture.make()
    do {
        let before = try await f.thread(), queued = QueuedTurn(id: UUID(), text: "CAS source", configuration: .init(thread: before), createdAt: .now)
        // Queue through the public remote command, then pin a host-owned view.
        _ = try await f.service.command(.init(environmentID: f.service.environmentID, command: .submit(threadID: before.id, text: queued.text, expectedConfiguration: .init(thread: before))))
        let read = try await f.read(), row = try #require(read.page.items.first)
        switch change {
        case "configuration": _ = try await f.service.command(.init(environmentID: f.service.environmentID, command: .editThread(threadID: before.id, edit: .model("Changed model"), expectedConfiguration: .init(thread: before))))
        case "run": await f.session.finish(); try await remoteSteeringEventually { try await f.thread().activeRun?.id != read.page.capture.runID }
        case "physical-root":
            try FileManager.default.moveItem(atPath: before.workspacePath, toPath: before.workspacePath + "-original")
            try FileManager.default.createDirectory(atPath: before.workspacePath, withIntermediateDirectories: false)
        default: _ = try await f.service.releaseSteering(.init(target: read.target, binding: read.page.capture.binding))
        }
        let result = try await f.service.command(.init(environmentID: f.service.environmentID, id: UUID(), command: .promptSteering(target: read.target,
            action: .steerQueued(capture: read.page.capture, queuedID: row.id, digest: row.digest))))
        #expect(result.receipt.rejection != nil)
        #expect(await f.session.steers.isEmpty)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(.timeLimit(.minutes(1)))
func remoteSteeringBoundedQueuePagesRetainExactFrozenContentAndRefuseWrongQueryAndReleasedLeases() async throws {
    let f = try await RemoteSteeringFixture.make()
    do {
        let first = try await f.thread()
        for index in 0..<40 {
            let result = try await f.service.command(.init(environmentID: f.service.environmentID, command: .submit(threadID: first.id,
                text: "Queued \(index) e\u{301}\u{327} 😀", expectedConfiguration: .init(thread: first))))
            #expect(result.receipt.rejection == nil)
        }
        let read = try await f.read(), cursor = try #require(read.page.nextCursor), binding = read.page.capture.binding
        #expect(read.page.items.count == 32 && read.page.totalCount == 40 && read.page.offset == 0)
        let request = RemoteSteeringPageRequest(target: read.target, binding: binding, cursor: cursor, kind: .queue)
        let page = try await f.service.steeringPage(request), again = try await f.service.steeringPage(request)
        #expect(page == again && page.offset == 32 && page.totalCount == 40 && page.complete)
        #expect(Set((read.page.items + page.items).map(\.id)).count == 40)
        #expect(try RemoteProjectionProtocol.payload(read).count <= RemoteSteeringProtocol.maximumBytes)
        await #expect(throws: (any Error).self) { _ = try await f.service.steeringPage(.init(target: read.target, binding: binding, cursor: cursor, kind: .operations)) }
        let reference = try #require(page.items.last?.text)
        let content = try await f.service.steeringContent(.init(target: read.target, binding: binding, reference: reference, offset: 0))
        #expect(content.complete && content.data == Data("Queued 39 e\u{301}\u{327} 😀".utf8))
        let removed = try await f.service.releaseSteering(.init(target: read.target, binding: binding)); #expect(removed.released)
        await #expect(throws: (any Error).self) { _ = try await f.service.steeringContent(.init(target: read.target, binding: binding, reference: reference, offset: 0)) }
        #expect(await f.session.sends.count == 1)
        #expect(await f.session.steers.isEmpty)
    } catch { await f.close(); throw error }
    await f.close()
}

@Test(arguments: ["queued-text-bytes", "queued-reference", "configuration", "thread-birth", "workspace"])
func queuedInputReplacementRefusesStaleSourceWithoutTouchingTheUnsentComposer(change: String) throws {
    let project = WorkspaceProject(path: "/private/owned-offline-cas")
    var thread = CodingThread(project: project); thread.queuePaused = true
    let ref = ChatAttachment(id: UUID(), name: "kept.txt", mimeType: "text/plain", byteCount: 4, digest: String(repeating: "a", count: 64), fileExtension: "txt")
    let queued = QueuedTurn(id: UUID(), text: "e\u{301}\u{327}", configuration: .init(thread: thread), createdAt: .now, attachments: [ref])
    thread.queuedTurns = [queued]; thread.draft = "Different unsent text"; thread.draftAttachments = [ref]
    let request = QueuedInputReplacement(thread: thread, queued: queued, text: "Replacement", attachments: [])
    switch change {
    case "queued-text-bytes": thread.queuedTurns[0].text = "e\u{327}\u{301}"
    case "queued-reference": thread.queuedTurns[0].attachments?[0].name = "Changed.txt"
    case "configuration": thread.model = "Different next-input model"
    case "thread-birth": thread.createdAt.addTimeInterval(1)
    default: thread.workspacePath = "/private/other-workspace"
    }
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    #expect(throws: (any Error).self) { try WorkspaceDecision.make(.queuedInputReplaced(request), id: UUID(), snapshot: snapshot, now: .now) }
    #expect(snapshot.threads[0].draft == "Different unsent text" && snapshot.threads[0].draftAttachments == [ref])
}

@Test func queuedInputReplacementJournalPersistsCanonicalEquivalentDifferentUTF8EvenWithoutATimestampChange() throws {
    let project = WorkspaceProject(path: "/private/offline-queue-journal")
    var thread = CodingThread(project: project); thread.queuePaused = true
    let now = thread.updatedAt
    let queued = QueuedTurn(id: UUID(), text: "e\u{301}\u{327}", configuration: .init(thread: thread), createdAt: now)
    thread.queuedTurns = [queued]; thread.draft = "Never replace this unsent draft"
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let request = QueuedInputReplacement(thread: thread, queued: queued, text: "e\u{327}\u{301}", attachments: [])
    let decision = try WorkspaceDecision.make(.queuedInputReplaced(request), id: UUID(), snapshot: snapshot, now: now)
    let events = try WorkspaceJournal.changes(from: snapshot, to: decision.snapshot)
    var rebuilt = snapshot
    for event in events { try event.apply(to: &rebuilt) }
    #expect(rebuilt.threads[0].queuedTurns[0].text.utf8.elementsEqual("e\u{327}\u{301}".utf8))
    #expect(rebuilt.threads[0].draft == thread.draft)
    #expect(rebuilt.threads[0].queuedTurns[0].configuration == queued.configuration)
}

@Test(.timeLimit(.minutes(1)))
func remoteComposerSteeringCapturesOnlySelectedReferencesAndPreservesOmittedHostDraftAttachmentsExactlyOnce() async throws {
    let f = try await RemoteSteeringFixture.make(keepingDraftAttachments: true)
    do {
        let before = try await f.thread(), read = try await f.read()
        try #require(before.draftAttachments.count == 2)
        let uploaded = try await f.upload("Actual uploaded steering reference")
        let selected = before.draftAttachments[1], omitted = before.draftAttachments[0]
        let input = RemoteComposerSubmission(target: .init(environmentID: f.service.environmentID, projectID: before.projectID, threadID: before.id),
            hostID: read.page.capture.binding.hostID, threadCreatedAt: before.createdAt, projectCreatedAt: read.page.capture.projectCreatedAt,
            text: "Steer the exact active input", expectedConfiguration: .init(thread: before), expectedHostDraftDigest: RemoteComposerSubmission.textDigest(before.draft),
            expectedDraftAttachments: before.draftAttachments, selectedDraftAttachmentIDs: [selected.id], uploadedAttachmentIDs: [uploaded.id],
            selectionDigest: String(repeating: "b", count: 64), orderedAttachmentIDs: [uploaded.id, selected.id])
        let request = RemoteEnvironmentCommandRequest(environmentID: f.service.environmentID, id: UUID(),
            command: .promptSteering(target: read.target, action: .steerComposer(capture: read.page.capture, input: input)))
        let receipt = try await f.service.command(request)
        try #require(receipt.receipt.rejection == nil)
        let operationID = RemoteSteeringProtocol.operationID(request.id)
        try await remoteSteeringEventually {
            try await f.service.snapshot(.init(environmentID: f.service.environmentID)).workspace.promptSteering(operationID)?.phase == .delivered
        }
        let snapshot = try await f.service.snapshot(.init(environmentID: f.service.environmentID)).workspace
        let operation = try #require(snapshot.promptSteering(operationID)), after = try #require(snapshot.threads.first { $0.id == f.threadID })
        #expect(operation.input.text == input.text && operation.input.attachments?.map(\.id) == [uploaded.id, selected.id])
        #expect(ComposerDraftSnapshot.sameAttachments(after.draftAttachments, [omitted]) && after.draft.utf8.elementsEqual(before.draft.utf8))
        #expect(after.activeRun?.id == before.activeRun?.id && after.queuedTurns.isEmpty)
        #expect(try await f.service.command(request) == receipt)
        let steerCount = await f.session.steers.count, sendCount = await f.session.sends.count
        #expect(steerCount == 1 && sendCount == 1)
    } catch { await f.close(); throw error }
    await f.close()
}
