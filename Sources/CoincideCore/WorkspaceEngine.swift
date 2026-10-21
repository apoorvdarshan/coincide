import Foundation

public struct WorkspaceUpdate: Sendable {
    public var snapshot: WorkspaceSnapshot
    public var sequence: Int64
    public var error: String?
}

/// Serial command decisions and durable commits are independent of provider I/O.
public actor WorkspaceEngine {
    public typealias ProviderFactory = @Sendable (CodingThread) throws -> any ProviderSession
    public typealias WorktreeFactory = @Sendable (GitWorktreeRequest) throws -> any WorkspaceWorktreeSession
    public typealias CloneFactory = @Sendable (GitClonePlan) throws -> any ProjectCloneSession
    public typealias IdentityResolver = @Sendable (URL) async throws -> RepositoryIdentity?
    private struct Envelope: Sendable {
        var id: UUID
        var command: EngineCommand
        var continuation: CheckedContinuation<WorkspaceCommandReceipt, any Error>
    }
    private struct Runtime: Sendable {
        var id: UUID
        var projectID: UUID
        var session: any ProviderSession
        var provider: ProviderKind
        var path: String
        var acpAgent: ACPAgentConfiguration?
        var reader: Task<Void, Never>?
    }
    private struct MetadataRuntime: Sendable {
        var session: any ProviderSession
        var threadID: UUID?
        var projectID: UUID?
        var configuration: ProviderConfiguration?
        var closeTask: Task<Void, Never>?
    }
    private struct Cleanup: Sendable {
        var projectIDs: Set<UUID>
        var task: Task<Void, Never>
    }
    private struct IdentityRefresh: Sendable {
        var id: UUID
        var incarnation: UUID
        var path: String
        var task: Task<RepositoryIdentity?, any Error>
    }
    private let database: WorkspaceDatabase
    public nonisolated let attachments: AttachmentStore
    public nonisolated let worktreesRoot: URL
    private let worktreeFactory: WorktreeFactory
    private struct WorktreeInspection: Sendable {
        let threadID: UUID
        let projectID: UUID
        let task: Task<GitWorktreeResult?, any Error>
    }
    private var worktreeInspections: [UUID: WorktreeInspection] = [:]
    private var threadIncarnations: [UUID: UUID] = [:]
    private let ownership: WorkspaceRuntimeLock
    private let factory: ProviderFactory
    private let cloneFactory: CloneFactory
    private let identityResolver: IdentityResolver
    private let identityGate = GitOperationGate()
    private let worktreeInspectionGate = GitOperationGate()
    private let workerID = UUID()
    private let inbox: AsyncStream<Envelope>
    private let incoming: AsyncStream<Envelope>.Continuation
    private var commandWorker: Task<Void, Never>?
    private var initialization: Task<WorkspaceSnapshot, any Error>?
    private var shutdownTask: Task<Void, Never>?
    private var revision = WorkspaceRevision(snapshot: WorkspaceSnapshot(), sequence: 0)
    private var loaded = false
    private var closing = false
    private var stoppingEffects = false
    private var fatalError: String?
    private var pendingCommands = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var listeners: [UUID: AsyncStream<WorkspaceUpdate>.Continuation] = [:]
    private var pumping = false
    private var effectWakeGeneration = 0
    private var effects: [UUID: Task<Void, Never>] = [:]
    private var effectRequests: [UUID: WorkspaceEffectRequest] = [:]
    private var runtimes: [UUID: Runtime] = [:]
    private var metadataSessions: [UUID: MetadataRuntime] = [:]
    private var projectIncarnations: [UUID: UUID] = [:]
    private var identityRefreshes: [UUID: IdentityRefresh] = [:]
    private var cleanupTasks: [UUID: Cleanup] = [:]
    private var retiringEffects: Set<UUID> = []
    private var retiringEffectWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var completedDuringCommit: Set<UUID>?
    private var removalCommitProjects: Set<UUID> = []
    private var removalCommitThreads: Set<UUID> = []
    private var removalCommitWaiters: [CheckedContinuation<Bool, Never>] = []
    private var cloneProgressTimes: [UUID: (ContinuousClock.Instant, GitCloneProgress)] = [:]
    private let encoder: JSONEncoder = { let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value }()

    public init(url: URL, providerFactory: @escaping ProviderFactory = { try ProviderSessions.make(for: $0) },
                cloneFactory: @escaping CloneFactory = { GitCloneService(plan: $0) },
                identityResolver: @escaping IdentityResolver = { try await RepositoryIdentityResolver(root: $0).resolve() },
                worktreeFactory: @escaping WorktreeFactory = { GitWorktreeService(request: $0) }) throws {
        ownership = try WorkspaceRuntimeLock(url: url.appendingPathExtension("runtime-lock"))
        database = try WorkspaceDatabase(url: url)
        attachments = try AttachmentStore(root: url.deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true))
        factory = providerFactory
        self.cloneFactory = cloneFactory
        self.identityResolver = identityResolver
        self.worktreeFactory = worktreeFactory
        worktreesRoot = url.deletingLastPathComponent().appendingPathComponent("Worktrees", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: worktreesRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let pair = AsyncStream<Envelope>.makeStream()
        inbox = pair.stream; incoming = pair.continuation
    }
    public func load() async throws -> WorkspaceSnapshot {
        guard !closing else { throw CancellationError() }
        if loaded { return revision.snapshot }
        if let initialization { return try await initialization.value }
        let task = Task { try await self.initialize() }
        initialization = task
        return try await task.value
    }
    private func initialize() async throws -> WorkspaceSnapshot {
        revision = try await database.revision()
        _ = try await database.cancelEffectsAfterProcessLoss()
        var recovered = revision.snapshot; recovered.recoverInterruptedWork()
        recovered = await reconcileCompletedClones(in: recovered)
        let receipt = try await database.commit(recovered, event: "workspace.opened", commandID: UUID(), expectedSequence: revision.sequence)
        revision = .init(snapshot: recovered, sequence: receipt.sequence)
        projectIncarnations = Dictionary(uniqueKeysWithValues: recovered.projects.map { ($0.id, UUID()) })
        threadIncarnations = Dictionary(uniqueKeysWithValues: recovered.threads.map { ($0.id, UUID()) })
        loaded = true
        let stream = inbox
        commandWorker = Task { [weak self] in
            for await envelope in stream {
                guard let self else { envelope.continuation.resume(throwing: CancellationError()); continue }
                await self.process(envelope)
            }
        }
        publish()
        scheduleIdentityRefreshes(previous: nil)
        scheduleWorktreeReconciliation()
        return recovered
    }
    public func current() -> WorkspaceUpdate { .init(snapshot: revision.snapshot, sequence: revision.sequence, error: fatalError) }
    public func updates() -> AsyncStream<WorkspaceUpdate> {
        let id = UUID(), pair = AsyncStream<WorkspaceUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        listeners[id] = pair.continuation
        if loaded { pair.continuation.yield(current()) }
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        return pair.stream
    }
    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }
    private func publish(error: String? = nil) {
        let update = WorkspaceUpdate(snapshot: revision.snapshot, sequence: revision.sequence, error: error ?? fatalError)
        for listener in listeners.values { listener.yield(update) }
    }
    @discardableResult public func dispatch(_ command: WorkspaceCommand, id: UUID = UUID()) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        guard !stoppingEffects else { throw CancellationError() }
        let receipt = try await enqueue(.client(command), id: id)
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }
    /// A retry first checks the previous attempt's durable publication evidence. A crash or
    /// late Cancel must not overwrite or clone over an already completed destination.
    @discardableResult public func retryProjectClone(_ projectID: UUID) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        guard !stoppingEffects else { throw CancellationError() }
        guard let clone = revision.snapshot.projects.first(where: { $0.id == projectID })?.clone, clone.canRetry else {
            throw WorkspaceCommandError("This project has no interrupted clone to retry.")
        }
        if try await cloneFactory(clone.plan).isCompleted() {
            guard !stoppingEffects else { throw CancellationError() }
            return try await enqueue(.effectResult(.projectClone(projectID: projectID, plan: clone.plan), .succeeded))
        }
        let plan = try GitClonePlan.prepare(source: clone.plan.source, destination: URL(fileURLWithPath: clone.plan.destinationPath))
        return try await dispatch(.retryProjectClone(projectID: projectID, plan: plan))
    }
    /// Record the destination before resolving Git references. The command rechecks the source
    /// and first-turn boundary after any UI command that was already queued.
    @discardableResult public func beginWorktreePreparation(threadID: UUID, selection: GitWorktreeSelection) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        if await waitForRemovalCommit(threadID: threadID) { throw CancellationError() }
        try Task.checkCancellation()
        guard !stoppingEffects, let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              let incarnation = threadIncarnations[threadID] else { throw CancellationError() }
        let source = thread.workspacePreparation.flatMap { $0.canRetry ? $0.request.sourcePath : nil } ?? thread.workspacePath
        let request = GitWorktreeRequest(sourcePath: source, destinationRoot: worktreesRoot.path, selection: selection)
        let receipt = try await enqueue(.beginWorktreePreparation(threadID: threadID, request: request, expectedSourcePath: thread.workspacePath, previousAttemptID: nil, incarnation: incarnation))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }; return receipt
    }
    @discardableResult public func cancelWorktreePreparation(_ threadID: UUID) async throws -> WorkspaceCommandReceipt {
        try await dispatch(.cancelWorktreePreparation(threadID))
    }
    /// Inspect an exact saved plan first. An unproven partial checkout is preserved, and a new
    /// attempt gets another managed folder rather than resuming Git over existing bytes.
    @discardableResult public func retryWorktreePreparation(_ threadID: UUID) async throws -> WorkspaceCommandReceipt {
        _ = try await load()
        if await waitForRemovalCommit(threadID: threadID) { throw CancellationError() }
        try Task.checkCancellation()
        guard !stoppingEffects, let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              let state = thread.workspacePreparation, state.canRetry,
              let incarnation = threadIncarnations[threadID], state.request.destinationRoot == worktreesRoot.path else {
            throw WorkspaceCommandError("This conversation has no interrupted workspace preparation to retry.")
        }
        if let plan = state.plan {
            let session = try worktreeFactory(state.request), token = UUID()
            let task = Task { try await session.inspectCompletion(plan) }
            worktreeInspections[token] = .init(threadID: threadID, projectID: thread.projectID, task: task)
            defer { worktreeInspections.removeValue(forKey: token) }
            let result: GitWorktreeResult?
            do {
                result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            } catch {
                if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { throw CancellationError() }
                guard ownsWorktree(threadID: threadID, attemptID: state.id, incarnation: incarnation), !task.isCancelled else { throw CancellationError() }
                try Task.checkCancellation(); throw error
            }
            if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { throw CancellationError() }
            guard ownsWorktree(threadID: threadID, attemptID: state.id, incarnation: incarnation), !task.isCancelled else { throw CancellationError() }
            try Task.checkCancellation()
            if let result {
                try ThreadWorkspacePreparation.validate(result: result, plan: plan)
                return try await enqueue(.effectResult(.prepareWorktree(threadID: threadID, plan: plan), .worktreePrepared(result)))
            }
        }
        guard ownsWorktree(threadID: threadID, attemptID: state.id, incarnation: incarnation) else { throw CancellationError() }
        let request = GitWorktreeRequest(sourcePath: state.request.sourcePath, destinationRoot: worktreesRoot.path, selection: state.request.selection)
        let receipt = try await enqueue(.beginWorktreePreparation(threadID: threadID, request: request, expectedSourcePath: thread.workspacePath, previousAttemptID: state.id, incarnation: incarnation))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }; return receipt
    }
    private func enqueue(_ command: EngineCommand, id: UUID = UUID()) async throws -> WorkspaceCommandReceipt {
        guard loaded, !closing, fatalError == nil else { throw CoincideError(fatalError ?? "The workspace is closing.") }
        return try await withCheckedThrowingContinuation { continuation in
            pendingCommands += 1
            incoming.yield(.init(id: id, command: command, continuation: continuation))
        }
    }
    private func process(_ envelope: Envelope) async {
        defer {
            pendingCommands -= 1
            if pendingCommands == 0 { let waiters = drainWaiters; drainWaiters = []; for waiter in waiters { waiter.resume() } }
        }
        if let fatalError { envelope.continuation.resume(throwing: CoincideError(fatalError)); return }
        do {
            let payload = try encoder.encode(envelope.command)
            if let receipt = try await database.receipt(envelope.id, matching: payload) {
                envelope.continuation.resume(returning: receipt); return
            }
            for attempt in 0..<4 {
                let base = try await database.revision()
                if let fatalError { throw CoincideError(fatalError) }
                let decision: WorkspaceDecision
                do {
                    if case .beginWorktreePreparation(let threadID, let request, _, _, let incarnation) = envelope.command,
                       (threadIncarnations[threadID] != incarnation || request.destinationRoot != worktreesRoot.path) {
                        throw WorkspaceCommandError("This conversation changed. Choose the worktree again in its current workspace.")
                    }
                    if case .worktreeRecovered(let threadID, let attemptID, let incarnation, _) = envelope.command,
                       !ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation) {
                        decision = WorkspaceDecision(snapshot: base.snapshot)
                    } else if case .repositoryIdentityResolved(let projectID, let path, let incarnation, let requestID, _) = envelope.command,
                       !ownsIdentityRefresh(projectID: projectID, path: path, incarnation: incarnation, requestID: requestID) {
                        decision = WorkspaceDecision(snapshot: base.snapshot)
                    } else { decision = try WorkspaceDecision.make(envelope.command, id: envelope.id, snapshot: base.snapshot, now: Date()) }
                }
                catch let error as WorkspaceCommandError {
                    do {
                        let receipt = try await database.rejectCommand(envelope.id, matching: payload, reason: error.message, expectedSequence: base.sequence)
                        envelope.continuation.resume(returning: receipt); return
                    } catch WorkspaceCommitError.revisionChanged where attempt < 3 { continue }
                }
                do {
                    completedDuringCommit = []
                    removalCommitProjects = Set(base.snapshot.projects.map(\.id)).subtracting(decision.snapshot.projects.map(\.id))
                    removalCommitThreads = Set(base.snapshot.threads.map(\.id)).subtracting(decision.snapshot.threads.map(\.id))
                    var committed = false
                    defer { finishCommitFence(removed: committed) }
                    let outcome = try await database.commitWithRemovedEffects(decision.snapshot, event: "workspace.command", commandID: envelope.id,
                        expectedSequence: base.sequence, effects: decision.effects, deduplicationPayload: payload)
                    let receipt = outcome.receipt
                    revision = .init(snapshot: decision.snapshot, sequence: receipt.sequence)
                    if let attemptID = decision.cancelCloneAttempt {
                        for (effectID, request) in effectRequests {
                            if case .projectClone(_, let plan) = request, plan.id == attemptID { effects[effectID]?.cancel() }
                        }
                    }
                    if let attemptID = decision.cancelWorktreeAttempt {
                        for (effectID, request) in effectRequests where request.worktreeAttemptID == attemptID { effects[effectID]?.cancel() }
                    }
                    beginDecisionCleanup(decision, previous: base.snapshot, removedEffects: outcome.removedEffects)
                    committed = true
                    publish()
                    envelope.continuation.resume(returning: receipt)
                    scheduleEffects()
                    scheduleIdentityRefreshes(previous: base.snapshot)
                    return
                } catch WorkspaceCommitError.revisionChanged where attempt < 3 { continue }
            }
            throw WorkspaceCommitError.revisionChanged
        } catch let error as WorkspaceCommitError { envelope.continuation.resume(throwing: error) }
        catch {
            envelope.continuation.resume(throwing: error)
            await infrastructureFailed(error.localizedDescription)
        }
    }
    public func drainCommands() async {
        if pendingCommands == 0 { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }
    /// The durable removal receipt returns before process I/O. Callers await this separately so
    /// serialized UI command tails and the engine inbox remain available to unrelated projects.
    public func awaitProjectRemovalCleanup(projectID: UUID) async {
        while true {
            let tasks = cleanupTasks.values.filter { $0.projectIDs.contains(projectID) }.map(\.task)
            guard !tasks.isEmpty else { return }
            for task in tasks { await task.value }
        }
    }
    /// A provider operation can resume while SQLite has committed a removal but before this actor
    /// receives its acknowledgement. Suspend new owner work until publication/detachment completes.
    /// Rollback resumes the unchanged owner; successful removal invalidates even a reused owner ID.
    private func waitForRemovalCommit(threadID: UUID? = nil, projectID: UUID? = nil) async -> Bool {
        guard threadID.map({ removalCommitThreads.contains($0) }) == true || projectID.map({ removalCommitProjects.contains($0) }) == true else { return false }
        return await withCheckedContinuation { removalCommitWaiters.append($0) }
    }
    private func finishCommitFence(removed: Bool) {
        completedDuringCommit = nil; removalCommitProjects = []; removalCommitThreads = []
        let waiters = removalCommitWaiters; removalCommitWaiters = []
        for waiter in waiters { waiter.resume(returning: removed) }
    }
    private func beginDecisionCleanup(_ decision: WorkspaceDecision, previous: WorkspaceSnapshot, removedEffects: [WorkspaceEffect]) {
        let removedProjects = Set(previous.projects.map(\.id)).subtracting(decision.snapshot.projects.map(\.id))
        let removedThreads = Set(previous.threads.map(\.id)).subtracting(decision.snapshot.threads.map(\.id))
        let threads = decision.closeRuntimes.union(removedThreads)
        var projectIDs = removedProjects
        var sessions: [any ProviderSession] = []
        var jobs: [Task<Void, Never>] = []
        let old = Dictionary(uniqueKeysWithValues: previous.projects.map { ($0.id, $0) })
        for project in decision.snapshot.projects where old[project.id] == nil || old[project.id]?.path != project.path {
            projectIncarnations[project.id] = UUID()
        }
        for id in removedProjects { projectIncarnations.removeValue(forKey: id) }
        let previousThreads = Dictionary(uniqueKeysWithValues: previous.threads.map { ($0.id, $0) })
        for thread in decision.snapshot.threads where previousThreads[thread.id] == nil || previousThreads[thread.id]?.workspacePath != thread.workspacePath {
            threadIncarnations[thread.id] = UUID()
        }
        for id in removedThreads { threadIncarnations.removeValue(forKey: id) }
        for (id, inspection) in worktreeInspections where removedThreads.contains(inspection.threadID) || removedProjects.contains(inspection.projectID) {
            worktreeInspections.removeValue(forKey: id); inspection.task.cancel(); projectIDs.insert(inspection.projectID)
            jobs.append(Task { _ = try? await inspection.task.value })
        }
        for (id, refresh) in identityRefreshes where removedProjects.contains(id) || !decision.snapshot.projects.contains(where: { $0.id == id && $0.path == refresh.path && ($0.clone == nil || $0.clone?.isReady == true) }) {
            identityRefreshes.removeValue(forKey: id); refresh.task.cancel(); projectIDs.insert(id)
            jobs.append(Task { _ = try? await refresh.task.value })
        }
        for id in threads {
            if let runtime = runtimes.removeValue(forKey: id) {
                runtime.reader?.cancel(); sessions.append(runtime.session); projectIDs.insert(runtime.projectID)
            }
        }
        for (id, metadata) in metadataSessions where metadata.threadID.map({ threads.contains($0) }) == true || metadata.projectID.map({ removedProjects.contains($0) }) == true {
            metadataSessions.removeValue(forKey: id)
            if let projectID = metadata.projectID { projectIDs.insert(projectID) }
            if metadata.closeTask == nil { sessions.append(metadata.session) }
        }
        for effect in removedEffects where effect.status == .running && effect.leaseOwner == workerID {
            // Shutdown/failure can finish an executor while the commit awaits SQLite. Its ID
            // must not become a waiter after its one completion notification already happened.
            if completedDuringCommit?.contains(effect.id) == true { continue }
            // Record exact IDs before yielding, covering a claim that is still returning from SQLite.
            retiringEffects.insert(effect.id); effects[effect.id]?.cancel()
            jobs.append(Task { await self.awaitRetiringEffect(effect.id) })
        }
        _ = startCleanup(projectIDs: projectIDs, sessions: sessions, jobs: jobs)
    }
    @discardableResult private func startCleanup(projectIDs: Set<UUID>, sessions: [any ProviderSession], jobs: [Task<Void, Never>] = []) -> Task<Void, Never>? {
        guard !sessions.isEmpty || !jobs.isEmpty else { return nil }
        let id = UUID()
        let task: Task<Void, Never> = Task.detached { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for session in sessions { group.addTask { await session.close() } }
                for job in jobs { group.addTask { await job.value } }
                await group.waitForAll()
            }
            await self?.cleanupFinished(id)
        }
        cleanupTasks[id] = .init(projectIDs: projectIDs, task: task)
        return task
    }
    private func cleanupFinished(_ id: UUID) { cleanupTasks.removeValue(forKey: id) }
    private func awaitRetiringEffect(_ id: UUID) async {
        guard retiringEffects.contains(id) else { return }
        await withCheckedContinuation { retiringEffectWaiters[id, default: []].append($0) }
    }
    private func retiredEffectFinished(_ id: UUID) {
        retiringEffects.remove(id)
        let waiters = retiringEffectWaiters.removeValue(forKey: id) ?? []
        for waiter in waiters { waiter.resume() }
    }
    /// Metadata reads are owned by one project incarnation. Cancelling waits for the resolver's
    /// owned process to exit; failures never stop provider execution or discard a known identity.
    public func refreshRepositoryIdentity(projectID: UUID) async throws -> RepositoryIdentity? {
        _ = try await load()
        if await waitForRemovalCommit(projectID: projectID) { throw CancellationError() }
        try Task.checkCancellation()
        guard let project = revision.snapshot.projects.first(where: { $0.id == projectID }), let incarnation = projectIncarnations[projectID] else { throw CancellationError() }
        let task = try startIdentityRefresh(projectID: projectID)
        return try await withTaskCancellationHandler {
            do {
                let value = try await task.value
                let owned = await identityCallerIsCurrent(projectID: projectID, path: project.path, incarnation: incarnation)
                try Task.checkCancellation()
                guard owned, !task.isCancelled else { throw CancellationError() }
                return value
            } catch {
                let owned = await identityCallerIsCurrent(projectID: projectID, path: project.path, incarnation: incarnation)
                try Task.checkCancellation()
                guard owned, !task.isCancelled else { throw CancellationError() }
                throw error
            }
        } onCancel: { task.cancel() }
    }
    private func identityCallerIsCurrent(projectID: UUID, path: String, incarnation: UUID) async -> Bool {
        if await waitForRemovalCommit(projectID: projectID) { return false }
        return !closing && !stoppingEffects && fatalError == nil && projectIncarnations[projectID] == incarnation &&
            revision.snapshot.projects.contains { $0.id == projectID && $0.path == path && ($0.clone == nil || $0.clone?.isReady == true) }
    }
    private func startIdentityRefresh(projectID: UUID) throws -> Task<RepositoryIdentity?, any Error> {
        guard !closing, !stoppingEffects, fatalError == nil,
              let project = revision.snapshot.projects.first(where: { $0.id == projectID && ($0.clone == nil || $0.clone?.isReady == true) }),
              let incarnation = projectIncarnations[projectID] else { throw CancellationError() }
        if let current = identityRefreshes[projectID], current.incarnation == incarnation, current.path == project.path { return current.task }
        let id = UUID(), path = project.path, resolver = identityResolver, gate = identityGate
        // Four independent FIFO lanes cap local Git discovery without sharing mutation locks.
        let lane = String(projectID.uuid.0 & 3)
        let task: Task<RepositoryIdentity?, any Error> = Task { [weak self] in
            do {
                let identity = try await gate.perform(key: lane) { try await resolver(URL(fileURLWithPath: path)) }
                try Task.checkCancellation()
                guard let self else { throw CancellationError() }
                let value = try await self.applyIdentityRefresh(projectID: projectID, path: path, incarnation: incarnation, requestID: id, identity: identity)
                await self.identityRefreshFinished(projectID: projectID, requestID: id)
                try Task.checkCancellation(); return value
            } catch {
                let owned = await self?.identityRefreshFailed(projectID: projectID, path: path, incarnation: incarnation, requestID: id) ?? false
                try Task.checkCancellation()
                guard owned else { throw CancellationError() }
                throw error
            }
        }
        identityRefreshes[projectID] = .init(id: id, incarnation: incarnation, path: path, task: task)
        return task
    }
    private func ownsIdentityRefresh(projectID: UUID, path: String, incarnation: UUID, requestID: UUID) -> Bool {
        guard !closing, !stoppingEffects, fatalError == nil, projectIncarnations[projectID] == incarnation,
              let current = identityRefreshes[projectID], !current.task.isCancelled, current.id == requestID, current.incarnation == incarnation, current.path == path,
              revision.snapshot.projects.contains(where: { $0.id == projectID && $0.path == path && ($0.clone == nil || $0.clone?.isReady == true) }) else { return false }
        return true
    }
    private func applyIdentityRefresh(projectID: UUID, path: String, incarnation: UUID, requestID: UUID, identity: RepositoryIdentity?) async throws -> RepositoryIdentity? {
        if await waitForRemovalCommit(projectID: projectID) { throw CancellationError() }
        guard ownsIdentityRefresh(projectID: projectID, path: path, incarnation: incarnation, requestID: requestID),
              let project = revision.snapshot.projects.first(where: { $0.id == projectID }) else { throw CancellationError() }
        try Task.checkCancellation()
        try WorkspaceJournal.validateRepositoryIdentity(identity, project: project)
        if project.repositoryIdentity != identity {
            _ = try await enqueue(.repositoryIdentityResolved(projectID: projectID, path: path, incarnation: incarnation, requestID: requestID, identity: identity))
        }
        if await waitForRemovalCommit(projectID: projectID) { throw CancellationError() }
        guard ownsIdentityRefresh(projectID: projectID, path: path, incarnation: incarnation, requestID: requestID) else { throw CancellationError() }
        try Task.checkCancellation(); return identity
    }
    private func identityRefreshFinished(projectID: UUID, requestID: UUID) {
        if identityRefreshes[projectID]?.id == requestID { identityRefreshes.removeValue(forKey: projectID) }
    }
    private func identityRefreshFailed(projectID: UUID, path: String, incarnation: UUID, requestID: UUID) async -> Bool {
        let removed = await waitForRemovalCommit(projectID: projectID)
        let owned = !removed && ownsIdentityRefresh(projectID: projectID, path: path, incarnation: incarnation, requestID: requestID)
        identityRefreshFinished(projectID: projectID, requestID: requestID)
        return owned
    }
    private func scheduleIdentityRefreshes(previous: WorkspaceSnapshot?) {
        guard loaded, !closing, !stoppingEffects, fatalError == nil else { return }
        let old = Dictionary(uniqueKeysWithValues: (previous?.projects ?? []).map { ($0.id, $0) })
        for project in revision.snapshot.projects where project.clone == nil || project.clone?.isReady == true {
            let prior = old[project.id]
            if prior == nil || prior?.path != project.path || (prior?.clone != nil && prior?.clone?.isReady != true) {
                _ = try? startIdentityRefresh(projectID: project.id)
            }
        }
    }
    private func scheduleEffects() {
        effectWakeGeneration += 1
        guard !pumping, !closing, !stoppingEffects, fatalError == nil else { return }
        pumping = true
        Task { await self.pumpEffects() }
    }
    private func pumpEffects() async {
        let generation = effectWakeGeneration
        defer {
            pumping = false
            if generation != effectWakeGeneration { scheduleEffects() }
        }
        do {
            while !closing, !stoppingEffects, fatalError == nil, effects.count < 64 {
                let startingCount = effectRequests.values.filter { if case .providerStart = $0 { true } else { false } }.count
                guard let effect = try await database.claimNextEffect(workerID: workerID, includeProviderStarts: startingCount < 8) else { break }
                effectRequests[effect.id] = effect.request
                effects[effect.id] = Task { await self.execute(effect) }
                if retiringEffects.contains(effect.id) { effects[effect.id]?.cancel() }
            }
        } catch { await infrastructureFailed(error.localizedDescription) }
    }
    private func execute(_ effect: WorkspaceEffect) async {
        defer {
            effects.removeValue(forKey: effect.id); effectRequests.removeValue(forKey: effect.id)
            completedDuringCommit?.insert(effect.id)
            retiredEffectFinished(effect.id)
            if case .projectClone(_, let plan) = effect.request { cloneProgressTimes.removeValue(forKey: plan.id) }
            scheduleEffects()
        }
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self else { return }
                await self.renew(effect.id)
            }
        }
        let result: EffectResult
        do {
            let performed = try await perform(effect.request)
            result = retiringEffects.contains(effect.id) ? .cancelled : performed
        }
        catch is CancellationError { result = .cancelled }
        catch {
            let message = effect.request.projectID == nil && effect.request.worktreeAttemptID == nil ? error.localizedDescription : String(GitService.redactURLs(error.localizedDescription).prefix(4_000))
            result = .failed(message)
        }
        heartbeat.cancel()
        if !closing, fatalError == nil {
            do {
                let owned: Bool
                switch result {
                case .succeeded, .stopped, .worktreeResolved, .worktreePrepared: owned = try await database.settleEffect(effect.id, workerID: workerID)
                case .failed(let message): owned = try await database.settleEffect(effect.id, workerID: workerID, error: message)
                case .cancelled: owned = try await database.cancelEffect(effect.id, workerID: workerID, reason: "The targeted run or request is no longer active.")
                }
                guard owned else { await infrastructureFailed("Provider execution lost its workspace lease."); return }
                _ = try await enqueue(.effectResult(effect.request, result))
            } catch { if !closing { await infrastructureFailed(error.localizedDescription) } }
        }
    }
    private func renew(_ id: UUID) async {
        guard effects[id] != nil, !closing, fatalError == nil else { return }
        do {
            guard try await database.renewEffectLease(id, workerID: workerID) else {
                await infrastructureFailed("Provider execution lost its workspace lease."); return
            }
        } catch { await infrastructureFailed(error.localizedDescription) }
    }
    private func perform(_ request: WorkspaceEffectRequest) async throws -> EffectResult {
        try Task.checkCancellation()
        guard !stoppingEffects, fatalError == nil else { throw CancellationError() }
        if await waitForRemovalCommit(threadID: request.threadID, projectID: request.projectID) { return .cancelled }
        try Task.checkCancellation()
        if request.worktreeAttemptID != nil { return try await performWorktree(request) }
        if case .projectClone(let projectID, let plan) = request {
            guard let clone = revision.snapshot.projects.first(where: { $0.id == projectID })?.clone,
                  clone.id == plan.id, clone.isRunning, !clone.cancelRequested else { return .cancelled }
            _ = try await enqueue(.cloneStarted(projectID: projectID, attemptID: plan.id))
            if await waitForRemovalCommit(projectID: projectID) { return .cancelled }
            guard let latest = revision.snapshot.projects.first(where: { $0.id == projectID })?.clone,
                  latest.id == plan.id, latest.isRunning, !latest.cancelRequested else { return .cancelled }
            try Task.checkCancellation()
            let session = try cloneFactory(plan)
            do {
                try await session.run { [weak self] progress in await self?.receiveCloneProgress(projectID: projectID, attemptID: plan.id, progress: progress) }
                return .succeeded
            } catch {
                // Git may have completed promotion while cancellation was arriving. Inspect
                // local ownership evidence on an uncancelled task before choosing its outcome.
                if (try? await Task.detached { try await session.isCompleted() }.value) == true { return .succeeded }
                throw error
            }
        }
        guard let thread = revision.snapshot.threads.first(where: { $0.id == request.threadID }), revision.snapshot.workspaceReady(for: thread) else { return .cancelled }
        switch request {
        case .resolveWorktree, .prepareWorktree, .projectClone: return .cancelled // Preparation/project actions are handled before thread lookup.
        case .providerStart(_, let runID, let configuration, let prompt, let references):
            guard thread.activeRun?.id == runID, thread.activeRun?.stopRequested == false else { return .cancelled }
            let input = try await attachments.prepare(text: prompt, attachments: references ?? [])
            guard !closing, !stoppingEffects,
                  revision.snapshot.workspaceReady(for: thread),
                  revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.id == runID,
                  revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.stopRequested == false else { return .cancelled }
            var configured = thread
            configured.provider = configuration.provider; configured.workspacePath = configuration.workspacePath
            configured.providerThreadID = configuration.nativeThreadID; configured.model = configuration.model; configured.permission = configuration.permission
            configured.acpAgent = configuration.acpAgent; configured.agentModeID = configuration.agentModeID
            configured.agentConfigValues = configuration.agentConfigValues
            configured.agentConfiguration = configuration.agentConfiguration
            let runtime = try await runtime(for: configured, runID: runID)
            if await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { return .cancelled }
            guard !closing, !stoppingEffects, revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.id == runID,
                  revision.snapshot.workspaceReady(for: thread),
                  revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.stopRequested == false,
                  runtimes[thread.id]?.id == runtime.id else { return .cancelled }
            try Task.checkCancellation()
            try await runtime.session.send(input: input, thread: configured)
            return .succeeded
        case .providerInterrupt(_, let runID):
            guard thread.activeRun?.id == runID else { return .cancelled }
            if thread.activeRun?.nativeTurnID != nil, let runtime = runtimes[thread.id] {
                do { try await runtime.session.interrupt(); return .succeeded } catch { /* Fall back to closing the owned process. */ }
            }
            // Closing the owned runtime also stops startup before a native turn ID exists.
            await closeRuntime(thread.id)
            return .stopped
        case .providerRespond(_, let runID, let request, let response):
            guard thread.activeRun?.id == runID, thread.activeRun?.stopRequested == false,
                  thread.runtimeRequests.contains(where: { $0.id == request.id && $0.responding }),
                  let runtime = runtimes[thread.id], runtime.id == thread.runtimeID else { return .cancelled }
            switch response {
            case .option(let id): try await runtime.session.choose(request, optionID: id)
            case .decision(let allow): try await runtime.session.respond(request, allow: allow)
            case .answers(let answers): try await runtime.session.answer(request, answers: answers)
            }
            return .succeeded
        case .providerSessionRespond(_, let runtimeID, let request, let response):
            guard thread.runtimeID == runtimeID, thread.runtimeRequests.contains(where: { $0.id == request.id && $0.responding && $0.sessionScoped == true }),
                  let runtime = runtimes[thread.id], runtime.id == runtimeID else { return .cancelled }
            switch response {
            case .option(let id): try await runtime.session.choose(request, optionID: id)
            case .decision(let allow): try await runtime.session.respond(request, allow: allow)
            case .answers(let answers): try await runtime.session.answer(request, answers: answers)
            }
            return .succeeded
        }
    }
    private func ownsWorktree(threadID: UUID, attemptID: UUID, incarnation: UUID) -> Bool {
        guard !closing, !stoppingEffects, fatalError == nil, threadIncarnations[threadID] == incarnation,
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              let state = thread.workspacePreparation, state.id == attemptID,
              thread.workspacePath == state.destinationPath, state.request.destinationRoot == worktreesRoot.path else { return false }
        return true
    }
    private func performWorktree(_ effect: WorkspaceEffectRequest) async throws -> EffectResult {
        guard let threadID = effect.threadID, let attemptID = effect.worktreeAttemptID,
              let incarnation = threadIncarnations[threadID],
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID }),
              let state = thread.workspacePreparation, state.id == attemptID, state.isRunning, !state.cancelRequested,
              ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation) else { return .cancelled }
        let session = try worktreeFactory(state.request)
        switch effect {
        case .resolveWorktree(_, let request):
            guard request == state.request, state.plan == nil else { return .cancelled }
            _ = try await enqueue(.worktreeStarted(threadID: threadID, attemptID: attemptID))
            if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { return .cancelled }
            guard ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation),
                  revision.snapshot.threads.first(where: { $0.id == threadID })?.workspacePreparation?.cancelRequested == false else { return .cancelled }
            try Task.checkCancellation()
            do {
                let plan = try await session.prepare()
                if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { return .cancelled }
                guard ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation) else { return .cancelled }
                try Task.checkCancellation(); try ThreadWorkspacePreparation.validate(plan: plan, request: request)
                return .worktreeResolved(plan)
            } catch {
                if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { throw CancellationError() }
                guard ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation) else { throw CancellationError() }
                throw error
            }
        case .prepareWorktree(_, let plan):
            guard state.plan == plan, state.phase == .preparing else { return .cancelled }
            do {
                let result = try await session.run(plan)
                if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { return .cancelled }
                guard ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation) else { return .cancelled }
                try ThreadWorkspacePreparation.validate(result: result, plan: plan)
                return .worktreePrepared(result)
            } catch {
                // A late cancellation can race Git's completed registration. Only local exact
                // ownership evidence may promote that attempt; its queue remains paused.
                let completed = try? await Task.detached { try await session.inspectCompletion(plan) }.value
                if await waitForRemovalCommit(threadID: threadID, projectID: thread.projectID) { throw CancellationError() }
                guard ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation) else { throw CancellationError() }
                if let result = completed {
                    try ThreadWorkspacePreparation.validate(result: result, plan: plan); return .worktreePrepared(result)
                }
                throw error
            }
        default: return .cancelled
        }
    }
    /// Publish interrupted state immediately. Local completion probes are owned background
    /// reads, so a slow repository cannot delay loading or commands in other workspaces.
    private func scheduleWorktreeReconciliation() {
        let gate = worktreeInspectionGate
        for thread in revision.snapshot.threads {
            guard let state = thread.workspacePreparation, !state.isReady, let plan = state.plan,
                  state.request.destinationRoot == worktreesRoot.path, let incarnation = threadIncarnations[thread.id],
                  let session = try? worktreeFactory(state.request) else { continue }
            let token = UUID(), threadID = thread.id, projectID = thread.projectID, attemptID = state.id
            let lane = String(threadID.uuid.0 & 3)
            let task: Task<GitWorktreeResult?, any Error> = Task { [weak self] in
                do {
                    let result = try await gate.perform(key: lane) { try await session.inspectCompletion(plan) }
                    try Task.checkCancellation()
                    if let result { try await self?.applyRecoveredWorktree(threadID: threadID, projectID: projectID, attemptID: attemptID, incarnation: incarnation, result: result, plan: plan) }
                    await self?.worktreeInspectionFinished(token)
                    return result
                } catch {
                    await self?.worktreeInspectionFinished(token); throw error
                }
            }
            worktreeInspections[token] = .init(threadID: threadID, projectID: projectID, task: task)
        }
    }
    private func applyRecoveredWorktree(threadID: UUID, projectID: UUID, attemptID: UUID, incarnation: UUID, result: GitWorktreeResult, plan: GitWorktreePlan) async throws {
        if await waitForRemovalCommit(threadID: threadID, projectID: projectID) { throw CancellationError() }
        try Task.checkCancellation()
        guard ownsWorktree(threadID: threadID, attemptID: attemptID, incarnation: incarnation) else { throw CancellationError() }
        try ThreadWorkspacePreparation.validate(result: result, plan: plan)
        _ = try await enqueue(.worktreeRecovered(threadID: threadID, attemptID: attemptID, incarnation: incarnation, result: result))
    }
    private func worktreeInspectionFinished(_ token: UUID) { worktreeInspections.removeValue(forKey: token) }
    private func receiveCloneProgress(projectID: UUID, attemptID: UUID, progress: GitCloneProgress) async {
        guard !closing, !stoppingEffects, fatalError == nil,
              revision.snapshot.projects.first(where: { $0.id == projectID })?.clone?.id == attemptID,
              effectRequests.values.contains(where: { if case .projectClone(let id, let plan) = $0 { id == projectID && plan.id == attemptID } else { false } }) else { return }
        let now = ContinuousClock.now
        if let last = cloneProgressTimes[attemptID] {
            if last.1 == progress { return }
            if last.1.stage == progress.stage, last.1.stalled == progress.stalled, progress.percent != 100, now - last.0 < .milliseconds(100) { return }
        }
        cloneProgressTimes[attemptID] = (now, progress)
        _ = try? await enqueue(.cloneProgress(projectID: projectID, attemptID: attemptID, progress: progress))
    }
    private func reconcileCompletedClones(in snapshot: WorkspaceSnapshot) async -> WorkspaceSnapshot {
        var recovered = snapshot
        for i in recovered.projects.indices {
            guard var clone = recovered.projects[i].clone, !clone.isReady else { continue }
            guard (try? await cloneFactory(clone.plan).isCompleted()) == true else { continue }
            clone.phase = .completed; clone.cancelRequested = false; clone.error = nil
            clone.progress = .init(stage: .checkout, percent: 100, detail: nil, stalled: false)
            clone.updatedAt = Date(); clone.endedAt = clone.updatedAt; recovered.projects[i].clone = clone
        }
        return recovered
    }
    private func runtime(for thread: CodingThread, runID: UUID) async throws -> Runtime {
        if await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
        try Task.checkCancellation()
        guard ownsRun(threadID: thread.id, projectID: thread.projectID, runID: runID) else { throw CancellationError() }
        if let existing = runtimes[thread.id], existing.provider == thread.provider, existing.path == thread.workspacePath, existing.acpAgent == thread.acpAgent { return existing }
        await closeRuntime(thread.id)
        if await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
        try Task.checkCancellation()
        // Closing the previous process is an await: removal may have committed during that I/O.
        guard ownsRun(threadID: thread.id, projectID: thread.projectID, runID: runID) else { throw CancellationError() }
        let id = UUID(), session = try factory(thread)
        var runtime = Runtime(id: id, projectID: thread.projectID, session: session, provider: thread.provider, path: thread.workspacePath, acpAgent: thread.acpAgent)
        runtimes[thread.id] = runtime
        _ = try await enqueue(.runtimeOpened(threadID: thread.id, runID: runID, runtimeID: id))
        guard ownsRun(threadID: thread.id, projectID: thread.projectID, runID: runID), runtimes[thread.id]?.id == id else {
            await closeRuntime(thread.id, matching: id); throw CancellationError()
        }
        let stream = session.events
        runtime.reader = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                do { _ = try await self.enqueue(.provider(threadID: thread.id, runtimeID: id, event: event)) }
                catch { return }
            }
        }
        if runtimes[thread.id]?.id == id { runtimes[thread.id] = runtime }
        else { runtime.reader?.cancel(); throw CancellationError() }
        return runtime
    }
    private func ownsRun(threadID: UUID, projectID: UUID, runID: UUID) -> Bool {
        guard !closing, !stoppingEffects, fatalError == nil,
              let thread = revision.snapshot.threads.first(where: { $0.id == threadID && $0.projectID == projectID }),
              thread.activeRun?.id == runID, thread.activeRun?.stopRequested == false,
              revision.snapshot.workspaceReady(for: thread) else { return false }
        return true
    }
    private func closeRuntime(_ threadID: UUID, matching expectedID: UUID? = nil) async {
        guard let runtime = runtimes[threadID], expectedID == nil || expectedID == runtime.id else { return }
        runtimes.removeValue(forKey: threadID); runtime.reader?.cancel()
        if let task = startCleanup(projectIDs: [runtime.projectID], sessions: [runtime.session]) { await task.value }
    }
    private func infrastructureFailed(_ message: String) async {
        guard fatalError == nil else { return }
        fatalError = "Workspace execution stopped: \(message)"; publish()
        for task in effects.values { task.cancel() }
        cancelIdentityRefreshes()
        let inspections = worktreeInspections; worktreeInspections = [:]
        for inspection in inspections.values {
            inspection.task.cancel()
            _ = startCleanup(projectIDs: [inspection.projectID], sessions: [], jobs: [Task { _ = try? await inspection.task.value }])
        }
        for id in Array(runtimes.keys) { await closeRuntime(id) }
    }
    private func cancelIdentityRefreshes() {
        let refreshes = identityRefreshes; identityRefreshes = [:]
        for (id, refresh) in refreshes {
            refresh.task.cancel()
            _ = startCleanup(projectIDs: [id], sessions: [], jobs: [Task { _ = try? await refresh.task.value }])
        }
    }
    public func models(provider: ProviderKind) async throws -> [ProviderModel] {
        var thread = CodingThread(project: WorkspaceProject(path: FileManager.default.homeDirectoryForCurrentUser.path)); thread.provider = provider
        return try await queryModels(thread: thread, owned: false)
    }
    public func models(thread: CodingThread) async throws -> [ProviderModel] {
        _ = try await load()
        guard !closing, !stoppingEffects,
              let current = revision.snapshot.threads.first(where: { $0.id == thread.id && $0.projectID == thread.projectID }),
              revision.snapshot.projects.contains(where: { $0.id == thread.projectID }),
              current.provider == thread.provider, current.workspacePath == thread.workspacePath, current.acpAgent == thread.acpAgent else { throw CancellationError() }
        if !revision.snapshot.workspaceReady(for: current) {
            throw CoincideError("Wait for the workspace to finish preparing before refreshing this agent's models.")
        }
        return try await queryModels(thread: current, owned: true)
    }
    private func queryModels(thread: CodingThread, owned: Bool) async throws -> [ProviderModel] {
        if owned {
            if await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
            guard let current = revision.snapshot.threads.first(where: { $0.id == thread.id && $0.projectID == thread.projectID }),
                  current.provider == thread.provider, current.workspacePath == thread.workspacePath, current.acpAgent == thread.acpAgent,
                  revision.snapshot.workspaceReady(for: current) else { throw CancellationError() }
        }
        guard !closing, !stoppingEffects else { throw CancellationError() }
        let id = UUID(), session = try factory(thread)
        metadataSessions[id] = .init(session: session, threadID: owned ? thread.id : nil,
                                     projectID: owned ? thread.projectID : nil, configuration: owned ? .init(thread: thread) : nil)
        do {
            let result = try await session.models()
            if owned, await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
            guard let metadata = metadataSessions[id], metadataOwnerIsCurrent(metadata) else { throw CancellationError() }
            if let task = beginMetadataClose(id) { await task.value }
            if owned, await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
            guard let metadata = metadataSessions[id], metadataOwnerIsCurrent(metadata) else { throw CancellationError() }
            metadataSessions.removeValue(forKey: id); return result
        } catch {
            if owned, await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
            let ownerIsCurrent = metadataSessions[id].map(metadataOwnerIsCurrent) == true
            if let task = beginMetadataClose(id) { await task.value }
            if owned, await waitForRemovalCommit(threadID: thread.id, projectID: thread.projectID) { throw CancellationError() }
            let stillOwned = metadataSessions[id].map(metadataOwnerIsCurrent) == true
            metadataSessions.removeValue(forKey: id)
            if !ownerIsCurrent || !stillOwned || closing || stoppingEffects { throw CancellationError() }
            throw error
        }
    }
    private func metadataOwnerIsCurrent(_ metadata: MetadataRuntime) -> Bool {
        guard !closing, !stoppingEffects else { return false }
        guard let threadID = metadata.threadID else { return true } // Neutral provider discovery.
        guard let thread = revision.snapshot.threads.first(where: { $0.id == threadID && $0.projectID == metadata.projectID }),
              revision.snapshot.projects.contains(where: { $0.id == thread.projectID }),
              let configuration = metadata.configuration,
              thread.provider == configuration.provider, thread.workspacePath == configuration.workspacePath, thread.acpAgent == configuration.acpAgent,
              revision.snapshot.workspaceReady(for: thread) else { return false }
        return true
    }
    private func beginMetadataClose(_ id: UUID) -> Task<Void, Never>? {
        guard let metadata = metadataSessions[id] else { return nil }
        if let task = metadata.closeTask { return task }
        let task = startCleanup(projectIDs: Set(metadata.projectID.map { [$0] } ?? []), sessions: [metadata.session])
        metadataSessions[id]?.closeTask = task
        return task
    }
    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        let task = Task { await self.stopRuntime() }; shutdownTask = task
        await task.value
    }
    private func stopRuntime() async {
        if let initialization { _ = try? await initialization.value }
        guard !closing else { return }
        stoppingEffects = true
        if loaded, fatalError == nil { _ = try? await enqueue(.pauseQueues) }
        closing = true
        let inspections = Array(worktreeInspections.values); worktreeInspections = [:]
        for inspection in inspections { inspection.task.cancel() }
        cancelIdentityRefreshes()
        let jobs = Array(effects.values); for job in jobs { job.cancel() }
        for id in Array(runtimes.keys) { await closeRuntime(id) }
        let metadata = Array(metadataSessions.values); metadataSessions = [:]
        for runtime in metadata where runtime.closeTask == nil {
            _ = startCleanup(projectIDs: Set(runtime.projectID.map { [$0] } ?? []), sessions: [runtime.session])
        }
        for job in jobs { await job.value }
        for inspection in inspections { _ = try? await inspection.task.value }
        while !cleanupTasks.isEmpty {
            let tasks = cleanupTasks.values.map(\.task)
            for task in tasks { await task.value }
        }
        await drainCommands()
        if loaded {
            do {
                _ = try await database.cancelEffectsAfterProcessLoss(reason: "The app closed.")
                let base = try await database.revision(); var recovered = base.snapshot; recovered.recoverInterruptedWork()
                recovered = await reconcileCompletedClones(in: recovered)
                let receipt = try await database.commit(recovered, event: "workspace.closed", commandID: UUID(), expectedSequence: base.sequence)
                revision = .init(snapshot: recovered, sequence: receipt.sequence); publish()
            } catch { fatalError = error.localizedDescription; publish() }
        }
        incoming.finish(); commandWorker?.cancel(); commandWorker = nil
        for listener in listeners.values { listener.finish() }; listeners = [:]
        ownership.release()
    }
}
