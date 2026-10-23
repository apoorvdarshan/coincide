import CoincideCore
import SwiftUI

struct RunCheckpointRestoreTarget: Identifiable {
    let runID: UUID
    let stage: RunCheckpointStage
    let attempt: ThreadRunCheckpointAttempt
    var id: UUID { attempt.id }
    var title: String { RunCheckpointRestorePresentation.target(stage: stage, later: attempt.isLaterObservation) }
}

struct RunCheckpointRestoreSheet: View {
    let store: WorkspaceStore
    let threadID: UUID
    let runID: UUID
    let stage: RunCheckpointStage
    let attemptID: UUID
    let close: () -> Void
    @State private var review: RunCheckpointRestoreReview?
    @State private var loading = true
    @State private var accepting = false
    @State private var error: String?
    private var operation: RunCheckpointRestoreOperation? { review.flatMap { store.snapshot.checkpointRestoreOperation($0.id) } }

    var body: some View {
        RunCheckpointRestoreContent(review: review, stage: stage, loading: loading, accepting: accepting,
                                    error: error, operation: operation, confirm: confirm, close: close) {
            if let operation { RunCheckpointRestoreOperationView(store: store, operation: operation) }
        }
        .interactiveDismissDisabled(accepting)
        .task {
            do {
                let value = try await store.reviewCheckpointRestore(threadID: threadID, runID: runID, stage: stage, expectedAttemptID: attemptID)
                guard !Task.isCancelled else { store.discardCheckpointRestoreReview(value.id); return }
                review = value; loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = RunCheckpointRestorePresentation.error(error); loading = false
            }
        }
        .onDisappear { if let review { store.discardCheckpointRestoreReview(review.id) } }
    }
    private func confirm() {
        guard let review, !accepting, operation == nil else { return }
        accepting = true; error = nil
        Task {
            defer { accepting = false }
            do { try await store.beginCheckpointRestore(review) }
            catch { self.error = RunCheckpointRestorePresentation.error(error) }
        }
    }
}

struct RunCheckpointRestoreContent<Status: View>: View {
    let review: RunCheckpointRestoreReview?
    let stage: RunCheckpointStage
    let loading: Bool
    let accepting: Bool
    var canConfirm = true
    let error: String?
    let operation: RunCheckpointRestoreOperation?
    let confirm: () -> Void
    let close: () -> Void
    @ViewBuilder let status: () -> Status

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Restore Workspace Files").font(.title2)
                Text("Replace files with the selected saved workspace observation. This can undo edits made by you, coding agents or other tools.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Working edits and staging will be lost. New files that are not ignored may be deleted. Ignored files are kept; the current branch and HEAD stay unchanged.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("checkpoint-restore-loss-warning")
                Text("Conversation history, current draft and provider settings stay unchanged.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if loading { ProgressView("Reviewing current files and checkpoint…").frame(maxWidth: .infinity).padding() }
                    if let review {
                        Text(RunCheckpointRestorePresentation.target(stage: stage, later: review.checkpoint.isLaterObservation)).font(.headline)
                        LabeledContent("Saved observation") { Text(review.checkpoint.requestedAt, format: .dateTime.year().month(.abbreviated).day().hour().minute().second()) }
                        if review.checkpoint.isLaterObservation {
                            Text("This was captured later, after the run ended. It is an observation of the workspace at that time.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Text(review.workspacePath).font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("checkpoint-restore-workspace")
                        LabeledContent("Affected paths", value: review.gitReview.affectedPaths.count.formatted())
                        DisclosureGroup("Paths in this restore") {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(review.gitReview.affectedPaths, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                            }.frame(maxHeight: 180)
                        }
                        if !review.gitReview.previewPatch.isEmpty {
                            DisclosureGroup("Preview changes to current files") {
                                ScrollView(.horizontal) {
                                    Text(review.gitReview.previewPatch).font(.caption.monospaced()).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                                }
                            }
                        }
                        if review.gitReview.previewTruncated {
                            Text("Preview size limit reached. The restore applies to the complete reviewed manifest, including changes not shown here.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if operation != nil { status() }
                    if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }.padding(20)
            }.frame(minHeight: 150, idealHeight: 280, maxHeight: 380)
            Divider()
            HStack {
                Spacer()
                Button(operation == nil ? "Cancel" : "Done", action: close).keyboardShortcut(.defaultAction)
                    .disabled(accepting).accessibilityIdentifier("checkpoint-restore-close")
                if operation == nil {
                    Button("Restore Files", role: .destructive, action: confirm)
                        .disabled(review == nil || loading || accepting || !canConfirm)
                        .accessibilityIdentifier("checkpoint-restore-confirm")
                }
            }.padding(16)
        }.frame(minWidth: 320, idealWidth: 580, maxWidth: 760)
            .onExitCommand { if !accepting { close() } }
    }
}

enum RunCheckpointRestorePresentation {
    static func target(stage: RunCheckpointStage, later: Bool) -> String {
        stage == .baseline ? String(localized: "Restore Files to Before Run…") : later
            ? String(localized: "Restore Files to Saved Observation…") : String(localized: "Restore Files to After Run…")
    }
    static func targets(_ record: ThreadRunRecord) -> [RunCheckpointRestoreTarget] {
        guard let checkpoints = record.checkpoints else { return [] }
        let before = [RunCheckpointRestoreTarget(runID: record.id, stage: .baseline, attempt: checkpoints.baseline)]
        let after = (checkpoints.postRun.map { [$0] } ?? []).map { RunCheckpointRestoreTarget(runID: record.id, stage: .postRun, attempt: $0) }
        return (before + after).filter { $0.attempt.phase == .ready && $0.attempt.receipt != nil }
    }
    static func status(_ operation: RunCheckpointRestoreOperation) -> String {
        switch operation.phase {
        case .accepted: String(localized: "File restoration accepted")
        case .dispatching: String(localized: "Restoring workspace files…")
        case .applied: String(localized: "Workspace files restored")
        case .failed: String(localized: "File restoration did not start")
        case .unconfirmed: operation.acknowledgedAt == nil ? String(localized: "File restoration outcome unconfirmed") : String(localized: "Current files kept after unconfirmed restoration")
        }
    }
    static func error(_ error: any Error) -> String {
        if let error = error as? GitCheckpointRestoreError { return error.localizedDescription }
        return String(localized: "The workspace, checkpoint or active work changed. Close this review and check the current files before reviewing again.")
    }
}
