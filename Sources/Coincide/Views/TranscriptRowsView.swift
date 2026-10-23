import CoincideCore
import CoincideMarkdown
import SwiftUI

struct TranscriptSheetRequest: Identifiable, Equatable {
    enum Action: Equatable { case history(UUID, ConversationHistoryKind), changes(UUID) }
    let source: TranscriptActionSource
    let action: Action
    var id: String { source.threadID.uuidString + "/" + String(source.threadCreatedAt.timeIntervalSince1970) + "/" + String(describing: action) }
}

struct TranscriptSheet: View {
    let store: WorkspaceStore
    let threadID: UUID
    let request: TranscriptSheetRequest
    let close: () -> Void
    var body: some View {
        if threadID == request.source.threadID, store.transcriptSourceIsCurrent(request.source) {
            switch request.action {
            case .history(let run, let kind): ConversationHistoryReviewSheet(store: store, threadID: threadID, runID: run, kind: kind, close: close)
            case .changes(let run): RunCheckpointDiffSheet(store: store, threadID: threadID, runID: run)
            }
        } else {
            VStack(spacing: 12) {
                Text("This conversation changed. Open the action again from its current message.")
                Button("Close", action: close)
            }.padding(24)
        }
    }
}

@MainActor @Observable final class TranscriptViewState {
    @ObservationIgnored private var scopes: [TranscriptCardScope: TranscriptThreadViewState] = [:]
    let cards = TranscriptCardCache()
    func scoped(_ scope: TranscriptCardScope) -> TranscriptThreadViewState {
        if let value = scopes[scope] { return value }
        if scopes.count >= 16 { scopes.removeAll(keepingCapacity: true) }
        let value = TranscriptThreadViewState(); scopes[scope] = value; return value
    }
    static func toggle(_ id: String, in set: inout Set<String>) { if set.contains(id) { set.remove(id) } else { set.insert(id) } }
}

@MainActor @Observable final class TranscriptThreadViewState {
    var expandedFolds: Set<String> = []
    var expandedGroups: Set<String> = []
    var expandedEntries: Set<String> = []
    var expandedUserMessages: Set<String> = []
    var expandedPlans: Set<String> = []
    var changeSummaries: [String: TranscriptChangesLoad] = [:]
    let reasoning = TranscriptReasoningTimer()
    func options(foldCompletedRuns: Bool, search: Set<String>) -> TranscriptLayoutOptions {
        .init(expandedFolds: expandedFolds, expandedGroups: expandedGroups, foldCompletedRuns: foldCompletedRuns, searchExpandedMessageIDs: search)
    }
}

enum TranscriptChangesLoad: Equatable { case loading, loaded([TranscriptFileChange], truncated: Bool), unavailable }

/// Observed timing belongs to this original transcript scope, not provider time.
final class TranscriptReasoningTimer {
    private var spans: [String: (start: Date, end: Date, length: Int)] = [:]
    func observe(_ message: ChatMessage, live: Bool, now: Date = Date()) {
        let key = (message.runReference?.threadID.uuidString ?? "legacy") + "/" + (message.runReference?.runID.uuidString ?? "legacy") + "/" + message.id
        let length = message.text.utf8.count
        if var span = spans[key] {
            guard live, span.length != length else { return }
            span.end = now; span.length = length; spans[key] = span
        } else if live {
            if spans.count >= 4_096 { spans.removeAll(keepingCapacity: true) }
            spans[key] = (now, now, length)
        }
    }
    func duration(_ message: ChatMessage) -> TimeInterval? {
        let key = (message.runReference?.threadID.uuidString ?? "legacy") + "/" + (message.runReference?.runID.uuidString ?? "legacy") + "/" + message.id
        guard let span = spans[key] else { return nil }
        let value = span.end.timeIntervalSince(span.start)
        return value >= 1 ? value : nil
    }
}

struct TranscriptRowsView: View {
    var store: WorkspaceStore
    let thread: CodingThread
    let state: TranscriptViewState
    let present: (TranscriptSheetRequest) -> Void
    @AppStorage(TranscriptPreferences.timestampFormatKey) private var timestampFormat = TranscriptTimestampFormat.system.rawValue
    @AppStorage(TranscriptPreferences.foldCompletedRunsKey) private var foldCompletedRuns = true
    @Environment(MainWindowController.self) private var controller: MainWindowController?
    private var scoped: TranscriptThreadViewState { state.scoped(.init(thread: thread)) }
    private var search: Set<String> { controller?.find.flatMap { $0.threadID == thread.id ? $0.matchedMessageIDs : nil } ?? [] }

    var body: some View {
        let rows = TranscriptLayout.rows(thread: thread, options: scoped.options(foldCompletedRuns: foldCompletedRuns, search: search)) { message, result, context in
            state.cards.card(message, result, context, scope: .init(thread: thread, runID: message.runReference?.runID))
        }
        let _ = observeReasoning(rows)
        ForEach(rows) { row in content(row) }
    }

    private func observeReasoning(_ rows: [TranscriptRow]) {
        guard thread.activeRun != nil else { return }
        for row in rows {
            switch row {
            case .entry(let entry) where entry.isReasoning && entry.runActive: scoped.reasoning.observe(entry.message, live: true)
            case .group(let group): for entry in group.entries where entry.isReasoning && entry.runActive { scoped.reasoning.observe(entry.message, live: true) }
            default: break
            }
        }
    }

    private var workspace: URL { URL(fileURLWithPath: thread.workspacePath) }
    private func openPath(_ url: URL, _ line: Int?) {
        guard store.thread(thread.id).map({ $0.createdAt == thread.createdAt && $0.projectID == thread.projectID && $0.workspacePath.utf8.elementsEqual(thread.workspacePath.utf8) && $0.workspacePreparation?.id == thread.workspacePreparation?.id }) == true,
              store.selectedThreadID == thread.id else { return }
        store.openFile(url, line: line, workspacePath: thread.workspacePath)
    }
    private var timestamps: TranscriptTimestamp { .init(format: .init(rawValue: timestampFormat) ?? .system) }

    @ViewBuilder private func content(_ row: TranscriptRow) -> some View {
        switch row {
        case .message(let message, let meta):
            MessageView(store: store, message: message, providerName: thread.providerName, workspacePath: thread.workspacePath,
                        openFile: openPath, meta: meta, actions: actions(message, meta), userExpanded: binding(message.id, \.expandedUserMessages))
                .id(message.id).threadFindHighlight(message.id)
        case .entry(let entry): entryView(entry)
        case .group(let group):
            TranscriptWorkGroupView(group: group, toggle: { TranscriptViewState.toggle(group.id, in: &scoped.expandedGroups) }) { entry in entryView(entry) }
        case .plan(let entry):
            let source = store.captureTranscriptSource(thread: thread, message: entry.message)
            PlanCardView(plan: entry.card?.plan ?? entry.message.text, workspacePath: thread.workspacePath, expanded: binding(entry.id, \.expandedPlans),
                         canImplement: source.map { store.canImplementTranscriptPlan($0) } ?? false,
                         canImplementInNewConversation: source.map { store.canImplementTranscriptPlanInNewConversation($0) } ?? false,
                         implement: { _ in guard let source else { return false }; return await store.implementTranscriptPlan(source) },
                         implementInNewConversation: { _ in guard let source else { return false }; return await store.implementTranscriptPlanInNewConversation(source) },
                         save: { path, contents in guard let source else { throw CancellationError() }; try await store.saveTranscriptPlan(source, path: path, contents: contents) }, openFile: openPath)
                .id(entry.message.id).threadFindHighlight(entry.message.id)
        case .fold(let fold):
            TurnFoldRow(fold: fold, toggle: { TranscriptViewState.toggle(fold.id, in: &scoped.expandedFolds) })
        case .changes(let changes):
            let key = changesKey(changes)
            TurnChangesFooter(changes: changes, workspacePath: thread.workspacePath, load: scoped.changeSummaries[key],
                              fetch: { await loadChanges(changes) }, viewChanges: changes.checkpointRevision == nil ? nil : {
                                  guard let message = thread.visibleMessages.last(where: { $0.runReference == .init(threadID: thread.id, runID: changes.runID) }),
                                        let source = store.captureTranscriptSource(thread: thread, message: message), store.transcriptSourceIsCurrent(source) else { return }
                                  present(.init(source: source, action: .changes(changes.runID)))
                              }, openFile: openPath).id(key)
        }
    }

    @ViewBuilder private func entryView(_ entry: TranscriptEntry) -> some View {
        let highlighted = entry.result.flatMap { search.contains($0.id) ? $0.id : nil } ?? entry.message.id
        Group {
            if entry.isReasoning {
                ReasoningRowView(text: entry.message.text, live: entry.trailing, duration: scoped.reasoning.duration(entry.message),
                                 expanded: binding(entry.id, \.expandedEntries), workspace: workspace, openFile: openPath)
            } else if let card = entry.card {
                ToolCardView(card: card, entity: entry.message.providerEntity, workspacePath: thread.workspacePath, caption: TranscriptEntryCaption.copilot(entry.message),
                             expanded: binding(entry.id, \.expandedEntries, alternate: entry.result?.id), openFile: openPath)
                    .accessibilityIdentifier("transcript-tool-\(entry.id)")
            }
            if let result = entry.result { Color.clear.frame(height: 0).id(result.id) }
        }.id(entry.message.id).threadFindHighlight(highlighted)
    }

    private func binding(_ id: String, _ path: ReferenceWritableKeyPath<TranscriptThreadViewState, Set<String>>, alternate: String? = nil) -> Binding<Bool> {
        let owner = scoped
        return Binding(get: { owner[keyPath: path].contains(id) || search.contains(id) || alternate.map(search.contains) == true }, set: { value in
            if value { owner[keyPath: path].insert(id) } else { owner[keyPath: path].remove(id) }
        })
    }

    func actions(_ message: ChatMessage, _ meta: TranscriptMessageMeta) -> TranscriptMessageActions {
        var actions = TranscriptMessageActions(timestamps: timestamps)
        guard let runID = meta.runID, message.role != .system, let source = store.captureTranscriptSource(thread: thread, message: message) else { return actions }
        if message.role == .user, meta.opensRun {
            actions.editUnavailableReason = store.conversationHistoryUnavailableReason(threadID: thread.id, runID: runID, kind: .rewindBeforeRun)
            actions.editFromHere = { guard store.transcriptSourceIsCurrent(source) else { return }; present(.init(source: source, action: .history(runID, .rewindBeforeRun))) }
        }
        if message.role == .assistant, meta.terminalResponse {
            actions.forkUnavailableReason = store.conversationHistoryUnavailableReason(threadID: thread.id, runID: runID, kind: .forkAfterRun)
            actions.forkFromHere = { guard store.transcriptSourceIsCurrent(source) else { return }; present(.init(source: source, action: .history(runID, .forkAfterRun))) }
            if meta.canShowChanges { actions.viewChanges = { guard store.transcriptSourceIsCurrent(source) else { return }; present(.init(source: source, action: .changes(runID))) } }
        }
        return actions
    }

    private func changesKey(_ changes: TranscriptTurnChanges) -> String { changes.runID.uuidString + "/" + (changes.checkpointRevision ?? "tools") }
    private func changesCurrent(_ changes: TranscriptTurnChanges) -> Bool {
        guard !Task.isCancelled, let current = store.thread(thread.id), current.createdAt == thread.createdAt,
              current.projectID == thread.projectID, current.workspacePath.utf8.elementsEqual(thread.workspacePath.utf8),
              current.workspacePreparation?.id == thread.workspacePreparation?.id else { return false }
        guard let run = current.activeHistoryRuns.first(where: { $0.id == changes.runID }), run.status.isTerminal,
              current.activeRun?.id != changes.runID, let checkpoints = run.checkpoints,
              TranscriptLayout.canShowDiff(checkpoints), let post = checkpoints.postRun else { return false }
        return changes.checkpointRevision == checkpoints.baseline.id.uuidString + ":" + post.id.uuidString
    }
    private func loadChanges(_ changes: TranscriptTurnChanges) async {
        let owner = scoped, key = changesKey(changes)
        guard changes.checkpointRevision != nil, changesCurrent(changes), owner.changeSummaries[key] == nil || owner.changeSummaries[key] == .unavailable else { return }
        if owner.changeSummaries.count >= 256 { owner.changeSummaries.removeAll(keepingCapacity: true) }
        owner.changeSummaries[key] = .loading
        do {
            let diff = try await store.runCheckpointDiff(threadID: thread.id, runID: changes.runID, maxBytes: 262_144)
            try Task.checkCancellation()
            let parsing = Task.detached(priority: .utility) { TranscriptPatch.parse(diff.patch) ?? [] }
            let files = await withTaskCancellationHandler { await parsing.value } onCancel: { parsing.cancel() }
            guard changesCurrent(changes) else { owner.changeSummaries.removeValue(forKey: key); return }
            owner.changeSummaries[key] = .loaded(files, truncated: diff.truncated)
        } catch {
            if Task.isCancelled || !changesCurrent(changes) { owner.changeSummaries.removeValue(forKey: key) }
            else { owner.changeSummaries[key] = .unavailable }
        }
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
