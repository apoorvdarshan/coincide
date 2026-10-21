import Foundation

public struct WorkspaceUpdate: Sendable {
    public var snapshot: WorkspaceSnapshot
    public var sequence: Int64
    public var error: String?
}

/// Serial command decisions and durable commits are independent of provider I/O.
public actor WorkspaceEngine {
    public typealias ProviderFactory = @Sendable (CodingThread) throws -> any ProviderSession
    private struct Envelope: Sendable {
        var id: UUID
        var command: EngineCommand
        var continuation: CheckedContinuation<WorkspaceCommandReceipt, any Error>
    }
    private struct Runtime {
        var id: UUID
        var session: any ProviderSession
        var provider: ProviderKind
        var path: String
        var acpAgent: ACPAgentConfiguration?
        var reader: Task<Void, Never>?
    }
    private let database: WorkspaceDatabase
    public nonisolated let attachments: AttachmentStore
    private let ownership: WorkspaceRuntimeLock
    private let factory: ProviderFactory
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
    private var metadataSessions: [UUID: any ProviderSession] = [:]
    private let encoder: JSONEncoder = { let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value }()

    public init(url: URL, providerFactory: @escaping ProviderFactory = { try ProviderSessions.make(for: $0) }) throws {
        ownership = try WorkspaceRuntimeLock(url: url.appendingPathExtension("runtime-lock"))
        database = try WorkspaceDatabase(url: url)
        attachments = try AttachmentStore(root: url.deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true))
        factory = providerFactory
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
        let receipt = try await database.commit(recovered, event: "workspace.opened", commandID: UUID(), expectedSequence: revision.sequence)
        revision = .init(snapshot: recovered, sequence: receipt.sequence)
        loaded = true
        let stream = inbox
        commandWorker = Task { [weak self] in
            for await envelope in stream {
                guard let self else { envelope.continuation.resume(throwing: CancellationError()); continue }
                await self.process(envelope)
            }
        }
        publish()
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
                let decision: WorkspaceDecision
                do { decision = try WorkspaceDecision.make(envelope.command, id: envelope.id, snapshot: base.snapshot, now: Date()) }
                catch let error as WorkspaceCommandError {
                    do {
                        let receipt = try await database.rejectCommand(envelope.id, matching: payload, reason: error.message, expectedSequence: base.sequence)
                        envelope.continuation.resume(returning: receipt); return
                    } catch WorkspaceCommitError.revisionChanged where attempt < 3 { continue }
                }
                do {
                    let receipt = try await database.commit(decision.snapshot, event: "workspace.command", commandID: envelope.id,
                        expectedSequence: base.sequence, effects: decision.effects, deduplicationPayload: payload)
                    revision = .init(snapshot: decision.snapshot, sequence: receipt.sequence)
                    if let id = decision.closeRuntime, let runtime = runtimes.removeValue(forKey: id) {
                        runtime.reader?.cancel(); Task { await runtime.session.close() }
                    }
                    publish()
                    envelope.continuation.resume(returning: receipt)
                    scheduleEffects()
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
            }
        } catch { await infrastructureFailed(error.localizedDescription) }
    }
    private func execute(_ effect: WorkspaceEffect) async {
        defer {
            effects.removeValue(forKey: effect.id); effectRequests.removeValue(forKey: effect.id)
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
        do { result = try await perform(effect.request) }
        catch is CancellationError { result = .cancelled }
        catch { result = .failed(error.localizedDescription) }
        heartbeat.cancel()
        if !closing, fatalError == nil {
            do {
                let owned: Bool
                switch result {
                case .succeeded, .stopped: owned = try await database.settleEffect(effect.id, workerID: workerID)
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
        guard let thread = revision.snapshot.threads.first(where: { $0.id == request.threadID }) else { return .cancelled }
        switch request {
        case .providerStart(_, let runID, let configuration, let prompt, let references):
            guard thread.activeRun?.id == runID, thread.activeRun?.stopRequested == false else { return .cancelled }
            let input = try await attachments.prepare(text: prompt, attachments: references ?? [])
            guard !closing, !stoppingEffects,
                  revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.id == runID,
                  revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.stopRequested == false else { return .cancelled }
            var configured = thread
            configured.provider = configuration.provider; configured.workspacePath = configuration.workspacePath
            configured.providerThreadID = configuration.nativeThreadID; configured.model = configuration.model; configured.permission = configuration.permission
            configured.acpAgent = configuration.acpAgent; configured.agentModeID = configuration.agentModeID
            configured.agentConfigValues = configuration.agentConfigValues
            configured.agentConfiguration = configuration.agentConfiguration
            let runtime = try await runtime(for: configured, runID: runID)
            guard !closing, !stoppingEffects, revision.snapshot.threads.first(where: { $0.id == thread.id })?.activeRun?.id == runID,
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
    private func runtime(for thread: CodingThread, runID: UUID) async throws -> Runtime {
        if let existing = runtimes[thread.id], existing.provider == thread.provider, existing.path == thread.workspacePath, existing.acpAgent == thread.acpAgent { return existing }
        await closeRuntime(thread.id)
        let id = UUID(), session = try factory(thread)
        var runtime = Runtime(id: id, session: session, provider: thread.provider, path: thread.workspacePath, acpAgent: thread.acpAgent)
        runtimes[thread.id] = runtime
        _ = try await enqueue(.runtimeOpened(threadID: thread.id, runID: runID, runtimeID: id))
        let stream = session.events
        runtime.reader = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                do { _ = try await self.enqueue(.provider(threadID: thread.id, runtimeID: id, event: event)) }
                catch { return }
            }
        }
        if runtimes[thread.id]?.id == id { runtimes[thread.id] = runtime }
        else { runtime.reader?.cancel(); await session.close() }
        return runtime
    }
    private func closeRuntime(_ threadID: UUID) async {
        guard let runtime = runtimes.removeValue(forKey: threadID) else { return }
        runtime.reader?.cancel(); await runtime.session.close()
    }
    private func infrastructureFailed(_ message: String) async {
        guard fatalError == nil else { return }
        fatalError = "Workspace execution stopped: \(message)"; publish()
        for task in effects.values { task.cancel() }
        for id in Array(runtimes.keys) { await closeRuntime(id) }
    }
    public func models(provider: ProviderKind) async throws -> [ProviderModel] {
        var thread = CodingThread(project: WorkspaceProject(path: FileManager.default.homeDirectoryForCurrentUser.path)); thread.provider = provider
        return try await models(thread: thread)
    }
    public func models(thread: CodingThread) async throws -> [ProviderModel] {
        guard !closing else { throw CancellationError() }
        let id = UUID(), session = try factory(thread); metadataSessions[id] = session
        do {
            let result = try await session.models(); await session.close(); metadataSessions.removeValue(forKey: id); return result
        } catch { await session.close(); metadataSessions.removeValue(forKey: id); throw error }
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
        let jobs = Array(effects.values); for job in jobs { job.cancel() }
        for id in Array(runtimes.keys) { await closeRuntime(id) }
        for session in metadataSessions.values { await session.close() }; metadataSessions = [:]
        for job in jobs { await job.value }
        await drainCommands()
        if loaded {
            do {
                _ = try await database.cancelEffectsAfterProcessLoss(reason: "The app closed.")
                let base = try await database.revision(); var recovered = base.snapshot; recovered.recoverInterruptedWork()
                let receipt = try await database.commit(recovered, event: "workspace.closed", commandID: UUID(), expectedSequence: base.sequence)
                revision = .init(snapshot: recovered, sequence: receipt.sequence); publish()
            } catch { fatalError = error.localizedDescription; publish() }
        }
        incoming.finish(); commandWorker?.cancel(); commandWorker = nil
        for listener in listeners.values { listener.finish() }; listeners = [:]
        ownership.release()
    }
}
