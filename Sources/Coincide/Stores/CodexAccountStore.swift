import CoincideCore
import Foundation
import Observation

/// Account and allowance observations stay in memory and never affect accepted inputs.
@MainActor @Observable final class CodexAccountStore {
    private(set) var snapshot: CodexAccountSnapshot?
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    private var accountReadFailed = false
    @ObservationIgnored private var currentRead: UUID?
    @ObservationIgnored private var reads: [UUID: Task<CodexAccountSnapshot, any Error>] = [:]

    var isStale: Bool { accountReadFailed || snapshot?.usage.isStale == true }

    func refresh(reader: @escaping @Sendable () async throws -> CodexAccountSnapshot) async {
        if let currentRead { reads[currentRead]?.cancel() }
        let id = UUID(), task = Task { try await reader() }
        currentRead = id; reads[id] = task; isRefreshing = true
        defer {
            reads.removeValue(forKey: id)
            if currentRead == id { currentRead = nil; isRefreshing = false }
        }
        do {
            let observed = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard currentRead == id, !task.isCancelled else { return }
            snapshot = observed.preservingLastGoodUsage(from: snapshot)
            accountReadFailed = false
            errorMessage = snapshot?.usage.isStale == true
                ? String(localized: "Codex usage could not be refreshed. Any retained allowance is from an earlier check.") : nil
        } catch is CancellationError {
            // Cancellation is not a new account observation or refresh failure.
        } catch {
            guard currentRead == id, !task.isCancelled, !Task.isCancelled else { return }
            accountReadFailed = true
            // Provider errors may contain account details; keep presentation bounded.
            errorMessage = String(localized: "Codex account status could not be refreshed. Check the CLI and try again.")
        }
    }

    /// Replaced reads remain owned until their cancellation-resistant work returns.
    func cancel() async {
        currentRead = nil; isRefreshing = false
        let owned = Array(reads.values)
        for task in owned { task.cancel() }
        for task in owned { _ = try? await task.value }
    }
}
