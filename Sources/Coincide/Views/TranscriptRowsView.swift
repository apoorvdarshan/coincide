import CoincideCore
import CoincideMarkdown
import SwiftUI

/// A transcript action that opens an existing reviewed flow: rewind/fork
/// through Run History's review sheet, or a run's checkpoint diff.
enum TranscriptSheetRequest: Identifiable, Equatable {
    case history(UUID, ConversationHistoryKind), changes(UUID)
    var id: String {
        switch self {
        case .history(let run, let kind): (kind == .forkAfterRun ? "fork-" : "rewind-") + run.uuidString
        case .changes(let run): "changes-" + run.uuidString
        }
    }
}

struct TranscriptSheet: View {
    let store: WorkspaceStore
    let threadID: UUID
    let request: TranscriptSheetRequest
    let close: () -> Void
    var body: some View {
        switch request {
        case .history(let run, let kind): ConversationHistoryReviewSheet(store: store, threadID: threadID, runID: run, kind: kind, close: close)
        case .changes(let run): RunCheckpointDiffSheet(store: store, threadID: threadID, runID: run)
        }
    }
}

/// Per-thread view state. Keys are message, group and run identities, so one
/// instance can outlive a thread switch without leaking expansion.
@MainActor @Observable final class TranscriptViewState {
    var expandedFolds: Set<String> = []
    var expandedGroups: Set<String> = []
    var expandedEntries: Set<String> = []
    var expandedUserMessages: Set<String> = []
    var expandedPlans: Set<String> = []
    var changeSummaries: [String: TranscriptChangesLoad] = [:]
    let cards = TranscriptCardCache()
    let reasoning = TranscriptReasoningTimer()
    func options(foldCompletedRuns: Bool) -> TranscriptLayoutOptions {
        .init(expandedFolds: expandedFolds, expandedGroups: expandedGroups, foldCompletedRuns: foldCompletedRuns)
    }
    static func toggle(_ id: String, in set: inout Set<String>) { if set.contains(id) { set.remove(id) } else { set.insert(id) } }
}

enum TranscriptChangesLoad: Equatable { case loading, loaded([TranscriptFileChange], truncated: Bool), unavailable }

/// Cards are derived once per message revision. A cheap fingerprint (lengths,
/// entity status and field counts) avoids re-parsing tool JSON on every token.
final class TranscriptCardCache {
    private struct Key: Hashable { var id: String; var context: TranscriptToolContext }
    private struct Fingerprint: Equatable {
        var text: Int, result: Int?, status: String?, fields: Int, content: Int, input: Bool, output: Bool, entity: String?
    }
    private var values: [Key: (Fingerprint, TranscriptToolCard)] = [:]
    func card(_ message: ChatMessage, _ result: ChatMessage?, _ context: TranscriptToolContext) -> TranscriptToolCard {
        let fields = message.providerEntity?.fields
        let print = Fingerprint(text: message.text.utf8.count, result: result?.text.utf8.count, status: fields?["status"].string,
                                fields: fields?.object?.count ?? 0, content: fields?["content"].array?.count ?? 0,
                                input: fields?["rawInput"] != .null && fields != nil, output: fields?["rawOutput"] != .null && fields != nil,
                                entity: message.providerEntity?.key.type)
        let key = Key(id: message.id, context: context)
        if let cached = values[key], cached.0 == print { return cached.1 }
        if values.count > 8_192 { values.removeAll(keepingCapacity: true) }
        let card = TranscriptToolPresentation.card(for: message, result: result, context: context)
        values[key] = (print, card)
        return card
    }
}

/// Reasoning rows carry no provider timing. While the app observes a live run it
/// records when each reasoning row first appeared and when its text last grew;
/// after a restart the row reads "Thought" without a duration.
final class TranscriptReasoningTimer {
    private var spans: [String: (start: Date, end: Date, length: Int)] = [:]
    func observe(_ message: ChatMessage, live: Bool, now: Date = Date()) {
        let length = message.text.utf8.count
        if var span = spans[message.id] {
            guard live, span.length != length else { return }
            span.end = now; span.length = length; spans[message.id] = span
        } else if live {
            if spans.count > 4_096 { spans.removeAll(keepingCapacity: true) }
            spans[message.id] = (now, now, length)
        }
    }
    func duration(_ id: String) -> TimeInterval? {
        guard let span = spans[id] else { return nil }
        let value = span.end.timeIntervalSince(span.start)
        return value >= 1 ? value : nil
    }
}

/// Replaces the flat message list: tool cards, work log groups, turn folds,
/// plan cards, per-message actions and changed-files footers. The body is a
/// `ForEach`, so rows stay lazy inside the conversation's `LazyVStack`.
struct TranscriptRowsView: View {
    var store: WorkspaceStore
    let thread: CodingThread
    let state: TranscriptViewState
    let present: (TranscriptSheetRequest) -> Void
    @AppStorage(TranscriptPreferences.timestampFormatKey) private var timestampFormat = TranscriptTimestampFormat.system.rawValue
    @AppStorage(TranscriptPreferences.foldCompletedRunsKey) private var foldCompletedRuns = true

    var body: some View {
        let rows = TranscriptLayout.rows(thread: thread, options: state.options(foldCompletedRuns: foldCompletedRuns), card: state.cards.card)
        let _ = observeReasoning(rows)
        ForEach(rows) { row in content(row) }
    }

    /// Live reasoning is timed even while its work group is collapsed.
    private func observeReasoning(_ rows: [TranscriptRow]) {
        guard thread.activeRun != nil else { return }
        for row in rows.reversed() {
            switch row {
            case .entry(let entry) where entry.isReasoning && entry.runActive: state.reasoning.observe(entry.message, live: true)
            case .group(let group): for entry in group.entries where entry.isReasoning && entry.runActive { state.reasoning.observe(entry.message, live: true) }
            case .message(let message, _) where message.role == .user && message.runReference?.runID != thread.activeRun?.id: return
            default: break
            }
        }
    }

    private var workspace: URL { URL(fileURLWithPath: thread.workspacePath) }
    private func openPath(_ url: URL, _ line: Int?) { store.openFile(url, line: line, workspacePath: thread.workspacePath) }
    private var timestamps: TranscriptTimestamp { .init(format: .init(rawValue: timestampFormat) ?? .system) }

    @ViewBuilder private func content(_ row: TranscriptRow) -> some View {
        switch row {
        case .message(let message, let meta):
            MessageView(store: store, message: message, providerName: thread.providerName, workspacePath: thread.workspacePath,
                        openFile: openPath, meta: meta, actions: actions(message, meta), userExpanded: binding(message.id, \.expandedUserMessages))
        case .entry(let entry): entryView(entry)
        case .group(let group):
            TranscriptWorkGroupView(group: group, toggle: { TranscriptViewState.toggle(group.id, in: &state.expandedGroups) }) { entry in entryView(entry) }
        case .plan(let entry):
            PlanCardView(plan: entry.card?.plan ?? entry.message.text, workspacePath: thread.workspacePath, expanded: binding(entry.id, \.expandedPlans),
                         canImplement: thread.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !thread.isSettled,
                         implement: implementPlan,
                         save: { path, contents in try await savePlan(path: path, contents: contents) }, openFile: openPath)
        case .fold(let fold):
            TurnFoldRow(fold: fold, toggle: { TranscriptViewState.toggle(fold.id, in: &state.expandedFolds) })
        case .changes(let changes):
            TurnChangesFooter(changes: changes, workspacePath: thread.workspacePath, load: state.changeSummaries[changes.checkpointRevision ?? ""],
                              fetch: { await loadChanges(changes) }, viewChanges: changes.checkpointRevision == nil ? nil : { present(.changes(changes.runID)) }, openFile: openPath)
        }
    }

    @ViewBuilder private func entryView(_ entry: TranscriptEntry) -> some View {
        if entry.isReasoning {
            ReasoningRowView(text: entry.message.text, live: entry.trailing, duration: state.reasoning.duration(entry.id),
                             expanded: binding(entry.id, \.expandedEntries), workspace: workspace, openFile: openPath)
        } else if let card = entry.card {
            ToolCardView(card: card, entity: entry.message.providerEntity, workspacePath: thread.workspacePath, caption: TranscriptEntryCaption.copilot(entry.message),
                         expanded: binding(entry.id, \.expandedEntries), openFile: openPath)
                .accessibilityIdentifier("transcript-tool-\(entry.id)")
        }
    }

    private func binding(_ id: String, _ path: ReferenceWritableKeyPath<TranscriptViewState, Set<String>>) -> Binding<Bool> {
        Binding(get: { state[keyPath: path].contains(id) }, set: { value in
            if value { state[keyPath: path].insert(id) } else { state[keyPath: path].remove(id) }
        })
    }

    /// Fills the composer draft only; nothing is sent.
    func implementPlan(_ plan: String) { store.setDraft(TranscriptPlanText.implementationPrompt(plan), id: thread.id) }

    func actions(_ message: ChatMessage, _ meta: TranscriptMessageMeta) -> TranscriptMessageActions {
        var actions = TranscriptMessageActions(timestamps: timestamps)
        guard let runID = meta.runID, message.role != .system else { return actions }
        if message.role == .user, meta.opensRun {
            actions.editUnavailableReason = store.conversationHistoryUnavailableReason(threadID: thread.id, runID: runID, kind: .rewindBeforeRun)
            actions.editFromHere = { present(.history(runID, .rewindBeforeRun)) }
        }
        if message.role == .assistant, meta.terminalResponse {
            actions.forkUnavailableReason = store.conversationHistoryUnavailableReason(threadID: thread.id, runID: runID, kind: .forkAfterRun)
            actions.forkFromHere = { present(.history(runID, .forkAfterRun)) }
            if meta.canShowChanges { actions.viewChanges = { present(.changes(runID)) } }
        }
        return actions
    }

    private func loadChanges(_ changes: TranscriptTurnChanges) async {
        guard let revision = changes.checkpointRevision, state.changeSummaries[revision] == nil || state.changeSummaries[revision] == .unavailable else { return }
        state.changeSummaries[revision] = .loading
        do {
            let diff = try await store.runCheckpointDiff(threadID: thread.id, runID: changes.runID, maxBytes: 262_144)
            let patch = diff.patch
            let files = await Task.detached(priority: .utility) { TranscriptPatch.parse(patch) ?? [] }.value
            state.changeSummaries[revision] = .loaded(files, truncated: diff.truncated)
        } catch { state.changeSummaries[revision] = .unavailable }
    }

    private func savePlan(path: String, contents: String) async throws {
        guard store.canEditWorkspace(thread.workspacePath) else { throw CoincideError(String(localized: "This workspace is not available for changes right now.")) }
        let service = try store.fileService(path: thread.workspacePath)
        _ = try await service.writeFile(relativePath: path, contents: contents, expected: .missing)
    }
}

enum TranscriptPreferences {
    static let timestampFormatKey = "transcriptTimestampFormat"
    static let foldCompletedRunsKey = "transcriptFoldCompletedRuns"
}

enum TranscriptEntryCaption {
    /// Copilot child activity names the background task that produced it.
    static func copilot(_ message: ChatMessage) -> String? {
        guard let owner = message.runReference, let metadata = message.providerEntity?.fields["_meta"]["github.com/copilot"],
              metadata["parentRunID"].string == owner.runID.uuidString, metadata["parentToolCallId"].string != nil else { return nil }
        return String(localized: "Copilot task · \(metadata["taskTitle"].string ?? String(localized: "Background task"))")
    }
}

/// The working row under an active run, with T3's live elapsed time.
struct TranscriptWorkingIndicator: View {
    let thread: CodingThread
    var body: some View {
        if thread.state == .running || thread.state == .awaitingApproval {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(RunCheckpointPresentation.preparingBaseline(in: thread)
                     ? String(localized: "Preparing workspace snapshot…")
                     : thread.state == .awaitingApproval ? String(localized: "Waiting for input…")
                     : thread.providerActivity?.state == .idle ? String(localized: "Waiting for agent confirmation…")
                     : String(localized: "\(thread.providerName) is working…"))
                    .font(.caption).foregroundStyle(.secondary)
                if let start = thread.activeRun?.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text(TranscriptDuration.elapsed(context.date.timeIntervalSince(start)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            .accessibilityLabel(String(localized: "Elapsed \(TranscriptDuration.elapsed(context.date.timeIntervalSince(start)))"))
                    }
                }
            }.accessibilityElement(children: .combine).accessibilityIdentifier("transcript-working")
        }
    }
}
