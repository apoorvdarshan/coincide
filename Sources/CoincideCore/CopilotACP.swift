import CryptoKit
import Foundation

public enum CopilotACPChildStatus: String, Sendable, Equatable {
    case running, completed, failed
}

/// A child task remains owned by its original local run after foreground completion.
public struct CopilotACPChildUpdate: Sendable, Equatable {
    public let sessionID: String
    public let childSessionID: String
    public let runID: UUID
    public let toolCallID: String
    public let status: CopilotACPChildStatus
    public let prompt: String
    public let title: String?
    public let model: String?
    public let isBackground: Bool
    public let result: String?

    public var entityUpdate: ProviderEntityUpdate {
        let text = result ?? prompt
        return .patch(.init(sessionID: childSessionID, type: "tool_call", id: "copilot-child-lifecycle"), .object([
            "title": .string(title ?? "Copilot task"),
            "status": .string(status == .running ? "in_progress" : status.rawValue),
            "content": .array([.object(["type": .string("content"), "content": .object(["type": .string("text"), "text": .string(text)])])]),
            "_meta": .object(["github.com/copilot": .object([
                "parentSessionId": .string(sessionID), "parentRunID": .string(runID.uuidString), "parentToolCallId": .string(toolCallID),
                "background": .bool(isBackground), "model": model.map(JSONValue.string) ?? .null])])
        ]))
    }
}

public struct CopilotACPRoutedUpdate: Sendable, Equatable {
    public let sessionID: String
    public let runID: UUID?
    public let update: JSONValue
    public let child: Bool
    public let children: [CopilotACPChildUpdate]
}

/// One instance belongs to one ACP transport. Feed notifications and session updates
/// in their actual reader order; never share a bridge between provider processes.
/// No permissions, auth or protocol capabilities beyond Copilot's raw-event feed
/// are advertised here. Unknown child ownership is discarded instead of guessed.
public struct CopilotACPBridge: Sendable {
    public static let notificationMethod = "_github.com/copilot/sessionEvent"
    public static let clientCapabilitiesMetadata: JSONValue = .object(["github.com/copilot": .object([
        "events": .array(["subagent.started", "subagent.completed", "subagent.failed",
                          "assistant.message_delta", "assistant.reasoning_delta"].map(JSONValue.string))])])
    public static let failureMessage = "The Copilot agent event could not be processed safely. Reconnect before continuing."
    public static let maximumSessions = 8
    public static let maximumTools = 4_096
    public static let maximumChildren = 256
    public static let maximumAgents = 1_024
    public static let maximumTextBytes = 262_144
    public static let maximumRetainedBytes = 4_194_304

    private struct Delta: Sendable {
        let kind: String
        let text: String
        let rootRunID: UUID?
        let taskID: String?
        let ownerRunID: UUID?
    }
    private struct Tool: Sendable {
        let runID: UUID
        var input: [String: String] = [:]
        var status: String?
        var output: String?
        var terminal: CopilotACPChildStatus?
        var published: CopilotACPChildUpdate?
        var isChild: Bool { input["agent_type"] != nil && input["prompt"] != nil }
    }
    private struct Session: Sendable {
        var runID: UUID?
        var delta: Delta?
        var invalidatedChunk = false
        var hasRawDeltas = false
        var tools: [String: Tool] = [:]
        var taskByAgent: [String: String] = [:]
    }
    private var sessions: [String: Session] = [:]

    public init() {}

    public mutating func beginRun(sessionID: String, runID: UUID) throws {
        try Self.identifier(sessionID)
        let sessionKey = Self.key(sessionID)
        var session = sessions[sessionKey] ?? Session()
        if session.runID == runID { return }
        guard session.runID == nil || session.runID == runID else { throw Self.failure() }
        guard sessions[sessionKey] != nil || sessions.count < Self.maximumSessions else { throw Self.failure() }
        session.invalidatedChunk = session.invalidatedChunk || session.delta != nil
        session.runID = runID; session.delta = nil; sessions[sessionKey] = session
    }

    public mutating func finishRun(sessionID: String, runID: UUID) {
        let sessionKey = Self.key(sessionID)
        guard var session = sessions[sessionKey], session.runID == runID else { return }
        session.invalidatedChunk = session.invalidatedChunk || session.delta != nil
        // Unbound starts cannot acquire the next run's task identity later.
        let knownTasks = Set(session.tools.filter { $0.value.isChild }.keys)
        session.taskByAgent = session.taskByAgent.filter { knownTasks.contains(Self.key($0.value)) }
        session.runID = nil; session.delta = nil; sessions[sessionKey] = session
    }

    /// Call on an intervening non-notification frame if it breaks raw-delta/chunk adjacency.
    public mutating func invalidatePendingDeltas() {
        for key in Array(sessions.keys) {
            if sessions[key]?.delta != nil { sessions[key]?.invalidatedChunk = true }
            sessions[key]?.delta = nil
        }
    }

    public mutating func reset() { sessions = [:] }

    /// Only the advertised extension method is consumed. Other notifications clear
    /// pending pairings, except session/update, which routeSessionUpdate consumes.
    public mutating func consumeNotification(method: String, params: JSONValue) throws -> [CopilotACPChildUpdate] {
        guard method == Self.notificationMethod || method == "github.com/copilot/sessionEvent" else {
            if method != "session/update" { invalidatePendingDeltas() }
            return []
        }
        let previous = sessions
        do {
            try Self.bounded(params)
            let object = try Self.object(params)
            let sessionID = try Self.id(object["sessionId"])
            let sessionKey = Self.key(sessionID)
            let kind = try Self.id(object["type"])
            guard var session = sessions[sessionKey] else { return [] }
            let data: [String: JSONValue]
            if let raw = object["data"], raw != .null { data = try Self.object(raw) }
            else { data = [:] }
            let agentID = try Self.optionalID(object["agentId"])
            if kind == "assistant.message_delta" || kind == "assistant.reasoning_delta" {
                session.hasRawDeltas = true
                guard let text = try Self.optionalText(data["deltaContent"]) else {
                    session.invalidatedChunk = session.invalidatedChunk || session.delta != nil
                    session.delta = nil; sessions[sessionKey] = session; return []
                }
                let taskID = try Self.optionalID(data["parentToolCallId"])
                let task = taskID.flatMap { session.tools[Self.key($0)] }
                session.delta = .init(kind: kind, text: text, rootRunID: session.runID, taskID: taskID,
                    ownerRunID: task?.isChild == true ? task?.runID : nil)
                session.invalidatedChunk = false
                sessions[sessionKey] = session
                try checkBounds()
                return []
            }
            session.invalidatedChunk = session.invalidatedChunk || session.delta != nil
            session.delta = nil
            if kind == "subagent.started" {
                if let agentID, let taskID = try Self.optionalID(data["toolCallId"]) {
                    if let old = session.taskByAgent[Self.key(agentID)], !Self.exact(old, taskID) { throw Self.failure() }
                    session.taskByAgent[Self.key(agentID)] = taskID
                }
            } else if kind == "subagent.completed" || kind == "subagent.failed" {
                guard let taskID = try Self.optionalID(data["toolCallId"]), var tool = session.tools[Self.key(taskID)], tool.isChild else {
                    sessions[sessionKey] = session; return []
                }
                if let agentID, let mapped = session.taskByAgent[Self.key(agentID)], !Self.exact(mapped, taskID) { throw Self.failure() }
                // A repeated or contradictory late completion cannot reopen or rewrite a child.
                guard tool.terminal == nil else { sessions[sessionKey] = session; return [] }
                tool.terminal = kind == "subagent.failed" ? .failed : .completed
                if let error = try Self.optionalText(data["error"]) { tool.output = error }
                let child = Self.child(tool, sessionID: sessionID, toolID: taskID)
                tool.published = child; session.tools[Self.key(taskID)] = tool
                session.taskByAgent = session.taskByAgent.filter { !Self.exact($0.value, taskID) }
                sessions[sessionKey] = session
                try checkBounds()
                return [child]
            }
            sessions[sessionKey] = session
            try checkBounds()
            return []
        } catch { sessions = previous; invalidatePendingDeltas(); throw Self.failure() }
    }

    /// Returns nil for foreign roots, unowned children, or unsafe stale chunks.
    /// The returned sessionID may be a child; preserve it and runID at emission.
    public mutating func routeSessionUpdate(_ params: JSONValue) throws -> CopilotACPRoutedUpdate? {
        let previous = sessions
        do {
            try Self.bounded(params)
            let object = try Self.object(params)
            let sessionID = try Self.id(object["sessionId"])
            let sessionKey = Self.key(sessionID)
            guard var session = sessions[sessionKey] else { return nil }
            let update = try Self.object(object["update"] ?? .null)
            let kind = try Self.id(update["sessionUpdate"])
            if kind == "agent_message_chunk" || kind == "agent_thought_chunk" {
                let delta = session.delta, invalidated = session.invalidatedChunk
                session.delta = nil; session.invalidatedChunk = false; sessions[sessionKey] = session
                let expected = kind == "agent_message_chunk" ? "assistant.message_delta" : "assistant.reasoning_delta"
                if let delta {
                    let content = update["content"] ?? .null
                    guard delta.kind == expected, content["type"].string == "text",
                          let text = content["text"].string, Self.exact(text, delta.text) else { return nil }
                    if let taskID = delta.taskID {
                        guard let tool = session.tools[Self.key(taskID)], tool.isChild, let owner = delta.ownerRunID,
                              tool.runID == owner, tool.terminal == nil else { return nil }
                        return .init(sessionID: Self.childSessionID(sessionID, taskID), runID: owner, update: .object(update), child: true, children: [])
                    }
                    guard let runID = delta.rootRunID, session.runID == runID else { return nil }
                    return .init(sessionID: sessionID, runID: runID, update: .object(update), child: false, children: [])
                }
                // Older peers may not implement the opt-in feed. Standard root
                // output is allowed only during the captured active foreground run.
                guard !invalidated, !session.hasRawDeltas, let runID = session.runID else { return nil }
                return .init(sessionID: sessionID, runID: runID, update: .object(update), child: false, children: [])
            }
            session.invalidatedChunk = session.invalidatedChunk || session.delta != nil
            session.delta = nil
            var children: [CopilotACPChildUpdate] = []
            if kind == "tool_call" || kind == "tool_call_update" {
                let toolID = try Self.id(update["toolCallId"])
                let toolKey = Self.key(toolID)
                let metadata = update["_meta"] ?? .null
                let agentID = try Self.optionalID(metadata["github.com/copilot"]["agentId"])
                if let agentID {
                    guard let taskID = session.taskByAgent[Self.key(agentID)], let parent = session.tools[Self.key(taskID)], parent.isChild,
                          parent.terminal == nil else { sessions[sessionKey] = session; return nil }
                    sessions[sessionKey] = session
                    return .init(sessionID: Self.childSessionID(sessionID, taskID), runID: parent.runID, update: .object(update), child: true, children: [])
                }
                var tool: Tool
                if let previous = session.tools[toolKey] {
                    guard kind != "tool_call" || session.runID == previous.runID else { throw Self.failure() }
                    tool = previous
                }
                else {
                    guard let runID = session.runID else { sessions[sessionKey] = session; return nil }
                    tool = .init(runID: runID)
                }
                if tool.terminal != nil, tool.isChild {
                    sessions[sessionKey] = session
                    return .init(sessionID: sessionID, runID: tool.runID, update: .object(update), child: false, children: [])
                }
                if let fields = update["rawInput"]?.object {
                    for key in ["agent_type", "prompt", "description", "model", "mode"] {
                        if let raw = fields[key], raw.string != nil, let value = try Self.optionalText(raw) {
                            if tool.isChild, key != "description", let previous = tool.input[key], !Self.exact(previous, value) { throw Self.failure() }
                            tool.input[key] = value
                        }
                    }
                }
                if let status = try Self.optionalID(update["status"]) { tool.status = status }
                if let output = update["rawOutput"]?.object, output["content"]?.string != nil,
                   let text = try Self.optionalText(output["content"]) { tool.output = text }
                if tool.isChild {
                    // Foreground child tool completion is its own completion. A
                    // background launcher completing is not the background task ending.
                    if tool.terminal == nil {
                        if tool.status == "failed" { tool.terminal = .failed }
                        else if tool.status == "completed", tool.input["mode"] != "background" { tool.terminal = .completed }
                    }
                    let child = Self.child(tool, sessionID: sessionID, toolID: toolID)
                    if child != tool.published { children = [child]; tool.published = child }
                }
                session.tools[toolKey] = tool; sessions[sessionKey] = session
                try checkBounds()
                return .init(sessionID: sessionID, runID: tool.runID, update: .object(update), child: false, children: children)
            }
            sessions[sessionKey] = session
            return .init(sessionID: sessionID, runID: session.runID, update: .object(update), child: false, children: [])
        } catch { sessions = previous; invalidatePendingDeltas(); throw Self.failure() }
    }

    private static func childSessionID(_ sessionID: String, _ toolID: String) -> String {
        let data = (try? JSONEncoder().encode([sessionID, toolID])) ?? Data()
        return "copilot-task:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func child(_ tool: Tool, sessionID: String, toolID: String) -> CopilotACPChildUpdate {
        .init(sessionID: sessionID, childSessionID: childSessionID(sessionID, toolID), runID: tool.runID, toolCallID: toolID,
              status: tool.terminal ?? .running, prompt: tool.input["prompt"] ?? "", title: tool.input["description"],
              model: tool.input["model"], isBackground: tool.input["mode"] == "background",
              result: tool.terminal == nil ? nil : tool.output)
    }

    private func checkBounds() throws {
        var tools = 0, children = 0, agents = 0, bytes = 0
        for (id, session) in sessions {
            bytes += id.utf8.count; tools += session.tools.count; agents += session.taskByAgent.count
            if let delta = session.delta { bytes += delta.text.utf8.count }
            for (agentID, taskID) in session.taskByAgent { bytes += agentID.utf8.count + taskID.utf8.count }
            for (id, tool) in session.tools {
                bytes += id.utf8.count + (tool.output?.utf8.count ?? 0)
                bytes += tool.input.values.reduce(0) { $0 + $1.utf8.count }
                if tool.isChild { children += 1 }
            }
        }
        guard tools <= Self.maximumTools, children <= Self.maximumChildren,
              agents <= Self.maximumAgents, bytes <= Self.maximumRetainedBytes else { throw Self.failure() }
    }

    private static func failure() -> CoincideError { CoincideError(failureMessage) }
    // Swift String equality normalizes Unicode. Provider IDs and delta text do not.
    private static func key(_ value: String) -> String { Data(value.utf8).base64EncodedString() }
    private static func exact(_ first: String, _ second: String) -> Bool { first.utf8.elementsEqual(second.utf8) }
    private static func identifier(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw failure() }
    }
    private static func id(_ value: JSONValue?) throws -> String {
        guard let value, case .string(let result) = value else { throw failure() }
        try identifier(result); return result
    }
    private static func optionalID(_ value: JSONValue?) throws -> String? {
        guard let value, value != .null else { return nil }; return try id(value)
    }
    private static func optionalText(_ value: JSONValue?) throws -> String? {
        guard let value, value != .null else { return nil }
        guard case .string(let text) = value, text.utf8.count <= maximumTextBytes else { throw failure() }; return text
    }
    private static func object(_ value: JSONValue) throws -> [String: JSONValue] {
        guard let object = value.object else { throw failure() }; return object
    }
    private static func bounded(_ value: JSONValue) throws {
        var stack: [(JSONValue, Int)] = [(value, 0)], bytes = 0, nodes = 0
        while let (value, depth) = stack.popLast() {
            nodes += 1
            guard nodes <= 8_192, depth <= 24 else { throw failure() }
            switch value {
            case .string(let text): bytes += text.utf8.count
            case .object(let fields):
                guard stack.count + fields.count <= 8_192 - nodes else { throw failure() }
                for (key, child) in fields { bytes += key.utf8.count; stack.append((child, depth + 1)) }
            case .array(let children):
                guard stack.count + children.count <= 8_192 - nodes else { throw failure() }
                for child in children { stack.append((child, depth + 1)) }
            case .number(let value): guard value.isFinite else { throw failure() }
            case .bool, .null: break
            }
            guard bytes <= 1_048_576 else { throw failure() }
        }
    }
}
