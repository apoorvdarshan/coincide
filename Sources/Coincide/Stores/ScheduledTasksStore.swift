import CoincideCore
import Foundation
import Observation

struct ScheduledTaskSourceOption: Identifiable, Equatable {
    let id: UUID
    let title: String
    let provider: ProviderKind
    let model: String
}

@MainActor @Observable
final class ScheduledTasksStore {
    private(set) var ledger = ScheduledTaskLedger()
    private(set) var sources: [ScheduledTaskSourceOption] = []
    private(set) var projects: [WorkspaceProject] = []
    private(set) var isWorking = false
    private(set) var listenerPort: UInt16?
    var error: String?
    @ObservationIgnored private var snapshot = WorkspaceSnapshot()
    @ObservationIgnored private let engine: WorkspaceEngine
    @ObservationIgnored private var service: ScheduledTaskService?
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var commands: [UUID: Task<Void, any Error>] = [:]
    @ObservationIgnored private var credentials: [UUID: Task<ScheduledTaskWebhookRegistration, any Error>] = [:]
    @ObservationIgnored private var closed = false
    init(engine: WorkspaceEngine, service: ScheduledTaskService? = nil) { self.engine = engine; self.service = service }
    func load() async {
        guard !closed else { return }
        do {
            let snapshot = try await engine.load(); apply(snapshot)
            if updates == nil {
                let stream = await engine.updates()
                updates = Task { [weak self] in
                    for await update in stream {
                        guard let self, !Task.isCancelled, !closed else { return }
                        apply(update.snapshot)
                    }
                }
            }
            let service: ScheduledTaskService
            if let existing = self.service { service = existing } else { service = await engine.scheduler(); self.service = service }
            await service.start(); listenerPort = await service.currentListenerPort()
        } catch { self.error = error.localizedDescription }
    }
    private func apply(_ snapshot: WorkspaceSnapshot) {
        self.snapshot = snapshot
        let ledger = snapshot.scheduler ?? .init()
        if self.ledger != ledger { self.ledger = ledger }
        if projects != snapshot.projects { projects = snapshot.projects }
        let options = snapshot.threads.filter { !$0.isArchived && snapshot.workspaceReady(for: $0) }.map { ScheduledTaskSourceOption(id: $0.id, title: $0.title, provider: $0.provider, model: $0.model) }
        if sources != options { sources = options }
    }
    func refresh() async {
        guard !closed else { return }
        apply(await engine.current().snapshot); listenerPort = await service?.currentListenerPort()
    }
    func source(threadID: UUID) throws -> ScheduledTaskSource {
        guard sources.contains(where: { $0.id == threadID }), let thread = snapshot.threads.first(where: { $0.id == threadID }), let project = projects.first(where: { $0.id == thread.projectID }) else { throw ScheduledTaskError.sourceChanged }
        return try .init(thread: thread, project: project)
    }
    func validateSource(_ source: ScheduledTaskSource) async throws {
        guard !closed else { throw ScheduledTaskError.unavailable }
        try source.validate(in: await engine.current().snapshot)
    }
    func save(_ definition: ScheduledTaskDefinition, expectedRevision: UUID?) async throws {
        try await perform { try await self.dispatch(.save(definition, expectedRevision: expectedRevision)) }
    }
    func setEnabled(_ definition: ScheduledTaskDefinition, enabled: Bool) async {
        await handling { try await self.perform { try await self.dispatch(.enabled(id: definition.id, revision: definition.revision, enabled: enabled, now: Date())) } }
    }
    func delete(_ definition: ScheduledTaskDefinition) async {
        await handling { try await self.perform { try await self.dispatch(.delete(id: definition.id, revision: definition.revision)) } }
    }
    func runNow(_ definition: ScheduledTaskDefinition, commandID: UUID = UUID()) async {
        await handling {
            guard let service = self.service else { throw ScheduledTaskError.unavailable }
            try await self.perform { _ = try await service.runNow(id: definition.id, commandID: commandID, expectedRevision: definition.revision) }
        }
    }
    func acknowledge(_ occurrence: ScheduledTaskOccurrence) async {
        await handling { try await self.perform { try await self.dispatch(.acknowledge(id: occurrence.id, now: Date())) } }
    }
    func prune() async {
        await handling { try await self.perform { try await self.dispatch(.pruneResolvedHistory) } }
    }
    func configureWebhook(taskID: UUID, configuration: ScheduledTaskWebhookConfiguration, signingSecret: Data?, rotateAuthorization: Bool = false) async throws -> ScheduledTaskWebhookRegistration {
        guard let service, !closed else { throw ScheduledTaskError.unavailable }
        let id = UUID(), task = Task { try await service.configureWebhook(taskID: taskID, configuration: configuration, signingSecret: signingSecret, rotateAuthorization: rotateAuthorization) }
        credentials[id] = task; defer { credentials.removeValue(forKey: id) }
        let value = try await task.value
        guard !closed else { throw CancellationError() }; return value
    }
    func listener(enabled: Bool, port: UInt16) async {
        await handling {
            try await self.perform {
                try await self.dispatch(.listener(port: enabled ? port : nil))
                guard let service = self.service else { throw ScheduledTaskError.unavailable }
                if enabled {
                    await service.stopWebhookListener(); self.listenerPort = try await service.startWebhookListener(port: port)
                } else { await service.stopWebhookListener(); self.listenerPort = nil }
            }
        }
    }
    private func handling(_ operation: () async throws -> Void) async {
        do { try await operation() } catch { self.error = error.localizedDescription }
    }
    private func dispatch(_ mutation: ScheduledTaskMutation) async throws {
        let receipt = try await engine.dispatch(.scheduledTask(mutation))
        if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        guard !closed, !isWorking else { throw ScheduledTaskError.unavailable }
        isWorking = true; error = nil
        let id = UUID(), task = Task { try await operation() }; commands[id] = task
        defer { commands.removeValue(forKey: id); isWorking = false }
        try await task.value
        await refresh()
    }
    func shutdown() async {
        closed = true; updates?.cancel(); await updates?.value; updates = nil
        await service?.shutdown()
        for task in Array(credentials.values) { _ = await task.result }
        while !commands.isEmpty { for command in Array(commands.values) { _ = await command.result }; await Task.yield() }
    }
}
