import CoincideCore
import Foundation

/// A confirmation belongs to the exact provider session reviewed by the user.
/// Nothing here changes Coincide's public messages, attachments or unsent draft.
struct ContextCompactionConfirmation: Identifiable, Equatable {
    let id = UUID()
    let threadID: UUID
    let runtimeID: UUID
    let configuration: ProviderConfiguration
    let providerName: String
}

extension WorkspaceStore {
    func contextCompactionUnavailableReason(threadID: UUID) -> String? {
        if acceptingContextCompaction.contains(threadID) { return "Context compaction is being requested." }
        return snapshot.contextCompactionUnavailableReason(threadID: threadID)
    }

    func prepareContextCompaction(threadID: UUID) throws -> ContextCompactionConfirmation {
        if let reason = contextCompactionUnavailableReason(threadID: threadID) { throw CoincideError(reason) }
        guard let thread = thread(threadID), let runtimeID = thread.runtimeID else {
            throw CoincideError("Send a reply in this conversation before compacting its context.")
        }
        return .init(threadID: threadID, runtimeID: runtimeID,
            configuration: .init(thread: thread), providerName: thread.providerName)
    }

    func requestContextCompaction(threadID: UUID) {
        do { contextCompactionConfirmation = try prepareContextCompaction(threadID: threadID) }
        catch { errorMessage = error.localizedDescription }
    }

    func confirmContextCompaction(_ confirmation: ContextCompactionConfirmation) async {
        if contextCompactionConfirmation?.id == confirmation.id { contextCompactionConfirmation = nil }
        do { _ = try await compactContext(confirmation) }
        catch { errorMessage = "Context compaction was not confirmed. Check this conversation's compaction status before trying again." }
    }

    func matchesContextCompactionConfirmation(_ confirmation: ContextCompactionConfirmation) -> Bool {
        guard let thread = thread(confirmation.threadID) else { return false }
        return thread.runtimeID == confirmation.runtimeID && ProviderConfiguration(thread: thread) == confirmation.configuration
    }
}
