import AppKit
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private actor NativeV1OriginalPeer {
    let source: OpenCodeV1HistorySnapshot
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var reads = 0
    private(set) var entered = false
    private(set) var sends = 0
    init(source: OpenCodeV1HistorySnapshot) { self.source = source }
    func read(_ id: String) async throws -> OpenCodeV1HistorySnapshot {
        guard id == source.reference.nativeThreadID else { throw ProviderHistoryError(.invalidRequest) }
        reads += 1; entered = true
        if !released { await withCheckedContinuation { waiters.append($0) } }
        try Task.checkCancellation()
        return source
    }
    func release() { released = true; let pending = waiters; waiters = []; for continuation in pending { continuation.resume() } }
    func rejectedSend() throws { sends += 1; throw CoincideError("This offline history fixture never submits provider input.") }
}

private actor NativeV1OriginalSession: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent> = AsyncStream { $0.finish() }
    let peer: NativeV1OriginalPeer
    init(peer: NativeV1OriginalPeer) { self.peer = peer }
    func models() -> [ProviderModel] { [] }
    func openCodeV1HistorySnapshot(threadID: String) async throws -> OpenCodeV1HistorySnapshot { try await peer.read(threadID) }
    func send(text: String, thread: CodingThread) async throws { try await peer.rejectedSend() }
    func interrupt() { }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() async { await peer.release() }
}

@MainActor private struct NativeV1HistoryFixture {
    let root: URL, database: URL
    let store: WorkspaceStore
    let review: ConversationHistoryReview
    let peer: NativeV1OriginalPeer
    let original: CodingThread
    static func make(candidateRecorded: Bool) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-native-v1-history-" + UUID().uuidString).resolvingSymlinksInPath()
        let checkout = root.appendingPathComponent("Private 工作 مرحباً checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        do {
            let project = WorkspaceProject(path: checkout.path)
            var thread = CodingThread(project: project)
            thread.provider = .opencode; thread.openCodeConfiguration = .init(generation: .v1, executable: "/fixture/opencode")
            thread.providerThreadID = "ses_native_v1_original"; thread.draft = "Existing unsent draft 😀"; thread.checkpointPolicy = .disabled
            let runID = UUID(), run = ActiveRun(id: runID, configuration: .init(thread: thread), startedAt: .now, nativeTurnID: "msg_100")
            var record = ThreadRunRecord(run: run, origin: .user, userMessageID: "native-v1-user")
            record.status = .completed; record.endedAt = .now; record.endReason = .providerCompleted; record.messageAttributionVersion = 1
            var user = ChatMessage(id: "native-v1-user", role: .user, text: "Original prompt 工作 مرحباً")
            user.runReference = .init(threadID: thread.id, runID: runID)
            var reply = ChatMessage(id: "native-v1-reply", role: .assistant, text: "Original reply"); reply.runReference = user.runReference
            thread.runHistory = [record]; thread.messages = [user, reply]
            var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
            let native = try OpenCodeV1HistorySnapshot(reference: .init(provider: .opencode, nativeThreadID: "ses_native_v1_original"),
                runtimeIdentity: thread.openCodeConfiguration!.runtimeIdentity, workspacePath: project.path,
                projectID: String(repeating: "a", count: 40), sessionDigest: String(repeating: "b", count: 64), messages: [
                    .init(id: "msg_100", role: .user, partIDs: ["prt_input"], contentDigest: String(repeating: "1", count: 64)),
                    .init(id: "msg_110", role: .assistant, parentID: "msg_100", partIDs: ["prt_reply"], contentDigest: String(repeating: "2", count: 64))])
            let evidence = try OpenCodeV1HistoryReviewEvidence.make(source: native, snapshot: snapshot, thread: thread, runID: runID, kind: .rewindBeforeRun)
            let review = try ConversationHistoryReview(kind: .rewindBeforeRun, sourceThreadID: thread.id, projectID: thread.projectID,
                runID: runID, sourceIncarnation: UUID(), sourceConfiguration: .init(thread: thread), targetConfiguration: record.configuration,
                sourceReference: native.reference, reviewedHeadTurnID: nil, boundary: evidence.boundary, expectedResultHeadTurnID: nil,
                prefix: [], removedRunIDs: [runID], removedMessageIDs: thread.messages.map(\.id),
                sourceFingerprint: snapshot.historySourceFingerprint(threadID: thread.id), targetThreadID: nil,
                suggestedTitle: "Verified native history 工作 مرحباً", openCodeV1: evidence)
            let candidate = try candidateRecorded ? OpenCodeV1HistoryCandidate(reference: .init(provider: .opencode, nativeThreadID: "ses_separate_unconfirmed_copy"),
                sourceInventoryDigest: native.inventoryDigest, runtimeIdentity: native.runtimeIdentity, workspacePath: native.workspacePath, boundary: review.boundary) : nil
            let operation = ConversationHistoryOperation(review: review, phase: .unconfirmed,
                error: ConversationHistoryOperation.unconfirmedMessage, openCodeV1Candidate: candidate)
            snapshot.conversationHistoryOperations = [operation]
            let database = root.appendingPathComponent("workspace.sqlite")
            try await WorkspaceDatabase(url: database).save(snapshot, event: "native.v1.history.unknown")
            let peer = NativeV1OriginalPeer(source: native)
            let engine = try WorkspaceEngine(url: database, providerFactory: { _ in NativeV1OriginalSession(peer: peer) }, identityResolver: { _ in nil })
            let store = WorkspaceStore(engine: engine,
                runtimeInstallation: .init(rootURL: root.appendingPathComponent("Antigravity"), release: nil),
                codexInstallation: .init(rootURL: root.appendingPathComponent("Codex"), release: nil))
            await store.load()
            return .init(root: root, database: database, store: store, review: review, peer: peer, original: thread)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func finish() async { await peer.release(); await store.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@MainActor private func waitNativeV1History(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Native v1 history fixture did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func nativeOpenCodeV1KeepOriginalOwnsItsReadPreservesLatestDraftAndNeverOffersV2Clear(candidateRecorded: Bool) async throws {
    let fixture = try await NativeV1HistoryFixture.make(candidateRecorded: candidateRecorded), store = fixture.store
    do {
        let operation = try #require(store.conversationHistoryOperation(fixture.review.id))
        #expect(store.canKeepOpenCodeV1Original(operation) && !store.canClearConversationHistoryMaintenance(operation))
        #expect(!store.canRecallConversationHistoryPrompt(operation))
        let action = Task { try await store.keepOpenCodeV1Original(operation.id) }
        try await waitNativeV1History { await fixture.peer.entered }
        #expect(store.isInspectingConversationHistory(operation.id) && !store.canKeepOpenCodeV1Original(operation))
        store.setDraft("Latest typing during original verification 😀", id: fixture.original.id)
        await fixture.peer.release(); try await action.value
        let kept = try #require(store.conversationHistoryOperation(operation.id)), source = try #require(store.thread(fixture.original.id))
        #expect(kept.phase == .failed && kept.error == ConversationHistoryOperation.openCodeV1NotAdoptedMessage)
        #expect(ConversationHistoryPresentation.status(kept) == String(localized: "Original conversation kept"))
        #expect(!store.canKeepOpenCodeV1Original(kept) && !store.canRecallConversationHistoryPrompt(kept) && !kept.locksSource)
        #expect((kept.openCodeV1Candidate != nil) == candidateRecorded && kept.recalledAt == nil)
        #expect(source.providerThreadID == fixture.original.providerThreadID && source.messages == fixture.original.messages && source.runHistory == fixture.original.runHistory)
        #expect(source.draft == "Latest typing during original verification 😀")
        #expect(await fixture.peer.sends == 0)
        #expect(await fixture.peer.reads >= 2)
        await store.shutdown()
        let saved = try await WorkspaceDatabase(url: fixture.database).load()
        #expect(saved.threads.first { $0.id == source.id }?.draft == source.draft)
    } catch { await fixture.finish(); throw error }
    await fixture.finish()
}

@MainActor @Test func nativeOpenCodeV1HistoryReviewAndRecoveryFitNarrowWindowsWithoutNativeActions() async throws {
    _ = NSApplication.shared
    for candidateRecorded in [false, true] {
        let fixture = try await NativeV1HistoryFixture.make(candidateRecorded: candidateRecorded)
        do {
            let operation = try #require(fixture.store.conversationHistoryOperation(fixture.review.id))
            for scheme in [ColorScheme.light, .dark] {
                for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                    for width in [CGFloat(320), 680] {
                        let view = ConversationHistoryReviewContent(review: fixture.review, kind: .rewindBeforeRun,
                            title: .constant(""), loading: false, accepting: false, error: nil, operation: operation,
                            openingPrompt: "Original prompt 工作 مرحباً", confirm: { Issue.record("Layout cannot accept a history action.") }, close: { }) {
                                ConversationHistoryOperationView(store: fixture.store, operation: operation)
                            }.environment(\.colorScheme, scheme).environment(\.layoutDirection, direction)
                        let controller = NSHostingController(rootView: view)
                        let size = controller.sizeThatFits(in: .init(width: width, height: 650))
                        #expect(size.width.isFinite && size.height.isFinite && size.width <= width + 1 && size.height <= 650)
                        try captureNativeV1History(view, size: .init(width: width, height: size.height), scheme: scheme,
                                                   direction: direction, candidateRecorded: candidateRecorded)
                    }
                }
            }
            #expect(await fixture.peer.reads == 0)
            #expect(await fixture.peer.sends == 0)
            #expect(fixture.store.thread(fixture.original.id)?.draft == fixture.original.draft)
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
}

@MainActor private func captureNativeV1History(_ view: some View, size: NSSize, scheme: ColorScheme,
                                              direction: LayoutDirection, candidateRecorded: Bool) throws {
    guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_OPENCODE_V1_HISTORY"] == "1" else { return }
    let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua)), previous = NSApp.appearance
    NSApp.appearance = appearance; defer { NSApp.appearance = previous }
    let window = NSWindow(contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = appearance; window.isReleasedWhenClosed = false; window.isOpaque = true; window.backgroundColor = .windowBackgroundColor
    defer { window.close() }
    var capture: Result<Data, any Error>?
    appearance.performAsCurrentDrawingAppearance {
        capture = Result {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = appearance; window.contentView = host; host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
    }
    let data = try #require(capture).get()
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-opencode-v1-history-\(candidateRecorded ? "candidate" : "unknown")-\(Int(size.width))-\(scheme == .light ? "light" : "dark")-\(direction == .leftToRight ? "ltr" : "rtl").png")
    try data.write(to: path)
}
