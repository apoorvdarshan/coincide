import CoincideCore
import CryptoKit
import Foundation
import Observation
import SwiftUI

/// Presentation-only messages. No thread, run configuration, native proof or
/// local file access is manufactured from the paged transcript.
struct RemoteTranscriptEntry {
    let presentation: RemoteTranscriptMessagePresentation
    let sourceText: String?
    let byteCount: Int
    var message: ChatMessage {
        var value = ChatMessage(id: presentation.messageID, role: presentation.role, text: sourceText ?? "")
        value.createdAt = presentation.createdAt; value.providerEntity = presentation.providerEntity
        value.runReference = presentation.runReference; value.promptSteeringID = presentation.promptSteeringID
        return value
    }
}

struct RemoteTranscriptMessageKey: Hashable {
    let environmentID: UUID
    let hostID: UUID
    let viewID: UUID
    let sequence: Int64
    let fingerprint: Data
    let id: Data
    init(_ message: RemoteMessageSummary, _ binding: RemoteProjectionBinding) {
        environmentID = binding.environmentID; hostID = binding.hostID; viewID = binding.viewID; sequence = binding.sequence
        fingerprint = Data(binding.fingerprint.utf8); id = Data(message.id.utf8)
    }
}

@MainActor @Observable
final class RemoteTranscriptState {
    typealias Read = @MainActor (RemoteProjectionContentReference, RemoteProjectionBinding) async throws -> Data
    private struct Job {
        let message: RemoteMessageSummary
        let binding: RemoteProjectionBinding
        let includeSource: Bool
        let read: Read
        var key: RemoteTranscriptMessageKey { .init(message, binding) }
    }
    private(set) var binding: RemoteProjectionBinding?
    private(set) var entries: [RemoteTranscriptMessageKey: RemoteTranscriptEntry] = [:]
    private(set) var errors: [RemoteTranscriptMessageKey: String] = [:]
    private(set) var loading: Set<RemoteTranscriptMessageKey> = []
    @ObservationIgnored private var pending: [Job] = []
    @ObservationIgnored private var workers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeWorker: UUID?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var order: [RemoteTranscriptMessageKey] = []
    @ObservationIgnored private var bytes = 0
    @ObservationIgnored private let maximumBytes: Int
    @ObservationIgnored private let cards = TranscriptCardCache()
    static let maximumDocumentBytes = 32 * 1_024 * 1_024
    init(maximumBytes: Int = 64 * 1_024 * 1_024) { self.maximumBytes = maximumBytes }

    func select(_ binding: RemoteProjectionBinding) {
        guard self.binding != binding else { return }
        cancel(); self.binding = binding
    }
    func entry(_ message: RemoteMessageSummary, _ binding: RemoteProjectionBinding) -> RemoteTranscriptEntry? { entries[.init(message, binding)] }
    func request(_ message: RemoteMessageSummary, binding: RemoteProjectionBinding, includeSource: Bool = false, read: @escaping Read) {
        if self.binding == nil { self.binding = binding }
        let key = RemoteTranscriptMessageKey(message, binding)
        guard self.binding == binding, message.presentation != nil, !loading.contains(key), loading.count < 512,
              entry(message, binding) == nil || (includeSource && entry(message, binding)?.sourceText == nil) else { return }
        loading.insert(key); errors.removeValue(forKey: key)
        pending.append(.init(message: message, binding: binding, includeSource: includeSource, read: read))
        guard activeWorker == nil else { return }
        let id = UUID(), owner = generation; activeWorker = id
        workers[id] = Task { [weak self] in
            defer { self?.workers.removeValue(forKey: id); if self?.activeWorker == id { self?.activeWorker = nil } }
            while !Task.isCancelled, let self, self.generation == owner, !self.pending.isEmpty {
                let job = self.pending.removeFirst()
                await self.load(job, owner: owner)
            }
        }
    }
    private func load(_ job: Job, owner: UUID) async {
        defer { if generation == owner { loading.remove(job.key) } }
        do {
            guard let reference = job.message.presentation, reference.kind == .transcriptPresentation,
                  reference.totalBytes <= Self.maximumDocumentBytes, reference.totalBytes <= maximumBytes else { throw RemoteProjectionFailure(.limitExceeded) }
            let data = try await job.read(reference, job.binding)
            guard generation == owner, binding == job.binding, !Task.isCancelled else { return }
            try Self.verify(data, reference)
            let value = try JSONDecoder().decode(RemoteTranscriptMessagePresentation.self, from: data)
            try Self.validate(value, message: job.message, binding: job.binding)
            var text: String?, cost = data.count
            if value.sourceText.complete {
                guard value.sourceText.content == nil else { throw RemoteProjectionFailure(.invalidRequest) }
                text = value.sourceText.preview
            } else if let source = value.sourceText.content {
                guard source.kind == .text else { throw RemoteProjectionFailure(.invalidRequest) }
                if job.includeSource || source.totalBytes <= 1_048_576 {
                    guard source.totalBytes <= Self.maximumDocumentBytes, cost + source.totalBytes <= maximumBytes else { throw RemoteProjectionFailure(.limitExceeded) }
                    let full = try await job.read(source, job.binding); try Self.verify(full, source)
                    guard let decoded = String(data: full, encoding: .utf8) else { throw RemoteProjectionFailure(.invalidRequest) }
                    text = decoded; cost += full.count
                }
            } else { throw RemoteProjectionFailure(.invalidRequest) }
            guard generation == owner, binding == job.binding, !Task.isCancelled else { return }
            if let previous = entries.removeValue(forKey: job.key) { bytes -= previous.byteCount; order.removeAll { $0 == job.key } }
            while bytes + cost > maximumBytes || entries.count >= 128 {
                guard !order.isEmpty else { throw RemoteProjectionFailure(.limitExceeded) }
                if let removed = entries.removeValue(forKey: order.removeFirst()) { bytes -= removed.byteCount }
            }
            entries[job.key] = .init(presentation: value, sourceText: text, byteCount: cost)
            bytes += cost; order.append(job.key); errors.removeValue(forKey: job.key)
        } catch is CancellationError {} catch {
            if generation == owner, binding == job.binding, !Task.isCancelled { errors[job.key] = error.localizedDescription }
        }
    }
    static func verify(_ data: Data, _ reference: RemoteProjectionContentReference) throws {
        guard data.count == reference.totalBytes, RemoteProjectionProtocol.digest(data) == reference.digest else { throw RemoteProjectionFailure(.invalidRequest) }
    }
    static func validate(_ value: RemoteTranscriptMessagePresentation, message: RemoteMessageSummary, binding: RemoteProjectionBinding) throws {
        guard case .thread(let threadID) = binding.scope, value.threadID == threadID,
              value.messageID.utf8.elementsEqual(message.id.utf8), value.role == message.role, value.createdAt == message.createdAt,
              value.runReference == message.runReference,
              value.threadCreatedAt.timeIntervalSince1970.isFinite, value.createdAt.timeIntervalSince1970.isFinite,
              value.workspacePath.hasPrefix("/"), !value.workspacePath.contains("\0"),
              !value.opensRun || (value.role == .user && value.runReference != nil),
              !value.terminalResponse || (value.role == .assistant && value.runStatus?.isTerminal == true),
              !value.streaming || (value.role == .assistant && value.runActive && value.trailing),
              !value.runActive || value.runReference != nil, !value.trailing || value.runActive,
              !value.canPairClaudeResult || (value.provider == .claude && value.runReference != nil && value.providerEntity == nil) else { throw RemoteProjectionFailure(.invalidRequest) }
    }
    func card(_ message: RemoteMessageSummary, result: RemoteMessageSummary? = nil, binding: RemoteProjectionBinding) -> TranscriptToolCard? {
        guard let entry = entry(message, binding), entry.sourceText != nil || entry.presentation.providerEntity != nil else { return nil }
        let value = entry.presentation
        let scope = TranscriptCardScope(threadID: value.threadID, createdAt: value.threadCreatedAt, projectID: value.projectID,
            workspacePath: value.workspacePath, runID: value.runReference?.runID, environmentID: binding.environmentID, hostID: binding.hostID)
        return cards.card(entry.message, result.flatMap { self.entry($0, binding)?.message },
            .init(provider: value.provider, runActive: value.runActive, trailing: value.trailing), scope: scope)
    }
    func cancel() {
        generation = UUID(); workers.values.forEach { $0.cancel() }; activeWorker = nil
        pending.removeAll(); loading.removeAll(); entries.removeAll(); errors.removeAll(); order.removeAll(); bytes = 0; binding = nil
    }
    func shutdown() async {
        await stopAndDrain().value
    }
    /// Captures original readers synchronously. Awaiting this returned drain
    /// later cannot cancel a replacement view or its new readers.
    func stopAndDrain() -> Task<Void, Never> {
        let owned = Array(workers.values); cancel()
        return Task { for task in owned { await task.value } }
    }
}

enum RemoteTranscriptRow: Identifiable {
    case message(RemoteMessageSummary, RemoteMessageSummary?)
    case group(String, [RemoteMessageSummary])
    case fold(String, [RemoteMessageSummary])
    var id: String { switch self { case .message(let value, _): "message:" + value.id; case .group(let id, _): id; case .fold(let id, _): id } }
}

@MainActor enum RemoteTranscriptLayout {
    static func pairedResult(_ message: RemoteMessageSummary, messages: [RemoteMessageSummary], binding: RemoteProjectionBinding,
                             state: RemoteTranscriptState) -> RemoteMessageSummary? {
        guard message.role == .tool, !message.id.hasPrefix("result-"),
              let original = state.entry(message, binding), original.presentation.canPairClaudeResult,
              original.sourceText != nil, let reference = message.runReference else { return nil }
        let calls = messages.indices.filter { messages[$0].role == .tool && messages[$0].id.utf8.elementsEqual(message.id.utf8) && messages[$0].runReference == reference }
        let results = messages.indices.filter {
            messages[$0].role == .tool && messages[$0].id.utf8.elementsEqual(("result-" + message.id).utf8) && messages[$0].runReference == reference
        }
        guard calls.count == 1, results.count == 1, let call = calls.first, let result = results.first, call < result,
              let entry = state.entry(messages[result], binding), entry.presentation.canPairClaudeResult, entry.sourceText != nil else { return nil }
        return messages[result]
    }
    static func rows(_ messages: [RemoteMessageSummary], binding: RemoteProjectionBinding, state: RemoteTranscriptState,
                     foldCompleted: Bool) -> [RemoteTranscriptRow] {
        var results: [Int: RemoteMessageSummary] = [:], removed = Set<Int>()
        for (index, message) in messages.enumerated() {
            guard let paired = pairedResult(message, messages: messages, binding: binding, state: state),
                  let result = messages.indices.first(where: { messages[$0].id.utf8.elementsEqual(paired.id.utf8) && messages[$0].runReference == paired.runReference }) else { continue }
            results[index] = paired; removed.insert(result)
        }
        let kept = messages.indices.filter { !removed.contains($0) }
        var rows: [RemoteTranscriptRow] = [], index = 0
        while index < kept.count {
            let position = kept[index], message = messages[position]
            let value = state.entry(message, binding)?.presentation
            let card = state.card(message, result: results[position], binding: binding)
            let canFold = foldCompleted && value?.runStatus == .completed && message.role != .user && message.role != .system
                && value?.terminalResponse != true && (message.role != .tool || card != nil) && card?.kind != .plan && card?.isFailure != true
            let activity = (message.role == .tool && card != nil) || message.role == .reasoning
            if (canFold || activity), let reference = message.runReference, value != nil, card?.kind != .plan, card?.kind != .compaction {
                var group = [message], end = index + 1
                while end < kept.count {
                    let next = messages[kept[end]], nextValue = state.entry(next, binding)?.presentation
                    let nextCard = state.card(next, result: results[kept[end]], binding: binding)
                    guard next.runReference == reference, nextValue != nil, nextCard?.kind != .plan, nextCard?.kind != .compaction else { break }
                    if canFold {
                        guard nextValue?.runStatus == .completed, next.role != .user, next.role != .system, nextValue?.terminalResponse != true,
                              next.role != .tool || nextCard != nil, nextCard?.isFailure != true else { break }
                    } else { guard (next.role == .tool && nextCard != nil) || next.role == .reasoning else { break } }
                    group.append(next); end += 1
                }
                if canFold { rows.append(.fold("fold:" + reference.runID.uuidString + ":" + message.id, group)) }
                else if group.count > 1 { rows.append(.group("work:" + reference.runID.uuidString + ":" + message.id, group)) }
                else { rows.append(.message(message, results[position])) }
                index = end
            } else { rows.append(.message(message, results[position])); index += 1 }
        }
        return rows
    }
}

private struct RemoteTranscriptSheet: Identifiable {
    enum Kind {
        case history(RemoteHistoryWorkspace, UUID, ConversationHistoryKind)
        case diff(RemoteCheckpointWorkspace, UUID)
        case restore(RemoteCheckpointWorkspace, UUID, RunCheckpointStage, UUID)
    }
    let id = UUID()
    let kind: Kind
}

struct RemoteTranscriptRowsView: View {
    @Bindable var store: RemoteWorkspaceStore
    let binding: RemoteProjectionBinding
    @State private var state = RemoteTranscriptState()
    @State private var expanded: Set<String> = []
    @State private var sheet: RemoteTranscriptSheet?
    @State private var drain: Task<Void, Never>?
    @AppStorage(TranscriptPreferences.foldCompletedRunsKey) private var foldCompleted = true
    private var messages: [RemoteMessageSummary] { store.projection.visibleMessages }

    var body: some View {
        ForEach(RemoteTranscriptLayout.rows(messages, binding: binding, state: state, foldCompleted: foldCompleted)) { row in
            switch row {
            case .message(let message, let result): messageView(message, result: result)
            case .group(let id, let values):
                DisclosureGroup(isExpanded: expansion(id)) {
                    ForEach(values) { messageView($0) }
                } label: {
                    let cards = values.compactMap { state.card($0, result: pairedResult($0), binding: binding) }
                    let summary = TranscriptToolPresentation.summary(cards: cards, reasoningCount: values.filter { $0.role == .reasoning }.count)
                    HStack { Text(summary.text).font(.caption.weight(.medium)); if summary.failed { Image(systemName: "exclamationmark.circle").foregroundStyle(.red) } }
                }
            case .fold(let id, let values):
                DisclosureGroup(isExpanded: expansion(id)) {
                    ForEach(values) { messageView($0) }
                } label: { Text("Earlier activity · \(values.count) loaded messages").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .onChange(of: binding, initial: true) { state.select(binding); sheet = nil; expanded.removeAll() }
        .onChange(of: store.selectedThreadID) { sheet = nil }
        .onDisappear { drain = state.stopAndDrain() }
        .sheet(item: $sheet) { selected in
            switch selected.kind {
            case .history(let model, let run, let kind):
                RemoteHistoryReviewPane(model: model, runID: run, kind: kind,
                    attachmentAccess: store.attachmentTarget.map { store.attachments.access(target: $0) }, close: { sheet = nil })
            case .diff(let model, let run):
                RemoteCheckpointDiffPane(model: model, runID: run,
                    restore: { sheet = .init(kind: .restore(model, run, $0, $1)) }, close: { sheet = nil })
            case .restore(let model, let run, let stage, let attempt):
                RemoteCheckpointRestorePane(model: model, runID: run, stage: stage, attemptID: attempt, close: { sheet = nil })
            }
        }
    }
    private func expansion(_ id: String) -> Binding<Bool> {
        .init(get: { expanded.contains(id) }, set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }
    private func messageView(_ message: RemoteMessageSummary, result: RemoteMessageSummary? = nil) -> some View {
        RemoteProjectedMessageView(message: message, binding: binding, store: store.projection,
            source: store.attachmentTarget.map { store.attachments.access(target: $0) }, transcript: state, workspace: store,
            result: result ?? pairedResult(message), historyAction: { runID, kind in
                guard let presentation = state.entry(message, binding)?.presentation,
                      store.transcriptActionIsCurrent(message: message, binding: binding, presentation: presentation),
                      let model = store.history.current, model.availability(runID: runID, kind: kind).allowed else { return }
                sheet = .init(kind: .history(model, runID, kind))
            }, changesAction: { runID in
                guard let presentation = state.entry(message, binding)?.presentation,
                      store.transcriptActionIsCurrent(message: message, binding: binding, presentation: presentation),
                      let model = store.checkpoints.current else { return }
                sheet = .init(kind: .diff(model, runID))
            })
    }
    private func pairedResult(_ message: RemoteMessageSummary) -> RemoteMessageSummary? {
        RemoteTranscriptLayout.pairedResult(message, messages: messages, binding: binding, state: state)
    }
}
