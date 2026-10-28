import AppKit
import CoincideKit

/// Session Undo for inbox operations. Deleted conversations keep their checkpoint refs until their
/// undo entry is discarded; Undo restores history, never restarts a stopped agent or terminal command.
@MainActor
final class ThreadInbox {
    static let shared = ThreadInbox()
    static let didChange = Notification.Name("coincide.inboxChanged")

    let undoManager = UndoManager()
    private let store: AppStore
    private let ui: UIState
    private let isRunning: (UUID) -> Bool
    private let reportError: (Error) -> Void
    private struct RestoreRetry {
        var snapshots: [AppStore.DeletedThread]
        var restored: [UUID]
    }
    /// Retain failed snapshots while UndoManager consumes its current action; requeue after it returns.
    private var restoreRetries: [RestoreRetry] = []

    init(store: AppStore = .shared, ui: UIState = .shared,
         isRunning: @escaping (UUID) -> Bool = { ThreadRunner.shared.isRunning($0) },
         reportError: @escaping (Error) -> Void = { _ = NSApp.presentError($0) }) {
        self.store = store
        self.ui = ui
        self.isRunning = isRunning
        self.reportError = reportError
        undoManager.levelsOfUndo = 20
        undoManager.groupsByEvent = false
    }

    func isSettled(_ thread: ThreadSummary) -> Bool {
        guard let date = ui.values.settledThreads[thread.id.uuidString] else { return false }
        return date >= thread.updatedAt
    }

    static func isHidden(_ thread: ThreadSummary) -> Bool {
        shared.isSettled(thread) && !ThreadRunner.shared.isRunning(thread.id)
            && ThreadActivity.shared.pendingApprovalCount(thread.id) == 0
            && ThreadActivity.shared.pendingQuestionCount(thread.id) == 0
    }

    func archive(_ ids: [UUID], archived: Bool) {
        applyArchive(ids.compactMap { id in
            guard let thread = store.summary(id), thread.isArchived != archived,
                !archived || !isRunning(id) else { return nil }
            return (id, archived)
        })
    }

    private func applyArchive(_ values: [(UUID, Bool)]) {
        // Undo/Redo can be invoked after a restored conversation starts new work.
        let values = values.filter { id, archived in !archived || !isRunning(id) }
        let previous = values.compactMap { id, _ in store.summary(id).map { (id, $0.isArchived) } }
        guard !previous.isEmpty else { return }
        register(String(localized: "Archive Threads")) { $0.applyArchive(previous) }
        for (id, archived) in values where store.summary(id) != nil {
            store.updateThread(id) { $0.isArchived = archived }
        }
        changed()
    }

    func settle(_ ids: [UUID], settled: Bool) {
        let now = Date()
        applySettled(ids.compactMap { id in
            guard store.hasThread(id), !settled || (!isRunning(id)
                && ThreadActivity.shared.pendingApprovalCount(id) == 0
                && ThreadActivity.shared.pendingQuestionCount(id) == 0) else { return nil }
            return (id, settled ? now : nil)
        })
    }

    private func applySettled(_ values: [(UUID, Date?)]) {
        let previous = values.filter { store.hasThread($0.0) }.map { ($0.0, ui.values.settledThreads[$0.0.uuidString]) }
        guard !previous.isEmpty else { return }
        register(String(localized: "Settle Threads")) { $0.applySettled(previous) }
        ui.update { state in
            for (id, date) in values { state.settledThreads[id.uuidString] = date }
        }
        changed()
    }

    /// Call only after any requested confirmation and after stopping selected agents.
    func delete(_ ids: [UUID]) throws {
        var deleted: [AppStore.DeletedThread] = []
        do {
            for id in Set(ids) {
                if let snapshot = try store.deleteThreadForUndo(id) { deleted.append(snapshot) }
            }
        } catch {
            var failed: [AppStore.DeletedThread] = []
            for snapshot in deleted {
                do { _ = try store.restoreDeletedThread(snapshot) } catch { failed.append(snapshot) }
            }
            if !failed.isEmpty { restoreRetries.append(RestoreRetry(snapshots: failed, restored: [])) }
            requeueRestores()
            throw error
        }
        guard !deleted.isEmpty else { return }
        register(String(localized: "Delete Threads")) { $0.restore(deleted) }
        changed()
    }

    private func restore(_ snapshots: [AppStore.DeletedThread], restored previouslyRestored: [UUID] = []) {
        var restored = previouslyRestored
        var failed: [AppStore.DeletedThread] = []
        var firstError: Error?
        for snapshot in snapshots {
            do {
                if try store.restoreDeletedThread(snapshot) { restored.append(snapshot.id) }
            } catch {
                failed.append(snapshot)
                if firstError == nil { firstError = error }
            }
        }
        if !failed.isEmpty {
            restoreRetries.append(RestoreRetry(snapshots: failed, restored: restored))
            if let firstError { reportError(firstError) }
            changed()
            return
        }
        guard !restored.isEmpty else { return }
        register(String(localized: "Delete Threads")) { inbox in
            // Redo does not silently stop new work started since Undo.
            let idle = restored.filter { !inbox.isRunning($0) && !ThreadActions.hasBusyTerminals($0) }
            do { try inbox.delete(idle) } catch { inbox.reportError(error) }
        }
        changed()
    }

    func undo() {
        if undoManager.canUndo { undoManager.undo() }
        requeueRestores()
        changed()
    }

    func redo() {
        if undoManager.canRedo { undoManager.redo() }
        requeueRestores()
        changed()
    }

    /// Register on the Undo stack only after an undo/redo finishes. Registering inside an undo would
    /// incorrectly make the recovery a Redo; dropping the snapshots would lose the only recovery copy.
    private func requeueRestores() {
        guard !undoManager.isUndoing, !undoManager.isRedoing, !restoreRetries.isEmpty else { return }
        let retries = restoreRetries
        restoreRetries.removeAll()
        for retry in retries {
            register(String(localized: "Delete Threads")) { $0.restore(retry.snapshots, restored: retry.restored) }
        }
        changed()
    }

    private func register(_ name: String, action: @escaping (ThreadInbox) -> Void) {
        let needsGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if needsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self, handler: action)
        undoManager.setActionName(name)
        if needsGroup { undoManager.endUndoGrouping() }
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
