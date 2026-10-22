import AppKit
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private actor OpenCodeHistoryViewNoProvider: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent> = AsyncStream { $0.finish() }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) throws { throw CoincideError("This layout fixture cannot send provider input.") }
    func interrupt() { }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() { }
}

@MainActor private struct OpenCodeHistoryViewFixture {
    let root: URL
    let store: WorkspaceStore
    let review: ConversationHistoryReview
    let expected: OpenCodeV2HistorySnapshot
    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-opencode-history-view-" + UUID().uuidString)
        let project = WorkspaceProject(path: root.appendingPathComponent("Workspace 工作").path)
        var thread = CodingThread(project: project)
        thread.provider = .opencode; thread.openCodeConfiguration = .init(executable: "/fixture/opencode")
        thread.providerThreadID = "ses_native_view"; thread.draft = "Latest unsent draft 😀"; thread.checkpointPolicy = .disabled
        let runID = UUID(), identity = thread.openCodeConfiguration!.runtimeIdentity
        let inputID = OpenCodeV2HistoryRunInput.openingMessageID(instanceID: identity.instanceID, runID: runID)
        let run = ActiveRun(id: runID, configuration: .init(thread: thread), startedAt: .now, nativeTurnID: inputID)
        var record = ThreadRunRecord(run: run, origin: .user, userMessageID: "native-view-input")
        record.status = .completed; record.endedAt = .now; record.messageAttributionVersion = 1
        thread.runHistory = [record]
        var user = ChatMessage(id: "native-view-input", role: .user, text: "Original prompt 工作 مرحباً")
        user.runReference = .init(threadID: thread.id, runID: runID); thread.messages = [user]
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        let source = try OpenCodeV2HistorySnapshot(reference: .init(provider: .opencode, nativeThreadID: "ses_native_view"),
            runtimeIdentity: identity, workspacePath: project.path,
            messages: [.init(id: inputID, kind: .user, contentDigest: String(repeating: "a", count: 64))])
        let evidence = try OpenCodeV2HistoryReviewEvidence.make(source: source, snapshot: snapshot, thread: thread,
                                                              runID: runID, kind: .rewindBeforeRun)
        let review = try ConversationHistoryReview(kind: .rewindBeforeRun, sourceThreadID: thread.id, projectID: project.id,
            runID: runID, sourceIncarnation: UUID(), sourceConfiguration: .init(thread: thread), targetConfiguration: record.configuration,
            sourceReference: source.reference, reviewedHeadTurnID: nil, boundary: evidence.boundary, expectedResultHeadTurnID: nil,
            prefix: [], removedRunIDs: [runID], removedMessageIDs: [user.id], sourceFingerprint: snapshot.historySourceFingerprint(threadID: thread.id),
            targetThreadID: nil, suggestedTitle: "Native OpenCode history", openCodeV2: evidence)
        let expected = try OpenCodeV2HistorySnapshot(reference: source.reference, runtimeIdentity: identity, workspacePath: project.path,
            messages: source.messages, stage: .init(messageID: inputID, files: .empty))
        let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { _ in OpenCodeHistoryViewNoProvider() }, identityResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine,
            runtimeInstallation: .init(rootURL: root.appendingPathComponent("Antigravity"), release: nil),
            codexInstallation: .init(rootURL: root.appendingPathComponent("Codex"), release: nil))
        store.snapshot = snapshot
        return .init(root: root, store: store, review: review, expected: expected)
    }
    func operation(phase: ConversationHistoryMaintenancePhase? = nil) throws -> ConversationHistoryOperation {
        var operation = ConversationHistoryOperation(review: review, phase: .unconfirmed, error: ConversationHistoryOperation.unconfirmedMessage)
        if let phase {
            let result: OpenCodeV2HistorySnapshot?
            if phase == .applied {
                let idle = try OpenCodeV2HistoryMessage(id: "msg_native_view_done", kind: .idle,
                    contentDigest: String(repeating: "b", count: 64), idleOutcome: "succeeded")
                result = try .init(reference: expected.reference, runtimeIdentity: expected.runtimeIdentity, workspacePath: expected.workspacePath,
                    messages: expected.messages + [idle], maintenance: .init(priorInventoryDigest: expected.inventoryDigest,
                        startEventID: "evt_native_view_start", terminalEventID: "evt_native_view_done", idleMessageID: idle.id))
            } else { result = nil }
            let error = phase == .failed ? ConversationHistoryMaintenanceAttempt.failureMessage :
                phase == .unconfirmed ? ConversationHistoryMaintenanceAttempt.unconfirmedMessage : nil
            operation.maintenance = .init(expected: expected, sourceIncarnation: review.sourceIncarnation, phase: phase, result: result, error: error)
        }
        try operation.validate(); return operation
    }
    func finish() async { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@MainActor @Test func nativeOpenCodeHistoryCleanupPresentationNeverOffersRepeatedConfirmedClearOrEarlyRecall() async throws {
    let fixture = try OpenCodeHistoryViewFixture.make()
    do {
        #expect(fixture.store.canClearConversationHistoryMaintenance(try fixture.operation()))
        for phase in [ConversationHistoryMaintenancePhase.accepted, .dispatching, .applied, .failed, .unconfirmed] {
            let operation = try fixture.operation(phase: phase)
            #expect(fixture.store.canClearConversationHistoryMaintenance(operation) == (phase == .failed || phase == .unconfirmed))
            #expect(!fixture.store.canRecallConversationHistoryPrompt(operation))
            #expect(operation.locksSource && operation.isWorking == phase.isWorking)
            if phase == .applied { #expect(ConversationHistoryPresentation.status(operation).contains("inspect")) }
        }
        #expect(fixture.store.snapshot.threads[0].draft == "Latest unsent draft 😀")
    } catch { await fixture.finish(); throw error }
    await fixture.finish()
}

@MainActor @Test func nativeOpenCodeHistoryMessageReviewAndMaintenanceFitNarrowSheetsWithoutSubmitting() async throws {
    _ = NSApplication.shared
    let fixture = try OpenCodeHistoryViewFixture.make()
    do {
        for scheme in [ColorScheme.light, .dark] {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                for width in [CGFloat(320), 680] {
                    for phase in [ConversationHistoryMaintenancePhase.dispatching, .unconfirmed, .applied] {
                        let operation = try fixture.operation(phase: phase)
                        let view = ConversationHistoryReviewContent(review: fixture.review, kind: .rewindBeforeRun,
                            title: .constant(""), loading: false, accepting: false, error: nil, operation: operation,
                            openingPrompt: "Original prompt 工作 مرحباً", confirm: { Issue.record("Layout must not submit a history action.") },
                            close: { }) { ConversationHistoryOperationView(store: fixture.store, operation: operation) }
                            .environment(\.colorScheme, scheme).environment(\.layoutDirection, direction)
                        let controller = NSHostingController(rootView: view)
                        let size = controller.sizeThatFits(in: .init(width: width, height: 650))
                        #expect(size.width.isFinite && size.height.isFinite && size.width <= width + 1 && size.height <= 650)
                        try captureOpenCodeHistory(view, width: width, height: size.height, scheme: scheme, direction: direction, phase: phase)
                    }
                }
            }
        }
        #expect(fixture.store.snapshot.conversationHistoryOperations == nil)
        #expect(fixture.store.snapshot.threads[0].draft == "Latest unsent draft 😀")
    } catch { await fixture.finish(); throw error }
    await fixture.finish()
}

@MainActor private func captureOpenCodeHistory(_ view: some View, width: CGFloat, height: CGFloat, scheme: ColorScheme,
                                              direction: LayoutDirection, phase: ConversationHistoryMaintenancePhase) throws {
    guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_OPENCODE_HISTORY"] == "1" else { return }
    let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
    let previous = NSApp.appearance
    NSApp.appearance = appearance; defer { NSApp.appearance = previous }
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = appearance; window.isReleasedWhenClosed = false; window.isOpaque = true; window.backgroundColor = .windowBackgroundColor
    defer { window.close() }
    var capture: Result<Data, any Error>?
    appearance.performAsCurrentDrawingAppearance {
        capture = Result {
            let host = NSHostingView(rootView: view.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = appearance; window.contentView = host; host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
    }
    let data = try #require(capture).get()
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-opencode-history-\(phase.rawValue)-\(Int(width))-\(scheme == .light ? "light" : "dark")-\(direction == .leftToRight ? "ltr" : "rtl").png")
    try data.write(to: path)
}
