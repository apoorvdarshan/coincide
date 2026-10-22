import CoincideCore
import Foundation
import Observation

struct ACPConnectionObservation: Sendable, Equatable {
    let agent: ACPAgentConfiguration
    let info: ACPConnectionInfo
    let checkedAt: Date
}

/// Initialize-only observations belong to an exact saved invocation, never a conversation.
@MainActor @Observable final class ACPConnectionStore {
    private struct Entry {
        let agent: ACPAgentConfiguration
        var observation: ACPConnectionObservation?
        var error: String?
    }
    private struct Read {
        let agent: ACPAgentConfiguration
        let task: Task<ACPConnectionInfo, any Error>
    }
    private struct CurrentRead {
        let id: UUID
        let agent: ACPAgentConfiguration
    }

    private var registered: [UUID: ACPAgentConfiguration] = [:]
    private var entries: [UUID: Entry] = [:]
    private var currentReads: [UUID: CurrentRead] = [:]
    @ObservationIgnored private var reads: [UUID: Read] = [:]

    func observation(for agent: ACPAgentConfiguration) -> ACPConnectionObservation? {
        guard registered[agent.id] == agent, entries[agent.id]?.agent == agent else { return nil }
        return entries[agent.id]?.observation
    }

    func isRefreshing(agent: ACPAgentConfiguration) -> Bool {
        registered[agent.id] == agent && currentReads[agent.id]?.agent == agent
    }

    func errorMessage(for agent: ACPAgentConfiguration) -> String? {
        guard registered[agent.id] == agent, entries[agent.id]?.agent == agent else { return nil }
        return entries[agent.id]?.error
    }

    /// Snapshot application must invalidate before any asynchronous cleanup.
    func invalidate(validAgents: [ACPAgentConfiguration]) {
        registered = validAgents.reduce(into: [:]) { $0[$1.id] = $1 }
        entries = entries.filter { registered[$0.key] == $0.value.agent }
        currentReads = currentReads.filter { registered[$0.key] == $0.value.agent }
        for read in reads.values where registered[read.agent.id] != read.agent { read.task.cancel() }
    }

    func refresh(agent: ACPAgentConfiguration,
                 reader: @escaping @Sendable () async throws -> ACPConnectionInfo) async {
        guard registered[agent.id] == agent, !Task.isCancelled else { return }
        if let current = currentReads[agent.id] { reads[current.id]?.task.cancel() }
        if entries[agent.id]?.agent != agent { entries[agent.id] = Entry(agent: agent) }
        let id = UUID(), task = Task {
            try Task.checkCancellation()
            return try await reader()
        }
        reads[id] = Read(agent: agent, task: task)
        currentReads[agent.id] = CurrentRead(id: id, agent: agent)
        defer {
            reads.removeValue(forKey: id)
            if currentReads[agent.id]?.id == id { currentReads.removeValue(forKey: agent.id) }
        }
        do {
            let info = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard registered[agent.id] == agent, currentReads[agent.id]?.id == id, !task.isCancelled else { return }
            entries[agent.id] = Entry(agent: agent,
                observation: .init(agent: agent, info: info, checkedAt: Date()))
        } catch is CancellationError {
            // Cancellation is not a failed connection observation.
        } catch {
            guard registered[agent.id] == agent, currentReads[agent.id]?.id == id,
                  !task.isCancelled, !Task.isCancelled else { return }
            entries[agent.id]?.error = String(localized: "The agent connection could not be checked. Verify the CLI and try again.")
        }
    }

    func prune(validAgents: [ACPAgentConfiguration]) async {
        invalidate(validAgents: validAgents)
        let obsolete = reads.values.filter { registered[$0.agent.id] != $0.agent }
        for read in obsolete { _ = try? await read.task.value }
    }

    /// Replaced reads stay owned even after their replacement has completed.
    func cancel() async {
        currentReads = [:]
        let owned = Array(reads.values)
        for read in owned { read.task.cancel() }
        for read in owned { _ = try? await read.task.value }
    }
}
