import CoincideCore
import SwiftUI

struct RunCheckpointRestoreBanner: View {
    let store: WorkspaceStore
    let threadID: UUID
    var body: some View {
        if let operation = store.checkpointRestoreOperations(threadID: threadID).first,
           operation.isPending || operation.phase == .unconfirmed {
            RunCheckpointRestoreOperationView(store: store, operation: operation)
                .padding(12).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .coincideSurface()
        }
    }
}

struct RunCheckpointRestoreOperationView: View {
    let store: WorkspaceStore
    let operation: RunCheckpointRestoreOperation
    @State private var error: String?
    @State private var confirmingKeep = false
    @State private var keeping = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if operation.isPending { ProgressView().controlSize(.small) }
                Text(RunCheckpointRestorePresentation.status(operation)).font(.caption.weight(.medium))
                    .accessibilityIdentifier("checkpoint-restore-status")
            }
            if operation.isPending {
                Text("Workspace changes and new agent work are paused until the restore finishes.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let message = operation.error {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if operation.phase == .unconfirmed, operation.acknowledgedAt == nil {
                Text("Some files or staging may have changed. Inspection reads saved evidence and never repeats the restore.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Inspect Restore State") { inspect() }.controlSize(.small)
                        .disabled(store.isInspectingCheckpointRestore(operation.id) || keeping)
                        .accessibilityIdentifier("checkpoint-restore-inspect")
                    Button("Keep Current Files…") { confirmingKeep = true }.controlSize(.small)
                        .disabled(store.isInspectingCheckpointRestore(operation.id) || keeping)
                        .accessibilityIdentifier("checkpoint-restore-keep")
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
            .onChange(of: operation.phase) { error = nil }
            .alert("Keep Current Files?", isPresented: $confirmingKeep) {
                Button("Cancel", role: .cancel) { }
                Button("Keep Current Files") { keepCurrentFiles() }
            } message: {
                Text("Release this workspace with its current files and staging, which may be partially changed. This does not restore files or repeat the previous action.")
            }
    }
    private func inspect() {
        error = nil
        Task {
            do { try await store.inspectCheckpointRestore(operation.id) }
            catch { self.error = RunCheckpointRestorePresentation.error(error) }
        }
    }
    private func keepCurrentFiles() {
        guard !keeping else { return }
        keeping = true; error = nil
        Task {
            defer { keeping = false }
            do { try await store.acknowledgeCheckpointRestore(operation.id) }
            catch { self.error = RunCheckpointRestorePresentation.error(error) }
        }
    }
}
