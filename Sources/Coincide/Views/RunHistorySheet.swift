import CoincideCore
import SwiftUI

struct RunHistorySheet: View {
    let store: WorkspaceStore
    let threadID: UUID
    @State private var sheet: RunHistorySheetRequest?

    var body: some View {
        RunHistoryContent(thread: store.thread(threadID), showWorkspaceChanges: { sheet = .diff($0) },
                          historyAction: { sheet = .history($0, $1) },
                          historyUnavailableReason: { store.conversationHistoryUnavailableReason(threadID: threadID, runID: $0, kind: $1) },
                          restoreAction: { sheet = .restore($0, $1, $2) },
                          restoreUnavailableReason: { store.checkpointRestoreUnavailableReason(threadID: threadID, runID: $0, stage: $1, expectedAttemptID: $2) },
                          restoreOperations: store.checkpointRestoreOperations(threadID: threadID),
                          restoreOperationView: { AnyView(RunCheckpointRestoreOperationView(store: store, operation: $0)) },
                          operations: store.conversationHistoryOperations(threadID: threadID),
                          operationView: { AnyView(ConversationHistoryOperationView(store: store, operation: $0)) })
            .sheet(item: $sheet) { request in
                switch request {
                case .diff(let id): RunCheckpointDiffSheet(store: store, threadID: threadID, runID: id, restoreAction: { sheet = .restore(id, $0, $1) })
                case .restore(let run, let stage, let attempt):
                    RunCheckpointRestoreSheet(store: store, threadID: threadID, runID: run, stage: stage, attemptID: attempt, close: { sheet = nil })
                case .history(let id, let kind):
                    ConversationHistoryReviewSheet(store: store, threadID: threadID, runID: id, kind: kind, close: { sheet = nil })
                }
            }
    }
}

private enum RunHistorySheetRequest: Identifiable {
    case diff(UUID), history(UUID, ConversationHistoryKind), restore(UUID, RunCheckpointStage, UUID)
    var id: String {
        switch self {
        case .diff(let id): "diff-" + id.uuidString
        case .restore(_, _, let id): "restore-" + id.uuidString
        case .history(let id, let kind): (kind == .forkAfterRun ? "fork-" : "rewind-") + id.uuidString
        }
    }
}

struct RunHistoryContent: View {
    let thread: CodingThread?
    var showWorkspaceChanges: ((UUID) -> Void)? = nil
    var historyAction: ((UUID, ConversationHistoryKind) -> Void)? = nil
    var historyUnavailableReason: ((UUID, ConversationHistoryKind) -> String?)? = nil
    var restoreAction: ((UUID, RunCheckpointStage, UUID) -> Void)? = nil
    var restoreUnavailableReason: ((UUID, RunCheckpointStage, UUID) -> String?)? = nil
    var restoreOperations: [RunCheckpointRestoreOperation] = []
    var restoreOperationView: ((RunCheckpointRestoreOperation) -> AnyView)? = nil
    var operations: [ConversationHistoryOperation] = []
    var operationView: ((ConversationHistoryOperation) -> AnyView)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Run History").font(.title2)
                if let thread {
                    Text(thread.title).foregroundStyle(.secondary).lineLimit(2)
                }
            }.padding(20)
            Divider()
            ScrollView {
                if let thread {
                    history(thread)
                } else {
                    ContentUnavailableView("Conversation unavailable", systemImage: "bubble.left",
                                           description: Text("This conversation is no longer in the workspace."))
                        .padding(20)
                }
            }.frame(minHeight: 180, idealHeight: 360, maxHeight: 420)
                .accessibilityIdentifier("run-history-records")
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("run-history-done")
            }.padding(16)
        }
        .frame(minWidth: 320, idealWidth: 560, maxWidth: 680)
        .onExitCommand { dismiss() }
        .accessibilityIdentifier("run-history")
    }

    @ViewBuilder private func history(_ thread: CodingThread) -> some View {
        let records = RunHistoryPresentation.records(in: thread)
        if records.isEmpty {
            ContentUnavailableView("No recorded runs", systemImage: "clock",
                                   description: Text(RunHistoryPresentation.emptyDescription(thread)))
                .padding(20)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let restoreOperationView, !restoreOperations.isEmpty {
                    DisclosureGroup("File restorations") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(restoreOperations) { operation in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(operation.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                    restoreOperationView(operation)
                                }
                            }
                        }.padding(.top, 8)
                    }.font(.caption).padding(.top, 14)
                }
                if let operationView, !operations.isEmpty {
                    DisclosureGroup("Conversation changes") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(operations) { operation in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(operation.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                    operationView(operation)
                                }
                            }
                        }.padding(.top, 8)
                    }.font(.caption).padding(.top, 14)
                }
                if RunHistoryPresentation.hasUnrecordedMessages(in: thread) {
                    Text("Some messages do not include recorded run details.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14).padding(.bottom, 4)
                        .accessibilityIdentifier("run-history-incomplete")
                }
                ForEach(records) { record in
                    RunHistoryRow(record: record, thread: thread, showWorkspaceChanges: showWorkspaceChanges,
                                  historyAction: historyAction, restoreAction: restoreAction, restoreUnavailableReason: restoreUnavailableReason,
                                  forkUnavailableReason: historyUnavailableReason?(record.id, .forkAfterRun),
                                  rewindUnavailableReason: historyUnavailableReason?(record.id, .rewindBeforeRun)).padding(.vertical, 14)
                    Divider()
                }
            }.padding(.horizontal, 20)
        }
    }
}

private struct RunHistoryRow: View {
    let record: ThreadRunRecord
    let thread: CodingThread
    let showWorkspaceChanges: ((UUID) -> Void)?
    let historyAction: ((UUID, ConversationHistoryKind) -> Void)?
    let restoreAction: ((UUID, RunCheckpointStage, UUID) -> Void)?
    let restoreUnavailableReason: ((UUID, RunCheckpointStage, UUID) -> String?)?
    let forkUnavailableReason: String?
    let rewindUnavailableReason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Label(RunHistoryPresentation.status(record.status), systemImage: RunHistoryPresentation.symbol(record.status))
                    .font(.callout.weight(.medium))
                    .accessibilityIdentifier("run-history-status-\(record.id)")
                Spacer(minLength: 8)
                Text(record.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(RunHistoryPresentation.prompt(record, in: thread))
                .font(.callout).lineLimit(3).textSelection(.enabled)
            Text("\(RunHistoryPresentation.provider(record.configuration)) · \(RunHistoryPresentation.model(record.configuration))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            if RunHistoryPresentation.hasSavedAgentOptions(record.configuration) {
                Text("Saved agent options").font(.caption).foregroundStyle(.secondary)
            }
            Text(record.configuration.workspacePath).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                .accessibilityIdentifier("run-history-workspace-\(record.id)")
            if record.stopRequested {
                Text("Stop requested").font(.caption).foregroundStyle(.secondary)
            }
            if record.removedByHistoryOperationID != nil {
                Text("Removed from the current conversation by a rewind").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("run-history-removed-\(record.id)")
            }
            if let historyAction {
                Menu("Conversation") {
                    Button("Fork After This Run…") { historyAction(record.id, .forkAfterRun) }
                        .disabled(forkUnavailableReason != nil)
                        .help(forkUnavailableReason ?? String(localized: "Create a separate conversation through this completed run."))
                        .accessibilityIdentifier("run-history-fork-\(record.id)")
                    Button("Rewind Before This Run…") { historyAction(record.id, .rewindBeforeRun) }
                        .disabled(rewindUnavailableReason != nil)
                        .help(rewindUnavailableReason ?? String(localized: "Rewind conversation context before this run. Workspace files stay unchanged."))
                        .accessibilityIdentifier("run-history-rewind-\(record.id)")
                }.menuStyle(.borderlessButton).fixedSize().font(.caption)
                    .accessibilityIdentifier("run-history-actions-\(record.id)")
                    .disabled(forkUnavailableReason != nil && rewindUnavailableReason != nil)
                if let unavailableReason = rewindUnavailableReason ?? forkUnavailableReason {
                    Text(unavailableReason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let checkpoints = record.checkpoints {
                checkpointSummary(checkpoints)
            }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Origin", value: RunHistoryPresentation.origin(record.origin))
                    LabeledContent("Provider", value: RunHistoryPresentation.provider(record.configuration))
                    LabeledContent("Model", value: RunHistoryPresentation.model(record.configuration))
                    if record.configuration.provider == .codex, let effort = record.configuration.reasoningEffort {
                        LabeledContent("Reasoning", value: ReasoningEffortPresentation.title(effort))
                    }
                    LabeledContent("Permissions") { Text(LocalizedStringKey(record.configuration.permission.title)) }
                    if let mode = record.configuration.agentModeID, !mode.isEmpty {
                        LabeledContent("Agent mode", value: mode)
                    }
                    LabeledContent("Started") {
                        Text(record.startedAt, format: .dateTime.year().month(.abbreviated).day().hour().minute().second())
                    }
                    if let endedAt = record.endedAt {
                        LabeledContent("Ended") {
                            Text(endedAt, format: .dateTime.year().month(.abbreviated).day().hour().minute().second())
                        }
                    }
                    if let reason = record.endReason {
                        LabeledContent("Outcome", value: RunHistoryPresentation.reason(reason))
                    }
                    if let reason = record.providerStopReason, !reason.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Provider stop reason").foregroundStyle(.secondary)
                            Text(reason).textSelection(.enabled)
                        }
                    }
                    Text(record.configuration.workspacePath).font(.caption.monospaced())
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityLabel("Captured workspace")
                    if record.origin == .user {
                        Text(RunHistoryPresentation.prompt(record, in: thread))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    references
                }.font(.caption).padding(.top, 8)
            }.font(.caption)
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain).accessibilityIdentifier("run-history-record-\(record.id)")
    }

    private func checkpointSummary(_ checkpoints: ThreadRunCheckpoints) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            LabeledContent("Before run", value: RunCheckpointPresentation.status(checkpoints.baseline))
            if let postRun = checkpoints.postRun {
                LabeledContent("After run", value: RunCheckpointPresentation.status(postRun))
                if postRun.isLaterObservation {
                    Text("Later observation of the current workspace. It may include edits made after the run ended.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("run-history-later-observation-\(record.id)")
                }
            } else if !record.status.isTerminal {
                LabeledContent("After run", value: String(localized: "Waiting for run to end"))
            }
            if !checkpoints.previousPostRunAttempts.isEmpty {
                DisclosureGroup("Earlier snapshot attempts") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(checkpoints.previousPostRunAttempts) { attempt in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(RunCheckpointPresentation.status(attempt))
                                    Spacer(minLength: 8)
                                    Text(attempt.requestedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .foregroundStyle(.secondary)
                                }
                                if attempt.isLaterObservation {
                                    Text("Later workspace observation").foregroundStyle(.secondary)
                                }
                                if attempt.phase == .ready, attempt.receipt != nil, let restoreAction {
                                    restoreButton(attempt, stage: .postRun, action: restoreAction)
                                }
                                if attempt.cleanupWarning != nil {
                                    Text("Some temporary checkpoint data was preserved.")
                                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }.padding(.top, 5)
                }
            }
            if checkpoints.baseline.cleanupWarning != nil || checkpoints.postRun?.cleanupWarning != nil {
                Text("Some temporary checkpoint data was preserved.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let restoreAction {
                ForEach(RunCheckpointRestorePresentation.targets(record)) { target in
                    restoreButton(target.attempt, stage: target.stage, action: restoreAction)
                }
            }
            if RunCheckpointPresentation.canShowDiff(checkpoints), let showWorkspaceChanges {
                Button("Workspace Changes…") { showWorkspaceChanges(record.id) }
                    .accessibilityIdentifier("run-history-changes-\(record.id)")
            }
        }.font(.caption)
            .accessibilityIdentifier("run-history-checkpoints-\(record.id)")
    }

    private func restoreButton(_ attempt: ThreadRunCheckpointAttempt, stage: RunCheckpointStage, action: @escaping (UUID, RunCheckpointStage, UUID) -> Void) -> some View {
        let reason = restoreUnavailableReason?(record.id, stage, attempt.id)
        return Button(RunCheckpointRestorePresentation.target(stage: stage, later: attempt.isLaterObservation)) { action(record.id, stage, attempt.id) }
            .disabled(reason != nil).help(reason ?? String(localized: "Review replacement of the current workspace files and staging."))
            .accessibilityIdentifier("run-history-restore-\(attempt.id)")
    }

    private var references: some View {
        DisclosureGroup("Recorded references") {
            VStack(alignment: .leading, spacing: 5) {
                Text("Session and turn references may be supplied by an adapter.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LabeledContent("Run", value: record.id.uuidString)
                if let session = record.providerThreadID, !session.isEmpty {
                    LabeledContent("Session", value: session)
                }
                ForEach(record.turnIDs, id: \.self) { reference in
                    LabeledContent("Turn", value: reference)
                }
            }.textSelection(.enabled).padding(.top, 5)
        }
    }
}

enum RunHistoryPresentation {
    static func records(in thread: CodingThread) -> [ThreadRunRecord] {
        Array((thread.runHistory ?? []).reversed())
    }

    static func hasUnrecordedMessages(in thread: CodingThread) -> Bool {
        let recorded = Set((thread.runHistory ?? []).compactMap(\.userMessageID))
        return thread.messages.contains { $0.role == .user && !recorded.contains($0.id) }
    }

    static func emptyDescription(_ thread: CodingThread) -> String {
        thread.messages.isEmpty
            ? String(localized: "Runs will appear here after a message starts a coding agent.")
            : String(localized: "Earlier messages do not include recorded run details.")
    }

    static func prompt(_ record: ThreadRunRecord, in thread: CodingThread) -> String {
        switch record.origin {
        case .agent: return String(localized: "Agent-initiated run")
        case .legacy: return String(localized: "Earlier run — original prompt not recorded")
        case .user:
            guard let id = record.userMessageID,
                  let message = thread.messages.first(where: { $0.id == id && $0.role == .user }) else {
                return String(localized: "User message unavailable")
            }
            if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message.attachments?.isEmpty == false
                    ? String(localized: "Message with attachments") : String(localized: "Empty user message")
            }
            return message.text
        }
    }

    static func provider(_ configuration: ProviderConfiguration) -> String {
        configuration.provider == .acp ? configuration.acpAgent?.name ?? configuration.provider.name : configuration.provider.name
    }
    static func model(_ configuration: ProviderConfiguration) -> String {
        guard configuration.model.isEmpty else { return configuration.model }
        return hasSavedAgentOptions(configuration)
            ? String(localized: "Agent-managed model") : String(localized: "Default model")
    }
    static func hasSavedAgentOptions(_ configuration: ProviderConfiguration) -> Bool {
        configuration.provider == .acp &&
            (configuration.agentConfiguration?.isEmpty == false || configuration.agentConfigValues?.isEmpty == false)
    }
    static func origin(_ origin: ThreadRunOrigin) -> String {
        switch origin {
        case .user: String(localized: "User message")
        case .agent: String(localized: "Agent initiated")
        case .legacy: String(localized: "Earlier session")
        }
    }
    static func status(_ status: ThreadRunStatus) -> String {
        switch status {
        case .running: String(localized: "Running")
        case .awaitingApproval: String(localized: "Waiting for approval")
        case .completed: String(localized: "Completed")
        case .interrupted: String(localized: "Interrupted")
        case .failed: String(localized: "Failed")
        case .unknown: String(localized: "Outcome unknown")
        }
    }
    static func symbol(_ status: ThreadRunStatus) -> String {
        switch status {
        case .running: "play.circle"
        case .awaitingApproval: "hand.raised"
        case .completed: "checkmark.circle"
        case .interrupted: "pause.circle"
        case .failed: "exclamationmark.circle"
        case .unknown: "questionmark.circle"
        }
    }
    static func reason(_ reason: ThreadRunEndReason) -> String {
        switch reason {
        case .providerCompleted: String(localized: "Provider reported turn completion")
        case .providerActivity: String(localized: "Provider activity ended")
        case .providerFailure: String(localized: "Provider reported a failure")
        case .connectionLost: String(localized: "Provider connection closed")
        case .startFailed: String(localized: "Provider could not start")
        case .forcedStop: String(localized: "Forced stop")
        case .applicationClosed: String(localized: "App closed during the run")
        }
    }
}
