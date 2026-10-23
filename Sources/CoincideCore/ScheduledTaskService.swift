import CryptoKit
import Foundation

public struct ScheduledTaskClock: Sendable {
    public let now: @Sendable () -> Date
    public let sleep: @Sendable (Duration) async throws -> Void
    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void) { self.now = now; self.sleep = sleep }
    public static let system = Self(now: { Date() }, sleep: sleepNormally)
    private static func sleepNormally(_ duration: Duration) async throws { try await Task.sleep(for: duration) }
}

/// Owns only polling/listener work. All definitions, input admission and recovery
/// evidence are committed by the normal Engine, never a sidecar database.
public actor ScheduledTaskService {
    private let engine: WorkspaceEngine
    private let clock: ScheduledTaskClock
    private let secrets: any ScheduledTaskSecretStore
    private var loop: Task<Void, Never>?
    private var jobs: [UUID: Task<WorkspaceCommandReceipt, any Error>] = [:]
    private var credentialJobs: [UUID: Task<ScheduledTaskWebhookRegistration, any Error>] = [:]
    private var listener: ScheduledTaskHTTPServer?
    public private(set) var listenerPort: UInt16?
    private var listenerAttempt: UInt16?
    private var closed = false
    private var sweeping = false
    public init(engine: WorkspaceEngine, clock: ScheduledTaskClock = .system, secrets: any ScheduledTaskSecretStore) {
        self.engine = engine; self.clock = clock; self.secrets = secrets
    }
    public func start() {
        guard !closed, loop == nil else { return }
        // The saved definition owns future execution. A scheduler started by an
        // MCP request must not retain that caller's short-lived TaskLocal scope.
        loop = Task.detached(priority: .utility) { [weak self, clock] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sweep()
                do { try await clock.sleep(.seconds(1)) } catch { return }
            }
        }
    }
    public func sweep() async {
        guard !closed, !sweeping else { return }; sweeping = true; defer { sweeping = false }
        guard let snapshot = try? await engine.load() else { return }
        let now = clock.now(), ledger = snapshot.scheduler ?? .init()
        if let port = ledger.webhookListenerPort, listener == nil, listenerAttempt != port {
            listenerAttempt = port; _ = try? await startWebhookListener(port: port)
        } else if ledger.webhookListenerPort == nil, listener != nil { await stopWebhookListener() }
        for occurrence in ledger.occurrences where occurrence.phase == .accepted {
            guard !closed, !Task.isCancelled else { return }
            let thread = snapshot.threads.first(where: { $0.id == occurrence.threadID })
            guard thread == nil || thread?.runHistory?.first(where: { $0.id == occurrence.id })?.endedAt != nil ||
                  (thread?.activeRun?.id != occurrence.id && thread?.queuedTurns.contains(where: { $0.id == occurrence.id }) != true && thread?.runHistory?.contains(where: { $0.id == occurrence.id }) != true) else { continue }
            _ = try? await engine.dispatch(.scheduledTask(.observe(id: occurrence.id, phase: .accepted)))
        }
        for pending in ledger.webhookPending where pending.fireAt <= now {
            guard !closed, !Task.isCancelled else { return }
            guard let task = ledger.tasks.first(where: { $0.id == pending.taskID && $0.revision == pending.revision }), task.enabled else { continue }
            do { _ = try await fire(task: task, trigger: .webhook, commandID: pending.id, due: pending.fireAt, now: now, prompt: pending.prompt, delivery: pending.delivery) }
            catch {
                _ = try? await engine.dispatch(.scheduledTask(.failure(id: task.id, revision: task.revision, occurrenceID: pending.id,
                    trigger: .webhook, dueAt: pending.fireAt, now: now)), id: TaskOrchestration.derivedID(pending.id, "refused"))
            }
        }
        for task in ledger.tasks where task.enabled {
            guard !closed, !Task.isCancelled else { return }
            guard let due = task.nextRunAt, due <= now else { continue }
            let identity = TaskOrchestration.derivedID(task.revision, "scheduled:\(due.timeIntervalSince1970)")
            if task.schedule.isMissed(due: due, now: now) {
                _ = try? await engine.dispatch(.scheduledTask(.missed(id: task.id, revision: task.revision, dueAt: due, now: now)), id: identity)
            } else {
                do { _ = try await fire(task: task, trigger: .scheduled, commandID: identity, due: due, now: now) }
                catch {
                    guard !closed else { return }
                    let latest = await engine.current().snapshot.scheduler?.tasks.first(where: { $0.id == task.id })
                    guard latest?.revision == task.revision, latest?.nextRunAt == due, latest?.enabled == true else { continue }
                    _ = try? await engine.dispatch(.scheduledTask(.failure(id: task.id, revision: task.revision, occurrenceID: identity,
                        trigger: .scheduled, dueAt: due, now: now)), id: TaskOrchestration.derivedID(identity, "refused"))
                }
            }
        }
    }
    @discardableResult public func runNow(id: UUID, commandID: UUID = UUID(), expectedRevision: UUID? = nil) async throws -> WorkspaceCommandReceipt {
        guard !closed else { throw ScheduledTaskError.unavailable }
        let snapshot = try await engine.load()
        if let occurrence = snapshot.scheduler?.occurrences.first(where: { $0.id == commandID }) {
            guard occurrence.taskID == id, let receipt = try await engine.scheduledTaskReceipt(commandID: commandID, taskID: id) else { throw ScheduledTaskError.staleRevision }
            if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
            return receipt
        }
        guard let task = snapshot.scheduler?.tasks.first(where: { $0.id == id }) else { throw ScheduledTaskError.staleRevision }
        guard expectedRevision == nil || task.revision == expectedRevision else { throw ScheduledTaskError.staleRevision }
        return try await fire(task: task, trigger: .manual, commandID: commandID, due: clock.now(), now: clock.now())
    }
    func fire(task: ScheduledTaskDefinition, trigger: ScheduledTaskOccurrence.Trigger, commandID: UUID, due: Date, now: Date,
              prompt: String? = nil, delivery: ScheduledTaskWebhookDelivery? = nil) async throws -> WorkspaceCommandReceipt {
        guard !closed, jobs[commandID] == nil else { throw ScheduledTaskError.unavailable }
        let engine = engine
        let job = Task { try await engine.fireScheduledTask(taskID: task.id, revision: task.revision, trigger: trigger,
            commandID: commandID, dueAt: due, observedAt: now, prompt: prompt, delivery: delivery) }
        jobs[commandID] = job; defer { jobs.removeValue(forKey: commandID) }
        let receipt = try await job.value // Accepted command admission outlives a closed settings sheet.
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
        return receipt
    }
    public func startWebhookListener(port: UInt16 = 0) async throws -> UInt16 {
        guard !closed, listener == nil else { throw ScheduledTaskError.unavailable }
        let server = ScheduledTaskHTTPServer { [weak self] request in
            guard let self else { return .init(status: 503) }
            return await self.receiveWebhook(request)
        }
        listener = server
        do {
            let bound = try await server.start(port: port)
            guard !closed, listener === server else { await server.shutdown(); throw CancellationError() }
            listenerPort = bound; return bound
        }
        catch {
            if listener === server { listener = nil; listenerPort = nil }
            await server.shutdown(); throw error
        }
    }
    public func currentListenerPort() async -> UInt16? {
        guard !closed, let listener, await listener.isListening else { return nil }; return listenerPort
    }
    public func stopWebhookListener() async {
        let owned = listener; listener = nil; listenerPort = nil; await owned?.shutdown()
    }
    public func configureWebhook(taskID: UUID, configuration: ScheduledTaskWebhookConfiguration, signingSecret: Data? = nil, rotateAuthorization: Bool = false) async throws -> ScheduledTaskWebhookRegistration {
        guard !closed else { throw ScheduledTaskError.invalidWebhook }
        let id = UUID(), secrets = secrets
        let task = Task { try await Self.prepareWebhookCredentials(taskID: taskID, configuration: configuration, signingSecret: signingSecret, rotateAuthorization: rotateAuthorization, secrets: secrets) }
        credentialJobs[id] = task; defer { credentialJobs.removeValue(forKey: id) }
        let value = try await task.value
        guard !closed else { throw CancellationError() }; return value
    }
    private static func prepareWebhookCredentials(taskID: UUID, configuration: ScheduledTaskWebhookConfiguration, signingSecret: Data?, rotateAuthorization: Bool, secrets: any ScheduledTaskSecretStore) async throws -> ScheduledTaskWebhookRegistration {
        var proposed = configuration
        if proposed.bearerDigest.isEmpty || rotateAuthorization {
            proposed.bearerDigest = String(repeating: "0", count: 64); proposed.bearerSecretName = "pending-private-credential"
        }
        if let signingSecret {
            guard !signingSecret.isEmpty, signingSecret.count <= 4096 else { throw ScheduledTaskError.invalidWebhook }
            proposed.signingSecretName = "pending-private-signature"
        }
        try proposed.validate()
        var bearer: Data?, result = configuration
        if configuration.bearerDigest.isEmpty || rotateAuthorization {
            let generated = try ScheduledTaskWebhookSecurity.randomSecret()
            let name = "scheduled-task-" + taskID.uuidString.lowercased() + "-bearer-" + UUID().uuidString.lowercased()
            try await secrets.set(generated, named: name)
            bearer = generated; result.bearerDigest = ScheduledTaskWebhookSecurity.digest(generated); result.bearerSecretName = name
        }
        if let signingSecret {
            guard !signingSecret.isEmpty, signingSecret.count <= 4096 else { throw ScheduledTaskError.invalidWebhook }
            let name = "scheduled-task-" + taskID.uuidString.lowercased() + "-hmac-" + UUID().uuidString.lowercased()
            try await secrets.set(signingSecret, named: name); result.signingSecretName = name
        }
        try result.validate()
        return .init(configuration: result, bearer: bearer)
    }
    func engineSnapshot() async throws -> WorkspaceSnapshot { guard !closed else { throw ScheduledTaskError.unavailable }; return try await engine.load() }
    func webhookSecret(_ name: String) async throws -> Data? { guard !closed else { throw ScheduledTaskError.unavailable }; return try await secrets.get(name) }
    func admitWebhook(task: ScheduledTaskDefinition, occurrenceID: UUID, prompt: String, delivery: ScheduledTaskWebhookDelivery) async throws -> ScheduledTaskHTTPResponse {
        guard !closed else { throw ScheduledTaskError.unavailable }
        let snapshot = try await engine.load(), now = clock.now(), history = snapshot.scheduler?.occurrences ?? []
        guard history.filter({ $0.taskID == task.id && $0.trigger == .webhook && now.timeIntervalSince($0.observedAt) < 60 }).count < 60 else { return .init(status: 429, outcome: "rate_limited") }
        if let replay = delivery.replayDigest, snapshot.scheduler?.webhookReplay.contains(where: { $0.taskID == task.id && $0.digest == replay && $0.expiresAt > now }) == true {
            return .init(status: 202, outcome: "duplicate")
        }
        if case .webhook(let config) = task.schedule, delivery.coalesceDigest != nil {
            let matching = snapshot.scheduler?.webhookPending.contains { $0.taskID == task.id && $0.revision == task.revision && $0.delivery.coalesceDigest == delivery.coalesceDigest && $0.fireAt > now } ?? false
            let pending = ScheduledTaskWebhookPending(id: occurrenceID, taskID: task.id, revision: task.revision, receivedAt: now,
                fireAt: now.addingTimeInterval(Double(config.coalesceWindowSeconds)), prompt: prompt, delivery: delivery)
            _ = try await engine.dispatch(.scheduledTask(.enqueueWebhook(pending)), id: TaskOrchestration.derivedID(occurrenceID, "coalesce-window"))
            return .init(status: 202, outcome: matching ? "coalesced" : "accepted")
        }
        _ = try await fire(task: task, trigger: .webhook, commandID: occurrenceID, due: now, now: now, prompt: prompt, delivery: delivery)
        return .init(status: 202, outcome: "accepted")
    }

    public func shutdown() async {
        closed = true
        let loop = loop; self.loop = nil; loop?.cancel()
        await stopWebhookListener()
        await loop?.value
        for job in Array(credentialJobs.values) { _ = await job.result }
        while !jobs.isEmpty { for job in Array(jobs.values) { _ = await job.result }; await Task.yield() }
    }
}
