import Foundation

struct RemoteThreadActionNativeRead: Sendable {
    let sequence: Int64, incarnation: UUID
    let state: ThreadActionUndoClaim.State
    let runID: UUID?, runtimeID: UUID?
}
struct RemoteThreadUndoNativeRead: Sendable { let sequence: Int64; let claims: [ThreadActionUndoClaim]; let deadline: Date? }

actor RemoteThreadActionsService {
    private struct Owner {
        let binding: RemoteThreadActionBinding
        var captures: [UUID: (RemoteThreadActionCapture, RemoteThreadActionNativeRead, Int)] = [:]
        var order: [UUID] = []
        var group: RemoteThreadUndoGroup?
        var consumed: Set<UUID> = []
    }
    private let environmentID: UUID, hostID: UUID
    private let engine: WorkspaceEngine
    private let workspace: RemoteWorkspaceService
    private var owners: [UUID: Owner] = [:]
    private var captureOrder: [(UUID, UUID)] = []
    private var captureBytes = 8_192
    private func reserveCapture(_ bytes: Int) throws {
        guard bytes <= 8 * 1_024 * 1_024 - 8_192 else { throw RemoteEnvironmentError(.limitExceeded) }
        while captureBytes + bytes > 8 * 1_024 * 1_024 {
            guard !captureOrder.isEmpty else { throw RemoteEnvironmentError(.limitExceeded) }
            let (lease, id) = captureOrder.removeFirst()
            if let old = owners[lease]?.captures.removeValue(forKey: id) { captureBytes -= old.2; owners[lease]?.order.removeAll { $0 == id } }
        }
    }
    private func removeOwner(_ binding: RemoteThreadActionBinding) {
        if let old = owners.removeValue(forKey: binding.leaseID) { captureBytes -= old.captures.values.reduce(0) { $0 + $1.2 } }
        captureOrder.removeAll { $0.0 == binding.leaseID }
    }
    private var closing = false, reading = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private struct Preparation { let digest: String; let task: Task<RemoteThreadActionsPreparation, any Error>; let deadline: Date; var bytes: Int }
    private var preparations: [UUID: Preparation] = [:]
    private func begin() throws { guard !closing else { throw RemoteEnvironmentAdmission.stale() }; reading += 1 }
    private func finish() { reading -= 1; if reading == 0 { let values = waiters; waiters = []; values.forEach { $0.resume() } } }
    init(environmentID: UUID, hostID: UUID, engine: WorkspaceEngine, workspace: RemoteWorkspaceService) { self.environmentID = environmentID; self.hostID = hostID; self.engine = engine; self.workspace = workspace }
    private func owner(_ binding: RemoteThreadActionBinding) throws -> Owner {
        guard !closing, binding.environmentID == environmentID, binding.hostID == hostID, let owner = owners[binding.leaseID], owner.binding == binding else { throw RemoteEnvironmentAdmission.stale() }
        return owner
    }
    func read(_ request: RemoteThreadActionsReadRequest) async throws -> RemoteThreadActionsReadResult {
        try begin(); defer { finish() }
        try Task.checkCancellation()
        guard !closing, request.environmentID == environmentID else { throw RemoteEnvironmentError(.wrongEnvironment) }
        let binding: RemoteThreadActionBinding
        if let existing = request.binding { _ = try owner(existing); binding = existing }
        else {
            guard owners.count < 16 else { throw RemoteEnvironmentError(.limitExceeded) }
            let id = UUID()
            binding = .init(environmentID: environmentID, hostID: hostID, leaseID: id, digest: try RemoteSteeringProtocol.digest([id, UUID()]))
            owners[id] = .init(binding: binding)
            await engine.registerRemoteThreadActionOwner(binding)
        }
        do {
            let native = try await engine.readRemoteThreadUndo(binding)
            var capture: RemoteThreadActionCapture?
            if let target = request.target {
                guard target.environmentID == environmentID else { throw RemoteEnvironmentError(.wrongEnvironment) }
                let source = try await engine.readRemoteThreadAction(target)
                let value = RemoteThreadActionCapture(id: UUID(), binding: binding, target: target, threadCreatedAt: source.state.birth,
                    projectCreatedAt: source.state.projectBirth, runID: source.runID, runtimeID: source.runtimeID,
                    expectedPinned: source.state.pinned, expectedArchived: source.state.archived, digest: try RemoteSteeringProtocol.digest(source.state))
                let bytes = try RemoteProjectionProtocol.payload(value).count + RemoteProjectionProtocol.payload(source.state).count + 256
                try reserveCapture(bytes)
                var owned = try owner(binding)
                while owned.order.count >= 32 {
                    let oldID = owned.order.removeFirst()
                    if let old = owned.captures.removeValue(forKey: oldID) { captureBytes -= old.2 }; captureOrder.removeAll { $0.1 == oldID }
                }
                owned.captures[value.id] = (value, source, bytes); owned.order.append(value.id); owners[binding.leaseID] = owned
                captureBytes += bytes; captureOrder.append((binding.leaseID, value.id)); capture = value
            }
            try Task.checkCancellation()
            var owned = try owner(binding)
            owned.consumed.formIntersection(native.claims.map(\.id))
            let available = native.claims.filter { !owned.consumed.contains($0.id) }
            let group: RemoteThreadUndoGroup?
            if let latest = available.last, let deadline = native.deadline, deadline > Date() {
                let claims = Array(available.reversed().prefix { $0.kind == latest.kind }.reversed())
                struct Key: Encodable { let ids: [UUID]; let expiresAt: Date }
                let digest = try RemoteSteeringProtocol.digest(Key(ids: claims.map(\.id), expiresAt: deadline))
                group = .init(id: owned.group?.digest == digest ? owned.group!.id : UUID(), digest: digest, kind: latest.kind,
                    claimIDs: claims.map(\.id), threadIDs: claims.map(\.threadID), forwardCommandIDs: claims.map(\.forwardCommandID), expiresAt: deadline, remainingMilliseconds: max(0, min(5_000, Int(deadline.timeIntervalSinceNow * 1_000))))
            } else { group = nil }
            owned.group = group; owners[binding.leaseID] = owned
            let result = RemoteThreadActionsReadResult(binding: binding, sequence: native.sequence, capture: capture, undo: group)
            guard try RemoteProjectionProtocol.payload(result).count <= RemoteThreadActionsProtocol.maximumBytes else { throw RemoteEnvironmentError(.limitExceeded) }
            return result
        } catch {
            if request.binding == nil { removeOwner(binding); await engine.releaseRemoteThreadActionOwner(binding) }
            throw error
        }
    }
    func prepare(commandID: UUID, action: RemoteThreadAction) async throws -> RemoteThreadActionsPreparation {
        try begin(); defer { finish() }
        preparations = preparations.filter { $0.value.deadline > Date() }
        let digest = try RemoteSteeringProtocol.digest(action)
        if let original = preparations[commandID] {
            guard original.digest == digest else { throw RemoteEnvironmentError(.commandCollision) }
            return try await original.task.value
        }
        guard preparations.count < 32 else { throw RemoteEnvironmentError(.limitExceeded) }
        let task = Task<RemoteThreadActionsPreparation, any Error> { [weak self] in
            guard let self else { throw CancellationError() }
            let result = try await self.prepareOwned(action)
            try Task.checkCancellation()
            let bytes = try RemoteProjectionProtocol.payload(result).count
            try await self.completePreparation(commandID, bytes: bytes)
            return result
        }
        preparations[commandID] = .init(digest: digest, task: task, deadline: Date().addingTimeInterval(5), bytes: 0)
        return try await task.value
    }
    private func completePreparation(_ id: UUID, bytes: Int) throws {
        guard !closing, preparations[id] != nil, bytes <= 8 * 1_024 * 1_024,
              preparations.filter({ $0.key != id }).values.reduce(bytes, { $0 + $1.bytes }) <= 8 * 1_024 * 1_024 else { throw RemoteEnvironmentError(.limitExceeded) }
        preparations[id]?.bytes = bytes
    }
    private func prepareOwned(_ action: RemoteThreadAction) async throws -> RemoteThreadActionsPreparation {
        var owned = try owner(action.binding)
        switch action {
        case .setPinned(let capture, _), .setArchived(let capture, _):
            guard let original = owned.captures[capture.id], RemoteLifecycleProtocol.same(original.0, capture) else { throw RemoteEnvironmentAdmission.stale() }
            return .init(binding: owned.binding, capture: capture, incarnation: original.1.incarnation, expected: original.1.state)
        case .undo(_, let id, let digest, let ids):
            guard let group = owned.group, group.id == id, group.digest == digest, group.claimIDs == ids,
                  group.expiresAt > Date(), !ids.isEmpty, Set(ids).count == ids.count else { throw RemoteEnvironmentAdmission.stale() }
            // Consume the exact button's group before the first suspension.
            owned.group = nil; owned.consumed.formUnion(ids); owners[owned.binding.leaseID] = owned
            let native = try await engine.readRemoteThreadUndo(owned.binding)
            let claims = ids.compactMap { id in native.claims.first { $0.id == id } }
            guard claims.count == ids.count, native.deadline == group.expiresAt else { throw RemoteEnvironmentAdmission.stale() }
            var targets: [RemoteWorkspaceTarget] = []
            for claim in claims where claim.kind == .settle {
                let update = await engine.current()
                guard let thread = update.snapshot.threads.first(where: { $0.id == claim.threadID }) else { throw RemoteEnvironmentAdmission.stale() }
                let target = RemoteWorkspaceTarget(environmentID: environmentID, projectID: thread.projectID, threadID: thread.id, configuration: .init(thread: thread))
                targets.append(try await workspace.bindCheckpointTarget(target))
            }
            try Task.checkCancellation(); _ = try owner(owned.binding)
            return .init(binding: owned.binding, claims: claims, deadline: group.expiresAt, targets: targets)
        }
    }
    func release(_ request: RemoteThreadActionsReleaseRequest) async -> RemoteThreadActionsReleaseResult {
        guard (try? owner(request.binding)) != nil else { return .init(binding: request.binding, released: false) }
        removeOwner(request.binding)
        await engine.releaseRemoteThreadActionOwner(request.binding)
        return .init(binding: request.binding, released: true)
    }
    func close() async {
        closing = true; let bindings = owners.values.map(\.binding), tasks = preparations.values.map(\.task); owners.removeAll(); preparations.removeAll(); captureOrder.removeAll(); captureBytes = 8_192
        for task in tasks { task.cancel() }
        for binding in bindings { await engine.releaseRemoteThreadActionOwner(binding) }
        for task in tasks { _ = await task.result }
        if reading > 0 { await withCheckedContinuation { waiters.append($0) } }
    }
}
