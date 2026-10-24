import CoincideCore
import Foundation
import Observation

@MainActor @Observable
final class RemoteSteeringEditor: Identifiable {
    let id = UUID()
    let source: RemoteQueuedInputSummary
    let state: RemoteSteeringReadResult
    let originals: [ChatAttachment]
    let composer: RemoteComposerStore
    let uploads: RemoteAttachmentsStore
    var text: String
    var isSaving = false
    var requiresRefresh = false
    var errorMessage: String?
    init(source: RemoteQueuedInputSummary, state: RemoteSteeringReadResult, originals: [ChatAttachment], text: String, root: URL) {
        self.source = source; self.state = state; self.originals = originals; self.text = text
        let directory = root.appendingPathComponent(source.id.uuidString, isDirectory: true)
        composer = .init(root: directory.appendingPathComponent("Composer", isDirectory: true))
        uploads = .init(root: directory.appendingPathComponent("Uploads", isDirectory: true))
    }
}

/// One selected host view. Reads are cancelled/joined; accepted writes remain
/// owned by the workspace's original-UUID pending-command lane.
@MainActor @Observable
final class RemoteSteeringStore {
    private(set) var state: RemoteSteeringReadResult?
    private(set) var queue: [RemoteQueuedInputSummary] = []
    private(set) var operations: [RemoteSteeringOperationSummary] = []
    private(set) var queueCursor: UUID?
    private(set) var operationCursor: UUID?
    private(set) var isLoading = false
    private(set) var isWorking = false
    var editor: RemoteSteeringEditor?
    var errorMessage: String?
    var inspectedText: String?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private var client: RemoteEnvironmentClient?
    @ObservationIgnored private var target: RemoteWorkspaceTarget?
    @ObservationIgnored private var selection: Data?
    @ObservationIgnored private var current: (@MainActor (RemoteWorkspaceTarget) -> Bool)?
    @ObservationIgnored private var perform: (@MainActor (RemoteEnvironmentCommand) async -> Bool)?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var drains: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var commands: [UUID: Task<Bool, Never>] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var stopped = false
    init(root: URL) { self.root = root }
    var canSteer: Bool { !isWorking && state?.canSteer == true && state.map { current?($0.target) == true && $0.target.rootID != nil } == true }
    var explanation: String? {
        guard let state else { return "Update the helper to enable steering, or refresh its active-turn state." }
        if state.canSteer { return "Steer uses the running turn's captured \(state.activeModel ?? "model") and \(state.activePermission?.rawValue ?? "permissions").\(state.interruptsTools ? " It may interrupt active tools." : "")" }
        return state.reason
    }
    func select(client: RemoteEnvironmentClient?, target: RemoteWorkspaceTarget?, supported: Bool, selection: Data,
                current: @escaping @MainActor (RemoteWorkspaceTarget) -> Bool,
                perform: @escaping @MainActor (RemoteEnvironmentCommand) async -> Bool) async {
        guard !stopped else { return }
        self.current = current; self.perform = perform
        guard supported, let client, let target else { disconnect(); return }
        if self.client === client, let old = self.target, self.selection == selection, RemoteLifecycleProtocol.same(old, target), state != nil { return }
        disconnect(); self.client = client; self.target = target; self.selection = selection; await refresh()
    }
    func refresh() async {
        guard !stopped, editor == nil, let client, let target, current?(target) == true else { return }
        worker?.cancel(); let oldWorker = worker; generation = UUID(); let owner = generation
        let job = Task { [weak self] in
            await oldWorker?.value
            guard let self, self.generation == owner, !self.stopped else { return }
            self.isLoading = true
            defer { if self.generation == owner { self.isLoading = false } }
            do {
                let value = try await client.readSteering(.init(target: target))
                guard !Task.isCancelled, self.generation == owner, self.current?(value.target) == true else {
                    _ = try? await client.releaseSteering(.init(target: value.target, binding: value.page.capture.binding)); return
                }
                let old = self.state
                self.state = value; self.queue = value.page.items; self.operations = value.operationPage.operations
                self.queueCursor = value.page.nextCursor; self.operationCursor = value.operationPage.nextCursor; self.errorMessage = nil
                if let old { _ = try? await client.releaseSteering(.init(target: old.target, binding: old.page.capture.binding)) }
            } catch { if self.generation == owner, !(error is CancellationError) { self.errorMessage = "The current remote queue could not be read. Refresh before steering or editing." } }
        }
        worker = job; await job.value
    }
    func page(_ kind: RemoteSteeringPageKind) async {
        guard !isLoading, let state, let client, current?(state.target) == true,
              let cursor = kind == .queue ? queueCursor : operationCursor else { return }
        let owner = generation
        await readJob {
            let page = try await client.steeringPage(.init(target: state.target, binding: state.page.capture.binding, cursor: cursor, kind: kind))
            guard self.generation == owner else { throw CancellationError() }
            if kind == .queue { self.queue += page.items; self.queueCursor = page.nextCursor }
            else { self.operations += page.operations; self.operationCursor = page.nextCursor }
        }
    }
    func inspect(_ row: RemoteSteeringOperationSummary) async {
        guard let state, let client, operations.contains(where: { $0.id == row.id && $0.digest == row.digest }) else { return }
        let owner = generation
        await readJob {
            let bytes = try await client.steeringDocument(row.text, binding: state.page.capture.binding, target: state.target)
            guard self.generation == owner, let text = String(data: bytes, encoding: .utf8) else { throw CancellationError() }
            self.inspectedText = text
        }
    }
    func edit(_ row: RemoteQueuedInputSummary, attachments: RemoteAttachmentsStore) async {
        guard editor == nil, row.canEdit, let state, let client, current?(state.target) == true else { return }
        let owner = generation
        await readJob { [self] in
            let textBytes = try await client.steeringDocument(row.text, binding: state.page.capture.binding, target: state.target)
            let referenceBytes = try await client.steeringDocument(row.attachments, binding: state.page.capture.binding, target: state.target)
            let refs = try JSONDecoder().decode([ChatAttachment].self, from: referenceBytes)
            try AttachmentLimits.validate(refs)
            guard self.generation == owner, self.current?(state.target) == true, let text = String(data: textBytes, encoding: .utf8), refs.count == row.attachmentCount else { throw CancellationError() }
            let model = RemoteSteeringEditor(source: row, state: state, originals: refs, text: text, root: self.root)
            self.editor = model
            let target = RemoteAttachmentTarget(environmentID: state.target.environmentID, projectID: state.target.projectID, threadID: state.target.threadID)
            await model.uploads.select(target: target, client: client, hostDraftAttachments: [], supported: true)
            guard self.generation == owner, self.editor === model else { await model.uploads.shutdown(); throw CancellationError() }
            let scope = RemoteComposerScope(environmentID: state.target.environmentID, hostID: state.page.capture.binding.hostID,
                threadID: state.target.threadID, projectID: state.target.projectID, threadCreatedAt: state.page.capture.threadCreatedAt,
                projectCreatedAt: state.page.capture.projectCreatedAt, workspacePath: state.target.workspacePath,
                configuration: RemoteComposerScope.fingerprint(row.digest))
            await model.composer.select(scope: scope, text: text, host: refs, locals: [], remoteAccess: attachments.access(target: target), localAccess: attachments.localAccess(target: target),
                isCurrent: { [weak self, weak model] _ in self?.editor === model && self?.generation == owner && self?.current?(state.target) == true },
                publish: { [weak model] _, text, expected in guard let model, model.text.utf8.elementsEqual(expected.utf8) else { return false }; model.text = text; return true },
                currentText: { [weak model] in model?.text ?? "" })
        }
    }
    func closeEditor() { let old = editor; editor = nil; let id = UUID(); drains[id] = Task { [weak self] in await old?.composer.shutdown(); await old?.uploads.shutdown(); self?.drains.removeValue(forKey: id) } }
    func send(_ action: RemoteSteeringAction, state: RemoteSteeringReadResult? = nil) async -> Bool {
        guard !isWorking, let captured = state ?? self.state, current?(captured.target) == true,
              captured.page.capture == action.capture, let perform else { return false }
        isWorking = true; let id = UUID()
        let task = Task { await perform(.promptSteering(target: captured.target, action: action)) }; commands[id] = task
        let accepted = await task.value; commands.removeValue(forKey: id); isWorking = false
        if accepted, editor == nil { await refresh() }
        return accepted
    }
    func steerQueued(_ row: RemoteQueuedInputSummary) async {
        guard row.canSteer, let state else { return }
        _ = await send(.steerQueued(capture: state.page.capture, queuedID: row.id, digest: row.digest))
    }
    func removeQueued(_ row: RemoteQueuedInputSummary, expected: RemoteSteeringCapture?) async {
        guard let state, state.page.capture == expected, queue.contains(where: { $0.id == row.id && $0.digest == row.digest }) else { return }
        _ = await send(.removeQueued(capture: state.page.capture, queuedID: row.id, digest: row.digest))
    }
    func moveQueued(_ row: RemoteQueuedInputSummary, beforeID: UUID?, expected: RemoteSteeringCapture?) async {
        guard let state, state.page.capture == expected, queue.contains(where: { $0.id == row.id && $0.digest == row.digest }), let revision = state.page.capture.queueRevision else { return }
        _ = await send(.moveQueued(capture: state.page.capture, queuedID: row.id, beforeID: beforeID, revision: revision))
    }
    private func readJob(_ body: @escaping @MainActor () async throws -> Void) async {
        guard !isLoading else { return }; isLoading = true
        let owner = generation, old = worker
        let job = Task { [weak self] in
            await old?.value
            do { try Task.checkCancellation(); try await body() }
            catch { if self?.generation == owner, !(error is CancellationError) { self?.errorMessage = "This captured remote input is no longer available. Refresh and review it again." } }
            if self?.generation == owner { self?.isLoading = false }
        }; worker = job; await job.value
    }
    func disconnect() {
        generation = UUID(); let old = worker; worker = nil; old?.cancel()
        let state = state, client = client, editor = editor
        self.state = nil; self.target = nil; self.client = nil; self.editor = nil; queue = []; operations = []; queueCursor = nil; operationCursor = nil; isLoading = false
        let id = UUID()
        drains[id] = Task { [weak self] in
            await old?.value; await editor?.composer.shutdown(); await editor?.uploads.shutdown()
            if let state, let client { _ = try? await client.releaseSteering(.init(target: state.target, binding: state.page.capture.binding)) }
            self?.drains.removeValue(forKey: id)
        }
    }
    func acknowledgeQueued(target: RemoteAttachmentTarget, queuedID: UUID, uploadedIDs: [UUID]) async -> Bool {
        if let editor, editor.source.id == queuedID {
            return await editor.uploads.acknowledge(target: target, uploadedAttachmentIDs: uploadedIDs)
        }
        let cache = RemoteAttachmentsStore(root: root.appendingPathComponent(queuedID.uuidString, isDirectory: true).appendingPathComponent("Uploads", isDirectory: true))
        let result = await cache.acknowledge(target: target, uploadedAttachmentIDs: uploadedIDs)
        await cache.shutdown(); return result
    }
    func drainReads() async { for task in Array(drains.values) { await task.value } }
    func shutdown() async { stopped = true; disconnect(); for task in Array(commands.values) { _ = await task.value }; await drainReads() }
    func cancelShutdown() { stopped = false }
}
