import AppKit
import CSQLite
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

/// Independent gates prove that the App keeps its file bridge through provider
/// acknowledgement and never recalls input while the second external step is held.
private actor CombinedHistoryPeer {
    let path: String
    private var head = "turn-3"
    private var pending: CheckedContinuation<ProviderConversationSnapshot, any Error>?
    private(set) var rewinds = 0
    init(path: String) { self.path = path }
    func snapshot() throws -> ProviderConversationSnapshot {
        try .init(reference: .init(provider: .codex, nativeThreadID: "combined-native"),
                  workspacePath: path, historyMode: .paginated, headTurnID: head)
    }
    func page() throws -> ProviderHistoryPage {
        try .init(reference: .init(provider: .codex, nativeThreadID: "combined-native"),
                  turns: (1...(head == "turn-3" ? 3 : 1)).reversed().map { try .init(id: "turn-\($0)", status: .completed) })
    }
    func rewind() async throws -> ProviderConversationSnapshot {
        rewinds += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending = $0 }
        } onCancel: { Task { await self.cancel() } }
    }
    func finish(uncertain: Bool = false) throws {
        let continuation = try #require(pending); pending = nil; head = "turn-1"
        if uncertain { continuation.resume(throwing: ProviderHistoryError(.outcomeUncertain)) }
        else { continuation.resume(returning: try snapshot()) }
    }
    func cancel() { pending?.resume(throwing: CancellationError()); pending = nil }
}

private actor CombinedHistorySession: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    let peer: CombinedHistoryPeer
    init(peer: CombinedHistoryPeer) {
        self.peer = peer
        let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation
    }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) throws { throw CoincideError("This synthetic history fixture never sends provider input.") }
    func interrupt() { }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { sink.finish() }
    func historyCapabilities(threadID: String) throws -> ProviderHistoryCapabilities {
        try .init(reference: .init(provider: .codex, nativeThreadID: threadID), historyMode: .paginated,
                  canRead: true, canForkHead: true, canForkFromTurn: true, canRevertBeforeTurn: true)
    }
    func conversationSnapshot(threadID: String) async throws -> ProviderConversationSnapshot { try await peer.snapshot() }
    func historyPage(threadID: String, cursor: String?, limit: Int) async throws -> ProviderHistoryPage { try await peer.page() }
    func revertConversation(thread: ProviderConversationReference, beforeTurnID: String,
                            expectedHeadTurnID: String) async throws -> ProviderConversationSnapshot {
        #expect(beforeTurnID == "turn-2" && expectedHeadTurnID == "turn-3")
        return try await peer.rewind()
    }
}

private actor CombinedFilesPeer {
    let path: URL
    private var pending: CheckedContinuation<GitCheckpointRestoreReceipt, any Error>?
    private var current: GitCheckpointRestoreReview?
    private(set) var starts = 0
    private(set) var inspections = 0
    private(set) var discards = 0
    init(path: URL) { self.path = path }
    func review(target: GitCheckpointReceipt, id: UUID) throws -> GitCheckpointRestoreReview {
        try .init(id: id, targetReceipt: target, currentPlan: target.plan,
                  manifestDigest: String(repeating: "e", count: 64), affectedPaths: ["notes.txt", "new.txt"],
                  previewPatch: "--- a/notes.txt\n+++ b/notes.txt\n@@ -1 +1 @@\n-current\n+previous visible run\n")
    }
    func restore(_ review: GitCheckpointRestoreReview) async throws -> GitCheckpointRestoreReceipt {
        starts += 1; current = review
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending = $0 }
        } onCancel: { Task { await self.cancel() } }
    }
    func finish(uncertain: Bool = false) throws {
        let continuation = try #require(pending), review = try #require(current); pending = nil
        try Data("previous visible run\n".utf8).write(to: path.appendingPathComponent("notes.txt"))
        if uncertain { continuation.resume(throwing: GitCheckpointRestoreError(.interrupted, mayHaveMutated: true)) }
        else { continuation.resume(returning: try .init(review: review, stateDigest: String(repeating: "f", count: 64))) }
    }
    func inspect() -> GitCheckpointRestoreInspection {
        guard starts > 0 else { return .notStarted }
        inspections += 1; return .interrupted
    }
    func discard() -> GitCheckpointScratchResult { discards += 1; return .removed }
    func cancel() { pending?.resume(throwing: CancellationError()); pending = nil }
}

private struct CombinedCheckpointSession: RunCheckpointSession {
    let peer: CombinedFilesPeer
    func prepare(id: UUID) async throws -> GitCheckpointPlan { throw GitCheckpointError(.commandFailed) }
    func capture(_ plan: GitCheckpointPlan) async throws -> GitCheckpointReceipt { throw GitCheckpointError(.commandFailed) }
    func inspect(_ plan: GitCheckpointPlan) async throws -> GitCheckpointInspection { .missing }
    func finalizeScratch(_ receipt: GitCheckpointReceipt) async throws -> GitCheckpointScratchResult { .removed }
    func reviewRestore(target: GitCheckpointReceipt, id: UUID) async throws -> GitCheckpointRestoreReview { try await peer.review(target: target, id: id) }
    func discardRestoreReview(_ review: GitCheckpointRestoreReview) async throws -> GitCheckpointScratchResult { await peer.discard() }
    func restore(review: GitCheckpointRestoreReview) async throws -> GitCheckpointRestoreReceipt { try await peer.restore(review) }
    func inspectRestore(review: GitCheckpointRestoreReview) async throws -> GitCheckpointRestoreInspection { await peer.inspect() }
}

@MainActor private struct CombinedNativeFixture {
    let root: URL, checkout: URL, database: URL, store: WorkspaceStore
    let history: CombinedHistoryPeer, files: CombinedFilesPeer
    let threadID: UUID, runID: UUID, previousRunID: UUID, previousPostID: UUID
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-combined-native-" + UUID().uuidString).resolvingSymlinksInPath()
        let projectPath = root.appendingPathComponent("Project"), checkout = root.appendingPathComponent("Private checkout")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        do {
            try Data("current\n".utf8).write(to: checkout.appendingPathComponent("notes.txt"))
            let project = WorkspaceProject(path: projectPath.path)
            var thread = CodingThread(project: project, model: "current-model")
            thread.workspacePath = checkout.path; thread.providerThreadID = "combined-native"
            thread.draft = "Initial unsent draft"; thread.permission = .auto; thread.checkpointPolicy = .disabled
            func attachment(_ name: String) -> ChatAttachment {
                .init(id: UUID(), name: name, mimeType: "text/plain", byteCount: 3,
                      digest: String(repeating: "a", count: 64), fileExtension: "txt")
            }
            let originalAttachment = attachment("original.txt")
            thread.draftAttachments = [originalAttachment]
            func ready(_ at: Date) throws -> ThreadRunCheckpointAttempt {
                var value = ThreadRunCheckpointAttempt(workspacePath: checkout.path, phase: .ready, now: at)
                let node = GitWorktreeNodeIdentity(device: 1, inode: 42)
                value.plan = try .init(id: value.id, workspacePath: checkout.path, repositoryPath: checkout.path,
                    gitDirectoryPath: checkout.path + "/.git", commonDirectoryPath: checkout.path + "/.git",
                    workspaceIdentity: node, repositoryIdentity: node, gitDirectoryIdentity: node, commonDirectoryIdentity: node,
                    objectDirectoryIdentity: node, headCommit: String(repeating: "a", count: 40),
                    configurationDigest: String(repeating: "b", count: 64), indexRevision: nil)
                value.receipt = try .init(plan: value.plan!, commit: String(repeating: "c", count: 40), tree: String(repeating: "d", count: 40), capturedAt: at)
                return value
            }
            var ids: [UUID] = [], previousPostID = UUID()
            for i in 1...3 {
                let id = UUID(), at = Date(timeIntervalSince1970: 1_700_000_000 + Double(i * 10))
                ids.append(id)
                var configuration = ProviderConfiguration(thread: thread)
                if i == 1 { configuration.nativeThreadID = nil }
                configuration.model = "recorded-model-\(i)"
                var record = ThreadRunRecord(run: .init(id: id, configuration: configuration, startedAt: at,
                    nativeTurnID: "turn-\(i)"), origin: .user, userMessageID: "prompt-\(i)")
                record.providerThreadID = thread.providerThreadID; record.status = .completed
                record.endedAt = at.addingTimeInterval(2); record.endReason = .providerCompleted; record.messageAttributionVersion = 1
                record.checkpoints = .init(baseline: try ready(at), providerReleased: true)
                record.checkpoints?.postRun = try ready(at.addingTimeInterval(3))
                if i == 1 { previousPostID = record.checkpoints!.postRun!.id }
                var prompt = ChatMessage(id: "prompt-\(i)", role: .user, text: "Original prompt \(i)")
                prompt.attachments = i == 2 ? [originalAttachment] : nil
                prompt.createdAt = at; prompt.runReference = .init(threadID: thread.id, runID: id)
                var answer = ChatMessage(id: "reply-\(i)", role: .assistant, text: "Recorded reply \(i)")
                answer.createdAt = at.addingTimeInterval(1); answer.runReference = prompt.runReference
                thread.messages += [prompt, answer]
                if thread.runHistory == nil { thread.runHistory = [] }; thread.runHistory!.append(record)
            }
            var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
            let database = root.appendingPathComponent("workspace.sqlite")
            _ = try await WorkspaceDatabase(url: database).commit(snapshot, event: "combined-native-fixture", commandID: UUID())
            let history = CombinedHistoryPeer(path: checkout.path), files = CombinedFilesPeer(path: checkout)
            let store = try makeStore(database: database, history: history, files: files); await store.load()
            return .init(root: root, checkout: checkout, database: database, store: store, history: history, files: files,
                         threadID: thread.id, runID: ids[1], previousRunID: ids[0], previousPostID: previousPostID)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    static func makeStore(database: URL, history: CombinedHistoryPeer, files: CombinedFilesPeer) throws -> WorkspaceStore {
        WorkspaceStore(engine: try .init(url: database, providerFactory: { _ in CombinedHistorySession(peer: history) },
            identityResolver: { _ in nil }, checkpointFactory: { _ in CombinedCheckpointSession(peer: files) }))
    }
    func review() async throws -> ConversationHistoryReview {
        try await store.reviewConversationHistory(threadID: threadID, runID: runID, kind: .rewindBeforeRun, recallPromptOnSuccess: true)
    }
    func thread() throws -> CodingThread { try #require(store.thread(threadID)) }
    func operation(_ id: UUID) throws -> ConversationHistoryOperation { try #require(store.conversationHistoryOperation(id)) }
    func cleanup() async { await history.cancel(); await files.cancel(); await store.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@MainActor private func waitCombined(file: StaticString = #fileID, line: UInt = #line, _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Combined native boundary timed out at \(file):\(line).") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeCombinedKeepChangesRemainsAnIndependentChoiceAndAutomaticallyRecallsLatestDraftOnce() async throws {
    let f = try await CombinedNativeFixture.make()
    do {
        let keep = try await f.review(), destructive = try await f.store.reviewConversationHistoryRestoringFiles(keep)
        #expect(keep.id != destructive.id && keep.files == nil && destructive.files != nil)
        #expect(await f.history.rewinds == 0); #expect(await f.files.starts == 0)
        f.store.discardConversationHistoryReview(destructive.id)
        try await f.store.beginConversationHistory(keep)
        try await waitCombined { await f.history.rewinds == 1 }
        f.store.setDraft("Latest text while provider rewind is held", id: f.threadID)
        try await f.history.finish()
        try await waitCombined { try f.operation(keep.id).recalledAt != nil }
        #expect(try f.thread().draft == "Latest text while provider rewind is held\n\nOriginal prompt 2")
        #expect(try f.thread().draftAttachments.count == 1 && f.thread().model == "current-model")
        #expect(try String(contentsOf: f.checkout.appendingPathComponent("notes.txt"), encoding: .utf8) == "current\n")
        #expect(await f.files.starts == 0); #expect(await f.history.rewinds == 1)
        #expect(!f.store.snapshot.isConversationHistoryLocked(threadID: f.threadID))
        await f.store.shutdown()
        let reopened = try CombinedNativeFixture.makeStore(database: f.database, history: f.history, files: f.files); await reopened.load()
        #expect(reopened.thread(f.threadID)?.draft == "Latest text while provider rewind is held\n\nOriginal prompt 2")
        #expect(reopened.conversationHistoryOperation(keep.id)?.recalledAt != nil)
        #expect(await f.history.rewinds == 1); #expect(await f.files.starts == 0)
        await reopened.shutdown()
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeCombinedFilesBridgeCoversSQLiteProviderAndRestoreWhilePreservingTheLatestDraftAndCleanCache() async throws {
    let f = try await CombinedNativeFixture.make(), store = f.store
    var writer: OpaquePointer?, locked = false
    func unlock() { if locked { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil); locked = false } }
    defer { unlock(); if let writer { sqlite3_close(writer) } }
    do {
        let browser = try store.fileBrowser(path: f.checkout.path)
        #expect(await browser.open("notes.txt"))
        let review = try await store.reviewConversationHistoryRestoringFiles(f.review())
        let target = try #require(review.files?.target)
        #expect(target.checkpointRunID == f.previousRunID && target.attemptID == f.previousPostID && target.stage == .postRun)
        #expect(sqlite3_open(f.database.path, &writer) == SQLITE_OK)
        sqlite3_busy_timeout(writer, 5_000); #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK); locked = true
        let begin = Task { try await store.beginConversationHistory(review) }
        try await waitCombined { !store.canEditWorkspace(f.checkout.path) }
        #expect(store.conversationHistoryOperation(review.id) == nil && !browser.canWrite)
        #expect(!store.canOpenTerminal(for: try f.thread()))
        unlock(); try await begin.value
        try await waitCombined { await f.history.rewinds == 1 }
        #expect(await f.files.starts == 0)
        store.setDraft("Typed during provider rewind", id: f.threadID)
        try await f.history.finish()
        try await waitCombined { await f.files.starts == 1 }
        #expect(try f.operation(review.id).phase == .applied && f.operation(review.id).recalledAt == nil)
        #expect(!browser.canWrite && !store.canEditWorkspace(f.checkout.path))
        #expect(try f.thread().visibleMessages.count == 2 && f.thread().messages.count == 6)
        store.setDraft("Newest text while files are held", id: f.threadID)
        #expect(await store.submit("Must stay paused", threadID: f.threadID).value == false)
        try await f.files.finish()
        try await waitCombined { try f.operation(review.id).recalledAt != nil && browser.contents == "previous visible run\n" && browser.canWrite }
        #expect(try f.thread().draft == "Newest text while files are held\n\nOriginal prompt 2")
        #expect(try f.operation(review.id).allExternalWorkSucceeded && !f.operation(review.id).locksSource)
        #expect(try f.thread().model == "current-model" && f.thread().permission == .auto && f.thread().draftAttachments.count == 1)
        #expect(store.selectedThreadID == f.threadID && store.canEditWorkspace(f.checkout.path))
        #expect(await f.history.rewinds == 1); #expect(await f.files.starts == 1)
    } catch { unlock(); await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeCombinedPartialFilesStayHeldAcrossRestartAndExplicitKeepDoesNotRecallOrReplay() async throws {
    let f = try await CombinedNativeFixture.make()
    do {
        let review = try await f.store.reviewConversationHistoryRestoringFiles(f.review())
        try await f.store.beginConversationHistory(review)
        try await waitCombined { await f.history.rewinds == 1 }; try await f.history.finish()
        try await waitCombined { await f.files.starts == 1 }
        f.store.setDraft("Keep this latest partial-outcome draft", id: f.threadID)
        try await f.files.finish(uncertain: true)
        try await waitCombined { try f.operation(review.id).files?.phase == .unconfirmed }
        #expect(try f.operation(review.id).phase == .applied && f.operation(review.id).recalledAt == nil)
        #expect(!f.store.canEditWorkspace(f.checkout.path) && f.store.snapshot.isConversationHistoryLocked(threadID: f.threadID))
        await f.store.shutdown()
        let reopened = try CombinedNativeFixture.makeStore(database: f.database, history: f.history, files: f.files); await reopened.load()
        do {
            #expect(reopened.thread(f.threadID)?.visibleMessages.count == 2 && !reopened.canEditWorkspace(f.checkout.path))
            try await reopened.inspectConversationHistoryFiles(review.id)
            #expect(reopened.conversationHistoryOperation(review.id)?.files?.phase == .unconfirmed)
            #expect(await f.files.inspections == 1); #expect(await f.files.starts == 1); #expect(await f.history.rewinds == 1)
            try await reopened.acknowledgeConversationHistoryFiles(review.id)
            #expect(reopened.canEditWorkspace(f.checkout.path) && !reopened.snapshot.isConversationHistoryLocked(threadID: f.threadID))
            #expect(reopened.conversationHistoryOperation(review.id)?.files?.acknowledgedAt != nil)
            #expect(reopened.conversationHistoryOperation(review.id)?.recalledAt == nil)
            #expect(reopened.thread(f.threadID)?.draft == "Keep this latest partial-outcome draft")
            await reopened.shutdown()
        } catch { await reopened.shutdown(); throw error }
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeCombinedProviderUncertaintyDoesNotStartFilesAndReadOnlyInspectionNeverStartsTheSecondStep() async throws {
    let f = try await CombinedNativeFixture.make()
    do {
        let review = try await f.store.reviewConversationHistoryRestoringFiles(f.review())
        try await f.store.beginConversationHistory(review)
        try await waitCombined { await f.history.rewinds == 1 }; try await f.history.finish(uncertain: true)
        try await waitCombined { try f.operation(review.id).phase == .unconfirmed }
        #expect(try f.thread().visibleMessages.count == 6 && f.operation(review.id).recalledAt == nil)
        #expect(await f.files.starts == 0 && !f.store.canEditWorkspace(f.checkout.path))
        f.store.setDraft("Latest draft during provider inspection", id: f.threadID)
        try await f.store.reconcileConversationHistory(review.id)
        #expect(try f.operation(review.id).phase == .applied && f.operation(review.id).files?.phase == .failed)
        #expect(try f.operation(review.id).recalledAt == nil && f.thread().visibleMessages.count == 2)
        #expect(await f.files.starts == 0); #expect(await f.history.rewinds == 1)
        #expect(!f.store.canEditWorkspace(f.checkout.path))
        try await f.store.acknowledgeConversationHistoryFiles(review.id)
        #expect(try f.thread().draft == "Latest draft during provider inspection")
        #expect(!f.store.snapshot.isConversationHistoryLocked(threadID: f.threadID))
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeCombinedRecallCapacityFailureKeepsTheLatestDraftAndAllowsExplicitKeepWithoutExternalReplay() async throws {
    let f = try await CombinedNativeFixture.make()
    do {
        let review = try await f.review()
        try await f.store.beginConversationHistory(review)
        try await waitCombined { await f.history.rewinds == 1 }
        let originalAttachment = try #require(f.thread().draftAttachments.first)
        f.store.removeAttachment(originalAttachment.id, threadID: f.threadID)
        try await waitCombined { try f.thread().draftAttachments.isEmpty }
        let files = try (0..<AttachmentLimits.count).map { index -> URL in
            let path = f.root.appendingPathComponent("latest-attachment-\(index).txt")
            try Data("Private attachment \(index)".utf8).write(to: path)
            return path
        }
        f.store.importAttachments(files: files, threadID: f.threadID)
        try await waitCombined { try !f.store.isImportingAttachments(f.threadID) && f.thread().draftAttachments.count == AttachmentLimits.count }
        f.store.setDraft("Latest text with a full attachment composer", id: f.threadID)
        try await f.history.finish()
        try await waitCombined { f.store.conversationHistoryRecallError(review.id) != nil && !f.store.isRecallingConversationHistoryPrompt(review.id) }
        #expect(try f.operation(review.id).needsPromptRecall && f.operation(review.id).recalledAt == nil)
        #expect(try f.thread().draft == "Latest text with a full attachment composer" && f.thread().draftAttachments.count == AttachmentLimits.count)
        #expect(f.store.snapshot.isConversationHistoryLocked(threadID: f.threadID))
        try await f.store.dismissConversationHistoryRecall(review.id)
        #expect(try f.operation(review.id).recallDismissedAt != nil && !f.operation(review.id).needsPromptRecall)
        #expect(try f.thread().draft == "Latest text with a full attachment composer" && f.thread().draftAttachments.count == AttachmentLimits.count)
        #expect(!f.store.snapshot.isConversationHistoryLocked(threadID: f.threadID))
        #expect(await f.history.rewinds == 1); #expect(await f.files.starts == 0)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeCombinedThreeChoicesAndPartialFileStateFitSmallNativeSheetsInBothAppearances() async throws {
    let f = try await CombinedNativeFixture.make()
    do {
        let keep = try await f.review(), files = try await f.store.reviewConversationHistoryRestoringFiles(keep)
        let result = try ProviderConversationSnapshot(reference: files.sourceReference, workspacePath: files.sourceConfiguration.workspacePath,
            historyMode: .paginated, headTurnID: files.expectedResultHeadTurnID)
        var partial = ConversationHistoryOperation(review: files, phase: .applied, result: result)
        partial.files?.phase = .unconfirmed; partial.files?.error = ConversationHistoryFilesState.unconfirmedMessage
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(320), 680] {
                let variants: [(String, AnyView)] = [
                    ("choices", AnyView(ConversationHistoryReviewContent(review: keep, kind: .rewindBeforeRun, title: .constant(""),
                        loading: false, accepting: false, error: nil, operation: nil, openingPrompt: "Original prompt 2",
                        reviewFiles: { }, confirmFiles: { }, confirm: { }, close: { }) { EmptyView() })),
                    ("files", AnyView(ConversationHistoryReviewContent(review: files, kind: .rewindBeforeRun, title: .constant(""),
                        loading: false, accepting: false, error: nil, operation: nil, openingPrompt: "Original prompt 2",
                        reviewFiles: { }, confirmFiles: { }, confirm: { }, close: { }) { EmptyView() })),
                    ("partial", AnyView(ConversationHistoryOperationView(store: f.store, operation: partial).padding(12)))
                ]
                for (name, view) in variants {
                    let content = view.environment(\.colorScheme, scheme)
                    let hosting = NSHostingController(rootView: content)
                    let size = hosting.sizeThatFits(in: CGSize(width: width, height: 700))
                    #expect(size.width <= width + 1 && size.height <= 700)
                    try await captureCombinedHistory(content, name: name, width: width, height: size.height, scheme: scheme)
                }
            }
        }
        #expect(await f.history.rewinds == 0); #expect(await f.files.starts == 0)
    } catch { await f.cleanup(); throw error }
    await f.cleanup()
}

@MainActor private func captureCombinedHistory<Content: View>(_ content: Content, name: String, width: CGFloat,
                                                            height: CGFloat, scheme: ColorScheme) async throws {
    guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_COMBINED_HISTORY"] == "1" else { return }
    let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
    let hosting = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)).frame(width: width, height: height))
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = appearance; hosting.appearance = appearance; window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-combined-history-\(name)-\(Int(width))-\(scheme == .light ? "light" : "dark").png")
    try data.write(to: path); print("Combined history preview: \(path.path)")
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["debounce", "shutdown", "identical-edit"])
func nativeCombinedRecallDrainsLateDraftPastItsSaveTimerAndShutdownBeforeDatabaseAcknowledgment(boundary: String) async throws {
    let f = try await CombinedNativeFixture.make(), store = f.store
    var writer: OpaquePointer?, locked = false
    func unlock() { if locked { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil); locked = false } }
    defer { unlock(); if let writer { sqlite3_close(writer) } }
    do {
        // The atomic recall command is shared by legacy/manual and automatic
        // recall. Starting it explicitly isolates its SQLite boundary from the
        // preceding provider acknowledgement, without adding a product test hook.
        let review = try await store.reviewConversationHistory(threadID: f.threadID, runID: f.runID, kind: .rewindBeforeRun)
        try await store.beginConversationHistory(review)
        try await waitCombined { await f.history.rewinds == 1 }; try await f.history.finish()
        try await waitCombined { try f.operation(review.id).phase == .applied }
        #expect(sqlite3_open(f.database.path, &writer) == SQLITE_OK)
        sqlite3_busy_timeout(writer, 5_000); #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK); locked = true
        let latest = "Typed while SQLite holds the accepted recall"
        if boundary == "identical-edit" { store.setDraft(latest, id: f.threadID) }
        let recall = Task { try await store.recallConversationHistoryPrompt(review.id) }
        try await waitCombined { store.isRecallingConversationHistoryPrompt(review.id) }
        store.setDraft(latest, id: f.threadID)
        // Cross the actual 350ms debounce while recall still owns the database.
        // This is the ordering under test, not a retry or an increased timeout.
        try await Task.sleep(for: .milliseconds(450))
        let shutdown: Task<Void, Never>?
        if boundary == "shutdown" {
            shutdown = Task { await store.shutdown() }
            try await waitCombined { !store.canEditWorkspace(f.checkout.path) }
        } else { shutdown = nil }
        unlock(); try await recall.value
        if let shutdown { await shutdown.value } else { await store.shutdown() }
        let reopened = try CombinedNativeFixture.makeStore(database: f.database, history: f.history, files: f.files); await reopened.load()
        #expect(reopened.thread(f.threadID)?.draft == latest + "\n\nOriginal prompt 2")
        #expect(reopened.conversationHistoryOperation(review.id)?.recalledAt != nil)
        #expect(reopened.thread(f.threadID)?.draftAttachments.count == 1)
        #expect(await f.history.rewinds == 1); #expect(await f.files.starts == 0)
        await reopened.shutdown()
    } catch { unlock(); await f.cleanup(); throw error }
    await f.cleanup()
}
