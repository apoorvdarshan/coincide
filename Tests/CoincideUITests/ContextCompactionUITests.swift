import Foundation
import SwiftUI
import Testing
@testable import CoincideCore
@testable import Coincide

@MainActor @Test func compactSlashActionPreservesTypedDraftAndNeverSubmitsOrSteers() {
    var draft = "/app:compact "
    var actions: [String] = []
    let composer = ComposerView(text: Binding(get: { draft }, set: { draft = $0 }),
        provider: .codex, permission: .supervised, busy: false, submitting: false, hasAttachments: false,
        steeringAvailable: true, steer: { actions.append("unexpected-steer") },
        attach: {}, importProviders: { _ in }, setPermission: { _ in },
        send: { actions.append("unexpected-send") }, stop: {},
        appCommand: { actions.append($0.rawValue) })
    composer.activate(alternate: false)
    #expect(actions == ["compact"])
    #expect(draft == "/app:compact ")
}

@MainActor private struct CompactionUIFixture {
    let root: URL
    let store: WorkspaceStore
    let threadID: UUID

    init(connected: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-compact-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = WorkspaceStore(databaseURL: root.appendingPathComponent("workspace.sqlite"), appMCPEnabled: false)
        let project = WorkspaceProject(path: root.path)
        var thread = CodingThread(project: project)
        thread.draft = "Keep this unsent draft"
        thread.messages = [.init(role: .user, text: "Keep the public conversation")]
        if connected { thread.runtimeID = UUID(); thread.providerThreadID = "synthetic-owned-session" }
        threadID = thread.id
        store.snapshot.projects = [project]; store.snapshot.threads = [thread]; store.selectedThreadID = thread.id
    }
    func cleanup() async { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@MainActor @Test func compactContextRequiresConnectedIdleSupportedSessionBeforeConfirmation() async throws {
    let f = try CompactionUIFixture(connected: false)
    let original = try #require(f.store.thread(f.threadID))
    #expect(f.store.contextCompactionUnavailableReason(threadID: f.threadID) != nil)
    f.store.runAppCommand(.compact)
    #expect(f.store.contextCompactionConfirmation == nil && f.store.errorMessage != nil)
    #expect(f.store.thread(f.threadID)?.messages == original.messages)
    #expect(f.store.thread(f.threadID)?.draft == original.draft)
    await #expect(throws: CoincideError.self) {
        try await f.store.cancelContextCompaction(threadID: f.threadID, operationID: UUID())
    }
    #expect(throws: CoincideError.self) { try f.store.prepareContextCompaction(threadID: f.threadID) }
    await f.cleanup()
}

@MainActor @Test func compactContextConfirmationAndCancellationPreserveDraftAndTranscript() async throws {
    let f = try CompactionUIFixture()
    let original = try #require(f.store.thread(f.threadID))
    f.store.requestContextCompaction(threadID: f.threadID)
    let confirmation = try #require(f.store.contextCompactionConfirmation)
    #expect(confirmation.threadID == f.threadID && confirmation.runtimeID == original.runtimeID)
    #expect(confirmation.configuration == ProviderConfiguration(thread: original))
    #expect(f.store.matchesContextCompactionConfirmation(confirmation))
    // Draft edits do not retarget the operation or become a provider prompt.
    f.store.snapshot.threads[0].draft = "A newer draft"
    #expect(f.store.matchesContextCompactionConfirmation(confirmation))
    f.store.contextCompactionConfirmation = nil
    #expect(f.store.snapshot.contextCompaction(threadID: f.threadID) == nil)
    #expect(f.store.thread(f.threadID)?.messages == original.messages)
    #expect(f.store.thread(f.threadID)?.draft == "A newer draft")
    await f.cleanup()
}

@MainActor @Test func compactContextRejectsReplacedRuntimeAndChangedModelBeforeAnyProviderCall() async throws {
    let f = try CompactionUIFixture()
    let original = try #require(f.store.thread(f.threadID))
    let confirmation = try f.store.prepareContextCompaction(threadID: f.threadID)
    f.store.snapshot.threads[0].runtimeID = UUID()
    #expect(!f.store.matchesContextCompactionConfirmation(confirmation))
    await #expect(throws: CoincideError.self) { try await f.store.compactContext(confirmation) }
    f.store.snapshot.threads[0].runtimeID = confirmation.runtimeID
    f.store.snapshot.threads[0].model = "changed-model"
    #expect(!f.store.matchesContextCompactionConfirmation(confirmation))
    await #expect(throws: CoincideError.self) { try await f.store.compactContext(confirmation) }
    #expect(f.store.snapshot.contextCompaction(threadID: f.threadID) == nil)
    #expect(f.store.acceptingContextCompaction.isEmpty)
    #expect(f.store.thread(f.threadID)?.messages == original.messages)
    #expect(f.store.thread(f.threadID)?.draft == original.draft)
    await f.cleanup()
}

@MainActor @Test func compactContextStatusDistinguishesPendingCompletedFailedAndUnconfirmed() async throws {
    let f = try CompactionUIFixture()
    let original = try #require(f.store.thread(f.threadID)), runtime = try #require(original.runtimeID)
    var operation = ContextCompactionOperation(thread: original, incarnation: UUID(), runtimeID: runtime)
    for phase in [ContextCompactionPhase.pending, .running, .completed, .failed, .unconfirmed] {
        operation.phase = phase
        f.store.snapshot.contextCompactionOperations = [operation]
        f.store.snapshot.threads[0].contextCompactionID = operation.isWorking ? operation.id : nil
        #expect(operation.isWorking == (phase == .pending || phase == .running))
        #expect(!ContextCompactionBanner.title(for: operation).isEmpty)
        if operation.isWorking { #expect(f.store.contextCompactionUnavailableReason(threadID: f.threadID) != nil) }
        #expect(f.store.thread(f.threadID)?.draft == original.draft)
        #expect(f.store.thread(f.threadID)?.messages == original.messages)
    }
    operation.phase = .unconfirmed
    #expect(ContextCompactionBanner.title(for: operation) != "Context compacted")
    await f.cleanup()
}

@MainActor @Test(arguments: [false, true])
func compactionStopKeepsExactOperationIdentityAndNeverFallsBackToOrdinaryInterrupt(guarded: Bool) async throws {
    let f = try CompactionUIFixture()
    let original = try #require(f.store.thread(f.threadID)), runtime = try #require(original.runtimeID)
    let old = ContextCompactionOperation(thread: original, incarnation: UUID(), runtimeID: runtime)
    let successor = ContextCompactionOperation(thread: original, incarnation: UUID(), runtimeID: runtime)
    f.store.snapshot.contextCompactionOperations = [successor]
    f.store.snapshot.threads[0].contextCompactionID = successor.id
    // A delayed stop carrying the earlier operation ID must not become a stop
    // of the successor, even when the provider runtime/configuration is unchanged.
    await #expect(throws: CoincideError.self) {
        try await f.store.cancelContextCompaction(threadID: f.threadID, operationID: old.id)
    }
    #expect(f.store.snapshot.contextCompaction(threadID: f.threadID) == successor)
    // A second ordinary Stop while exact cancellation is already in flight must
    // fail locally, rather than queue an unscoped interrupt that can run later.
    f.store.cancellingContextCompaction.insert(successor.id)
    if guarded { await f.store.interrupt(f.threadID, expectedRunID: nil, expectedRuntimeID: runtime) }
    else { await f.store.interrupt(f.threadID) }
    #expect(f.store.errorMessage == "Stopping context compaction was not confirmed. Check its current status before trying again.")
    #expect(f.store.snapshot.contextCompaction(threadID: f.threadID) == successor)
    #expect(f.store.cancellingContextCompaction == [successor.id])
    #expect(f.store.thread(f.threadID)?.messages == original.messages)
    #expect(f.store.thread(f.threadID)?.draft == original.draft)
    f.store.cancellingContextCompaction.remove(successor.id)
    await f.cleanup()
}
