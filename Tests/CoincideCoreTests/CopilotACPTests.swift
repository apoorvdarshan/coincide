import Foundation
import Testing
@testable import CoincideCore

private func copilotUpdate(_ session: String = "root", _ fields: [String: JSONValue]) -> JSONValue {
    .object(["sessionId": .string(session), "update": .object(fields)])
}

@discardableResult
private func copilotTool(_ bridge: inout CopilotACPBridge, session: String = "root", id: String = "task",
                         background: Bool = true, status: String = "in_progress", prompt: String = "Inspect the synthetic fixture") throws -> CopilotACPRoutedUpdate {
    let value = try bridge.routeSessionUpdate(copilotUpdate(session, ["sessionUpdate": .string("tool_call"), "toolCallId": .string(id),
        "status": .string(status), "rawInput": .object(["agent_type": .string("explore"), "prompt": .string(prompt),
            "description": .string("Synthetic child"), "model": .string("advertised-model"), "mode": .string(background ? "background" : "sync")])]))
    return try #require(value)
}

@discardableResult
private func copilotRaw(_ bridge: inout CopilotACPBridge, session: String = "root", type: String,
                        data: [String: JSONValue] = [:], agent: String? = nil, method: String = CopilotACPBridge.notificationMethod) throws -> [CopilotACPChildUpdate] {
    var fields: [String: JSONValue] = ["sessionId": .string(session), "type": .string(type), "data": .object(data)]
    if let agent { fields["agentId"] = .string(agent) }
    return try bridge.consumeNotification(method: method, params: .object(fields))
}

private func copilotDelta(_ bridge: inout CopilotACPBridge, session: String = "root", text: String = "same text", task: String? = nil,
                          reasoning: Bool = false) throws {
    var fields: [String: JSONValue] = ["deltaContent": .string(text)]
    if let task { fields["parentToolCallId"] = .string(task) }
    try copilotRaw(&bridge, session: session, type: reasoning ? "assistant.reasoning_delta" : "assistant.message_delta", data: fields)
}

private func copilotChunk(_ bridge: inout CopilotACPBridge, session: String = "root", text: String = "same text", reasoning: Bool = false) throws -> CopilotACPRoutedUpdate? {
    try bridge.routeSessionUpdate(copilotUpdate(session, ["sessionUpdate": .string(reasoning ? "agent_thought_chunk" : "agent_message_chunk"),
        "messageId": .string("native-message"), "content": .object(["type": .string("text"), "text": .string(text)])]))
}

private func copilotRejects(_ body: () throws -> Void) {
    do { try body(); Issue.record("An unsafe synthetic Copilot event was accepted.") }
    catch {
        #expect(error.localizedDescription == CopilotACPBridge.failureMessage)
        #expect(!error.localizedDescription.contains("synthetic-private-token"))
    }
}

@Test func copilotACPAdvertisesOnlyExactRawEventMetadataAndHandlesCanonicalAndLegacyMethodNames() throws {
    let events = CopilotACPBridge.clientCapabilitiesMetadata["github.com/copilot"]["events"].array?.compactMap(\.string)
    #expect(events == ["subagent.started", "subagent.completed", "subagent.failed", "assistant.message_delta", "assistant.reasoning_delta"])
    #expect(CopilotACPBridge.notificationMethod == "_github.com/copilot/sessionEvent")
    for method in [CopilotACPBridge.notificationMethod, "github.com/copilot/sessionEvent"] {
        var bridge = CopilotACPBridge(); let run = UUID()
        try bridge.beginRun(sessionID: "root", runID: run)
        try copilotRaw(&bridge, type: "assistant.message_delta", data: ["deltaContent": .string("exact")], method: method)
        let result = try #require(copilotChunk(&bridge, text: "exact"))
        #expect(result.runID == run)
        #expect(!result.child)
    }
}

@Test func copilotACPStandardRootOutputWorksWithoutRawFeedOnlyWhileItsRunIsActive() throws {
    var bridge = CopilotACPBridge(); let run = UUID()
    try bridge.beginRun(sessionID: "root", runID: run)
    #expect(try copilotChunk(&bridge)?.runID == run)
    bridge.finishRun(sessionID: "root", runID: UUID())
    #expect(try copilotChunk(&bridge)?.runID == run)
    bridge.finishRun(sessionID: "root", runID: run)
    #expect(try copilotChunk(&bridge) == nil)
    #expect(try bridge.routeSessionUpdate(copilotUpdate("foreign", ["sessionUpdate": .string("agent_message_chunk")])) == nil)
}

@Test func copilotACPExactUnicodeAndLineSeparatorBytesArePreservedAndRawPairIsUsedOnce() throws {
    var bridge = CopilotACPBridge(); let run = UUID()
    let text = "a\n日本語😀\u{2028}\u{2029}e\u{301}"
    try bridge.beginRun(sessionID: "root", runID: run)
    try copilotDelta(&bridge, text: text)
    let result = try #require(copilotChunk(&bridge, text: text))
    #expect(result.update["content"]["text"].string.map { Data($0.utf8) } == Data(text.utf8))
    #expect(try copilotChunk(&bridge, text: text) == nil)
}

@Test func copilotACPCanonicallyEquivalentTextAndOpaqueIDsRemainByteDistinct() throws {
    var bridge = CopilotACPBridge(); let first = UUID(), second = UUID()
    let composed = "\u{e9}", decomposed = "e\u{301}"
    // Swift strings compare canonically equal; native IDs and raw deltas do not.
    #expect(composed == decomposed)
    #expect(Data(composed.utf8) != Data(decomposed.utf8))
    try bridge.beginRun(sessionID: composed, runID: first)
    try bridge.beginRun(sessionID: decomposed, runID: second)
    let one = try copilotTool(&bridge, session: composed, id: composed).children[0]
    let two = try copilotTool(&bridge, session: decomposed, id: decomposed).children[0]
    #expect(one.childSessionID != two.childSessionID)
    try copilotDelta(&bridge, session: composed, text: composed, task: composed)
    #expect(try copilotChunk(&bridge, session: composed, text: decomposed) == nil)
    try copilotDelta(&bridge, session: decomposed, text: decomposed, task: decomposed)
    let routed = try #require(copilotChunk(&bridge, session: decomposed, text: decomposed))
    #expect(routed.sessionID == two.childSessionID && routed.runID == second)
}

@Test func copilotACPIdempotentRunRegistrationDoesNotConsumeItsPendingRawPair() throws {
    var bridge = CopilotACPBridge(); let run = UUID()
    try bridge.beginRun(sessionID: "root", runID: run)
    try copilotTool(&bridge)
    try copilotDelta(&bridge, task: "task")
    try bridge.beginRun(sessionID: "root", runID: run)
    let chunk = try copilotChunk(&bridge)
    let routed = try #require(chunk)
    #expect(routed.child && routed.runID == run)
}

@Test func copilotACPBackgroundChildSurvivesForegroundExitAndOnlyItsOwnRawCompletionEndsIt() throws {
    var bridge = CopilotACPBridge(); let run = UUID()
    try bridge.beginRun(sessionID: "root", runID: run)
    let launch = try copilotTool(&bridge, status: "completed")
    let child = try #require(launch.children.first)
    #expect(child.status == .running)
    #expect(child.isBackground)
    let entity = try child.entityUpdate.apply(to: nil)
    #expect(entity.fields["_meta"]["github.com/copilot"]["parentRunID"].string == run.uuidString)
    #expect(entity.fields["status"].string == "in_progress")
    #expect(entity.text.contains("Inspect the synthetic fixture"))
    bridge.finishRun(sessionID: "root", runID: run)
    try copilotDelta(&bridge, task: "task")
    let chunk = try copilotChunk(&bridge)
    let output = try #require(chunk)
    #expect(output.child && output.runID == run)
    #expect(output.sessionID == child.childSessionID)
    let completed = try copilotRaw(&bridge, type: "subagent.completed", data: ["toolCallId": .string("task")])
    #expect(completed.map(\.status) == [.completed])
    #expect(completed[0].runID == run)
    #expect(try copilotRaw(&bridge, type: "subagent.failed", data: ["toolCallId": .string("task"), "error": .string("late failure")]).isEmpty)
    try copilotDelta(&bridge, task: "task")
    #expect(try copilotChunk(&bridge) == nil)
}

@Test func copilotACPSameToolIDsAndTextNeverCrossRootSessionOrRuntimeIdentity() throws {
    var bridge = CopilotACPBridge(); let first = UUID(), second = UUID()
    try bridge.beginRun(sessionID: "one", runID: first); try bridge.beginRun(sessionID: "two", runID: second)
    let one = try copilotTool(&bridge, session: "one").children[0]
    let two = try copilotTool(&bridge, session: "two").children[0]
    #expect(one.childSessionID != two.childSessionID)
    try copilotDelta(&bridge, session: "one", task: "task")
    try copilotDelta(&bridge, session: "two", task: "task")
    let routedTwo = try #require(copilotChunk(&bridge, session: "two"))
    let routedOne = try #require(copilotChunk(&bridge, session: "one"))
    #expect(routedTwo.runID == second && routedTwo.sessionID == two.childSessionID)
    #expect(routedOne.runID == first && routedOne.sessionID == one.childSessionID)
    var otherRuntime = CopilotACPBridge()
    try otherRuntime.beginRun(sessionID: "one", runID: UUID())
    try copilotDelta(&otherRuntime, session: "one", task: "task")
    #expect(try copilotChunk(&otherRuntime, session: "one") == nil)
}

@Test(arguments: ["text", "kind", "unknown-child", "run-boundary", "intervening-frame"])
func copilotACPUnprovenOrStaleRawPairNeverFallsBackToRoot(_ mode: String) throws {
    var bridge = CopilotACPBridge(); let run = UUID()
    try bridge.beginRun(sessionID: "root", runID: run)
    try copilotDelta(&bridge, task: mode == "unknown-child" ? "unknown-task" : nil)
    if mode == "run-boundary" {
        bridge.finishRun(sessionID: "root", runID: run); try bridge.beginRun(sessionID: "root", runID: UUID())
    }
    if mode == "intervening-frame" { bridge.invalidatePendingDeltas() }
    #expect(try copilotChunk(&bridge, text: mode == "text" ? "different text" : "same text", reasoning: mode == "kind") == nil)
    #expect(try copilotChunk(&bridge) == nil)
}

@Test func copilotACPChildAgentToolRoutingKeepsSiblingsSeparateAndIgnoresUnknownAgent() throws {
    var bridge = CopilotACPBridge(); let run = UUID()
    try bridge.beginRun(sessionID: "root", runID: run)
    let first = try copilotTool(&bridge, id: "first").children[0]
    let second = try copilotTool(&bridge, id: "second").children[0]
    try copilotRaw(&bridge, type: "subagent.started", data: ["toolCallId": .string("first")], agent: "agent-one")
    try copilotRaw(&bridge, type: "subagent.started", data: ["toolCallId": .string("second")], agent: "agent-two")
    func toolUpdate(_ agent: String) -> JSONValue { copilotUpdate("root", ["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("nested-tool"),
        "_meta": .object(["github.com/copilot": .object(["agentId": .string(agent)])])]) }
    #expect(try bridge.routeSessionUpdate(toolUpdate("agent-one"))?.sessionID == first.childSessionID)
    #expect(try bridge.routeSessionUpdate(toolUpdate("agent-two"))?.sessionID == second.childSessionID)
    #expect(try bridge.routeSessionUpdate(toolUpdate("unknown")) == nil)
    let ended = try copilotRaw(&bridge, type: "subagent.failed", data: ["toolCallId": .string("first"), "error": .string("Synthetic child failure")], agent: "agent-one")
    #expect(ended[0].status == .failed)
    #expect(ended[0].result == "Synthetic child failure")
    #expect(try bridge.routeSessionUpdate(toolUpdate("agent-one")) == nil)
    #expect(try bridge.routeSessionUpdate(toolUpdate("agent-two"))?.sessionID == second.childSessionID)
}

@Test func copilotACPPartialTaskMetadataAndArbitraryNonTaskToolOutputsRemainCompatible() throws {
    var bridge = CopilotACPBridge(); let run = UUID()
    try bridge.beginRun(sessionID: "root", runID: run)
    let initial = try bridge.routeSessionUpdate(copilotUpdate("root", ["sessionUpdate": .string("tool_call"), "toolCallId": .string("partial"),
        "rawInput": .object(["agent_type": .string("explore")]), "rawOutput": .array([.string("ordinary tool output")])]))
    #expect(initial?.children.isEmpty == true)
    let finished = try bridge.routeSessionUpdate(copilotUpdate("root", ["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("partial"),
        "rawInput": .object(["prompt": .string("Synthetic foreground task")]), "status": .string("completed"),
        "rawOutput": .object(["content": .string("Synthetic result")])]))
    let child = try #require(finished?.children.first)
    #expect(child.status == .completed && !child.isBackground)
    #expect(child.result == "Synthetic result")
    let late = try bridge.routeSessionUpdate(copilotUpdate("root", ["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("partial"),
        "status": .string("in_progress"), "rawOutput": .object(["content": .string("late overwrite")])]))
    #expect(late?.children.isEmpty == true)
}

@Test func copilotACPOldBackgroundOwnerCannotBeReboundOrCompletedByNewRunOrUnknownTask() throws {
    var bridge = CopilotACPBridge(); let old = UUID(), current = UUID()
    try bridge.beginRun(sessionID: "root", runID: old)
    try copilotTool(&bridge)
    bridge.finishRun(sessionID: "root", runID: old); try bridge.beginRun(sessionID: "root", runID: current)
    copilotRejects { _ = try copilotTool(&bridge) }
    try copilotDelta(&bridge, task: "task")
    #expect(try copilotChunk(&bridge)?.runID == old)
    #expect(try copilotRaw(&bridge, type: "subagent.completed", data: ["toolCallId": .string("unknown")]).isEmpty)
    let new = try copilotTool(&bridge, id: "new-task").children[0]
    #expect(new.runID == current)
    let ended = try copilotRaw(&bridge, type: "subagent.completed", data: ["toolCallId": .string("task")])
    #expect(ended[0].runID == old)
    try copilotDelta(&bridge, task: "new-task")
    #expect(try copilotChunk(&bridge)?.runID == current)
    bridge.reset()
    #expect(try copilotChunk(&bridge) == nil)
}

@Test func copilotACPUnboundAgentStartCannotAcquireNextRunsSameNamedTask() throws {
    var bridge = CopilotACPBridge(); let old = UUID(), current = UUID()
    try bridge.beginRun(sessionID: "root", runID: old)
    try copilotRaw(&bridge, type: "subagent.started", data: ["toolCallId": .string("task")], agent: "old-agent")
    bridge.finishRun(sessionID: "root", runID: old)
    try bridge.beginRun(sessionID: "root", runID: current)
    try copilotTool(&bridge)
    let stale = try bridge.routeSessionUpdate(copilotUpdate("root", ["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("nested"),
        "_meta": .object(["github.com/copilot": .object(["agentId": .string("old-agent")])])]))
    #expect(stale == nil)
    try copilotDelta(&bridge, task: "task")
    #expect(try copilotChunk(&bridge)?.runID == current)
}

@Test func copilotACPAgentIDReassignmentRejectsWithoutChangingPriorOwnership() throws {
    var bridge = CopilotACPBridge(); try bridge.beginRun(sessionID: "root", runID: UUID())
    let child = try copilotTool(&bridge).children[0]
    try copilotTool(&bridge, id: "other")
    try copilotRaw(&bridge, type: "subagent.started", data: ["toolCallId": .string("task")], agent: "same-agent")
    copilotRejects { _ = try copilotRaw(&bridge, type: "subagent.started", data: ["toolCallId": .string("other")], agent: "same-agent") }
    let routed = try bridge.routeSessionUpdate(copilotUpdate("root", ["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("nested"),
        "_meta": .object(["github.com/copilot": .object(["agentId": .string("same-agent")])])]))
    #expect(routed?.sessionID == child.childSessionID)
}

@Test(arguments: ["text", "depth", "session", "children", "aggregate-bytes"])
func copilotACPBoundedStateRejectsWithoutEvictingOrRebindingOwnedChildren(_ mode: String) throws {
    var bridge = CopilotACPBridge(); try bridge.beginRun(sessionID: "root", runID: UUID())
    let owned = try copilotTool(&bridge).children[0]
    if mode == "text" {
        copilotRejects { try copilotDelta(&bridge, text: String(repeating: "x", count: CopilotACPBridge.maximumTextBytes + 1)) }
    } else if mode == "depth" {
        var nested: JSONValue = .string("synthetic-private-token")
        for _ in 0..<25 { nested = .object(["nested": nested]) }
        copilotRejects { _ = try copilotRaw(&bridge, type: "future-event", data: ["nested": nested]) }
    } else if mode == "session" {
        for index in 1..<CopilotACPBridge.maximumSessions { try bridge.beginRun(sessionID: "root-\(index)", runID: UUID()) }
        copilotRejects { try bridge.beginRun(sessionID: "one-too-many", runID: UUID()) }
    } else if mode == "children" {
        for index in 1..<CopilotACPBridge.maximumChildren { try copilotTool(&bridge, id: "task-\(index)") }
        copilotRejects { _ = try copilotTool(&bridge, id: "one-too-many") }
    } else {
        let prompt = String(repeating: "x", count: CopilotACPBridge.maximumTextBytes)
        for index in 1...15 { try copilotTool(&bridge, id: "large-\(index)", prompt: prompt) }
        copilotRejects { _ = try copilotTool(&bridge, id: "one-too-many", prompt: prompt) }
    }
    try copilotDelta(&bridge, task: "task")
    #expect(try copilotChunk(&bridge)?.sessionID == owned.childSessionID)
}

@Test func copilotACPUnknownMethodsNeverAdvertiseOrSynthesizePermissionOrAuthenticationResponses() throws {
    var bridge = CopilotACPBridge(); try bridge.beginRun(sessionID: "root", runID: UUID())
    #expect(try bridge.consumeNotification(method: "_github.com/copilot/sessionEvent/forged", params: .null).isEmpty)
    #expect(try bridge.consumeNotification(method: "authenticate", params: .null).isEmpty)
    #expect(try bridge.consumeNotification(method: "session/request_permission", params: .null).isEmpty)
}
