import CoincideKit
import Foundation

/// Stable identity of a transcript row, so updates can be diffed against what the table shows.
enum TranscriptRowID: Hashable {
    case item(UUID)
    /// The "Working…" / "Worked for…" header of the turn that starts with this item: the user's message,
    /// or the notice of a turn the agent started on its own.
    case turnHeader(UUID)
    /// A collapsible group of consecutive tool calls, keyed by its first item.
    case group(UUID)
    case changedFiles(UUID)
    case live
    case header
    case footer
}

struct TranscriptRow: Equatable {
    enum Kind: Hashable {
        case user
        case assistant(meta: AssistantMeta?)
        case reasoning(isNested: Bool)
        case tool(isNested: Bool)
        case group(itemIDs: [UUID], isExpanded: Bool)
        case approval
        case question
        case plan
        case error
        case notice
        case turnHeader(TurnHeader)
        case changedFiles(turnID: UUID)
        case live(LiveStatus)
        /// Breathing room above the first row and between the last row and the composer.
        case spacer(height: CGFloat)
    }

    var id: TranscriptRowID
    var kind: Kind
    /// Changes whenever anything the row draws changes; cached heights are keyed by it.
    var revision: Int
    /// Work-log rows followed by another work-log row sit closer together.
    var continuesWork = false

    var itemID: UUID? {
        if case .item(let id) = id { return id }
        return nil
    }

    var isWorkLog: Bool {
        switch kind {
        case .reasoning, .tool, .group: true
        default: false
        }
    }

    var isExpandable: Bool {
        switch kind {
        case .reasoning, .tool, .group: true
        case .turnHeader(.worked): true
        default: false
        }
    }
}

/// Footer of the turn's final reply: who answered, so a provider switch is visible.
struct AssistantMeta: Hashable {
    var provider: ProviderKind
    var modelID: String?
}

enum TurnHeader: Hashable {
    case working(startedAt: Date)
    case worked(duration: TimeInterval, isExpanded: Bool)
}

enum LiveStatus: Hashable {
    case starting(ProviderKind)
    case thinking
}

/// Builds rows from a thread's transcript, the way T3 Code lays out its timeline: each turn opens
/// with the user's message; while it runs a "Working for…" header leads its live work, and once
/// done the tool calls, reasoning and interim replies fold under "Worked for…" above the reply.
/// A turn the agent started on its own opens with the notice saying so and lays out the same way.
/// Plans, questions and anything still waiting for the user stay in view.
struct TranscriptBuilder {
    var items: [TranscriptItem]
    /// The item the running turn opened with, if a turn runs: the user's message, or the notice of a
    /// turn the agent started (`ThreadRunner.TurnState.userItemID`).
    var runningTurnID: UUID?
    var turnStartedAt: Date?
    var isStarting = false
    var runningProvider: ProviderKind?
    var showReasoning = true
    var expanded: Set<TranscriptRowID> = []
    /// Notices that opened turns an agent started on its own (see `AgentTurns`).
    var agentTurnIDs: Set<UUID> = []
    /// Room kept above the first row, so the find bar does not cover it, as T3 reserves for its find bar.
    var topReserve: CGFloat = 0
    /// Bumped per item whenever the item changes.
    var revisions: [UUID: Int] = [:]
    /// Turns (by user item) that changed files, with a signature of the change set.
    var changedFiles: [UUID: Int] = [:]

    func build() -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var start = 0
        for index in items.indices where index > start && opensTurn(items[index]) {
            appendTurn(items[start..<index], to: &rows)
            start = index
        }
        if start < items.count { appendTurn(items[start...], to: &rows) }

        if let runningTurnID, needsLiveRow(after: rows.last, turnID: runningTurnID) {
            let status: LiveStatus =
                isStarting ? .starting(runningProvider ?? .claude) : .thinking
            rows.append(row(.live, .live(status)))
        }
        for index in rows.indices.dropLast() where rows[index].isWorkLog && rows[index + 1].isWorkLog {
            rows[index].continuesWork = true
        }
        if !rows.isEmpty {
            rows.insert(row(.header, .spacer(height: TranscriptMetrics.edgePadding + topReserve)), at: 0)
            rows.append(row(.footer, .spacer(height: TranscriptMetrics.edgePadding)))
        }
        return rows
    }

    // MARK: Turns

    /// The user's messages open turns, and so do the notices of turns an agent started by itself.
    func opensTurn(_ item: TranscriptItem) -> Bool {
        item.kind == .user || (item.kind == .notice && agentTurnIDs.contains(item.id))
    }

    /// The item that opened the turn `itemID` belongs to, if a turn holds it.
    func turnOpener(of itemID: UUID) -> UUID? {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return nil }
        return items[...index].last(where: opensTurn)?.id
    }

    private func appendTurn(_ turn: ArraySlice<TranscriptItem>, to rows: inout [TranscriptRow]) {
        let opener = turn.first.flatMap { opensTurn($0) ? $0 : nil }
        let body = turn.dropFirst(opener == nil ? 0 : 1).filter(isVisible)
        if let opener { rows.append(row(.item(opener.id), opener.kind == .user ? .user : .notice)) }

        if let opener, opener.id == runningTurnID {
            rows.append(row(.turnHeader(opener.id), .turnHeader(.working(startedAt: turnStartedAt ?? opener.createdAt))))
            appendBody(body, terminalID: nil, meta: nil, to: &rows)
            return
        }

        let terminalIndex = body.lastIndex { $0.kind == .assistant }
        var hidden = Set<UUID>()
        if !body.contains(where: { $0.kind == .error }) {
            for (index, item) in body.enumerated() where index != terminalIndex {
                let beforeReply = terminalIndex.map { index < $0 } ?? true
                switch item.kind {
                case .tool, .reasoning:
                    if beforeReply || item.status != .failed { hidden.insert(item.id) }
                case .assistant:
                    if beforeReply { hidden.insert(item.id) }
                case .approval:
                    if item.status != .waiting { hidden.insert(item.id) }
                case .user, .plan, .question, .error, .notice:
                    break
                }
            }
        }
        if let opener, !hidden.isEmpty {
            let isExpanded = expanded.contains(.turnHeader(opener.id))
            let end = turn.map { $0.completedAt ?? $0.createdAt }.max() ?? opener.createdAt
            rows.append(
                row(
                    .turnHeader(opener.id),
                    .turnHeader(.worked(duration: max(0, end.timeIntervalSince(opener.createdAt)), isExpanded: isExpanded))))
            if isExpanded { hidden.removeAll() }
        }

        let terminal = terminalIndex.map { body[$0] }
        let meta = terminal.flatMap { item in item.provider.map { AssistantMeta(provider: $0, modelID: item.modelID) } }
        appendBody(body.filter { !hidden.contains($0.id) }, terminalID: terminal?.id, meta: meta, to: &rows)

        if let user = opener, user.kind == .user, let signature = changedFiles[user.id] {
            let filesRow = row(.changedFiles(user.id), .changedFiles(turnID: user.id), salt: signature)
            if let terminal, let replyIndex = rows.lastIndex(where: { $0.id == .item(terminal.id) }) {
                rows.insert(filesRow, at: replyIndex + 1)
            } else {
                rows.append(filesRow)
            }
        }
    }

    private func appendBody(_ body: [TranscriptItem], terminalID: UUID?, meta: AssistantMeta?, to rows: inout [TranscriptRow]) {
        var run: [TranscriptItem] = []
        func flush() {
            defer { run.removeAll() }
            guard let first = run.first else { return }
            if run.count == 1 {
                rows.append(row(.item(first.id), first.kind == .reasoning ? .reasoning(isNested: false) : .tool(isNested: false)))
                return
            }
            let groupID = TranscriptRowID.group(first.id)
            let isExpanded = expanded.contains(groupID)
            rows.append(row(groupID, .group(itemIDs: run.map(\.id), isExpanded: isExpanded), items: run))
            guard isExpanded else { return }
            for item in run {
                rows.append(row(.item(item.id), item.kind == .reasoning ? .reasoning(isNested: true) : .tool(isNested: true)))
            }
        }
        for item in body {
            switch item.kind {
            case .tool, .reasoning:
                run.append(item)
            case .assistant:
                flush()
                rows.append(row(.item(item.id), .assistant(meta: item.id == terminalID ? meta : nil)))
            case .approval:
                flush()
                rows.append(row(.item(item.id), .approval))
            case .question:
                flush()
                rows.append(row(.item(item.id), .question))
            case .plan:
                flush()
                rows.append(row(.item(item.id), .plan))
            case .error:
                flush()
                rows.append(row(.item(item.id), .error))
            case .notice:
                flush()
                rows.append(row(.item(item.id), .notice))
            case .user:
                flush()
            }
        }
        flush()
    }

    private func isVisible(_ item: TranscriptItem) -> Bool {
        switch item.kind {
        case .reasoning: showReasoning && item.text.nonBlank != nil
        case .assistant, .plan: item.text.nonBlank != nil
        default: true
        }
    }

    /// The live row says the agent is busy when nothing else at the bottom already does.
    private func needsLiveRow(after last: TranscriptRow?, turnID: UUID) -> Bool {
        guard let last else { return true }
        switch last.kind {
        case .tool, .reasoning:
            guard let id = last.itemID, let item = items.last(where: { $0.id == id }) else { return true }
            return item.status != .running
        case .group(let ids, _):
            return !items.contains { ids.contains($0.id) && $0.status == .running }
        case .assistant:
            guard let id = last.itemID, let item = items.last(where: { $0.id == id }) else { return true }
            return item.status != .running
        case .approval, .question:
            guard let id = last.itemID, let item = items.last(where: { $0.id == id }) else { return true }
            return item.status != .waiting
        default:
            return true
        }
    }

    // MARK: Revisions

    private func row(_ id: TranscriptRowID, _ kind: TranscriptRow.Kind, items: [TranscriptItem] = [], salt: Int = 0) -> TranscriptRow {
        var hasher = Hasher()
        hasher.combine(kind)
        hasher.combine(salt)
        hasher.combine(expanded.contains(id))
        if case .item(let itemID) = id { hasher.combine(revisions[itemID] ?? 0) }
        for item in items { hasher.combine(revisions[item.id] ?? 0) }
        return TranscriptRow(id: id, kind: kind, revision: hasher.finalize())
    }
}

// MARK: - Labels

/// Human labels for work-log rows, following T3 Code's wording.
enum TranscriptLabels {
    /// "Ran 3 commands and read 2 files", naming the two most significant kinds of work.
    static func summary(of items: [TranscriptItem]) -> String {
        let tools = items.filter { $0.kind == .tool }
        if tools.isEmpty {
            return items.count == 1 ? String(localized: "Thought") : String(localized: "Thought \(items.count) times")
        }
        var order: [ToolCategory] = []
        var counts: [ToolCategory: Int] = [:]
        for tool in tools {
            let category = tool.category ?? .other
            if counts[category] == nil { order.append(category) }
            counts[category, default: 0] += 1
        }
        let ranked = order.enumerated()
            .sorted { lhs, rhs in
                let left = priority(lhs.element)
                let right = priority(rhs.element)
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .prefix(2)
            .sorted { $0.offset < $1.offset }
            .map(\.element)
        var parts = ranked.map { phrase(for: $0, count: counts[$0] ?? 0) }
        let remaining = tools.count - ranked.reduce(0) { $0 + (counts[$1] ?? 0) }
        if remaining > 0 {
            parts.append(remaining == 1 ? String(localized: "performed 1 other action") : String(localized: "performed \(remaining) other actions"))
        }
        let sentence = parts.enumerated().map { index, part in index == 0 ? part : part.lowercasedFirstLetter }
        switch sentence.count {
        case 0: return String(localized: "Used tools")
        case 1: return sentence[0]
        case 2: return String(localized: "\(sentence[0]) and \(sentence[1])")
        default: return String(localized: "\(sentence[0]), \(sentence[1]), and \(sentence[2])")
        }
    }

    private static func priority(_ category: ToolCategory) -> Int {
        switch category {
        case .command, .fileChange, .task: 0
        case .other: 2
        default: 1
        }
    }

    static func phrase(for category: ToolCategory, count: Int) -> String {
        let one = count == 1
        switch category {
        case .command: return one ? String(localized: "Ran 1 command") : String(localized: "Ran \(count) commands")
        case .fileChange: return one ? String(localized: "Changed 1 file") : String(localized: "Changed \(count) files")
        case .read: return one ? String(localized: "Read 1 file") : String(localized: "Read \(count) files")
        case .search: return one ? String(localized: "Searched code once") : String(localized: "Searched code \(count) times")
        case .web: return one ? String(localized: "Searched the web once") : String(localized: "Searched the web \(count) times")
        case .mcp: return one ? String(localized: "Called 1 MCP tool") : String(localized: "Called \(count) MCP tools")
        case .task: return one ? String(localized: "Ran 1 subagent") : String(localized: "Ran \(count) subagents")
        case .todo: return one ? String(localized: "Updated the plan") : String(localized: "Updated the plan \(count) times")
        case .other: return one ? String(localized: "Used 1 tool") : String(localized: "Used \(count) tools")
        }
    }

    /// The symbol for a group: its category when all calls share one, otherwise a generic tool.
    static func symbol(for items: [TranscriptItem]) -> String {
        let categories = Set(items.filter { $0.kind == .tool }.map { $0.category ?? .other })
        if categories.isEmpty { return "brain" }
        return categories.count == 1 ? categories.first!.symbolName : "hammer"
    }

    /// "Worked for 2m 13s", T3 Code's duration format.
    static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0s" }
        if interval < 10 {
            let tenths = (interval * 10).rounded() / 10
            return tenths < 1 ? String(format: "%.1fs", max(0.1, tenths)) : String(format: "%.1fs", min(tenths, 9.9))
        }
        let total = Int(interval.rounded())
        if total < 60 { return "\(total)s" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        if seconds > 0 { parts.append("\(seconds)s") }
        return parts.joined(separator: " ")
    }

    /// A live timer: "12s", "1m 05s", "1h 02m".
    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let minutes = seconds / 60
        if minutes == 0 { return "\(seconds)s" }
        let hours = minutes / 60
        if hours == 0 { return String(format: "%dm %02ds", minutes, seconds % 60) }
        return String(format: "%dh %02dm", hours, minutes % 60)
    }

    /// The first sentence of a thought, flattened to one line, for a collapsed reasoning row.
    static func thoughtPreview(_ markdown: String) -> String {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("**"), let end = trimmed.dropFirst(2).range(of: "**") {
            return String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<end.lowerBound])
        }
        let flat = ChatMarkdown.parse(trimmed).compactMap { block -> String? in
            switch block {
            case .paragraph(let inlines), .heading(_, let inlines): ChatMarkdown.plainText(inlines)
            default: nil
            }
        }.joined(separator: " ")
        let collapsed = flat.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let end = collapsed.firstIndex(where: { ".?!".contains($0) }), collapsed.index(after: end) < collapsed.endIndex {
            return String(collapsed[...end])
        }
        return collapsed
    }
}

fileprivate extension String {
    var lowercasedFirstLetter: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
