import AppKit
import CSQLite
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

/// The native command is gated independently of its durable acceptance. Each
/// factory call still creates a distinct session actor and event stream.
private actor NativeHistoryPeer {
    let path: String
    private var head: String? = "turn-3"
    private var pending: CheckedContinuation<ProviderConversationSnapshot, any Error>?
    private var pendingKind: ConversationHistoryKind?
    private(set) var mutations: [ConversationHistoryKind] = []
    private(set) var factoryThreads: [UUID] = []
    private(set) var reads = 0
    init(path: String) { self.path = path }
    func made(_ id: UUID) { factoryThreads.append(id) }
    func snapshot(_ id: String) throws -> ProviderConversationSnapshot {
        reads += 1
        return try .init(reference: .init(provider: .codex, nativeThreadID: id), workspacePath: path,
                         historyMode: .paginated, headTurnID: id == "native-fork" ? "turn-2" : head)
    }
    func page(_ id: String) throws -> ProviderHistoryPage {
        let last = head == "turn-1" ? 1 : 3
        return try .init(reference: .init(provider: .codex, nativeThreadID: id),
                         turns: (1...last).reversed().map { try .init(id: "turn-\($0)", status: .completed) })
    }
    func mutate(_ kind: ConversationHistoryKind) async throws -> ProviderConversationSnapshot {
        mutations.append(kind)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pendingKind = kind; pending = continuation
            }
        } onCancel: { Task { await self.cancel() } }
    }
    func complete(uncertain: Bool = false) throws {
        let continuation = try #require(pending)
        let kind = try #require(pendingKind)
        pending = nil; pendingKind = nil
        if kind == .rewindBeforeRun { head = "turn-1" }
        if uncertain { continuation.resume(throwing: ProviderHistoryError(.outcomeUncertain)) }
        else { continuation.resume(returning: try snapshot(kind == .forkAfterRun ? "native-fork" : "native-source")) }
    }
    func cancel() { pending?.resume(throwing: CancellationError()); pending = nil; pendingKind = nil }
}

private actor NativeHistorySession: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    let peer: NativeHistoryPeer
    init(peer: NativeHistoryPeer) {
        self.peer = peer
        let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation
    }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) throws { throw CoincideError("This fixture never sends provider input.") }
    func interrupt() { }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { sink.finish() }
    func historyCapabilities(threadID: String) throws -> ProviderHistoryCapabilities {
        try .init(reference: .init(provider: .codex, nativeThreadID: threadID), historyMode: .paginated,
                  canRead: true, canForkHead: true, canForkFromTurn: true, canRevertBeforeTurn: true)
    }
    func conversationSnapshot(threadID: String) async throws -> ProviderConversationSnapshot { try await peer.snapshot(threadID) }
    func historyPage(threadID: String, cursor: String?, limit: Int) async throws -> ProviderHistoryPage { try await peer.page(threadID) }
    func forkConversation(source: ProviderConversationReference, boundary: ProviderHistoryBoundary,
                          configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot {
        #expect(boundary == .throughTurn("turn-2") && configuration.model == "recorded-model-2")
        return try await peer.mutate(.forkAfterRun)
    }
    func revertConversation(thread: ProviderConversationReference, beforeTurnID: String,
                            expectedHeadTurnID: String) async throws -> ProviderConversationSnapshot {
        #expect((beforeTurnID == "turn-2" && expectedHeadTurnID == "turn-3") ||
                (beforeTurnID == "turn-1" && expectedHeadTurnID == "turn-1"))
        return try await peer.mutate(.rewindBeforeRun)
    }
}

@MainActor private struct NativeHistoryFixture {
    let root: URL, database: URL, engine: WorkspaceEngine, store: WorkspaceStore, peer: NativeHistoryPeer
    let sourceID: UUID, otherID: UUID, runIDs: [UUID]
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-native-history-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let checkout = root.appendingPathComponent("Private synthetic checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        do {
            let project = WorkspaceProject(path: checkout.path)
            var source = CodingThread(project: project, model: "current-model")
            source.providerThreadID = "native-source"; source.permission = .auto
            source.title = "Source conversation"; source.draft = "Existing unsent draft"
            source.checkpointPolicy = .disabled
            let attachment = ChatAttachment(id: UUID(), name: "input.txt", mimeType: "text/plain", byteCount: 3,
                digest: String(repeating: "a", count: 64), fileExtension: "txt")
            source.draftAttachments = [attachment]
            let ids = (0..<3).map { _ in UUID() }
            for (index, id) in ids.enumerated() {
                var configuration = ProviderConfiguration(thread: source)
                configuration.model = "recorded-model-\(index + 1)"; configuration.permission = .supervised
                let started = Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 10))
                let run = ActiveRun(id: id, configuration: configuration, startedAt: started, nativeTurnID: "turn-\(index + 1)")
                var record = ThreadRunRecord(run: run, origin: .user, userMessageID: "prompt-\(index + 1)")
                record.status = .completed; record.endedAt = started.addingTimeInterval(2)
                record.endReason = .providerCompleted; record.messageAttributionVersion = 1
                if source.runHistory == nil { source.runHistory = [] }; source.runHistory!.append(record)
                var prompt = ChatMessage(id: "prompt-\(index + 1)", role: .user, text: "Original prompt \(index + 1)")
                prompt.attachments = index == 1 ? [attachment] : nil
                var reply = ChatMessage(id: "reply-\(index + 1)", role: .assistant, text: "Recorded reply \(index + 1)")
                prompt.createdAt = started; reply.createdAt = started.addingTimeInterval(1)
                prompt.runReference = .init(threadID: source.id, runID: id); reply.runReference = prompt.runReference
                source.messages += [prompt, reply]
            }
            var other = CodingThread(project: project); other.title = "Another conversation"; other.checkpointPolicy = .disabled
            var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [source, other]
            let database = root.appendingPathComponent("workspace.sqlite")
            _ = try await WorkspaceDatabase(url: database).commit(snapshot, event: "native-history-fixture", commandID: UUID())
            let peer = NativeHistoryPeer(path: checkout.path)
            let engine = try makeEngine(database: database, root: root, peer: peer)
            let store = WorkspaceStore(engine: engine); await store.load()
            store.selectedThreadID = source.id; store.selectedProjectID = project.id
            return .init(root: root, database: database, engine: engine, store: store, peer: peer,
                         sourceID: source.id, otherID: other.id, runIDs: ids)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    static func makeEngine(database: URL, root: URL, peer: NativeHistoryPeer) throws -> WorkspaceEngine {
        try .init(url: database, providerFactory: { thread in
            Task { await peer.made(thread.id) }
            return NativeHistorySession(peer: peer)
        }, identityResolver: { _ in nil })
    }
    func source() throws -> CodingThread { try #require(store.thread(sourceID)) }
    func operation(_ id: UUID) throws -> ConversationHistoryOperation { try #require(store.conversationHistoryOperation(id)) }
    func cleanup() async { await peer.cancel(); await store.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@MainActor private func waitNativeHistory(file: StaticString = #fileID, line: UInt = #line,
                                        _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Native history boundary timed out at \(file):\(line).") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func nativeHistoryForkAcceptsWithoutBlockingDraftAndPinCommandsAndRespectsSelectionSteering(steer: Bool) async throws {
    let f = try await NativeHistoryFixture.make(), store = f.store
    var writer: OpaquePointer?, locked = false
    func releaseWriter() {
        if locked { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil); locked = false }
    }
    defer { releaseWriter(); if let writer { sqlite3_close(writer) } }
    do {
        let before = try f.source()
        let review = try await store.reviewConversationHistory(threadID: f.sourceID, runID: f.runIDs[1], kind: .forkAfterRun)
        #expect(await f.peer.mutations.isEmpty && store.snapshot.conversationHistoryOperations == nil)
        #expect(review.prefix.count == 4 && review.targetConfiguration.model == "recorded-model-2")
        #expect(sqlite3_open(f.database.path, &writer) == SQLITE_OK)
        sqlite3_busy_timeout(writer, 5_000)
        #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        locked = true
        let acceptance = Task { try await store.beginConversationHistory(review, title: "Reviewed fork") }
        try await waitNativeHistory {
            store.conversationHistoryUnavailableReason(threadID: f.sourceID, runID: f.runIDs[1], kind: .forkAfterRun) != nil
        }
        #expect(!store.snapshot.isConversationHistoryLocked(threadID: f.sourceID), "The durable acceptance is still awaiting its SQLite acknowledgment.")
        store.setDraft("Draft while acceptance is pending", id: f.sourceID)
        #expect(await store.submit("Draft while acceptance is pending", threadID: f.sourceID).value == false)
        #expect(try f.source().draft == "Draft while acceptance is pending")
        releaseWriter()
        try await acceptance.value
        try await waitNativeHistory { await f.peer.mutations == [.forkAfterRun] }
        #expect(store.selectedThreadID == f.sourceID && store.thread(review.targetThreadID!) == nil)
        #expect(store.snapshot.isConversationHistoryLocked(threadID: f.sourceID))
        store.setDraft("Draft edited while the native fork is held", id: f.sourceID)
        store.togglePin(f.sourceID)
        try await waitNativeHistory {
            let source = await f.engine.current().snapshot.threads.first { $0.id == f.sourceID }
            return source?.isPinned == true && source?.draft == "Draft edited while the native fork is held"
        }
        if steer { store.selectedThreadID = f.otherID; store.selectedThreadID = f.sourceID }
        try await f.peer.complete()
        try await waitNativeHistory { try f.operation(review.id).phase == .applied }
        let target = try #require(store.thread(review.targetThreadID!)), source = try f.source()
        #expect(store.selectedThreadID == (steer ? f.sourceID : target.id))
        #expect(target.title == "Reviewed fork" && target.model == "recorded-model-2" && target.permission == .supervised)
        #expect(target.providerThreadID == "native-fork" && target.forkedFromHistoryOperationID == review.id)
        #expect(target.messages == review.prefix && target.runHistory == nil && target.draft.isEmpty)
        #expect(source.messages == before.messages && source.runHistory == before.runHistory)
        #expect(source.model == before.model && source.permission == before.permission && source.providerThreadID == before.providerThreadID)
        #expect(source.isPinned && source.draft == "Draft edited while the native fork is held")
        #expect(await f.peer.factoryThreads.contains(target.id))
        #expect(await f.peer.mutations == [.forkAfterRun])
    } catch { releaseWriter(); await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeHistoryRewindRetainsAuditAndSettingsAndRecallsInputIntoTheLatestDraftExactlyOnceAcrossReopen() async throws {
    let f = try await NativeHistoryFixture.make(), store = f.store
    do {
        let before = try f.source()
        let review = try await store.reviewConversationHistory(threadID: f.sourceID, runID: f.runIDs[1], kind: .rewindBeforeRun)
        try await store.beginConversationHistory(review)
        try await waitNativeHistory { await f.peer.mutations == [.rewindBeforeRun] }
        store.setDraft("Latest unsent text", id: f.sourceID)
        try await f.peer.complete()
        try await waitNativeHistory { try f.operation(review.id).phase == .applied }
        let source = try f.source()
        #expect(source.messages.count == 6 && source.runHistory?.count == 3 && source.visibleMessages.count == 2)
        #expect(source.model == before.model && source.permission == before.permission)
        #expect(source.draft == "Latest unsent text" && source.draftAttachments == before.draftAttachments)
        store.search = "Original prompt 3"; #expect(!store.visibleThreads.contains { $0.id == f.sourceID })
        store.search = "Original prompt 1"; #expect(store.visibleThreads.contains { $0.id == f.sourceID })
        store.search = ""
        #expect(store.canRecallConversationHistoryPrompt(try f.operation(review.id)))
        try await store.recallConversationHistoryPrompt(review.id)
        try await waitNativeHistory { try f.source().draft == "Latest unsent text\n\nOriginal prompt 2" }
        #expect(try f.source().draftAttachments == before.draftAttachments, "A recalled attachment already in the composer is deduplicated.")
        #expect(try f.operation(review.id).recalledAt != nil)
        await #expect(throws: CancellationError.self) { try await store.recallConversationHistoryPrompt(review.id) }
        await store.shutdown()
        let reopened = WorkspaceStore(engine: try NativeHistoryFixture.makeEngine(database: f.database, root: f.root, peer: f.peer))
        await reopened.load()
        #expect(reopened.thread(f.sourceID)?.draft == "Latest unsent text\n\nOriginal prompt 2")
        #expect(reopened.thread(f.sourceID)?.visibleMessages.count == 2 && reopened.thread(f.sourceID)?.messages.count == 6)
        #expect(reopened.conversationHistoryOperation(review.id)?.recalledAt != nil)
        #expect(await f.peer.mutations == [.rewindBeforeRun])
        await reopened.shutdown()
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeHistoryUnconfirmedRewindKeepsDraftEditableAndInspectsWithoutRepeatingTheProviderMutation() async throws {
    let f = try await NativeHistoryFixture.make(), store = f.store
    do {
        let before = try f.source()
        let review = try await store.reviewConversationHistory(threadID: f.sourceID, runID: f.runIDs[1], kind: .rewindBeforeRun)
        try await store.beginConversationHistory(review)
        try await waitNativeHistory { await f.peer.mutations == [.rewindBeforeRun] }
        try await f.peer.complete(uncertain: true)
        try await waitNativeHistory { try f.operation(review.id).phase == .unconfirmed }
        #expect(store.snapshot.isConversationHistoryLocked(threadID: f.sourceID))
        store.setDraft("Typing remains available during inspection", id: f.sourceID)
        #expect(await store.submit("Typing remains available during inspection", threadID: f.sourceID).value == false)
        #expect(try f.source().draft == "Typing remains available during inspection")
        await #expect(throws: WorkspaceCommandError.self) {
            try await f.engine.dispatch(.editThread(f.sourceID, .model("must-not-apply")))
        }
        await #expect(throws: WorkspaceCommandError.self) {
            try await f.engine.dispatch(.editThread(f.sourceID, .archived(true)))
        }
        #expect(try f.source().messages == before.messages && f.source().model == before.model)
        #expect(try f.source().isArchived == false)
        let reads = await f.peer.reads
        try await store.reconcileConversationHistory(review.id)
        #expect(try f.operation(review.id).phase == .applied)
        #expect(!store.snapshot.isConversationHistoryLocked(threadID: f.sourceID))
        #expect(try f.source().visibleMessages.count == 2 && f.source().draft == "Typing remains available during inspection")
        #expect(await f.peer.reads > reads)
        #expect(await f.peer.mutations == [.rewindBeforeRun])
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeHistoryOlderRecallWaitsWhileANewerHistoryActionOwnsTheSource() async throws {
    let f = try await NativeHistoryFixture.make(), store = f.store
    do {
        let first = try await store.reviewConversationHistory(threadID: f.sourceID, runID: f.runIDs[1], kind: .rewindBeforeRun)
        try await store.beginConversationHistory(first)
        try await waitNativeHistory { await f.peer.mutations.count == 1 }
        try await f.peer.complete()
        try await waitNativeHistory { try f.operation(first.id).phase == .applied }
        #expect(store.canRecallConversationHistoryPrompt(try f.operation(first.id)))
        let second = try await store.reviewConversationHistory(threadID: f.sourceID, runID: f.runIDs[0], kind: .rewindBeforeRun)
        try await store.beginConversationHistory(second)
        try await waitNativeHistory { await f.peer.mutations.count == 2 }
        store.setDraft("Keep typing while the newer rewind is held", id: f.sourceID)
        #expect(!store.canRecallConversationHistoryPrompt(try f.operation(first.id)))
        await #expect(throws: CancellationError.self) { try await store.recallConversationHistoryPrompt(first.id) }
        #expect(try f.operation(first.id).recalledAt == nil)
        #expect(try f.source().draft == "Keep typing while the newer rewind is held")
        #expect(try f.source().visibleMessages.count == 2)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeHistoryRecallMergesTypingWhileItsAtomicCommandAwaitsDatabaseAcknowledgment() async throws {
    let f = try await NativeHistoryFixture.make(), store = f.store
    var writer: OpaquePointer?, locked = false
    func releaseWriter() {
        if locked { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil); locked = false }
    }
    defer { releaseWriter(); if let writer { sqlite3_close(writer) } }
    do {
        let review = try await store.reviewConversationHistory(threadID: f.sourceID, runID: f.runIDs[1], kind: .rewindBeforeRun)
        try await store.beginConversationHistory(review)
        try await waitNativeHistory { await f.peer.mutations == [.rewindBeforeRun] }
        try await f.peer.complete()
        try await waitNativeHistory { try f.operation(review.id).phase == .applied }
        #expect(sqlite3_open(f.database.path, &writer) == SQLITE_OK)
        sqlite3_busy_timeout(writer, 5_000)
        #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        locked = true
        let recall = Task { try await store.recallConversationHistoryPrompt(review.id) }
        try await waitNativeHistory { store.isRecallingConversationHistoryPrompt(review.id) }
        store.setDraft("Typed while Recall Prompt is awaiting its acknowledgment", id: f.sourceID)
        releaseWriter()
        try await recall.value
        let expected = "Typed while Recall Prompt is awaiting its acknowledgment\n\nOriginal prompt 2"
        #expect(try f.source().draft == expected)
        await store.shutdown()
        let reopened = WorkspaceStore(engine: try NativeHistoryFixture.makeEngine(database: f.database, root: f.root, peer: f.peer))
        await reopened.load()
        #expect(reopened.thread(f.sourceID)?.draft == expected)
        #expect(reopened.conversationHistoryOperation(review.id)?.recalledAt != nil)
        await reopened.shutdown()
    } catch { releaseWriter(); await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeHistoryReviewAndUnknownOutcomeFitSmallNativeSheetsInBothAppearances() async throws {
    let f = try await NativeHistoryFixture.make()
    do {
        let review = try await f.store.reviewConversationHistory(threadID: f.sourceID, runID: f.runIDs[1], kind: .rewindBeforeRun)
        var operation = ConversationHistoryOperation(review: review, phase: .unconfirmed)
        operation.error = ConversationHistoryOperation.unconfirmedMessage
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(320), 680] {
                let views: [(String, AnyView)] = [
                    ("review", AnyView(ConversationHistoryReviewContent(review: review, kind: .rewindBeforeRun,
                        title: .constant(""), loading: false, accepting: false, error: nil, operation: nil,
                        openingPrompt: "Original prompt 2", confirm: { }, close: { }) { EmptyView() })),
                    ("unknown", AnyView(ConversationHistoryReviewContent(review: review, kind: .rewindBeforeRun,
                        title: .constant(""), loading: false, accepting: false, error: nil, operation: operation,
                        openingPrompt: "Original prompt 2", confirm: { }, close: { }) {
                            ConversationHistoryOperationView(store: f.store, operation: operation)
                        }))
                ]
                for (name, view) in views {
                    let content = view.environment(\.colorScheme, scheme)
                    let controller = NSHostingController(rootView: content)
                    let size = controller.sizeThatFits(in: CGSize(width: width, height: 650))
                    #expect(size.width <= width + 1 && size.height <= 650)
                    try await captureNativeHistory(content, name: name, width: width, height: size.height, scheme: scheme)
                }
            }
        }
        #expect(review.sourceConfiguration.model == "current-model" && review.targetConfiguration.model == "recorded-model-2")
        #expect(await f.peer.mutations.isEmpty, "Opening either review is read-only.")
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor private func captureNativeHistory<Content: View>(_ content: Content, name: String, width: CGFloat,
                                                           height: CGFloat, scheme: ColorScheme) async throws {
    guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_HISTORY_ACTIONS"] == "1" else { return }
    let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
    let hosting = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)).frame(width: width, height: height))
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = appearance; hosting.appearance = appearance; window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-history-action-\(name)-\(Int(width))-\(scheme == .light ? "light" : "dark").png")
    try data.write(to: path); print("Conversation history preview: \(path.path)")
}
