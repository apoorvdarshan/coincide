import CoincideCore
import Foundation
import Observation

/// Serial background persistence coalesces keystrokes. The UI distinguishes
/// writes still pending from positively durable recovery and exposes failure.
@MainActor @Observable
final class EditorRecoveryBuffer {
    let journal: EditorRecoveryJournal?
    let id: UUID
    private(set) var errorMessage: String?
    private(set) var isSaving = false
    private(set) var isDurable = false
    @ObservationIgnored private var saved: EditorRecoveryRecord?
    @ObservationIgnored private var latest: EditorRecoveryRecord?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    init(journal: EditorRecoveryJournal?, restored: EditorRecoveryRecord? = nil) {
        self.journal = journal; id = restored?.id ?? UUID(); saved = restored; latest = restored; isDurable = restored != nil
    }
    func replace(_ record: EditorRecoveryRecord?) {
        guard let journal else { return }
        latest = record; isDurable = false; isSaving = true
        let owner = UUID(); generation = owner; let previous = task
        task = Task {
            await previous?.value
            guard generation == owner else { return }
            let candidate = latest, prior = saved
            do {
                try await Task.detached {
                    if let candidate { try journal.save(candidate, expectedVersion: prior?.version) }
                    else if let prior { try journal.remove(id: prior.id, expectedVersion: prior.version) }
                }.value
                saved = candidate
                if generation == owner { errorMessage = nil; isSaving = false; isDurable = candidate != nil }
            } catch {
                if generation == owner { errorMessage = (error as? EditorRecoveryError)?.localizedDescription ?? "The editor recovery draft could not be saved. Keep this editor open and retry."; isSaving = false }
            }
        }
    }
    func failed(_ error: any Error) { errorMessage = (error as? EditorRecoveryError)?.localizedDescription ?? "The editor recovery draft could not be saved. Keep this editor open and retry."; isDurable = false }
    func retry() { replace(latest) }
    func flush() async {
        while let pending = task {
            let owner = generation
            await pending.value
            if generation == owner { return }
        }
    }
}
