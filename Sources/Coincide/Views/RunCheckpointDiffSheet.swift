import CoincideCore
import SwiftUI

struct RunCheckpointDiffSheet: View {
    let store: WorkspaceStore
    let threadID: UUID
    let runID: UUID
    var restoreAction: ((RunCheckpointStage, UUID) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var diff: GitCheckpointDiff?
    @State private var error: String?
    @State private var loading = true

    private var record: ThreadRunRecord? { store.thread(threadID)?.runHistory?.first { $0.id == runID } }
    private var revision: String {
        guard let checkpoints = record?.checkpoints else { return "unavailable" }
        return checkpoints.baseline.id.uuidString + ":" + (checkpoints.postRun?.id.uuidString ?? "pending")
    }

    var body: some View {
        RunCheckpointDiffContent(workspacePath: record?.configuration.workspacePath, diff: diff, error: error,
                                 loading: loading, close: { dismiss() }, restoreTargets: record.map(RunCheckpointRestorePresentation.targets) ?? [],
                                 restoreAction: restoreAction, restoreUnavailableReason: { stage, attempt in
                                     store.checkpointRestoreUnavailableReason(threadID: threadID, runID: runID, stage: stage, expectedAttemptID: attempt)
                                 })
            .task(id: revision) {
                loading = true; diff = nil; error = nil
                do {
                    let result = try await store.runCheckpointDiff(threadID: threadID, runID: runID, maxBytes: 262_144)
                    try Task.checkCancellation()
                    diff = result; loading = false
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = String(localized: "Workspace changes are unavailable. The saved checkpoints or workspace may have changed.")
                    loading = false
                }
            }
    }
}

struct RunCheckpointDiffContent: View {
    let workspacePath: String?
    let diff: GitCheckpointDiff?
    let error: String?
    let loading: Bool
    let close: () -> Void
    var restoreTargets: [RunCheckpointRestoreTarget] = []
    var restoreAction: ((RunCheckpointStage, UUID) -> Void)? = nil
    var restoreUnavailableReason: ((RunCheckpointStage, UUID) -> String?)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Workspace Changes").font(.title2)
                Text("Changes between saved workspace observations may include edits from you or other tools.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let workspacePath {
                    Text(workspacePath).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
            }.padding(20)
            Divider()
            Group {
                if loading {
                    ProgressView("Loading workspace changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView("Changes unavailable", systemImage: "exclamationmark.circle", description: Text(error))
                        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let diff {
                    if diff.patch.isEmpty {
                        ContentUnavailableView("No workspace changes", systemImage: "checkmark.circle",
                                               description: Text("These saved observations have the same file contents."))
                            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        DiffView(diff: UnifiedDiff.parse(diff.patch, truncated: diff.truncated), workspacePath: workspacePath, showsTruncationNotice: false)
                            .accessibilityIdentifier("run-checkpoint-diff-patch")
                    }
                }
            }.frame(minHeight: 160, idealHeight: 340, maxHeight: 440)
            Divider()
            HStack {
                if let restoreAction, !restoreTargets.isEmpty {
                    Menu("Restore Files") {
                        ForEach(restoreTargets) { target in
                            let reason = restoreUnavailableReason?(target.stage, target.id)
                            Button(target.title) { restoreAction(target.stage, target.id) }
                                .disabled(reason != nil).help(reason ?? String(localized: "Review this saved workspace observation."))
                        }
                    }.fixedSize().accessibilityIdentifier("run-checkpoint-diff-restore")
                }
                if diff?.truncated == true {
                    Text("Preview size limit reached. Some changes are not shown.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("run-checkpoint-diff-truncated")
                }
                Spacer(minLength: 8)
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }.padding(16)
        }
        .frame(minWidth: 320, idealWidth: 680, maxWidth: 900)
        .onExitCommand(perform: close)
        .accessibilityIdentifier("run-checkpoint-diff")
    }
}
