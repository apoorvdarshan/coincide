import CoincideCore
import Foundation
import Observation

struct DelegatedTasksTransport: Sendable {
    /// Inspection deliberately has no acknowledgment argument or write route.
    var inspect: @Sendable (UUID, UUID) async throws -> DelegatedTaskStatusSnapshot
    var cancel: @Sendable (UUID, UUID, UUID) async throws -> WorkspaceCommandReceipt
}

@MainActor @Observable
final class DelegatedTasksStore {
    private(set) var conversationID: UUID?
    private(set) var snapshot = WorkspaceSnapshot()
    private(set) var selectedTaskID: UUID?
    private(set) var detail: DelegatedTaskStatusSnapshot?
    private(set) var errorMessage: String?
    private(set) var notice: String?
    private(set) var isInspecting = false
    private(set) var cancellingTaskIDs: Set<UUID> = []
    @ObservationIgnored private var transport: DelegatedTasksTransport?
    @ObservationIgnored private var openConversation: @MainActor (UUID) -> Void = { _ in }
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var readOwner = UUID()
    @ObservationIgnored private var reads: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var writes: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var attemptedCancellations: Set<UUID> = []
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    var tasks: [DelegatedTask] { (snapshot.delegatedTasks ?? []).filter { $0.parentThreadID == conversationID && $0.isFollowup != true }.sorted { $0.createdAt < $1.createdAt } }
    var parentConversationID: UUID? { snapshot.threads.first { $0.id == conversationID }?.delegatedTaskLineage?.parentThreadID }
    var selectedTask: DelegatedTask? {
        guard let current = tasks.first(where: { $0.id == selectedTaskID }) else { return nil }
        if let detail, detail.task.id == current.id, detail.task.updatedAt >= current.updatedAt { return detail.task }
        return current
    }
    var latestChildResult: DelegatedTaskResult? {
        guard let selectedTask else { return nil }
        return selectedTask.latestTerminalResult ?? snapshot.delegatedTasks?.last { $0.parentThreadID == selectedTask.parentThreadID && $0.childThreadID == selectedTask.childThreadID && $0.result?.runID != selectedTask.result?.runID && $0.result != nil }?.result
    }
    var child: CodingThread? { selectedTask.flatMap { selected in snapshot.threads.first { $0.id == selected.childThreadID } } }
    var pendingQuestionCount: Int { child?.runtimeRequests.filter { !$0.responding && $0.request.isQuestion }.count ?? 0 }
    var pendingApprovalCount: Int { child?.runtimeRequests.filter { !$0.responding && !$0.request.isQuestion }.count ?? 0 }
    var hasPendingChildRuns: Bool { detail?.task.id == selectedTaskID && detail?.hasPendingChildRuns == true || child?.isBusy == true || child?.queuedTurns.isEmpty == false }
    var canCancelSelected: Bool {
        guard !closed, transport != nil, let task = selectedTask, task.cancelRequestedAt == nil,
              !attemptedCancellations.contains(task.id), !cancellingTaskIDs.contains(task.id) else { return false }
        return !task.status.isTerminal || hasPendingChildRuns || snapshot.delegatedTaskTree(task.id).contains { !$0.status.isTerminal }
    }
    func update(conversationID: UUID, snapshot: WorkspaceSnapshot, transport: DelegatedTasksTransport?, open: @escaping @MainActor (UUID) -> Void) {
        guard !closed else { return }
        if self.conversationID != conversationID {
            generation = UUID(); reads.values.forEach { $0.cancel() }
            selectedTaskID = nil; detail = nil; isInspecting = false; errorMessage = nil; notice = nil
        }
        self.conversationID = conversationID; self.snapshot = snapshot; self.transport = transport; openConversation = open
        if let selectedTaskID, !tasks.contains(where: { $0.id == selectedTaskID }) {
            readOwner = UUID(); reads.values.forEach { $0.cancel() }; self.selectedTaskID = nil; detail = nil; isInspecting = false
        }
    }
    @discardableResult func inspect(_ taskID: UUID) -> Task<Void, Never>? {
        guard !closed, let parent = conversationID, let task = tasks.first(where: { $0.id == taskID }), let transport else { return nil }
        selectedTaskID = taskID; detail = nil; errorMessage = nil; notice = nil
        reads.values.forEach { $0.cancel() }
        let owner = UUID(), scope = generation; readOwner = owner; isInspecting = true
        let work = Task {
            defer { reads.removeValue(forKey: owner); if readOwner == owner { isInspecting = false } }
            do {
                let value = try await transport.inspect(parent, taskID)
                guard !closed, !Task.isCancelled, generation == scope, readOwner == owner, selectedTaskID == taskID else { return }
                guard value.task.id == taskID, value.task.parentThreadID == parent, value.task.childThreadID == task.childThreadID,
                      value.task.isFollowup != true else { throw DelegatedTaskError.notFound }
                detail = value
            } catch is CancellationError { }
            catch { if !closed, generation == scope, readOwner == owner, !Task.isCancelled { errorMessage = Self.safe(error) } }
        }
        reads[owner] = work; return work
    }
    @discardableResult func cancelSelected() -> Task<Void, Never>? {
        guard canCancelSelected, let task = selectedTask, let parent = conversationID, let transport else { return nil }
        let commandID = UUID(), scope = generation
        attemptedCancellations.insert(task.id); cancellingTaskIDs.insert(task.id); errorMessage = nil; notice = nil
        let work = Task {
            defer { writes.removeValue(forKey: commandID); cancellingTaskIDs.remove(task.id) }
            do {
                let receipt = try await transport.cancel(parent, task.id, commandID)
                guard !closed, generation == scope, selectedTaskID == task.id, !Task.isCancelled else { return }
                guard receipt.commandID == commandID else { throw DelegatedTaskError.unavailable }
                if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
                notice = "Cancellation requested. Open the child conversation to inspect its final state."
            } catch is CancellationError { }
            catch { if !closed, generation == scope, selectedTaskID == task.id, !Task.isCancelled { errorMessage = Self.safe(error) } }
        }
        writes[commandID] = work; return work
    }
    func open(_ id: UUID) { guard !closed, snapshot.threads.contains(where: { $0.id == id }) else { return }; openConversation(id) }
    func stop() {
        guard !closed else { return }; closed = true; generation = UUID(); transport = nil
        reads.values.forEach { $0.cancel() }
        // An explicit Cancel owns its original parent/task/command identity.
        // Closing a sheet joins that control operation without withdrawing it.
        let waiters = closeWaiters; closeWaiters = []; waiters.forEach { $0.resume() }
    }
    func waitForClose() async {
        if Task.isCancelled { stop(); return }; if closed { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }
    func shutdown() async {
        stop(); let pending = Array(reads.values) + Array(writes.values)
        for task in pending { await task.value }
    }
    private static func safe(_ error: any Error) -> String {
        if let error = error as? DelegatedTaskError { return error.localizedDescription }
        if let error = error as? WorkspaceCommandError { return error.localizedDescription }
        return "The delegated task could not be inspected or cancelled. Open its conversation to check the current state."
    }
}
