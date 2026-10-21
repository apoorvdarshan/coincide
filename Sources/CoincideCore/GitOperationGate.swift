import Foundation

/// A process-local FIFO for Git mutations, shared by all windows and linked worktrees.
/// Git's own locks still arbitrate with external clients. Cancellation never runs a queued mutation.
actor GitOperationGate {
    static let shared = GitOperationGate()
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var owners: Set<String> = []
    private var waiters: [String: [Waiter]] = [:]

    func perform<T: Sendable>(key: String, operation: @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if owners.insert(key).inserted { continuation.resume() }
                else { waiters[key, default: []].append(.init(id: id, continuation: continuation)) }
            }
        } onCancel: { Task { await self.cancel(key: key, id: id) } }
        defer { release(key: key) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func cancel(key: String, id: UUID) {
        guard let index = waiters[key]?.firstIndex(where: { $0.id == id }) else { return }
        waiters[key]?.remove(at: index).continuation.resume(throwing: CancellationError())
        if waiters[key]?.isEmpty == true { waiters.removeValue(forKey: key) }
    }
    private func release(key: String) {
        if var pending = waiters[key], !pending.isEmpty {
            let next = pending.removeFirst()
            if pending.isEmpty { waiters.removeValue(forKey: key) } else { waiters[key] = pending }
            next.continuation.resume()
        } else { owners.remove(key) }
    }
}
