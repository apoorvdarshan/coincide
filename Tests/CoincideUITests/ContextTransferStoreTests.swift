import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private actor ContextUIBoundary {
    var started = false
    var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var exits: [CheckedContinuation<Void, Never>] = []
    func wait() async { started = true; let values = arrivals; arrivals = []; values.forEach { $0.resume() }; if !released { await withCheckedContinuation { exits.append($0) } } }
    func entered() async { if !started { await withCheckedContinuation { arrivals.append($0) } } }
    func release() { released = true; let values = exits; exits = []; values.forEach { $0.resume() } }
}
private actor ContextNativeUIPeer {
    let runID: UUID
    var gate: ContextUIBoundary?
    var reviews: [ContextTransferReview] = []
    var discarded: [UUID] = []
    var accepted: [UUID] = []
    init(runID: UUID) { self.runID = runID }
    func hold(_ gate: ContextUIBoundary) { self.gate = gate }
    func review(_ request: ContextTransferReviewRequest) async throws -> ContextTransferReview {
        let destination: ProviderConfiguration
        let target: UUID
        switch request.intent {
        case .fork(let value): destination = value; target = UUID()
        case .providerHandoff(let value): destination = value; target = request.sourceThreadID
        case .mergeBack(let value): destination = value; target = UUID()
        }
        let value = ContextTransferReview(id: UUID(), digest: String(repeating: "a", count: 64), request: request,
            sourcePoint: .init(threadID: request.sourceThreadID, runID: runID), basePoint: nil, targetThreadID: target,
            projectID: UUID(), sourceConfiguration: request.expectedConfiguration, targetConfiguration: destination,
            targetProviderBinding: nil, strategy: .portableContext, title: "Reviewed fork", messages: [.init(id: "m1", runID: runID, role: "assistant", kind: "text", text: "Exact source 工作 e\u{301}\n")],
            nativeReview: nil, sourceFingerprint: "owned", sourceIncarnation: UUID(), targetIncarnation: nil, reviewedAt: Date())
        reviews.append(value)
        if let gate { await gate.wait() }; return value
    }
    func discard(_ id: UUID) { discarded.append(id) }
    func accept(_ id: UUID) -> WorkspaceCommandReceipt { accepted.append(id); return .init(commandID: UUID(), sequence: 1, eventCount: 1, acceptedAt: Date(), rejection: nil) }
}
@MainActor private struct NativeContextUIFixture {
    let store = ContextTransferStore()
    var snapshot: WorkspaceSnapshot
    let peer: ContextNativeUIPeer
    let runID: UUID
    var source: CodingThread { snapshot.threads[0] }
    init() {
        let project = WorkspaceProject(path: "/owned/native-context"), unrelated = WorkspaceProject(path: "/unrelated")
        var thread = CodingThread(project: project); thread.draft = "Keep literal draft 工作"
        let run = ActiveRun(id: UUID(), configuration: .init(thread: thread), startedAt: Date()); runID = run.id
        var record = ThreadRunRecord(run: run, origin: .user); record.status = .completed; record.messageAttributionVersion = 1
        thread.runHistory = [record]
        var sibling = CodingThread(project: project); sibling.workspacePath = "/owned/native-context-worktree"
        snapshot = WorkspaceSnapshot(); snapshot.projects = [project, unrelated]; snapshot.threads = [thread, sibling, CodingThread(project: unrelated)]
        peer = ContextNativeUIPeer(runID: run.id)
    }
    func update() {
        store.update(sourceThreadID: source.id, snapshot: snapshot,
            transport: .init(review: { [peer] in try await peer.review($0) }, discard: { [peer] id, _ in await peer.discard(id) }, accept: { [peer] id, _, _ in await peer.accept(id) }),
            destination: { _, provider, path, model, permission in var value = ProviderConfiguration(thread: source); value.provider = provider; value.workspacePath = path; value.model = model; value.permission = permission; value.nativeThreadID = nil; return value },
            canReview: { true }, canAccept: { _ in true }, open: { _ in })
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func contextTransferNativeSelectionUsesOnlySourceProjectAndNoProviderWorkUntilExplicitReview() async throws {
    let f = NativeContextUIFixture(); f.update()
    #expect(!f.store.workspaceOptions.contains { $0.path == "/unrelated" })
    #expect(f.store.workspaceOptions.contains { $0.path == "/owned/native-context-worktree" })
    #expect(f.store.sourceOptions.contains { $0.id == "run-" + f.runID.uuidString })
    let initialReviews = await f.peer.reviews; #expect(initialReviews.isEmpty && f.store.canPrepare)
    _ = await f.store.prepare(); let review = try #require(f.store.review)
    #expect(f.store.canConfirm && review.messages[0].text == "Exact source 工作 e\u{301}\n")
    #expect(await f.store.accept()); #expect(await f.peer.accepted == [review.id])
    let duplicate = await f.store.accept(); #expect(!duplicate && f.source.draft == "Keep literal draft 工作")
    await f.store.shutdown()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func contextTransferNativeCancelledReviewIsDisposedAndStalePaneCannotClearReplacement() async throws {
    let f = NativeContextUIFixture(), gate = ContextUIBoundary(); f.update(); await f.peer.hold(gate)
    let task = Task { await f.store.prepare() }; await gate.entered(); task.cancel(); await gate.release()
    let cancelled = await task.value; #expect(cancelled == nil && f.store.review == nil)
    _ = await f.store.prepare(); let replacement = try #require(f.store.review)
    let ids = await f.peer.reviews.map(\.id)
    f.store.clear(id: ids[0]); #expect(f.store.review?.id == replacement.id)
    await f.store.shutdown(); #expect(await f.peer.discarded.contains(ids[0]))
    #expect(await f.peer.accepted.isEmpty)
}

private actor RemoteContextUIPeer {
    let initial: RemoteWorkspaceTarget
    let rootID = UUID(), hostID = UUID(), runID = UUID(), parentID = UUID()
    var gate: ContextUIBoundary?
    var inventoryGate: ContextUIBoundary?
    var bindCount = 0, parentCount = 0, readCount = 0
    var discarded: [RemoteContextDiscardRequest] = []
    var released: [RemoteWorkspaceTarget] = []
    var requests: [RemoteContextReviewRequest] = []
    var documents: [UUID: Data] = [:]
    var uncertain: RemoteContextDeliveryControl?
    init(_ target: RemoteWorkspaceTarget) { initial = target }
    func hold(_ gate: ContextUIBoundary) { self.gate = gate }
    func holdInventory(_ gate: ContextUIBoundary) { inventoryGate = gate }
    func setUncertain() { uncertain = .init(deliveryID: UUID(), transferIDs: [UUID(), UUID()], canUseFreshContext: true) }
    func bind(_ target: RemoteWorkspaceTarget) -> RemoteWorkspaceTarget { bindCount += 1; return .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID, configuration: target.configuration, rootID: rootID) }
    func parent(_ id: UUID) throws -> RemoteWorkspaceTarget { parentCount += 1; guard id == parentID else { throw RemoteContextFailure(.invalidTarget) }; return .init(environmentID: initial.environmentID, projectID: initial.projectID, threadID: id, configuration: initial.configuration, rootID: UUID()) }
    func binding(_ target: RemoteWorkspaceTarget, id: UUID = UUID()) -> RemoteHistoryBinding { .init(environmentID: target.environmentID, hostID: hostID, leaseID: UUID(), threadID: target.threadID, objectID: id, digest: String(repeating: "b", count: 64)) }
    func reference<T: Encodable>(_ value: T, kind: RemoteProjectionContentKind = .text) throws -> RemoteProjectionContentReference {
        let data = try RemoteContextProtocol.payload(value), id = UUID(); documents[id] = data
        return .init(id: id, kind: kind, totalBytes: data.count, digest: RemoteProjectionProtocol.digest(data))
    }
    func rawText(_ text: String) -> RemoteProjectionContentReference {
        let data = Data(text.utf8), id = UUID(); documents[id] = data
        return .init(id: id, kind: .text, totalBytes: data.count, digest: RemoteProjectionProtocol.digest(data))
    }
    func review(_ request: RemoteContextReviewRequest) async throws -> RemoteContextReview {
        requests.append(request)
        let destination: ProviderConfiguration, kind: ContextTransferKind, targetID: UUID
        switch request.intent {
        case .fork(let closed), .providerHandoff(let closed):
            var value = request.target.configuration; value.provider = closed.provider ?? value.provider; value.model = closed.model ?? value.model; value.permission = closed.permission ?? value.permission; value.workspacePath = closed.workspacePath ?? value.workspacePath
            destination = value
            if case .fork = request.intent { kind = .fork; targetID = UUID() } else { kind = .providerHandoff; targetID = request.target.threadID }
        case .mergeBack(let parent): destination = parent.configuration; kind = .mergeBack; targetID = parent.threadID
        }
        let config = try reference(request.target.configuration, kind: .configuration), targetConfig = try reference(destination, kind: .configuration)
        let selection = try ContextHandoffService.select(messages: [.init(id: "item", role: "assistant", kind: "text", text: "Exact whole context 工作\n")], coverage: .init(transferID: UUID(), sourceThreadID: request.target.threadID, strategy: "portableContext"), budget: ContextHandoffBudget.defaultTokenCap)
        let selected = try reference(selection), id = UUID(), lease = binding(request.target, id: id)
        let value = RemoteContextReview(id: id, digest: lease.digest, target: request.target, binding: lease, value: .init(kind: kind, strategy: kind == .mergeBack ? .forkDeltaContext : .portableContext,
            sourcePoint: .init(threadID: request.target.threadID, runID: runID), basePoint: nil, targetThreadID: targetID, projectID: request.target.projectID,
            title: .init(preview: "Host reviewed title", complete: true), sourceConfiguration: config, targetConfiguration: targetConfig,
            archiveItemCount: 1, archiveByteCount: 100, previewSelection: selected, warnings: []))
        if let gate { await gate.wait() }; return value
    }
    func read(_ request: RemoteContextReadRequest) async throws -> RemoteContextReadResult {
        readCount += 1
        switch request.query {
        case .inventory:
            let lease = binding(request.target)
            if let inventoryGate { await inventoryGate.wait() }
            return .init(target: request.target, value: .inventory(.init(binding: lease,
                lineage: .init(parentThreadID: parentID, rootThreadID: parentID, transferID: UUID(), basePoint: .init(threadID: parentID, runID: runID)), pendingCount: uncertain == nil ? 0 : 2, uncertain: uncertain,
                transfers: .init(binding: lease, offset: 0, items: [], totalCount: 0, nextCursor: nil, complete: true))))
        case .release: released.append(request.target); return .init(target: request.target, value: .released(true))
        case .content(let lease, let reference, let offset, _):
            guard let data = documents[reference.id], offset <= data.count else { throw RemoteContextFailure(.invalidRequest) }
            let end = min(data.count, offset + RemoteHistoryProtocol.maximumContentChunkBytes), complete = end == data.count
            return .init(target: request.target, value: .content(.init(binding: lease, reference: reference, offset: offset,
                data: data.subdata(in: offset..<end), nextCursor: complete ? nil : UUID(), complete: complete)))
        default: throw RemoteContextFailure(.invalidRequest)
        }
    }
    func discard(_ request: RemoteContextDiscardRequest) -> RemoteContextDiscardResult { discarded.append(request); return .init(request: request, discarded: true) }
    func document(_ reference: RemoteProjectionContentReference) throws -> Data { guard let data = documents[reference.id] else { throw RemoteContextFailure(.invalidRequest) }; return data }
    func counts() -> [Int] { [bindCount, parentCount, readCount, requests.count, discarded.count] }
}
@MainActor private final class RemoteContextUIFixture {
    let store = RemoteContextTransferStore(), projection = RemoteProjectionStore(), target: RemoteWorkspaceTarget, peer: RemoteContextUIPeer
    var commands: [RemoteEnvironmentCommand] = [], opened: [UUID] = []
    var accepted = true
    var draft = "Keep exact private local draft 工作\n"
    init() {
        let project = WorkspaceProject(path: "/remote/context/project"), thread = CodingThread(project: project)
        target = .init(environmentID: UUID(), projectID: project.id, threadID: thread.id, configuration: .init(thread: thread)); peer = .init(target)
    }
    var transport: RemoteContextTransferTransport {
        .init(bind: { [peer] in await peer.bind($0) }, parent: { [peer] in try await peer.parent($0) }, review: { [peer] in try await peer.review($0) },
            read: { [peer] in try await peer.read($0) }, discard: { [peer] in await peer.discard($0) }, document: { [peer] reference, _, _ in try await peer.document(reference) })
    }
    func update(target replacement: RemoteWorkspaceTarget? = nil, canWrite: Bool = true) async {
        await store.select(target: replacement ?? target, projection: projection, transport: transport, supported: true, providers: [.codex, .claude], canWrite: canWrite,
            perform: { [weak self] command in guard let self else { return false }; self.commands.append(command); return self.accepted }, openConversation: { [weak self] in self?.opened.append($0) })
    }
    func model() throws -> RemoteContextTransferWorkspace { try #require(store.current) }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteContextTransferHydratesOpaqueReviewAndAcceptsExactClaimOnceWithoutChangingDraft() async throws {
    let f = RemoteContextUIFixture(); await f.update(); let model = try f.model()
    let initialRequests = await f.peer.requests; #expect(f.commands.isEmpty && initialRequests.isEmpty)
    model.kind = .providerHandoff; model.provider = .claude
    _ = await model.prepare(); let review = try #require(model.review)
    #expect(model.sourceConfiguration == f.target.configuration && model.destinationConfiguration?.provider == .claude)
    #expect(model.previewSelection?.messages.first?.text == "Exact whole context 工作\n" && model.canConfirm)
    #expect(await model.accept()); #expect(await model.accept() == false)
    #expect(f.commands == [.contextTransfer(target: review.target, action: .begin(reviewID: review.id, digest: review.digest, title: nil))])
    #expect(review.value.targetThreadID == f.target.threadID && f.opened == [f.target.threadID] && f.draft == "Keep exact private local draft 工作\n")
    await f.store.shutdown()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteContextTransferDisconnectDisposesLateClaimAtExactBoundRootAndReconnectRebinds() async throws {
    let f = RemoteContextUIFixture(), gate = ContextUIBoundary(); await f.update(); let model = try f.model(); await f.peer.hold(gate)
    let reviewing = Task { await model.prepare() }; await gate.entered(); f.store.disconnect(); await gate.release()
    let cancelled = await reviewing.value; #expect(cancelled == nil && model.review == nil && f.commands.isEmpty)
    await f.update(); _ = await model.prepare(); let replacement = try #require(model.review)
    let binds = await f.peer.bindCount; #expect(binds == 2 && replacement.target.rootID != nil)
    await f.store.shutdown(); let discards = await f.peer.discarded
    #expect(discards.count == 2 && discards.allSatisfy { $0.target.rootID != nil })
    let releases = await f.peer.released; #expect(releases.contains { $0.rootID == nil })
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteContextTransferDisconnectDrainsLateInventoryAndReleasesItsCapturedTransportLease() async throws {
    let f = RemoteContextUIFixture(), gate = ContextUIBoundary(); await f.peer.holdInventory(gate)
    let selecting = Task { await f.update() }; await gate.entered(); let model = try f.model()
    f.store.disconnect(); var closed = false
    let shutdown = Task { await f.store.shutdown(); closed = true }
    #expect(model.inventory == nil && !model.connected && !closed)
    await gate.release(); await selecting.value; await shutdown.value
    let released = await f.peer.released
    #expect(closed && released == [f.target] && model.inventory == nil && f.commands.isEmpty)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteContextTransferUncertainCommandIsNotRepeatedAndFreshChoiceUsesExactRootlessDeliveryIDs() async throws {
    let f = RemoteContextUIFixture(); await f.peer.setUncertain(); await f.update(); let model = try f.model()
    let control = try #require(model.inventory?.uncertain)
    await model.useFreshContext(.init(deliveryID: control.deliveryID, transferIDs: [UUID()], canUseFreshContext: true)); #expect(f.commands.isEmpty)
    await model.useFreshContext(control)
    #expect(f.commands == [.contextTransfer(target: f.target, action: .useFreshContext(deliveryID: control.deliveryID, expectedTransferIDs: control.transferIDs))])
    let binds = await f.peer.bindCount; #expect(binds == 0 && f.draft == "Keep exact private local draft 工作\n")
    f.accepted = false; _ = await model.prepare(); let review = try #require(model.review)
    #expect(await model.accept() == false); #expect(await model.accept() == false)
    #expect(f.commands.count == 2 && model.review?.id == review.id && !model.canConfirm)
    await f.store.shutdown()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteContextTransferMergeBackResolvesActualParentAndChangedCaptureInvalidatesReview() async throws {
    let f = RemoteContextUIFixture(); await f.update(); let model = try f.model(); model.kind = .mergeBack
    _ = await model.prepare(); let review = try #require(model.review)
    let requests = await f.peer.requests
    guard case .mergeBack(let parent) = try #require(requests.last).intent else { Issue.record("Expected exact parent intent"); await f.store.shutdown(); return }
    #expect(parent.threadID == model.inventory?.lineage?.parentThreadID && parent.rootID != nil && review.value.targetThreadID == parent.threadID)
    var configuration = f.target.configuration; configuration.model = "new-model"
    await f.update(target: .init(environmentID: f.target.environmentID, projectID: f.target.projectID, threadID: f.target.threadID, configuration: configuration))
    let accepted = await model.accept(); #expect(model.review == nil && !accepted && f.commands.isEmpty)
    await f.store.shutdown()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteContextTransferLeasedUnicodeTextKeepsBoundedWindowAndVerifiesEveryByte() async throws {
    let f = RemoteContextUIFixture(); await f.update(); let model = try f.model(); _ = await model.prepare()
    let review = try #require(model.review), text = String(repeating: "工作🧪e\u{301}\n", count: 100_003)
    let reference = await f.peer.rawText(text), reader = RemoteContextTextReader()
    while !reader.complete, reader.error == nil { await reader.load(model: model, binding: review.binding, reference: reference) }
    #expect(reader.verified && reader.offset == text.utf8.count && reader.windowStart > 0)
    #expect(reader.text.utf8.count <= 1_048_576 && !reader.text.contains("\u{fffd}") && text.hasSuffix(reader.text))
    #expect(f.commands.isEmpty && f.draft == "Keep exact private local draft 工作\n")
    await f.store.shutdown()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func contextTransferOffscreenNativeAndRemoteReviewedSheetsFitLightDarkSmallBoundsWithoutCalls() async throws {
    _ = NSApplication.shared
    let native = NativeContextUIFixture(); native.update(); _ = await native.store.prepare()
    let remote = RemoteContextUIFixture(); await remote.update(); let model = try remote.model(); _ = await model.prepare()
    let before = await remote.peer.counts(), nativeBefore = await native.peer.reviews.count
    for scheme in [ColorScheme.light, .dark] {
        for size in [CGSize(width: 480, height: 560), CGSize(width: 640, height: 680)] {
            let views: [AnyView] = [AnyView(ContextTransferSheetContent(model: native.store, prepare: { Issue.record("No implicit review") }, accept: { Issue.record("No implicit accept") }, close: {})),
                AnyView(RemoteContextTransferSheetContent(model: model, prepare: { Issue.record("No implicit remote review") }, accept: { Issue.record("No implicit remote accept") }, close: {}))]
            for view in views {
                let hosting = NSHostingController(rootView: view.environment(\.colorScheme, scheme)), fitted = hostingSize(view.environment(\.colorScheme, scheme), size)
                #expect(fitted.width.isFinite && fitted.height.isFinite && fitted.width > 0 && fitted.height > 0)
                #expect(fitted.width <= size.width + 1 && fitted.height <= size.height + 1)
                hosting.view.frame = CGRect(origin: .zero, size: fitted); hosting.view.layoutSubtreeIfNeeded(); #expect(hosting.view.window == nil)
            }
        }
    }
    let after = await remote.peer.counts(), nativeAfter = await native.peer.reviews.count
    #expect(after == before && remote.commands.isEmpty)
    #expect(nativeAfter == nativeBefore && native.source.draft == "Keep literal draft 工作")
    await native.store.shutdown(); await remote.store.shutdown()
}
@MainActor private func hostingSize<V: View>(_ view: V, _ size: CGSize) -> CGSize { NSHostingController(rootView: view).sizeThatFits(in: size) }

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteContextTransferSourceCheckpointHydrationRejectsChangedPinnedViewAndKeepsCurrentFailedAttempt() async throws {
    let cache = RemoteContextSourceCheckpoints(), gate = ContextUIBoundary(), runID = UUID(), threadID = UUID()
    let binding = RemoteProjectionBinding(environmentID: UUID(), hostID: UUID(), viewID: UUID(), sequence: 7,
        fingerprint: String(repeating: "c", count: 64), scope: .thread(threadID))
    func attempt(_ phase: RunCheckpointPhase, later: Bool) -> RemoteCheckpointAttemptSummary {
        .init(id: UUID(), stage: .postRun, workspacePath: "/remote/source", phase: phase, requestedAt: Date(), updatedAt: Date(),
            isLaterObservation: later, hasReceipt: phase == .ready, digest: String(repeating: "d", count: 64), restore: .init(allowed: false))
    }
    let oldReady = attempt(.ready, later: false), currentFailed = attempt(.failed, later: true)
    let values = [oldReady, currentFailed], data = try RemoteProjectionProtocol.payload(values)
    let reference = RemoteProjectionContentReference(id: UUID(), kind: .checkpointAttempts, totalBytes: data.count, digest: RemoteProjectionProtocol.digest(data))
    let run = RemoteRunSummary(id: runID, origin: .user, status: .completed, startedAt: Date(), stopRequested: false, turnCount: 1,
        checkpointAttempts: [currentFailed], checkpointAttemptCount: values.count, checkpointAttemptsComplete: false, checkpointAttemptsContent: reference,
        checkpointDiff: .init(allowed: false), fork: .init(allowed: false), rewind: .init(allowed: false))
    var currentBinding: RemoteProjectionBinding? = binding
    let loading = Task { try await cache.load(run: run, binding: binding, document: { _, _ in await gate.wait(); return data }, current: { (run, currentBinding) }) }
    await gate.entered(); currentBinding = .init(environmentID: binding.environmentID, hostID: binding.hostID, viewID: UUID(), sequence: 8,
        fingerprint: binding.fingerprint, scope: binding.scope)
    await gate.release(); #expect(try await loading.value == false)
    #expect(cache.attempts(for: run, binding: binding).isEmpty && !cache.isLoading)
    currentBinding = binding
    #expect(try await cache.load(run: run, binding: binding, document: { _, _ in data }, current: { (run, currentBinding) }))
    let loaded = cache.attempts(for: run, binding: binding)
    #expect(loaded.map(\.id) == [oldReady.id, currentFailed.id] && loaded.last?.phase == .failed)
    #expect(cache.attempts(for: run, binding: currentBinding.map { .init(environmentID: $0.environmentID, hostID: $0.hostID, viewID: UUID(), sequence: $0.sequence, fingerprint: $0.fingerprint, scope: $0.scope) }).isEmpty)
    cache.clear(); #expect(!cache.contains(run, binding: binding))
}
