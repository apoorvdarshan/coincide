import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private final class NativePiHistoryLaunches: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}
private actor NativePiHistoryForbiddenSession: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent> = AsyncStream { $0.finish() }
    func models() -> [ProviderModel] { Issue.record("History presentation must not discover models."); return [] }
    func send(text: String, thread: CodingThread) { Issue.record("History presentation must not send a prompt.") }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) { Issue.record("History controls must not answer a chat runtime.") }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { Issue.record("History controls must not answer a chat runtime.") }
    func close() {}
}

@MainActor private struct NativePiHistoryUIFixture {
    let root: URL
    let store: WorkspaceStore
    let source: CodingThread
    let snapshot: WorkspaceSnapshot
    let review: ConversationHistoryReview
    let launches: NativePiHistoryLaunches

    static func make(inherited: Bool = false, fork: Bool = false) async throws -> Self {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pi-history-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let physical = try PiRuntimeConfiguration.physical(requested.path), root = URL(fileURLWithPath: physical)
        do {
            let project = WorkspaceProject(path: root.path)
            let runtime = try PiRuntimeConfiguration(instanceID: UUID(), executable: "/usr/bin/true", requestedExecutable: "pi",
                workspacePath: physical, registeredWorkspacePath: project.path, homeDirectory: physical,
                agentDirectory: physical + "/.pi/agent", agentDirectorySelection: .defaultHome(homeDirectory: physical))
            let file = physical + "/native-source.jsonl", nativeID = UUID().uuidString.lowercased()
            let stamp = "2026-10-23T00:00:00.000Z"
            let header: JSONValue = .object(["type": .string("session"), "version": .number(3), "id": .string(nativeID),
                "cwd": .string(physical), "timestamp": .string(stamp)])
            func entry(_ id: String, parent: String?, role: String, text: String) -> JSONValue {
                .object(["type": .string("message"), "id": .string(id), "parentId": parent.map(JSONValue.string) ?? .null,
                    "timestamp": .string(stamp), "message": .object(["role": .string(role), "content": .string(text)])])
            }
            var rows: [JSONValue] = [], parent: String?
            if inherited {
                rows = [entry("inherited-user", parent: nil, role: "user", text: "Inherited context"),
                        entry("inherited-answer", parent: "inherited-user", role: "assistant", text: "Inherited reply")]
                parent = "inherited-answer"
            }
            let baseline = try PiHistoryGraph(header: header, entries: rows, leafID: parent)
            let before = try PiRuntimeEntryObservation(nativeSessionFile: file, nativeSessionID: nativeID, leafID: parent,
                entries: baseline.entries.map(PiHistoryEntryDescriptor.init))
            let prompt = "Original exact input 工作 مرحباً 😀", runID = UUID(), userID = "user-" + runID.uuidString.lowercased()
            rows += [entry("opening-user", parent: parent, role: "user", text: prompt),
                     entry("final-answer", parent: "opening-user", role: "assistant", text: "Native reply")]
            let graph = try PiHistoryGraph(header: header, entries: rows, leafID: "final-answer")
            let observed = try PiRuntimeEntryObservation(nativeSessionFile: file, nativeSessionID: nativeID, leafID: graph.leafID,
                entries: graph.entries.map(PiHistoryEntryDescriptor.init))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var bytes = Data()
            for row in [header] + rows { bytes.append(try encoder.encode(row)); bytes.append(10) }
            try bytes.write(to: URL(fileURLWithPath: file), options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
            var thread = CodingThread(project: project); thread.provider = .pi
            thread.piConfiguration = .init(instanceID: runtime.instanceID, executable: "pi", runtime: runtime)
            thread.providerThreadID = file; thread.draft = "Latest unsent draft 😀"; thread.checkpointPolicy = .disabled
            let run = ActiveRun(id: runID, configuration: .init(thread: thread), startedAt: .now)
            var record = ThreadRunRecord(run: run, origin: .user, userMessageID: userID)
            let opening = try PiHistoryInputEvidence(clientMessageID: userID, inputDigest: PiHistoryInputEvidence.digest(.init(text: prompt)), kind: .opening)
            let preparation = try PiRunHistoryPreparation(runID: runID, runtimeIdentity: thread.piConfiguration!.runtimeIdentity,
                observedVersion: "0.80.5", openingInput: opening, baseline: before)
            var mapped = opening; mapped.nativeUserEntryID = "opening-user"
            record.pi = try .init(preparation: preparation, inputs: [mapped], finalObservation: observed,
                openingUserEntryID: "opening-user", nativeUserEntryIDs: ["opening-user"], captureStatus: .proven, terminalStatus: .completed)
            record.status = .completed; record.endedAt = .now; record.endReason = .providerCompleted; record.messageAttributionVersion = 1
            var user = ChatMessage(id: userID, role: .user, text: prompt), answer = ChatMessage(id: "local-answer", role: .assistant, text: "Native reply")
            user.runReference = .init(threadID: thread.id, runID: runID); answer.runReference = user.runReference
            thread.runHistory = [record]; thread.messages = [user, answer]
            var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
            let kind: ConversationHistoryKind = fork ? .forkAfterRun : .rewindBeforeRun, operationID = UUID()
            let service = try PiHistoryService(configuration: runtime, workerRootURL: root.appendingPathComponent("Workers"))
            let native = try service.snapshot(observation: observed, observedVersion: "0.80.5")
            let evidence = try PiHistoryReviewEvidence.make(source: native, snapshot: snapshot, thread: thread, runID: runID,
                kind: kind, operationID: operationID)
            let review = try ConversationHistoryReview(id: operationID, kind: kind, sourceThreadID: thread.id, projectID: project.id,
                runID: runID, sourceIncarnation: UUID(), sourceConfiguration: .init(thread: thread), targetConfiguration: record.configuration,
                sourceReference: native.reference, reviewedHeadTurnID: nil, boundary: evidence.boundary.providerBoundary,
                expectedResultHeadTurnID: nil, prefix: fork ? thread.visibleMessages : [], removedRunIDs: fork ? [] : [runID],
                removedMessageIDs: fork ? [] : thread.messages.map(\.id), sourceFingerprint: snapshot.historySourceFingerprint(threadID: thread.id),
                targetThreadID: fork ? UUID() : nil, suggestedTitle: "Pi native branch 工作 مرحباً", recallPromptOnSuccess: !fork, pi: evidence)
            let database = root.appendingPathComponent("workspace.sqlite")
            try await WorkspaceDatabase(url: database).save(snapshot, event: "native.pi.history.ui.fixture")
            let launches = NativePiHistoryLaunches()
            let engine = try WorkspaceEngine(url: database, providerFactory: { _ in launches.record(); return NativePiHistoryForbiddenSession() }, identityResolver: { _ in nil })
            let store = WorkspaceStore(engine: engine, runtimeInstallation: .init(rootURL: root.appendingPathComponent("Antigravity"), release: nil),
                codexInstallation: .init(rootURL: root.appendingPathComponent("Codex"), release: nil))
            await store.load()
            return .init(root: root, store: store, source: thread, snapshot: snapshot, review: review, launches: launches)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func finish() async { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
    func pending(method: PiExtensionRequest.Method = .confirm) -> (ConversationHistoryOperation, ApprovalRequest, UUID) {
        let generation = UUID()
        let request = ApprovalRequest(id: .string("reused-native-request-id"), method: "pi/extension", params: .object([
            "method": .string(method.rawValue), "title": .string("Verify this exact Pi branch 工作 مرحباً " + String(repeating: "long choice ", count: 8)),
            "message": .string("This belongs to the history operation, not the active conversation."),
            "options": .array([.string("Keep inherited context 工作"), .string("Cancel مرحباً")]), "prefill": .string("Unsent extension note 😀")]))
        var operation = ConversationHistoryOperation(review: review, phase: .dispatching)
        operation.piControls = .init(sessionID: generation, requests: [.init(request: request, sessionScoped: true)])
        return (operation, request, generation)
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativePiHistoryControlsRejectReusedIDsChangedPayloadsAndTerminalGenerationsWithoutAnsweringChat() async throws {
    let fixture = try await NativePiHistoryUIFixture.make()
    do {
        let store = fixture.store
        let (operation, request, generation) = fixture.pending()
        store.snapshot.conversationHistoryOperations = [operation]
        #expect(store.canRespondPiHistory(operationID: operation.id, sessionID: generation, requestID: request.id))
        #expect(store.canCancelPiHistory(operation) && !store.isRespondingPiHistory(operationID: operation.id, sessionID: generation, requestID: request.id))
        #expect(!store.canRespondPiHistory(operationID: operation.id, sessionID: UUID(), requestID: request.id))
        var changed = request; changed.params = .object(["method": .string("confirm"), "title": .string("A different question")])
        do { try await store.respondPiHistory(operationID: operation.id, sessionID: generation, request: changed, response: .decision(true)); Issue.record("A stale question payload was admitted.") }
        catch is CancellationError {} catch { Issue.record("A stale question should be rejected before Engine I/O.") }
        var next = operation; next.piControls = .init(sessionID: UUID(), requests: [.init(request: request, sessionScoped: true)])
        store.snapshot.conversationHistoryOperations = [next]
        do { try await store.respondPiHistory(operationID: operation.id, sessionID: generation, request: request, response: .decision(true)); Issue.record("An old worker generation was admitted.") }
        catch is CancellationError {} catch { Issue.record("An old worker should be rejected before Engine I/O.") }
        next.piControls = .init(sessionID: generation, requests: [.init(request: request, responding: true, sessionScoped: true)])
        store.snapshot.conversationHistoryOperations = [next]
        #expect(!store.canRespondPiHistory(operationID: operation.id, sessionID: generation, requestID: request.id))
        next.phase = .unconfirmed; store.snapshot.conversationHistoryOperations = [next]
        #expect(!store.canCancelPiHistory(next) && !store.canRespondPiHistory(operationID: operation.id, sessionID: generation, requestID: request.id))
        #expect(!store.canClearConversationHistoryMaintenance(next) && !store.canKeepOpenCodeV1Original(next))
        #expect(store.thread(fixture.source.id)?.draft == fixture.source.draft && fixture.launches.count == 0)
        #expect(store.thread(fixture.source.id)?.runHistory?.first?.turnIDs.isEmpty == true)
    } catch { await fixture.finish(); throw error }
    await fixture.finish()
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func nativePiHistoryReviewsDistinguishEmptyResetFromInheritedBranchWithoutSendingOrCreatingCopies(inherited: Bool) async throws {
    let fixture = try await NativePiHistoryUIFixture.make(inherited: inherited)
    do {
        let evidence = try #require(fixture.review.pi)
        if inherited {
            #expect(evidence.retainedLeafID == "inherited-answer" && evidence.retainedEntries.map(\.id) == ["inherited-user", "inherited-answer"])
            #expect(fixture.review.boundary == .beforePiUserEntry("opening-user"))
        } else {
            if case .freshPiSession = fixture.review.boundary {} else { Issue.record("First local run must select an explicit empty-context intent.") }
            #expect(evidence.retainedEntries.isEmpty && evidence.retainedLeafID == nil)
        }
        #expect(fixture.review.reviewedHeadTurnID == nil && fixture.review.expectedResultHeadTurnID == nil)
        #expect(ConversationHistoryPresentation.piContextDetail(fixture.review) != ConversationHistoryPresentation.claudeContextDetail(fixture.review))
        #expect(fixture.store.thread(fixture.source.id) == fixture.source && fixture.launches.count == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Workers").path), "Review and presentation cannot allocate a native history worker.")
    } catch { await fixture.finish(); throw error }
    await fixture.finish()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativePiHistoryReviewQuestionsAndRecoveryFitNarrowNativeSheetsWithoutSideEffects() async throws {
    _ = NSApplication.shared
    for shape in ["empty", "inherited", "unknown-fork"] {
        let fixture = try await NativePiHistoryUIFixture.make(inherited: shape == "inherited", fork: shape == "unknown-fork")
        do {
            var (operation, _, _) = fixture.pending(method: shape == "empty" ? .input : .select)
            if shape == "unknown-fork" {
                operation.phase = .unconfirmed; operation.piControls = nil; operation.error = ConversationHistoryOperation.unconfirmedMessage
                let evidence = try #require(fixture.review.pi)
                let directory = fixture.root.path + "/Recorded Operation"
                operation.piCandidates = [try .init(operationID: operation.id, stage: .reserved,
                    runtimeIdentity: evidence.source.runtimeIdentity, operationDirectory: directory,
                    expectedParentSessionPath: evidence.source.reference.nativeThreadID,
                    sourceInventoryDigest: evidence.source.inventoryDigest, semanticDigest: evidence.semanticDigest),
                    try .init(operationID: operation.id, stage: .initialClone,
                    runtimeIdentity: evidence.source.runtimeIdentity, operationDirectory: directory,
                    nativeSessionFile: directory + "/recorded-copy.jsonl", nativeSessionID: "recorded-copy",
                    expectedParentSessionPath: evidence.source.reference.nativeThreadID,
                    sourceInventoryDigest: evidence.source.inventoryDigest, semanticDigest: evidence.semanticDigest)]
            }
            fixture.store.snapshot.conversationHistoryOperations = [operation]
            for scheme in [ColorScheme.light, .dark] {
                for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                    for width in [CGFloat(320), 680] {
                        let content = ConversationHistoryReviewContent(review: fixture.review, kind: fixture.review.kind,
                            title: .constant(""), loading: false, accepting: operation.isWorking, error: nil, operation: operation,
                            openingPrompt: "Original input 工作 مرحباً 😀", confirm: { Issue.record("Rendering cannot accept history.") }, close: {}) {
                                ConversationHistoryOperationView(store: fixture.store, operation: operation)
                            }.environment(\.colorScheme, scheme).environment(\.layoutDirection, direction)
                        let controller = NSHostingController(rootView: content), size = controller.sizeThatFits(in: .init(width: width, height: 650))
                        #expect(size.width.isFinite && size.height.isFinite && size.width <= width + 1 && size.height <= 650)
                        try captureNativePiHistory(content, size: size, scheme: scheme, direction: direction, shape: shape)
                    }
                }
            }
            #expect(fixture.launches.count == 0 && fixture.store.thread(fixture.source.id)?.draft == fixture.source.draft)
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
}

@MainActor private func captureNativePiHistory(_ view: some View, size: NSSize, scheme: ColorScheme, direction: LayoutDirection, shape: String) throws {
    guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_PI_HISTORY"] == "1" else { return }
    let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua)), previous = NSApp.appearance
    NSApp.appearance = appearance; defer { NSApp.appearance = previous }
    let window = NSWindow(contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = appearance; window.isReleasedWhenClosed = false; window.isOpaque = true; window.backgroundColor = .windowBackgroundColor
    defer { window.close() }
    var result: Result<Data, any Error>?
    appearance.performAsCurrentDrawingAppearance {
        result = Result {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = appearance; window.contentView = host; host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
    }
    let data = try #require(result).get()
    try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pi-history-\(shape)-\(Int(size.width))-\(scheme == .light ? "light" : "dark")-\(direction == .leftToRight ? "ltr" : "rtl").png"))
}
