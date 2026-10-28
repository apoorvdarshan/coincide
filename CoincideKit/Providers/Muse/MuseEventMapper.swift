import Foundation

/// Turns Muse's transcript items (`item/started`, `item/updated`, `item/completed` and `item/delta`) into `AgentEvent`s.
///
/// It holds no process, so recorded MSP traffic can be replayed through it. Which turn an item belongs to is decided
/// by `MuseSession`; the mapper applies Muse's revision rule (a higher revision replaces, deltas append) and shows
/// each item the way T3 Code's Muse adapter does.
struct MuseEventMapper {
    let presentation: MusePresentation
    /// Items seen, at their latest revision with deltas applied.
    private var items: [String: MuseItem] = [:]
    /// What each tool item last showed, to tell starts from updates.
    private var tools: [String: ToolCallInfo] = [:]
    /// How each tool item ended, so an unchanged repeat is not reported again.
    private var settled: [String: MusePresentation.Tool] = [:]
    /// The assistant or reasoning text last reported per item.
    private var texts: [String: String] = [:]
    /// Items whose final text was reported.
    private var finished: Set<String> = []
    /// The reasoning summary part each item last streamed into.
    private var reasoningParts: [String: Int] = [:]
    /// Subagents and workflows still running when their turn ended. Muse keeps reporting on them (T3's
    /// `observedChildren`), and ending the session would stop them.
    private(set) var background: Set<String> = []
    /// Workflow agents' labels, by child and attempt: later revisions drop them, so the first one is kept (T3).
    private var childLabels: [String: String] = [:]

    init(workingDirectory: String) {
        presentation = MusePresentation(workingDirectory: workingDirectory)
    }

    func isBackground(_ itemID: String) -> Bool { background.contains(itemID) }

    /// The turn ended. Its subagents and workflows that still run carry on in the background; everything else is done.
    mutating func endTurn() {
        for (id, item) in items where ["subagent", "workflow"].contains(item.kind) && MusePresentation.status(item) == .running {
            background.insert(id)
        }
        items = items.filter { background.contains($0.key) }
        tools = tools.filter { background.contains($0.key) }
        settled = settled.filter { background.contains($0.key) }
        texts = [:]
        finished = []
        reasoningParts = [:]
    }

    /// The host ended, and its background work with it (T3: background tasks end with the process).
    mutating func endBackground() {
        background.removeAll()
        items.removeAll()
        endTurn()
    }

    /// Applies one revision of an item. An older revision than the one held changes nothing.
    mutating func apply(_ item: MuseItem) -> [AgentEvent] {
        if let previous = items[item.id], previous.revision >= item.revision { return [] }
        items[item.id] = item
        if MusePresentation.hiddenKinds.contains(item.kind) { return [] }
        if item.kind == "toolCall", let tool = item.tool, MusePresentation.toolsShownElsewhere.contains(tool),
            MusePresentation.status(item) != .failed, tools[item.id] == nil
        {
            return []
        }
        switch item.kind {
        case "agentMessage":
            return text(item, item.text ?? "") { .assistantText(itemID: $0, text: $1) }
        case "reasoning":
            let text = TerminalText.nonEmpty(item.text)
                ?? (item.summary ?? []).compactMap { TerminalText.nonEmpty($0) }.joined(separator: "\n")
            return self.text(item, text) { .reasoningText(itemID: $0, text: $1) }
        default:
            return toolEvents(item)
        }
    }

    /// Appends a streamed piece: an answer's or reasoning's text (`text`), a tool's output (`output`), or a reasoning
    /// summary part (`summary.N`, a new part when N changes). Deltas only extend an item that is still running.
    mutating func delta(itemID: String, field: String, delta: String) -> [AgentEvent] {
        guard var item = items[itemID], item.isRunning, !delta.isEmpty, !MusePresentation.hiddenKinds.contains(item.kind)
        else { return [] }
        switch field {
        case "text":
            item.text = (item.text ?? "") + delta
            items[itemID] = item
            switch item.kind {
            case "agentMessage":
                texts[itemID, default: ""] += delta
                return [.assistantTextDelta(itemID: itemID, delta: delta)]
            case "reasoning":
                texts[itemID, default: ""] += delta
                return [.reasoningDelta(itemID: itemID, delta: delta)]
            default:
                return []
            }
        case "output", "visibleOutput":
            item.visibleOutput = (item.visibleOutput ?? "") + delta
            items[itemID] = item
            return tools[itemID] == nil ? [] : [.toolOutput(id: itemID, delta: delta)]
        default:
            guard item.kind == "reasoning", field.hasPrefix("summary."), let index = Int(field.dropFirst("summary.".count)),
                (0..<100).contains(index)
            else { return [] }
            var summary = item.summary ?? []
            while summary.count <= index { summary.append("") }
            summary[index] += delta
            item.summary = summary
            items[itemID] = item
            // Parts read as paragraphs of one entry, as T3 joins them.
            let streamed = texts[itemID] ?? ""
            let piece = reasoningParts[itemID].map { $0 != index && !streamed.isEmpty } == true ? "\n" + delta : delta
            reasoningParts[itemID] = index
            texts[itemID] = streamed + piece
            return [.reasoningDelta(itemID: itemID, delta: piece)]
        }
    }

    // MARK: Items

    /// An answer's or reasoning's text: reported when it changes, and once more, authoritatively, when the item ends.
    private mutating func text(_ item: MuseItem, _ text: String, _ event: (String, String) -> AgentEvent) -> [AgentEvent] {
        let ended = !item.isRunning && !finished.contains(item.id)
        if ended { finished.insert(item.id) }
        guard !text.isEmpty, ended || texts[item.id] != text else { return [] }
        texts[item.id] = text
        return [event(item.id, text)]
    }

    private mutating func toolEvents(_ item: MuseItem) -> [AgentEvent] {
        for child in item.children ?? [] {
            let key = "\(child.id)#\(child.attempt)"
            if childLabels[key] == nil, let label = TerminalText.nonEmpty(child.label) { childLabels[key] = label }
        }
        let tool = presentation.tool(item, childLabels: childLabels)
        var events = show(tool.info).map { [$0] } ?? []
        guard tool.status != .running else { return events }
        background.remove(item.id)
        guard settled[item.id] != tool else { return events }
        settled[item.id] = tool
        events.append(.toolCompleted(id: item.id, status: tool.status, output: tool.output))
        return events
    }

    /// Emits a tool the first time it is seen and again only when its title or detail changed.
    private mutating func show(_ info: ToolCallInfo) -> AgentEvent? {
        guard let shown = tools[info.id] else {
            tools[info.id] = info
            return .toolStarted(info)
        }
        guard shown != info else { return nil }
        tools[info.id] = info
        return .toolUpdated(info)
    }
}
