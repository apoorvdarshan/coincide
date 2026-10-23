import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private final class ClaudeHistoryUIStorage: CodexCredentialStorage, @unchecked Sendable {
    func read(instanceID: UUID) -> Data? { Issue.record("Claude UI must not read credentials."); return nil }
    func write(_ data: Data, instanceID: UUID) { Issue.record("Claude UI must not write credentials.") }
    func delete(instanceID: UUID) { Issue.record("Claude UI must not delete credentials.") }
    func createIfAbsent(_ data: Data, instanceID: UUID) -> Bool { Issue.record("Claude UI must not create credentials."); return false }
}
private actor ClaudeHistoryUIOAuth: CodexOAuthTransport {
    func response(for request: URLRequest, maximumBytes: Int) throws -> CodexOAuthHTTPResponse {
        Issue.record("Claude UI must not make an authentication request."); throw CancellationError()
    }
}
private final class ClaudeHistoryUICapture: @unchecked Sendable {
    let configuration: ClaudeRuntimeConfiguration
    let fails: Bool
    private let lock = NSLock()
    private var paths: [String] = []
    private var submitted: [CodingThread] = []
    private var metadata: [CodingThread] = []
    init(configuration: ClaudeRuntimeConfiguration, fails: Bool) { self.configuration = configuration; self.fails = fails }
    var captures: [String] { lock.withLock { paths } }
    var inputs: [CodingThread] { lock.withLock { submitted } }
    var modelRequests: [CodingThread] { lock.withLock { metadata } }
    func capture(_ path: String) throws -> ClaudeRuntimeConfiguration {
        lock.withLock { paths.append(path) }
        if fails { throw CoincideError("Synthetic unavailable Claude launcher") }
        #expect(path == configuration.registeredWorkspacePath)
        return configuration
    }
    func record(_ thread: CodingThread) { lock.withLock { submitted.append(thread) } }
    func recordModels(_ thread: CodingThread) { lock.withLock { metadata.append(thread) } }
}
private actor ClaudeHistoryUIPeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private let capture: ClaudeHistoryUICapture
    private let configured: CodingThread
    init(capture: ClaudeHistoryUICapture, thread: CodingThread) {
        self.capture = capture; configured = thread
        let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation
    }
    func models() -> [ProviderModel] {
        capture.recordModels(configured)
        return [.init(id: configured.claudeRuntimeConfiguration == nil ? "legacy-ambient" : "captured-workspace", name: "Offline model")]
    }
    func send(text: String, thread: CodingThread) { capture.record(thread) }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { sink.finish() }
}
@MainActor private struct ClaudeHistoryUIFixture {
    let root: URL
    let store: WorkspaceStore
    let engine: WorkspaceEngine
    let capture: ClaudeHistoryUICapture
    let legacyID: UUID
    let otherID: UUID
    let nativeID: String
    static func make(failingCapture: Bool = false) async throws -> Self {
        let pointer = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        let temporary = URL(fileURLWithPath: String(cString: pointer)); free(pointer)
        let root = temporary.appendingPathComponent("coincide-claude-history-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let executable = root.appendingPathComponent("claude-never-executed")
            try Data("#!/bin/sh\nexit 99\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let project = WorkspaceProject(path: root.path), nativeID = UUID().uuidString.lowercased()
            let runtime = ClaudeRuntimeConfiguration(executable: executable.path,
                configurationDirectory: root.appendingPathComponent("PrivateClaude").path, workspacePath: root.path,
                registeredWorkspacePath: project.path)
            let capture = ClaudeHistoryUICapture(configuration: runtime, fails: failingCapture)
            var legacy = CodingThread(project: project); legacy.provider = .claude; legacy.providerThreadID = nativeID
            legacy.draft = "Keep the latest Unicode draft 工作 😀"; legacy.checkpointPolicy = .disabled
            var other = CodingThread(project: project); other.checkpointPolicy = .disabled
            var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [legacy, other]
            let database = root.appendingPathComponent("workspace.sqlite")
            try await WorkspaceDatabase(url: database).save(snapshot, event: "claude.history.ui.fixture")
            let engine = try WorkspaceEngine(url: database, providerFactory: { ClaudeHistoryUIPeer(capture: capture, thread: $0) }, identityResolver: { _ in nil })
            let transport = ClaudeHistoryUIOAuth()
            let broker = CodexOwnedRuntimeBroker(storage: ClaudeHistoryUIStorage(), lockRoot: root.appendingPathComponent("locks"),
                homesRoot: root.appendingPathComponent("homes"), clientFactory: { CodexOAuthClient(transport: transport) })
            let store = WorkspaceStore(engine: engine, codexOwnedRuntime: broker, codexHostID: UUID(),
                codexListenerFactory: { Issue.record("Claude UI must not open a sign-in listener."); throw CancellationError() },
                codexAuthorization: { _ in Issue.record("Claude UI must not open a browser."); throw CancellationError() },
                claudeRuntimeCapture: { try capture.capture($0) })
            await store.load()
            return .init(root: root, store: store, engine: engine, capture: capture,
                legacyID: legacy.id, otherID: other.id, nativeID: nativeID)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func close() async { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
}
@MainActor private func waitClaudeHistoryUI(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The offline Claude UI boundary did not settle.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeClaudeLegacySubmitCapturesRuntimeAtomicallyAndQueuesWithoutChangingLiveIdentity() async throws {
    let fixture = try await ClaudeHistoryUIFixture.make()
    do {
        #expect(fixture.store.thread(fixture.legacyID)?.claudeRuntimeConfiguration == nil && fixture.capture.captures.isEmpty)
        #expect(await fixture.store.submit("First explicit input", threadID: fixture.legacyID).value)
        try await waitClaudeHistoryUI { fixture.capture.inputs.count == 1 }
        let live = try #require(fixture.store.thread(fixture.legacyID)), runID = try #require(live.activeRun?.id)
        #expect(live.claudeRuntimeConfiguration == fixture.capture.configuration && live.providerThreadID == fixture.nativeID)
        #expect(live.activeRun?.configuration.claudeRuntimeConfiguration == fixture.capture.configuration)
        #expect(fixture.capture.inputs[0].activeRun?.configuration.claudeRuntimeConfiguration == fixture.capture.configuration)
        #expect(await fixture.store.submit("Second explicit input", threadID: fixture.legacyID).value)
        let queued = try #require(fixture.store.thread(fixture.legacyID))
        #expect(queued.activeRun?.id == runID && queued.providerThreadID == fixture.nativeID)
        #expect(queued.queuedTurns.count == 1 && queued.queuedTurns[0].configuration.claudeRuntimeConfiguration == fixture.capture.configuration)
        #expect(fixture.capture.captures == [fixture.capture.configuration.registeredWorkspacePath] && fixture.capture.inputs.count == 1)
    } catch { await fixture.close(); throw error }
    await fixture.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeClaudeProviderSelectionBindsRuntimeBeforeAnyInputAndKeepsOtherConversation() async throws {
    let fixture = try await ClaudeHistoryUIFixture.make()
    do {
        let original = try #require(fixture.store.thread(fixture.legacyID))
        fixture.store.setProvider(.claude, id: fixture.otherID)
        try await waitClaudeHistoryUI { fixture.store.thread(fixture.otherID)?.provider == .claude }
        let selected = try #require(fixture.store.thread(fixture.otherID))
        #expect(selected.claudeRuntimeConfiguration == fixture.capture.configuration && selected.providerThreadID == nil)
        #expect(fixture.capture.inputs.isEmpty && fixture.store.thread(fixture.legacyID) == original)
        fixture.store.setProvider(.claude, id: fixture.otherID)
        #expect(fixture.capture.captures == [fixture.capture.configuration.registeredWorkspacePath])
    } catch { await fixture.close(); throw error }
    await fixture.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeClaudeCapturedModelsUseTheirExactThreadRuntimeAndDoNotReuseAmbientCatalog() async throws {
    let fixture = try await ClaudeHistoryUIFixture.make()
    do {
        fixture.store.selectedThreadID = fixture.legacyID
        await fixture.store.refreshModels(provider: .claude)
        #expect(fixture.store.models(for: .claude).map(\.id) == ["legacy-ambient"])
        fixture.store.setProvider(.claude, id: fixture.otherID)
        try await waitClaudeHistoryUI { fixture.store.thread(fixture.otherID)?.claudeRuntimeConfiguration != nil }
        fixture.store.selectedThreadID = fixture.otherID
        let selected = try #require(fixture.store.thread(fixture.otherID))
        #expect(fixture.store.models(for: selected).isEmpty, "Ambient metadata cannot fill a captured runtime's model picker.")
        await fixture.store.refreshModels(provider: .claude)
        #expect(fixture.capture.modelRequests.last?.claudeRuntimeConfiguration == fixture.capture.configuration)
        #expect(fixture.capture.modelRequests.last?.workspacePath == selected.workspacePath)
        #expect(fixture.store.models(for: selected).map(\.id) == ["captured-workspace"])
        var changed = selected
        changed.claudeRuntimeConfiguration = .init(executable: fixture.capture.configuration.executable,
            configurationDirectory: fixture.root.appendingPathComponent("DifferentClaude").path, workspacePath: fixture.root.path,
            registeredWorkspacePath: selected.workspacePath)
        #expect(fixture.store.models(for: changed).isEmpty)
        changed = selected; changed.id = UUID()
        #expect(fixture.store.models(for: changed).isEmpty && fixture.capture.inputs.isEmpty)
    } catch { await fixture.close(); throw error }
    await fixture.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeClaudeUnavailableCapturePreservesProviderDraftAndNativeIdentityWithoutFallback() async throws {
    let fixture = try await ClaudeHistoryUIFixture.make(failingCapture: true)
    do {
        let legacy = try #require(fixture.store.thread(fixture.legacyID)), other = try #require(fixture.store.thread(fixture.otherID))
        #expect(await fixture.store.submit("Must stay unsent", threadID: fixture.legacyID).value == false)
        fixture.store.setProvider(.claude, id: fixture.otherID)
        #expect(fixture.store.thread(fixture.legacyID) == legacy && fixture.store.thread(fixture.otherID) == other)
        #expect(fixture.capture.inputs.isEmpty && fixture.store.errorMessage == "Install and sign in to Claude before sending a message.")
    } catch { await fixture.close(); throw error }
    await fixture.close()
}

@MainActor private func claudeUIReview(_ fixture: ClaudeHistoryUIFixture, shape: String) throws -> (WorkspaceSnapshot, ConversationHistoryReview, ClaudeHistoryResult) {
    let runtime = fixture.capture.configuration, nativeID = fixture.nativeID
    var thread = try #require(fixture.store.thread(fixture.legacyID))
    thread.workspacePath = runtime.registeredWorkspacePath
    thread.claudeRuntimeConfiguration = runtime
    let nativeProject = URL(fileURLWithPath: runtime.configurationDirectory).appendingPathComponent("projects").appendingPathComponent(runtime.projectKey)
    try FileManager.default.createDirectory(at: nativeProject, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let runIDs = [UUID(), UUID()], assistantIDs = [UUID().uuidString.lowercased(), UUID().uuidString.lowercased()]
    let inheritedID = UUID().uuidString.lowercased()
    var native: [JSONValue] = [], parent: String?
    func append(_ id: String, role: String, text: String) {
        native.append(.object(["type": .string(role), "uuid": .string(id), "sessionId": .string(nativeID),
            "parentUuid": parent.map(JSONValue.string) ?? .null, "cwd": .string(runtime.workspacePath),
            "isSidechain": .bool(false), "timestamp": .string("2026-10-23T00:00:00.000Z"),
            "message": .object(["role": .string(role), "content": role == "user" ? .string(text) :
                .array([.object(["type": .string("text"), "text": .string(text)])])])]))
        parent = id
    }
    if shape == "inherited" {
        append(UUID().uuidString.lowercased(), role: "user", text: "Inherited native input")
        append(inheritedID, role: "assistant", text: "Inherited native answer")
        thread.messages = [.init(id: "inherited-user", role: .user, text: "Inherited input"), .init(id: "inherited-assistant", role: .assistant, text: "Inherited answer")]
        thread.claudeInheritedHead = try .init(runtimeIdentity: runtime.runtimeIdentity, nativeSessionID: nativeID, cursor: inheritedID)
    }
    for index in runIDs.indices {
        let runID = runIDs[index], opening = ClaudeInputIdentity.opening(runID: runID)
        append(opening, role: "user", text: "Native input \(index)")
        append(assistantIDs[index], role: "assistant", text: "Native answer \(index)")
        let active = ActiveRun(id: runID, configuration: .init(thread: thread), startedAt: Date(), nativeTurnID: opening)
        var record = ThreadRunRecord(run: active, origin: .user, userMessageID: "user-\(runID)")
        record.status = .completed; record.endedAt = Date(); record.endReason = .providerCompleted; record.messageAttributionVersion = 1
        var observed = try #require(record.claude)
        try observed.observe(nativeSessionID: nativeID, inputIDs: [opening], rootAssistantMessageID: assistantIDs[index])
        try observed.finish(.completed); record.claude = observed
        if thread.runHistory == nil { thread.runHistory = [] }; thread.runHistory?.append(record)
        var user = ChatMessage(id: "user-\(runID)", role: .user, text: "Original input \(index)")
        var reply = ChatMessage(id: "reply-\(runID)", role: .assistant, text: "Original answer \(index)")
        user.runReference = .init(threadID: thread.id, runID: runID); reply.runReference = user.runReference
        thread.messages += [user, reply]
    }
    var bytes = Data()
    for record in native { bytes.append(try JSONEncoder().encode(record)); bytes.append(10) }
    let file = nativeProject.appendingPathComponent(nativeID + ".jsonl")
    try bytes.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let service = try ClaudeHistoryService(configuration: runtime), source = try service.snapshot(sessionID: nativeID)
    var snapshot = fixture.store.snapshot
    let threadIndex = try #require(snapshot.threads.firstIndex { $0.id == thread.id }); snapshot.threads[threadIndex] = thread
    let selected = shape == "fresh" || shape == "inherited" ? runIDs[0] : runIDs[1]
    let evidence = try ClaudeHistoryReviewEvidence.make(source: source, snapshot: snapshot, thread: thread, runID: selected, kind: .rewindBeforeRun)
    let prefix = try thread.transcriptPrefix(runID: selected, boundary: .beforeRun), prefixIDs = Set(prefix.map(\.id))
    let review = try ConversationHistoryReview(kind: .rewindBeforeRun, sourceThreadID: thread.id, projectID: thread.projectID,
        runID: selected, sourceIncarnation: UUID(), sourceConfiguration: .init(thread: thread), targetConfiguration: .init(thread: thread),
        sourceReference: source.reference, reviewedHeadTurnID: nil, boundary: evidence.boundary.providerBoundary, expectedResultHeadTurnID: nil,
        prefix: prefix, removedRunIDs: shape == "fresh" || shape == "inherited" ? runIDs : [selected],
        removedMessageIDs: thread.messages.filter { !prefixIDs.contains($0.id) }.map(\.id),
        sourceFingerprint: try snapshot.historySourceFingerprint(threadID: thread.id), targetThreadID: nil,
        suggestedTitle: "Selected Claude context", recallPromptOnSuccess: true, claude: evidence)
    return (snapshot, review, try service.prepareRewind(review: evidence, selectionID: review.id))
}

@Test(.timeLimit(.minutes(1)), arguments: ["resume", "fresh", "inherited"]) @MainActor
func nativeClaudeHistoryReviewExplainsDeferredContextAndFitsBothNativeAppearances(shape: String) async throws {
    _ = NSApplication.shared
    let fixture = try await ClaudeHistoryUIFixture.make()
    do {
        let (_, review, result) = try claudeUIReview(fixture, shape: shape)
        let operation = ConversationHistoryOperation(review: review, phase: .applied,
            result: try .init(reference: result.reference, workspacePath: result.workspacePath, historyMode: .nativeTranscript, claude: result))
        #expect(ConversationHistoryPresentation.status(operation) == "Claude resume point saved")
        #expect(ConversationHistoryPresentation.reviewSummary(review, kind: .rewindBeforeRun).contains("no message is sent"))
        let detail = ConversationHistoryPresentation.claudeContextDetail(review)
        if shape == "fresh" { #expect(detail.contains("no native transcript is created until you send")) }
        else if shape == "inherited" { #expect(detail.contains("inherited fork head") && detail.contains("inherited context is kept")) }
        else { #expect(detail.contains("not deleted or truncated")) }
        for scheme in [ColorScheme.light, .dark] {
            for width: CGFloat in [320, 680] {
                let view = ConversationHistoryReviewContent(review: review, kind: .rewindBeforeRun,
                    title: .constant(""), loading: false, accepting: false, error: nil, operation: nil,
                    openingPrompt: "Original Unicode input 工作 😀", confirm: {}, close: {}) { EmptyView() }
                    .environment(\.colorScheme, scheme)
                let controller = NSHostingController(rootView: view)
                let size = controller.sizeThatFits(in: .init(width: width, height: 650))
                #expect(size.width <= width + 1 && size.height <= 650)
            }
        }
        #expect(fixture.capture.inputs.isEmpty && fixture.capture.captures.isEmpty)
    } catch { await fixture.close(); throw error }
    await fixture.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeClaudeResumeBannerTracksExactSelectionAfterRecallAndShowsFailedConsumerInspection() async throws {
    _ = NSApplication.shared
    let fixture = try await ClaudeHistoryUIFixture.make()
    do {
        let sequence = await fixture.engine.current().sequence
        let (source, review, result) = try claudeUIReview(fixture, shape: "resume")
        let selection = try #require(result.selection)
        var operation = ConversationHistoryOperation(review: review, phase: .applied,
            result: try .init(reference: result.reference, workspacePath: result.workspacePath, historyMode: .nativeTranscript, claude: result))
        operation.recalledAt = Date()
        var applied = source
        let index = try #require(applied.threads.firstIndex { $0.id == review.sourceThreadID })
        for i in applied.threads[index].messages.indices where review.removedMessageIDs.contains(applied.threads[index].messages[i].id) {
            applied.threads[index].messages[i].removedByHistoryOperationID = operation.id
        }
        for i in (applied.threads[index].runHistory ?? []).indices where review.removedRunIDs.contains(applied.threads[index].runHistory![i].id) {
            applied.threads[index].runHistory?[i].removedByHistoryOperationID = operation.id
        }
        applied.threads[index].claudeResumeSelection = selection
        applied.conversationHistoryOperations = [operation]
        fixture.store.snapshot = applied
        #expect(!operation.needsPromptRecall && fixture.store.hasPendingClaudeResumeSelection(operation))
        #expect(!fixture.store.claudeResumeSelectionNeedsInspection(threadID: review.sourceThreadID))
        let chat = ChatView(store: fixture.store, threadID: review.sourceThreadID)
        #expect(!chat.composerHistoryLocked)
        let consumerID = UUID()
        var consuming = ProviderConfiguration(thread: applied.threads[index]); consuming.claudeLaunchSelection = selection
        let run = ActiveRun(id: consumerID, configuration: consuming, startedAt: Date())
        var failed = ThreadRunRecord(run: run, origin: .user, userMessageID: "failed-user-\(consumerID)")
        failed.status = .failed; failed.endedAt = Date(); failed.endReason = .providerFailure; failed.messageAttributionVersion = 1
        var observed = try #require(failed.claude)
        try observed.observe(nativeSessionID: selection.nativeSessionID)
        try observed.finish(.failed); failed.claude = observed
        var input = ChatMessage(id: "failed-user-\(consumerID)", role: .user, text: "Previous explicit input; do not replay")
        input.runReference = .init(threadID: review.sourceThreadID, runID: consumerID)
        applied.threads[index].messages.append(input); applied.threads[index].runHistory?.append(failed)
        applied.threads[index].claudeResumeConsumerRunID = consumerID; applied.threads[index].state = .failed
        fixture.store.snapshot = applied
        #expect(fixture.store.claudeResumeSelectionNeedsInspection(threadID: review.sourceThreadID))
        #expect(chat.composerHistoryLocked, "A failed selected-context consumer holds nonempty composer input until read-only inspection.")
        #expect(!fixture.store.snapshot.isConversationHistoryLocked(threadID: review.sourceThreadID), "The inspection action must remain available outside the composer hold.")
        let held = fixture.store.snapshot
        #expect(await fixture.store.submit("A held explicit input must remain unsent", threadID: review.sourceThreadID).value == false)
        #expect(fixture.store.snapshot == held && fixture.capture.inputs.isEmpty && fixture.capture.captures.isEmpty)
        #expect(await fixture.engine.current().sequence == sequence, "A held submission must not clear the draft or enter command admission.")
        let view = ConversationHistoryOperationView(store: fixture.store, operation: operation)
        let controller = NSHostingController(rootView: view)
        let size = controller.sizeThatFits(in: .init(width: 320, height: 650))
        #expect(size.width <= 321 && size.height <= 650)
        let unrelated = try ClaudeResumeSelection(nativeSessionID: selection.nativeSessionID, cursor: selection.cursor,
            discardedInputID: selection.discardedInputID, kind: selection.kind,
            reviewedLocation: selection.reviewedLocation, reviewedRevision: selection.reviewedRevision)
        fixture.store.snapshot.threads[index].claudeResumeSelection = unrelated
        #expect(!fixture.store.hasPendingClaudeResumeSelection(operation), "An old applied review must not describe another selection.")
        fixture.store.snapshot.threads[index].claudeResumeSelection = nil
        fixture.store.snapshot.threads[index].claudeResumeConsumerRunID = nil
        #expect(!fixture.store.hasPendingClaudeResumeSelection(operation))
        #expect(!chat.composerHistoryLocked)
        #expect(fixture.capture.inputs.isEmpty)
    } catch { await fixture.close(); throw error }
    await fixture.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeClaudeUnconfirmedForkOffersInspectionOnlyForItsDurableReservedCandidate() async throws {
    _ = NSApplication.shared
    let fixture = try await ClaudeHistoryUIFixture.make()
    do {
        let (snapshot, rewind, _) = try claudeUIReview(fixture, shape: "resume")
        let original = try #require(rewind.claude), head = try #require(original.source.headMessageID)
        let evidence = try ClaudeHistoryReviewEvidence(source: original.source, kind: .forkAfterRun,
            runID: rewind.runID, inputs: original.inputs, boundary: .throughMessage(head),
            retainedMessageIDs: original.source.selectedMessageIDs)
        let thread = try #require(snapshot.threads.first { $0.id == rewind.sourceThreadID })
        let review = try ConversationHistoryReview(kind: .forkAfterRun, sourceThreadID: thread.id, projectID: thread.projectID,
            runID: rewind.runID, sourceIncarnation: rewind.sourceIncarnation,
            sourceConfiguration: rewind.sourceConfiguration, targetConfiguration: rewind.targetConfiguration,
            sourceReference: rewind.sourceReference, reviewedHeadTurnID: nil, boundary: evidence.boundary.providerBoundary,
            expectedResultHeadTurnID: nil, prefix: thread.visibleMessages, removedRunIDs: [], removedMessageIDs: [],
            sourceFingerprint: rewind.sourceFingerprint, targetThreadID: UUID(), suggestedTitle: "Reserved native fork", claude: evidence)
        let service = try ClaudeHistoryService(configuration: fixture.capture.configuration)
        let plan = try service.prepareFork(review: evidence, targetSessionID: UUID().uuidString.lowercased())
        var operation = ConversationHistoryOperation(review: review, phase: .unconfirmed,
            error: ConversationHistoryOperation.unconfirmedMessage, claudeForkPublication: plan.publication)
        try operation.validate()
        fixture.store.snapshot = snapshot; fixture.store.snapshot.conversationHistoryOperations = [operation]
        #expect(fixture.store.canInspectConversationHistory(operation))
        #expect(fixture.store.thread(review.targetThreadID!) == nil && fixture.capture.inputs.isEmpty)
        for scheme in [ColorScheme.light, .dark] {
            let content = ConversationHistoryOperationView(store: fixture.store, operation: operation).environment(\.colorScheme, scheme)
            let controller = NSHostingController(rootView: content)
            let size = controller.sizeThatFits(in: .init(width: 320, height: 650))
            #expect(size.width <= 321 && size.height <= 650)
        }
        operation.claudeForkPublication = nil
        fixture.store.snapshot.conversationHistoryOperations = [operation]
        #expect(!fixture.store.canInspectConversationHistory(operation))
        if case .notStarted = try service.inspectFork(review: evidence, publication: plan.publication) {} else {
            Issue.record("Rendering the recovery view must not publish its candidate.")
        }
    } catch { await fixture.close(); throw error }
    await fixture.close()
}
