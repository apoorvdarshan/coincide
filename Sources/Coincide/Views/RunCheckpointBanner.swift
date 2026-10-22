import CoincideCore
import SwiftUI

struct RunCheckpointBanner: View {
    let store: WorkspaceStore
    let threadID: UUID
    @State private var actionError: String?

    var body: some View {
        if let thread = store.thread(threadID), let presentation = RunCheckpointPresentation.banner(in: thread) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    if presentation.attempt.phase.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(presentation.title).font(.caption.weight(.medium))
                            .accessibilityIdentifier("run-checkpoint-status")
                        Text(presentation.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if presentation.canResolve {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            retry(presentation)
                            continueWithout(presentation)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            retry(presentation)
                            continueWithout(presentation)
                        }
                    }
                    .controlSize(.small)
                    .disabled(store.isRespondingToPostRunCheckpoint(presentation.attempt.id))
                }
                if let actionError {
                    Text(actionError).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("run-checkpoint")
            .onChange(of: presentation.attempt.id) { actionError = nil }
        }
    }

    private func retry(_ presentation: RunCheckpointBannerPresentation) -> some View {
        Button("Retry Current Workspace") {
            perform(attemptID: presentation.attempt.id) {
                try await store.retryPostRunCheckpoint(threadID: threadID, runID: presentation.runID,
                                                       expectedAttemptID: presentation.attempt.id)
            }
        }.disabled(!presentation.canRetry).accessibilityIdentifier("run-checkpoint-retry")
            .help("Save a later observation of the current workspace. It may include changes made after the run ended.")
    }

    private func continueWithout(_ presentation: RunCheckpointBannerPresentation) -> some View {
        Button("Continue Without Snapshot") {
            perform(attemptID: presentation.attempt.id) {
                try await store.continueAfterPostRunCheckpoint(threadID: threadID, runID: presentation.runID,
                                                               expectedAttemptID: presentation.attempt.id)
            }
        }.disabled(!presentation.canContinue).accessibilityIdentifier("run-checkpoint-continue")
    }

    private func perform(attemptID: UUID, _ operation: @escaping @MainActor () async throws -> Void) {
        actionError = nil
        Task {
            do { try await operation() }
            catch is CancellationError { }
            catch {
                guard store.thread(threadID)?.heldPostRunCheckpoint?.attempt.id == attemptID else { return }
                actionError = String(localized: "The snapshot state changed. Review its current status before trying again.")
            }
        }
    }
}

struct RunCheckpointBannerPresentation {
    let runID: UUID
    let attempt: ThreadRunCheckpointAttempt
    let title: String
    let detail: String
    let canRetry: Bool
    let canContinue: Bool
    var canResolve: Bool { canRetry || canContinue }
}

enum RunCheckpointPresentation {
    static func preparingBaseline(in thread: CodingThread) -> Bool {
        guard let active = thread.activeRun,
              let checkpoints = thread.runHistory?.first(where: { $0.id == active.id })?.checkpoints else { return false }
        return !checkpoints.providerReleased && checkpoints.baseline.phase.isRunning
    }

    static func banner(in thread: CodingThread) -> RunCheckpointBannerPresentation? {
        if let held = thread.heldPostRunCheckpoint {
            let running = held.attempt.phase.isRunning
            return .init(runID: held.runID, attempt: held.attempt,
                         title: running ? String(localized: "Saving workspace snapshot…") : String(localized: "Workspace snapshot needs attention"),
                         detail: running
                            ? String(localized: "Queued messages are waiting until this snapshot finishes.")
                            : String(localized: "Queued messages are waiting. Retry saves a later observation of the current workspace, including any newer edits."),
                         canRetry: held.attempt.canRetryPostRun && !thread.isArchived,
                         canContinue: held.attempt.canContinuePostRun && !thread.isArchived)
        }
        guard let active = thread.activeRun,
              let checkpoints = thread.runHistory?.first(where: { $0.id == active.id })?.checkpoints else { return nil }
        let baseline = checkpoints.baseline
        if preparingBaseline(in: thread) {
            return .init(runID: active.id, attempt: baseline, title: String(localized: "Preparing workspace snapshot…"),
                         detail: String(localized: "Agent work begins after this snapshot attempt finishes."), canRetry: false, canContinue: false)
        }
        if baseline.phase == .failed || baseline.phase == .interrupted || baseline.phase == .unavailable {
            return .init(runID: active.id, attempt: baseline, title: String(localized: "Before-run snapshot unavailable"),
                         detail: String(localized: "Agent work can continue. This run may not have a complete workspace comparison."), canRetry: false, canContinue: false)
        }
        return nil
    }

    static func status(_ attempt: ThreadRunCheckpointAttempt) -> String {
        switch attempt.phase {
        case .resolving, .capturing: String(localized: "Saving…")
        case .ready: String(localized: "Saved")
        case .unavailable:
            switch attempt.unavailableReason {
            case .notRepository: String(localized: "Git workspace unavailable")
            case .agentInitiated: String(localized: "Agent-initiated run")
            case .failedRun: String(localized: "Run did not complete")
            case .unknownExit: String(localized: "Run outcome unknown")
            case .providerNotStarted: String(localized: "Agent did not start")
            case nil: String(localized: "Unavailable")
            }
        case .failed: String(localized: "Could not save")
        case .interrupted: String(localized: "Interrupted")
        case .skipped: String(localized: "Continued without snapshot")
        }
    }

    static func canShowDiff(_ checkpoints: ThreadRunCheckpoints) -> Bool {
        checkpoints.baseline.phase == .ready && checkpoints.baseline.receipt != nil &&
            checkpoints.postRun?.phase == .ready && checkpoints.postRun?.receipt != nil
    }
}
