import CoincideCore
import SwiftUI

private enum RemoteCheckpointSheetSelection: Identifiable {
    case diff(UUID)
    case restore(UUID, RunCheckpointStage, UUID)
    var id: String {
        switch self { case .diff(let run): "diff-\(run)"; case .restore(let run, let stage, let attempt): "restore-\(run)-\(stage.rawValue)-\(attempt)" }
    }
}

struct RemoteRunCheckpointsSheet: View {
    let store: RemoteCheckpointStore
    @State private var captured: RemoteCheckpointWorkspace?
    @State private var selection: RemoteCheckpointSheetSelection?
    init(store: RemoteCheckpointStore) { self.store = store; _captured = State(initialValue: store.current) }
    var body: some View {
        RemoteRunCheckpointHistoryContent(model: captured, refresh: { Task { await captured?.refresh() } },
            showWorkspaceChanges: { selection = .diff($0) }, restore: { selection = .restore($0, $1, $2) })
            .task { await captured?.refresh() }
            .sheet(item: $selection) { selected in
                if let model = captured {
                    switch selected {
                    case .diff(let run): RemoteCheckpointDiffPane(model: model, runID: run,
                        restore: { selection = .restore(run, $0, $1) }, close: { selection = nil })
                    case .restore(let run, let stage, let attempt): RemoteCheckpointRestorePane(model: model,
                        runID: run, stage: stage, attemptID: attempt, close: { selection = nil })
                    }
                }
            }
    }
}

/// Rendering is pure; the sheet wrapper owns explicit appearance reads and
/// the lifetime of the selected restoration review.
struct RemoteRunCheckpointHistoryContent: View {
    var model: RemoteCheckpointWorkspace?
    let refresh: () -> Void
    let showWorkspaceChanges: (UUID) -> Void
    let restore: (UUID, RunCheckpointStage, UUID) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Remote Run Checkpoints").font(.headline)
                    Text("Saved observations and file actions belong to the remote Mac.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", action: refresh).disabled(model?.canRead != true || model?.isLoading == true)
            }.padding(16)
            if let model {
                if let message = model.errorMessage ?? model.unavailableMessage { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.horizontal, 16) }
                if model.isLoading { ProgressView("Reading remote checkpoint inventory…").controlSize(.small).padding(.horizontal, 16) }
                if model.projection != nil {
                    RemoteProjectedCheckpointHistory(model: model, showDiff: showWorkspaceChanges, restore: restore)
                } else {
                RunHistoryContent(thread: model.thread, showWorkspaceChanges: showWorkspaceChanges,
                    historyAction: nil, historyUnavailableReason: nil,
                    restoreAction: restore,
                    restoreUnavailableReason: { model.restoreUnavailableReason(runID: $0, stage: $1, attemptID: $2) },
                    restoreOperations: model.operations,
                    restoreOperationView: { AnyView(RemoteCheckpointRestoreOperationView(model: model, operation: $0)) })
                }
            } else { ContentUnavailableView("Choose a Remote Conversation", systemImage: "clock") }
        }.frame(minWidth: 360, idealWidth: 620, maxWidth: 760)
    }
}

private struct RemoteCheckpointDiffPane: View {
    var model: RemoteCheckpointWorkspace
    let runID: UUID
    let restore: (RunCheckpointStage, UUID) -> Void
    let close: () -> Void
    private var record: ThreadRunRecord? { model.thread?.runHistory?.first { $0.id == runID } }
    private var revision: String { (record?.checkpoints?.baseline.id.uuidString ?? "missing") + ":" + (record?.checkpoints?.postRun?.id.uuidString ?? "missing") }
    var body: some View {
        RunCheckpointDiffContent(workspacePath: record?.configuration.workspacePath ?? model.projectedRuns.first(where: { $0.id == runID })?.workspacePath,
            diff: model.diff.flatMap { $0.runID == runID ? .init(patch: $0.patch, truncated: $0.truncated) : nil },
            error: model.diffError, loading: model.isLoadingDiff, close: close,
            restoreTargets: record.map(RunCheckpointRestorePresentation.targets) ?? [], restoreAction: restore,
            restoreUnavailableReason: { model.restoreUnavailableReason(runID: runID, stage: $0, attemptID: $1) })
            .task(id: revision) { await model.loadAttempts(runID: runID); await model.loadDiff(runID: runID) }
    }
}

struct RemoteCheckpointRestorePane: View {
    var model: RemoteCheckpointWorkspace
    let runID: UUID
    let stage: RunCheckpointStage
    let attemptID: UUID
    let close: () -> Void
    @State private var ownedReviewID: UUID?
    var body: some View {
        RemoteCheckpointRestorePresentationContent(model: model, runID: runID, stage: stage, attemptID: attemptID,
            confirm: { Task { await model.applyRestore() } }, close: close)
            .interactiveDismissDisabled(model.isActing)
            .task {
                if model.inventory == nil, model.projection == nil { await model.refresh() }
                let owned = await model.prepareRestore(runID: runID, stage: stage, attemptID: attemptID)
                guard !Task.isCancelled else { if let owned { model.clearReview(id: owned) }; return }
                ownedReviewID = owned
            }
            .onDisappear { if !model.isActing, let ownedReviewID { model.clearReview(id: ownedReviewID) } }
    }
}

struct RemoteCheckpointRestorePresentationContent: View {
    var model: RemoteCheckpointWorkspace
    let runID: UUID
    let stage: RunCheckpointStage
    let attemptID: UUID
    let confirm: () -> Void
    let close: () -> Void
    private var review: RunCheckpointRestoreReview? {
        guard let value = model.restoreReview?.value, value.runID == runID, value.stage == stage, value.attemptID == attemptID else { return nil }; return value
    }
    private var operation: RunCheckpointRestoreOperation? {
        if let id = model.restoreReview?.id { return model.operations.first { $0.id == id } }
        return model.operations.first { $0.review.runID == runID && $0.review.stage == stage && $0.review.attemptID == attemptID }
    }
    var body: some View {
        RunCheckpointRestoreContent(review: review, stage: stage, loading: model.isReviewing || model.isLoading,
            accepting: model.isActing, canConfirm: model.canApply,
            error: model.restoreError ?? model.restoreUnavailableReason(runID: runID, stage: stage, attemptID: attemptID),
            operation: operation, confirm: confirm, close: close) {
                if let operation { RemoteCheckpointRestoreOperationView(model: model, operation: operation) }
            }
    }
}

struct RemoteRunCheckpointBanner: View {
    var store: RemoteCheckpointStore
    var body: some View {
        if let model = store.current {
            VStack(alignment: .leading, spacing: 8) {
                if let banner = model.projectedBanner {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(banner.title).font(.caption.weight(.semibold))
                        Text(banner.detail).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if banner.canRetry { Button("Retry Current Workspace") { Task { await model.retryPostRun(runID: banner.runID, attemptID: banner.attempt.id) } } }
                            if banner.canContinue { Button("Continue Without Snapshot") { Task { await model.continuePostRun(runID: banner.runID, attemptID: banner.attempt.id) } } }
                        }.disabled(!model.canRead || !model.writesAllowed || !model.mutationsAllowed || model.isActing)
                    }
                }
                ForEach(model.projectedOperations.filter { !$0.acknowledged && $0.phase != "completed" }) { operation in
                    RemoteProjectedOperationCard(operation: operation, enabled: model.canRead && model.writesAllowed && !model.isActing) { action in
                        Task { await model.recover(operation.id, acknowledge: action == .acknowledgeRestore) }
                    }
                }
                if let presentation = model.banner {
                    HStack(alignment: .top, spacing: 8) {
                        if presentation.attempt.phase.isRunning { ProgressView().controlSize(.small) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(presentation.title).font(.caption.weight(.medium))
                            Text(presentation.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if presentation.canResolve {
                        ViewThatFits(in: .horizontal) {
                            HStack { resolutionButtons(model, presentation) }
                            VStack(alignment: .leading, spacing: 6) { resolutionButtons(model, presentation) }
                        }.controlSize(.small).disabled(!model.canRead || !model.writesAllowed || !model.mutationsAllowed || model.isActing)
                    }
                    if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                if let operation = model.operations.first, operation.isPending || operation.phase == .unconfirmed {
                    RemoteCheckpointRestoreOperationView(model: model, operation: operation)
                }
            }.padding(model.banner == nil && model.operations.isEmpty ? 0 : 12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private func resolutionButtons(_ model: RemoteCheckpointWorkspace, _ presentation: RunCheckpointBannerPresentation) -> some View {
        Button("Retry Current Workspace") { Task { await model.retryPostRun(runID: presentation.runID, attemptID: presentation.attempt.id) } }
            .disabled(!presentation.canRetry).help("Capture a later observation on the remote Mac, including saved edits made after this run.")
        Button("Continue Without Snapshot") { Task { await model.continuePostRun(runID: presentation.runID, attemptID: presentation.attempt.id) } }.disabled(!presentation.canContinue)
    }
}

struct RemoteCheckpointRestoreOperationView: View {
    var model: RemoteCheckpointWorkspace
    let operation: RunCheckpointRestoreOperation
    @State private var acknowledging: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                if operation.isPending || model.isActing { ProgressView().controlSize(.small) }
                Text(RunCheckpointRestorePresentation.status(operation)).font(.caption.weight(.medium))
            }
            if let error = operation.error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if operation.isPending { Text("Remote file changes and new agent work are held until restoration finishes.").font(.caption).foregroundStyle(.secondary) }
            if operation.phase == .unconfirmed, operation.acknowledgedAt == nil {
                Text("Files or staging may have changed. Inspection reads saved evidence and never repeats the restore.").font(.caption).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack { recoveryButtons }
                    VStack(alignment: .leading, spacing: 6) { recoveryButtons }
                }.controlSize(.small).disabled(!model.canRead || !model.writesAllowed || model.isActing)
            }
        }
        .confirmationDialog("Keep the current remote files?", isPresented: Binding(get: { acknowledging != nil }, set: { if !$0 { acknowledging = nil } })) {
            if let captured = acknowledging {
                Button("Keep Current Files") { acknowledging = nil; Task { await model.recover(captured, acknowledge: true) } }
            }
            Button("Cancel", role: .cancel) { acknowledging = nil }
        } message: { Text("This releases the hold with the current remote files and staging, which may be partially changed. It does not restore files or repeat the previous action.") }
    }
    @ViewBuilder private var recoveryButtons: some View {
        Button("Inspect Restore State") { Task { await model.recover(operation.id) } }
        Button("Keep Current Files…") { acknowledging = operation.id }
    }
}

struct RemoteProjectedCheckpointHistory: View {
    var model: RemoteCheckpointWorkspace
    let showDiff: (UUID) -> Void
    let restore: (UUID, RunCheckpointStage, UUID) -> Void
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let projection = model.projection {
                    Text("Showing \(projection.runs.count) of \(projection.runCount) runs · \(projection.runsComplete ? "end of history reached" : "more history available")")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.projectedOperations) { operation in
                        RemoteProjectedOperationCard(operation: operation, enabled: model.canRead && model.writesAllowed && !model.isActing) { action in
                            Task { await model.recover(operation.id, acknowledge: action == .acknowledgeRestore) }
                        }
                    }
                    ForEach(model.projectedRuns) { run in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(run.startedAt, style: .date); Text(run.status.rawValue).foregroundStyle(.secondary); Spacer() }
                            Text("\(run.providerName) · \(run.model.preview)").font(.caption).foregroundStyle(.secondary)
                            Text(run.workspacePath).font(.caption).textSelection(.enabled)
                            if run.checkpointDiff.allowed { Button("Show Workspace Changes") { showDiff(run.id) } }
                            ForEach(model.attempts(runID: run.id)) { attempt in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("\(attempt.stage.rawValue) · \(attempt.phase.rawValue)").font(.caption.weight(.medium))
                                        Spacer()
                                        Button("Review Restore…") { restore(run.id, attempt.stage, attempt.id) }
                                            .disabled(model.restoreUnavailableReason(runID: run.id, stage: attempt.stage, attemptID: attempt.id) != nil)
                                    }
                                    if let error = attempt.error { RemoteProjectionPreview(text: error).font(.caption) }
                                    if let reason = attempt.restore.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            if !run.checkpointAttemptsComplete, model.attempts(runID: run.id).count < run.checkpointAttemptCount {
                                Button("Load All \(run.checkpointAttemptCount) Observations") { Task { await model.loadAttempts(runID: run.id) } }
                            }
                        }.padding(12).coincideSurface()
                    }
                    if projection.canLoadRuns { Button("Load More Runs") { Task { await projection.loadMore(.runs) } } }
                    if projection.hasNewerContent || !projection.followsLatest { Button("Follow Latest") { Task { await projection.followLatest() } } }
                }
            }.padding(16)
        }
    }
}
