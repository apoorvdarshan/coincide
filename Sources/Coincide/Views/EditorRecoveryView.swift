import CoincideCore
import SwiftUI

struct EditorRecoveryShelf: View {
    let records: [EditorRecoveryRecord]
    let active: EditorRecoveryBuffer?
    let error: String?
    let canRestore: (EditorRecoveryRecord) -> Bool
    let restore: (EditorRecoveryRecord) async -> Void
    let discard: (EditorRecoveryRecord) async -> Void
    let refresh: () async -> Void
    @State private var inspecting: EditorRecoveryRecord?
    @State private var discarding: EditorRecoveryRecord?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !records.isEmpty {
                Menu("Recovered Drafts (\(records.count))") {
                    ForEach(records) { record in
                        Menu(record.relativePath + " · " + record.scope.workspacePath) {
                            Button("View Saved Text…") { inspecting = record }
                            Button("Restore in Editor") { Task { await restore(record) } }.disabled(!canRestore(record))
                            Button("Discard Saved Draft…", role: .destructive) { discarding = record }
                        }
                    }
                }.accessibilityIdentifier("editor-recovered-drafts")
            }
            if active?.isSaving == true { Text("Saving recovery draft…").font(.caption).foregroundStyle(.secondary) }
            else if active?.isDurable == true { Label("Draft saved for recovery", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary) }
            if let message = active?.errorMessage ?? error {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                HStack {
                    if let active { Button("Retry Recovery") { active.retry() } }
                    Button("Refresh Recovery") { Task { await refresh() } }
                }.controlSize(.small)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
        .sheet(item: $inspecting) { record in EditorRecoveryPreview(record: record) }
        .confirmationDialog("Discard this saved editor draft?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } })) {
            if let record = discarding {
                Button("Discard Saved Draft", role: .destructive) { discarding = nil; Task { await discard(record) } }
            }
            Button("Cancel", role: .cancel) { discarding = nil }
        } message: { Text("This removes only the private recovery draft. No workspace file or remote operation is changed.") }
    }
}

private struct EditorRecoveryPreview: View {
    let record: EditorRecoveryRecord
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recovered Editor Draft").font(.title2)
            Text(record.scope.workspacePath + "/" + record.relativePath).font(.caption).textSelection(.enabled)
            Text("Saved locally for recovery. Opening this text does not write a workspace file or repeat a remote operation.").font(.caption).foregroundStyle(.secondary)
            SourceEditor(text: .constant(record.contents), path: "recovery:\(record.id)", navigation: nil, isEditable: false)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(minWidth: 580, idealWidth: 760, minHeight: 400, idealHeight: 560)
    }
}
