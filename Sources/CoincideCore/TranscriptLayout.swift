import Foundation

public struct TranscriptLayoutOptions: Sendable, Equatable {
    public var expandedFolds: Set<String>
    public var expandedGroups: Set<String>
    public var foldCompletedRuns: Bool
    public var searchExpandedMessageIDs: Set<String>
    public init(expandedFolds: Set<String> = [], expandedGroups: Set<String> = [], foldCompletedRuns: Bool = true,
                searchExpandedMessageIDs: Set<String> = []) {
        self.expandedFolds = expandedFolds; self.expandedGroups = expandedGroups; self.foldCompletedRuns = foldCompletedRuns
        self.searchExpandedMessageIDs = searchExpandedMessageIDs
    }
}

/// One tool or reasoning row, with a Claude `result-<id>` row merged into its call.
public struct TranscriptEntry: Sendable, Equatable, Identifiable {
    public var message: ChatMessage
    public var result: ChatMessage?
    public var card: TranscriptToolCard?
    public var runID: UUID?
    public var runActive: Bool
    public var trailing: Bool
    public var id: String { message.id }
    public var isReasoning: Bool { message.role == .reasoning }
    public var isLive: Bool { trailing || card?.status == .running }
}

public struct TranscriptWorkGroup: Sendable, Equatable, Identifiable {
    public var id: String
    public var entries: [TranscriptEntry]
    public var summary: String
    public var hasFailure: Bool
    public var expanded: Bool
    public var live: Bool { entries.contains(where: \.isLive) }
}

public struct TranscriptTurnFold: Sendable, Equatable, Identifiable {
    public var id: String
    public var runID: UUID
    public var label: String
    public var hiddenCount: Int
    public var expanded: Bool
}

public struct TranscriptMessageMeta: Sendable, Equatable {
    public var runID: UUID?
    /// The user message opened this recorded run (an Edit from Here candidate).
    public var opensRun = false
    /// The final assistant message of a finished run (a Fork from Here candidate).
    public var terminalResponse = false
    /// The assistant message is the newest row of the active run.
    public var streaming = false
    public var canShowChanges = false
    public init(runID: UUID? = nil) { self.runID = runID }
}

public struct TranscriptTurnChanges: Sendable, Equatable {
    public var runID: UUID
    /// Ready baseline and post-run checkpoints; nil when only tool cards describe the changes.
    public var checkpointRevision: String?
    public var cardChanges: [TranscriptFileChange]
}

public enum TranscriptRow: Sendable, Equatable, Identifiable {
    case message(ChatMessage, TranscriptMessageMeta)
    case entry(TranscriptEntry)
    case group(TranscriptWorkGroup)
    case plan(TranscriptEntry)
    case fold(TranscriptTurnFold)
    case changes(TranscriptTurnChanges)
    public var id: String {
        switch self {
        case .message(let message, _): message.id
        case .entry(let entry): "entry-" + entry.id
        case .group(let group): group.id
        case .plan(let entry): "plan-" + entry.id
        case .fold(let fold): fold.id
        case .changes(let changes): "changes-" + changes.runID.uuidString
        }
    }
}

/// Turns the visible transcript into display rows: consecutive tool/reasoning
/// rows of one run become a work log group, a completed run's intermediate work
/// folds under "Worked for …", and each finished run gets a changed-files footer.
/// Only recorded local run attribution is used; unattributed rows never fold.
public enum TranscriptLayout {
    public typealias CardProvider = (ChatMessage, ChatMessage?, TranscriptToolContext) -> TranscriptToolCard

    public static func rows(thread: CodingThread, options: TranscriptLayoutOptions = .init(),
                            card: CardProvider = { TranscriptToolPresentation.card(for: $0, result: $1, context: $2) }) -> [TranscriptRow] {
        let messages = thread.visibleMessages
        var records: [UUID: ThreadRunRecord] = [:]
        for record in thread.activeHistoryRuns where records[record.id] == nil { records[record.id] = record }
        let activeRunID = thread.activeRun?.id

        // Native call IDs are only unique inside their original observed run.
        // Inherited source references remain source references; unattributed
        // legacy rows or ambiguous duplicate IDs stay separately visible.
        struct ToolPairKey: Hashable {
            let source: TranscriptRunReference
            let id: Data
        }
        func pairKey(_ message: ChatMessage, result: Bool) -> ToolPairKey? {
            guard message.role == .tool, message.providerEntity == nil,
                  let source = message.runReference, let record = records[source.runID],
                  record.messageAttributionVersion == 1, record.configuration.provider == .claude else { return nil }
            let identifier = result ? String(message.id.dropFirst(7)) : message.id
            guard !identifier.isEmpty else { return nil }
            return .init(source: source, id: Data(identifier.utf8))
        }
        var calls: [ToolPairKey: [Int]] = [:], resultRows: [ToolPairKey: [Int]] = [:]
        for (index, message) in messages.enumerated() where message.role == .tool {
            let isResult = message.id.hasPrefix("result-")
            guard let key = pairKey(message, result: isResult) else { continue }
            if isResult { resultRows[key, default: []].append(index) }
            else { calls[key, default: []].append(index) }
        }
        var results: [Int: ChatMessage] = [:], merged = Set<Int>()
        for (key, indices) in resultRows {
            guard indices.count == 1, let candidates = calls[key], candidates.count == 1,
                  let call = candidates.first, let result = indices.first, call < result else { continue }
            results[call] = messages[result]; merged.insert(result)
        }
        func run(_ message: ChatMessage) -> UUID? {
            guard let reference = message.runReference, reference.threadID == thread.id, records[reference.runID] != nil else { return nil }
            return reference.runID
        }
        let kept = messages.indices.filter { !merged.contains($0) }
        let runIDs = kept.map { run(messages[$0]) }
        let lastActive = activeRunID.flatMap { id in runIDs.lastIndex(of: id) }
        var entries: [TranscriptEntry?] = []
        entries.reserveCapacity(kept.count)
        for (position, index) in kept.enumerated() {
            let message = messages[index]
            guard message.role == .tool || message.role == .reasoning else { entries.append(nil); continue }
            let runID = runIDs[position]
            let active = runID != nil && runID == activeRunID
            var entry = TranscriptEntry(message: message, result: results[index], card: nil, runID: runID, runActive: active, trailing: active && position == lastActive)
            if message.role == .tool {
                let captured = message.runReference.flatMap { records[$0.runID] }
                let provider = captured?.configuration.provider ?? thread.provider
                entry.card = card(message, entry.result, .init(provider: provider, runActive: active, trailing: entry.trailing,
                    workspacePath: captured?.configuration.workspacePath ?? thread.workspacePath))
            }
            entries.append(entry)
        }

        // Folds for completed runs.
        var positionsByRun: [UUID: [Int]] = [:], runOrder: [UUID] = []
        for (position, runID) in runIDs.enumerated() {
            guard let runID else { continue }
            if positionsByRun[runID] == nil { runOrder.append(runID) }
            positionsByRun[runID, default: []].append(position)
        }
        var terminalByRun: [UUID: Int] = [:]
        for runID in runOrder {
            if let last = positionsByRun[runID]!.last(where: { messages[kept[$0]].role == .assistant }) { terminalByRun[runID] = last }
        }
        var foldBefore: [Int: TranscriptTurnFold] = [:], hiddenBy: [Int: String] = [:]
        var expandedFoldIDs = options.expandedFolds
        if options.foldCompletedRuns {
            for runID in runOrder where runID != activeRunID {
                guard let record = records[runID], record.status == .completed else { continue }
                let positions = positionsByRun[runID]!, terminal = terminalByRun[runID]
                var segments: [[Int]] = [[]], steers: [Int] = []
                for position in positions {
                    let message = messages[kept[position]]
                    if message.role == .user {
                        guard message.promptSteeringID != nil, record.userMessageID != message.id else { continue }
                        if segments.last!.isEmpty { if !steers.isEmpty { steers[steers.count - 1] = position } }
                        else { segments.append([]); steers.append(position) }
                        continue
                    }
                    segments[segments.count - 1].append(position)
                }
                if segments.last!.isEmpty, segments.count > 1 { segments.removeLast(); steers.removeLast() }
                for (number, segment) in segments.enumerated() {
                    let hidden = segment.filter { position in
                        guard position != terminal else { return false }
                        let message = messages[kept[position]]
                        if message.role == .system || message.role == .user { return false }
                        if let card = entries[position]?.card, card.kind == .plan { return false }
                        if let terminal, position > terminal {
                            guard let entry = entries[position] else { return false }
                            return entry.card?.isFailure != true && entry.card?.status != .running
                        }
                        return true
                    }
                    guard let anchor = segment.first, !hidden.isEmpty else { continue }
                    let id: String, label: String
                    if number == 0 {
                        id = "fold-" + runID.uuidString
                        let duration = record.endedAt.map { $0.timeIntervalSince(record.startedAt) }
                        label = duration.map { String(localized: "Worked for \(TranscriptDuration.format($0))") } ?? String(localized: "Worked")
                    } else {
                        let steer = messages[kept[steers[number - 1]]]
                        id = "fold-" + runID.uuidString + "-" + steer.id
                        let end = number == segments.count - 1 ? record.endedAt : segment.map { messages[kept[$0]].createdAt }.max()
                        let duration = end.map { $0.timeIntervalSince(steer.createdAt) }
                        label = duration.map { String(localized: "Continued for \(TranscriptDuration.format($0))") } ?? String(localized: "Continued")
                    }
                    if hidden.contains(where: { position in
                        options.searchExpandedMessageIDs.contains(messages[kept[position]].id)
                            || entries[position]?.result.map { options.searchExpandedMessageIDs.contains($0.id) } == true
                    }) { expandedFoldIDs.insert(id) }
                    foldBefore[anchor] = .init(id: id, runID: runID, label: label, hiddenCount: hidden.count, expanded: expandedFoldIDs.contains(id))
                    for position in hidden { hiddenBy[position] = id }
                }
            }
        }

        var rows: [TranscriptRow] = [], pending: [TranscriptEntry] = [], pendingFold: String?, lastRow: [UUID: Int] = [:]
        func flush() {
            guard let first = pending.first else { return }
            if pending.count == 1 { rows.append(.entry(first)) }
            else {
                let id = "group-" + first.id
                let summary = TranscriptToolPresentation.summary(cards: pending.compactMap(\.card), reasoningCount: pending.filter(\.isReasoning).count)
                rows.append(.group(.init(id: id, entries: pending, summary: summary.text, hasFailure: summary.failed, expanded: options.expandedGroups.contains(id) || pending.contains(where: {
                    options.searchExpandedMessageIDs.contains($0.id) || $0.result.map { options.searchExpandedMessageIDs.contains($0.id) } == true
                }))))
            }
            if let runID = first.runID { lastRow[runID] = rows.count - 1 }
            pending = []
        }
        for (position, index) in kept.enumerated() {
            if let fold = foldBefore[position] { flush(); rows.append(.fold(fold)); lastRow[fold.runID] = rows.count - 1 }
            if let fold = hiddenBy[position], !expandedFoldIDs.contains(fold) { continue }
            let message = messages[index], runID = runIDs[position]
            if let entry = entries[position] {
                if let kind = entry.card?.kind, kind == .plan || kind == .compaction {
                    flush(); rows.append(kind == .plan ? .plan(entry) : .entry(entry))
                    if let runID { lastRow[runID] = rows.count - 1 }
                    continue
                }
                // A group never spans runs or a fold boundary.
                if let previous = pending.last, previous.runID != entry.runID || hiddenBy[position] != pendingFold { flush() }
                if pending.isEmpty { pendingFold = hiddenBy[position] }
                pending.append(entry)
                continue
            }
            flush()
            var meta = TranscriptMessageMeta(runID: runID)
            if let runID, let record = records[runID] {
                if message.role == .user { meta.opensRun = record.origin == .user && record.userMessageID == message.id }
                if message.role == .assistant {
                    meta.terminalResponse = record.status.isTerminal && terminalByRun[runID] == position
                    meta.streaming = runID == activeRunID && position == lastActive
                    meta.canShowChanges = record.status.isTerminal && record.checkpoints.map(Self.canShowDiff) == true
                }
            }
            rows.append(.message(message, meta))
            if let runID, message.role != .user { lastRow[runID] = rows.count - 1 }
        }
        flush()

        // Changed-files footers, inserted from the end so earlier offsets stay valid.
        var footers: [(Int, TranscriptRow)] = []
        for runID in runOrder {
            guard let record = records[runID], record.status.isTerminal, runID != activeRunID, let at = lastRow[runID] else { continue }
            let revision = record.checkpoints.flatMap { checkpoints -> String? in
                guard canShowDiff(checkpoints), let post = checkpoints.postRun else { return nil }
                return checkpoints.baseline.id.uuidString + ":" + post.id.uuidString
            }
            let changes = combined(positionsByRun[runID]!.compactMap { entries[$0]?.card }.filter { !$0.isFailure }.flatMap(\.changes))
            guard revision != nil || !changes.isEmpty else { continue }
            footers.append((at + 1, .changes(.init(runID: runID, checkpointRevision: revision, cardChanges: changes))))
        }
        for (at, row) in footers.sorted(by: { $0.0 > $1.0 }) { rows.insert(row, at: at) }
        return rows
    }

    public static func canShowDiff(_ checkpoints: ThreadRunCheckpoints) -> Bool {
        checkpoints.baseline.phase == .ready && checkpoints.baseline.receipt != nil &&
            checkpoints.postRun?.phase == .ready && checkpoints.postRun?.receipt != nil
    }

    /// One summary row per path; repeated edits add their line counts.
    public static func combined(_ changes: [TranscriptFileChange]) -> [TranscriptFileChange] {
        var order: [Data] = [], byPath: [Data: TranscriptFileChange] = [:]
        for change in changes {
            let path = Data(change.path.utf8)
            if var existing = byPath[path] {
                existing.additions += change.additions; existing.deletions += change.deletions; existing.hunks += change.hunks
                if existing.kind == .modified, change.kind == .deleted { existing.kind = .deleted }
                existing.isTruncated = existing.isTruncated || change.isTruncated
                existing.countsComplete = existing.countsComplete && change.countsComplete
                byPath[path] = existing
            } else { order.append(path); byPath[path] = change }
        }
        return order.map { byPath[$0]! }
    }
}
