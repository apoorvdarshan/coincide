import Foundation

/// A bounded projection for one proven native session. Its finite byte/item
/// budget spans this value's lifetime; callers need separate retained values for
/// independent runs to avoid imposing that lifetime budget on an entire chat.
/// The caller owns run/child routing; this type never adopts ambient global
/// activity or decides that an execution has completed.
public struct OpenCodeV2Projection: Sendable {
    public enum ChildOutcome: String, Sendable { case completed, failed, interrupted }
    private let instanceID: UUID
    private let sessionID: String
    private var textStates: [ProviderEntityKey: TextState] = [:]
    private var toolStates: [ProviderEntityKey: ToolState] = [:]
    private var seen = Set<String>()
    private var seenOrder: [String] = []
    private var observedBytes = 0
    private var compaction: ProviderEntityKey?
    private var compactionCount = 0
    private struct TextState: Sendable {
        var bytes = 0
        var chunks = 0
        var ended = false
        var seq: Int?
    }
    private struct ToolState: Sendable {
        var name: String?
        var rawInput = ""
        var terminal = false
        var childTerminal = false
        var seq: Int?
        var childSessionID: String?
        var background = false
    }

    public init(instanceID: UUID, sessionID: String) { self.instanceID = instanceID; self.sessionID = sessionID }

    public func toolKey(assistantMessageID: String, id: String) -> ProviderEntityKey {
        key(type: "tool_call", components: [assistantMessageID, id])
    }

    public func isSubagentCall(assistantMessageID: String, id: String) -> Bool {
        toolStates[toolKey(assistantMessageID: assistantMessageID, id: id)]?.name == "subagent"
    }

    /// A caller must first prove the parent/call/child graph. Only this exact
    /// linked call settles; siblings and the parent execution remain untouched.
    public mutating func childCompleted(assistantMessageID: String, toolID: String, childSessionID: String,
                                        outcome: ChildOutcome) throws -> [ProviderEntityUpdate] {
        let key = toolKey(assistantMessageID: assistantMessageID, id: toolID)
        guard var state = toolStates[key], state.name == "subagent", state.childSessionID == childSessionID else {
            throw OpenCodeV2ProtocolError.invalidOwner
        }
        if state.terminal { return [] }
        state.terminal = true; state.childTerminal = true; toolStates[key] = state
        return [.patch(key, .object(["status": .string(outcome.rawValue), "_meta": .object(["opencode": .object([
            "instanceID": .string(instanceID.uuidString.lowercased()), "sessionID": .string(sessionID),
            "assistantMessageID": .string(assistantMessageID), "toolID": .string(toolID),
            "childSessionID": .string(childSessionID), "background": .bool(state.background)
        ])])]))]
    }

    public mutating func apply(_ event: OpenCodeV2Event) throws -> [ProviderEntityUpdate] {
        guard event.sessionID == sessionID, event.durable?.aggregateID == nil || event.durable?.aggregateID == sessionID else {
            throw OpenCodeV2ProtocolError.invalidOwner
        }
        guard !event.requiresReconciliation else { throw OpenCodeV2ProtocolError.invalidEvent }
        if let id = event.id, seen.contains(id) { return [] }
        let result: [ProviderEntityUpdate]
        switch event.kind {
        case .textStarted, .textDelta, .textEnded, .reasoningStarted, .reasoningDelta, .reasoningEnded:
            result = try text(event)
        case .toolInputStarted, .toolInputDelta, .toolInputEnded, .toolCalled, .toolProgress, .toolSuccess, .toolFailed:
            result = try tool(event)
        case .compactionStarted, .compactionDelta, .compactionEnded, .compactionFailed:
            result = try compact(event)
        default: result = []
        }
        if let id = event.id {
            seen.insert(id); seenOrder.append(id)
            if seenOrder.count > 4_096 { seen.remove(seenOrder.removeFirst()) }
        }
        return result
    }

    private func key(type: String, components: [String]) -> ProviderEntityKey {
        // JSON arrays preserve opaque boundaries, including colons and Unicode.
        let id = String(decoding: (try? JSONEncoder().encode(components)) ?? Data(), as: UTF8.self)
        return .init(sessionID: "opencode:\(instanceID.uuidString.lowercased()):\(sessionID)", type: type, id: id)
    }

    private func metadata(_ event: OpenCodeV2Event, extra: [String: JSONValue] = [:]) -> JSONValue {
        var values: [String: JSONValue] = ["sessionID": .string(sessionID), "instanceID": .string(instanceID.uuidString.lowercased())]
        if let id = event.assistantMessageID { values["assistantMessageID"] = .string(id) }
        if let ordinal = event.ordinal { values["ordinal"] = .number(Double(ordinal)) }
        if let durable = event.durable { values["seq"] = .number(Double(durable.seq)); values["version"] = .number(Double(durable.version)) }
        for (key, value) in extra { values[key] = value }
        return .object(["opencode": .object(values)])
    }

    private mutating func budget(_ bytes: Int, newItem: Bool = false) throws {
        guard bytes >= 0, bytes <= 16_777_216 - observedBytes,
              !newItem || textStates.count + toolStates.count < 4_096 else { throw OpenCodeV2ProtocolError.limitExceeded }
        observedBytes += bytes
    }

    private mutating func text(_ event: OpenCodeV2Event) throws -> [ProviderEntityUpdate] {
        guard let assistant = event.assistantMessageID, let ordinal = event.ordinal else { throw OpenCodeV2ProtocolError.invalidEvent }
        let reasoning = [.reasoningStarted, .reasoningDelta, .reasoningEnded].contains(event.kind)
        let key = key(type: reasoning ? "agent_thought" : "agent_message", components: [assistant, String(ordinal)])
        let previous = textStates[key]
        var state = previous ?? TextState()
        if let seq = event.durable?.seq, let prior = state.seq, seq <= prior { return [] }
        if [.textStarted, .reasoningStarted].contains(event.kind) {
            guard previous == nil else { return [] }
            try budget(0, newItem: true); state.seq = event.durable?.seq; textStates[key] = state
            return [.patch(key, .object(["content": .array([]), "_meta": metadata(event)]))]
        }
        let value = event.text ?? ""
        let ended = [.textEnded, .reasoningEnded].contains(event.kind)
        if !ended && state.ended { return [] }
        let size = value.utf8.count
        guard size <= 4_194_304, ended || size <= 4_194_304 - state.bytes, state.chunks < 65_536 else { throw OpenCodeV2ProtocolError.limitExceeded }
        try budget(size, newItem: previous == nil)
        state.bytes = ended ? size : state.bytes + size; state.chunks += 1
        if let seq = event.durable?.seq { state.seq = seq }
        state.ended = ended; textStates[key] = state
        if ended {
            return [.patch(key, .object(["content": .array([.object(["type": .string("text"), "text": .string(value)])]), "_meta": metadata(event)]))]
        }
        return [.content(key, field: "content", value: .object(["type": .string("text"), "text": .string(value)]), annotation: nil)]
    }

    private mutating func tool(_ event: OpenCodeV2Event) throws -> [ProviderEntityUpdate] {
        guard let tool = event.tool, let assistant = event.assistantMessageID else { throw OpenCodeV2ProtocolError.invalidEvent }
        let key = key(type: "tool_call", components: [assistant, tool.id])
        let previous = toolStates[key]
        var state = previous ?? ToolState()
        if state.childTerminal { return [] }
        if let seq = event.durable?.seq, let prior = state.seq, seq <= prior { return [] }
        if state.terminal && ![.toolSuccess, .toolFailed].contains(event.kind) { return [] }
        if let name = tool.name { state.name = name }
        if let child = tool.childSessionID { state.childSessionID = child }
        if let background = tool.background { state.background = background }
        if let seq = event.durable?.seq { state.seq = seq }
        var patch: [String: JSONValue] = [:], extra: [String: JSONValue] = ["toolID": .string(tool.id)]
        if let child = state.childSessionID { extra["childSessionID"] = .string(child) }
        extra["background"] = .bool(state.background)
        if let executed = tool.executed { extra["executed"] = .bool(executed) }
        if let agent = tool.agentID { extra["agentID"] = .string(agent) }
        if let model = tool.model { extra["model"] = .string(model) }
        if let description = tool.description { extra["description"] = .string(description) }
        patch["title"] = .string(state.name ?? "OpenCode tool")
        patch["kind"] = .string(state.name == "shell" ? "execute" : state.name == "edit" ? "edit" : "other")
        patch["status"] = .string("in_progress")
        switch event.kind {
        case .toolInputDelta:
            let text = tool.text ?? ""
            guard text.utf8.count <= 65_536 - state.rawInput.utf8.count else { throw OpenCodeV2ProtocolError.limitExceeded }
            state.rawInput += text
        case .toolInputEnded:
            let text = tool.text ?? ""
            guard text.utf8.count <= 65_536 else { throw OpenCodeV2ProtocolError.limitExceeded }
            state.rawInput = text
            if let bytes = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: bytes), value.object != nil {
                patch["rawInput"] = try OpenCodeV2Bounds.safeInput(value)
            } else { extra["inputUnavailable"] = .bool(true) }
        case .toolCalled:
            if let input = tool.input { patch["rawInput"] = input }; state.rawInput = ""
        case .toolSuccess, .toolFailed:
            let background = state.name == "subagent" && tool.status == "running"
            if background { state.background = true; extra["background"] = .bool(true) }
            state.terminal = !background
            patch["status"] = .string(background ? "in_progress" : event.kind == .toolSuccess ? "completed" : tool.aborted ? "interrupted" : "failed")
            var content = tool.content.map(Self.content)
            if event.kind == .toolFailed {
                content.append(.object(["type": .string("content"), "content": .object([
                    "type": .string("text"), "text": .string(tool.aborted ? "The native tool was interrupted." : "The native tool failed.")])]))
            }
            patch["content"] = .array(content)
        default: break
        }
        patch["_meta"] = metadata(event, extra: extra)
        let size = try JSONEncoder().encode(JSONValue.object(patch)).count
        try budget(size, newItem: previous == nil); toolStates[key] = state
        // Native question tools are represented by forms, avoiding duplicate tool approval rows.
        if state.name == "question" { return [] }
        return [.patch(key, .object(patch))]
    }

    private static func content(_ content: OpenCodeV2ToolEvent.Content) -> JSONValue {
        let block: JSONValue
        switch content {
        case .text(let text): block = .object(["type": .string("text"), "text": .string(text)])
        case .file(let name, let mime, let uri):
            if let uri { block = .object(["type": .string("resource_link"), "uri": .string(uri), "name": .string(name ?? "Returned file"), "mimeType": .string(mime)]) }
            else { block = .object(["type": .string("text"), "text": .string("Returned file: \(name ?? mime)")]) }
        }
        return .object(["type": .string("content"), "content": block])
    }

    private mutating func compact(_ event: OpenCodeV2Event) throws -> [ProviderEntityUpdate] {
        if event.kind == .compactionStarted {
            compactionCount += 1
            compaction = key(type: "compaction", components: ["compaction", String(compactionCount)])
        }
        guard let key = compaction else { throw OpenCodeV2ProtocolError.invalidEvent }
        try budget(event.text?.utf8.count ?? 0)
        switch event.kind {
        case .compactionStarted: return [.patch(key, .object(["status": .string("in_progress"), "summary": .array([]), "_meta": metadata(event)]))]
        case .compactionDelta: return [.content(key, field: "summary", value: .object(["type": .string("text"), "text": .string(event.text ?? "")]), annotation: nil)]
        case .compactionEnded, .compactionFailed:
            compaction = nil
            return [.patch(key, .object(["status": .string(event.kind == .compactionEnded ? "completed" : "failed"),
                "summary": .array([.object(["type": .string("text"), "text": .string(event.text ?? "")])]), "_meta": metadata(event)]))]
        default: return []
        }
    }
}
