import Foundation
import Testing
@testable import CoincideCore

private let claudeUsageNow = Date(timeIntervalSince1970: 1_700_000_000)
private func claudeUsageCounts(input: Double = 100, cached: Double = 20, created: Double = 30, output: Double = 0, thinking: Double? = nil) -> JSONValue {
    var value: [String: JSONValue] = ["input_tokens": .number(input), "cache_read_input_tokens": .number(cached),
        "cache_creation_input_tokens": .number(created), "output_tokens": .number(output)]
    if let thinking { value["output_tokens_details"] = .object(["thinking_tokens": .number(thinking)]) }
    return .object(value)
}
private func claudeUsageStart(id: String = "request-a", usage: JSONValue, model: String = "native-model") -> JSONValue {
    .object(["type": .string("message_start"), "message": .object(["id": .string(id), "model": .string(model), "usage": usage])])
}
private func claudeUsageAssistant(id: String = "request-a", usage: JSONValue, model: String = "native-model") -> JSONValue {
    .object(["message": .object(["id": .string(id), "model": .string(model), "usage": usage])])
}
private func claudeUsageResult(input: Double = 10, output: Double = 4, cost: Double = 0.12, modelInput: Double = 400,
                               subtype: String = "success", id: String = "result-one") -> JSONValue {
    .object(["uuid": .string(id), "subtype": .string(subtype),
        "usage": claudeUsageCounts(input: input, cached: 2, created: 3, output: output, thinking: 1),
        "total_cost_usd": .number(cost), "modelUsage": .object(["native-model": .object([
            "inputTokens": .number(modelInput), "outputTokens": .number(75), "thinkingTokens": .number(9),
            "cacheReadInputTokens": .number(120), "cacheCreationInputTokens": .number(80), "webSearchRequests": .number(2),
            "costUSD": .number(cost), "contextWindow": .number(200_000), "maxOutputTokens": .number(8_000),
            "canonicalModel": .string("native-model"), "provider": .string("firstParty"), "costBasis": .string("managed"),
            "privateCredential": .string("PRIVATE-MUST-NOT-PERSIST")])])])
}

@Test func claudeUsageProgressiveCountersAreCumulativeSparseAndDuplicateBlocksNeverAddTokens() throws {
    var state = ClaudeUsageAccumulator(); let runID = UUID()
    state.beginTurn(runID: runID, now: claudeUsageNow)
    var raw = claudeUsageCounts(output: 1).object!
    raw["cache_creation"] = .object(["ephemeral_5m_input_tokens": .number(30), "ephemeral_1h_input_tokens": .number(0)])
    let streamChanged1 = state.stream(claudeUsageStart(usage: .object(raw)), now: claudeUsageNow)
    #expect(streamChanged1)
    #expect(state.snapshot?.context?.inputTokens == 150 && state.snapshot?.context?.usedTokens == 151)
    #expect(state.snapshot?.context?.promptCacheExpiresAt == claudeUsageNow.addingTimeInterval(300))
    #expect(state.snapshot?.context?.maxTokens == nil, "A known model name does not invent a native capacity.")
    let delta: JSONValue = .object(["type": .string("message_delta"), "usage": .object([
        "input_tokens": .null, "cache_read_input_tokens": .number(0), "cache_creation_input_tokens": .null, "output_tokens": .number(6)])])
    let streamChanged2 = state.stream(delta, now: claudeUsageNow.addingTimeInterval(1))
    #expect(streamChanged2)
    #expect(state.snapshot?.context?.inputTokens == 130 && state.snapshot?.context?.cachedInputTokens == 0)
    #expect(state.snapshot?.context?.cacheCreationTokens == 30 && state.snapshot?.context?.usedTokens == 136)
    let revision = state.snapshot?.revision
    let streamChanged3 = state.stream(delta, now: claudeUsageNow.addingTimeInterval(2))
    #expect(!streamChanged3)
    let assistantChanged1 = state.assistant(claudeUsageAssistant(usage: claudeUsageCounts(input: 500, output: 99)), now: claudeUsageNow.addingTimeInterval(3))
    #expect(!assistantChanged1)
    #expect(state.snapshot?.revision == revision && state.snapshot?.context?.usedTokens == 136)
    let streamChanged4 = state.stream(claudeUsageStart(id: "local-command", usage: claudeUsageCounts(input: 0, cached: 0, created: 0), model: "<synthetic>"))
    #expect(!streamChanged4)
    let streamChanged5 = state.stream(.object(["type": .string("message_delta"), "usage": claudeUsageCounts(input: 999, output: 100)]))
    #expect(!streamChanged5)
    #expect(state.snapshot?.context?.usedTokens == 136 && state.snapshot?.turn?.usageStatus == .unavailable)
}

@Test func claudeUsageSnapshotFallbackDoesNotInventCacheExpiryAndCompactionPreventsStaleResurrection() throws {
    var state = ClaudeUsageAccumulator(); state.beginTurn(runID: UUID(), now: claudeUsageNow)
    var raw = claudeUsageCounts(output: 5).object!
    raw["cache_creation"] = .object(["ephemeral_1h_input_tokens": .number(30)])
    let assistantChanged2 = state.assistant(claudeUsageAssistant(usage: .object(raw)), now: claudeUsageNow)
    #expect(assistantChanged2)
    #expect(state.snapshot?.context?.promptCacheTtlMs == 3_600_000 && state.snapshot?.context?.promptCacheExpiresAt == nil)
    let systemChanged1 = state.system(.object(["subtype": .string("status"), "status": .string("compacting")]), now: claudeUsageNow)
    #expect(systemChanged1)
    #expect(state.snapshot?.status == .compacting && state.snapshot?.statusObserved == true)
    let systemChanged2 = state.system(.object(["subtype": .string("compact_boundary"), "compact_metadata": .object([
        "trigger": .string("auto"), "pre_tokens": .number(800), "post_tokens": .number(320), "private": .string("PRIVATE-MUST-NOT-PERSIST")])]), now: claudeUsageNow)
    #expect(systemChanged2)
    #expect(state.snapshot?.context?.source == .compaction && state.snapshot?.context?.usedTokens == 320)
    #expect(state.snapshot?.context?.inputTokens == nil && state.snapshot?.context?.promptCacheTtlMs == nil)
    let assistantChanged3 = state.assistant(claudeUsageAssistant(usage: claudeUsageCounts(input: 800, output: 50)))
    #expect(!assistantChanged3)
    #expect(state.snapshot?.context?.usedTokens == 320)
    let systemChanged3 = state.system(.object(["subtype": .string("status"), "status": .null, "compact_result": .string("failed"),
        "compact_error": .string("PRIVATE-MUST-NOT-PERSIST")]), now: claudeUsageNow)
    #expect(systemChanged3)
    #expect(state.snapshot?.status == nil && state.snapshot?.statusObserved == true && state.snapshot?.compaction?.outcome == .failed)
    let report: JSONValue = .object(["context_usage": .object(["model": .string("reported-model"), "total_tokens": .number(500),
        "raw_max_tokens": .number(180_000), "memory_files": .array([.object(["path": .string("PRIVATE-MUST-NOT-PERSIST")])])])])
    let assistantChanged4 = state.assistant(report, now: claudeUsageNow)
    #expect(assistantChanged4)
    #expect(state.snapshot?.context?.source == .nativeReport && state.snapshot?.context?.maxTokens == 180_000)
    let encoded = try JSONEncoder().encode(state.snapshot)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("PRIVATE-MUST-NOT-PERSIST"))
}

@Test func claudeUsageTurnAndQuerySessionTotalsKeepDifferentScopesAcrossRepeatedTurnsAndClear() throws {
    var state = ClaudeUsageAccumulator(); let first = UUID(), second = UUID()
    state.beginTurn(runID: first, now: claudeUsageNow); state.observedSubagent()
    let resultChanged1 = state.result(claudeUsageResult(), terminalStatus: .completed, steeringSegment: false, now: claudeUsageNow)
    #expect(resultChanged1)
    #expect(state.snapshot?.turn?.inputTokens == 15 && state.snapshot?.turn?.outputTokens == 4)
    #expect(state.snapshot?.turn?.reasoningTokens == 1 && state.snapshot?.turn?.hasSubagents == true)
    #expect(state.snapshot?.turn?.usageStatus == .complete && state.snapshot?.turn?.usageScope == .mainAgent)
    #expect(state.snapshot?.session?.models.first?.inputTokens == 400 && state.snapshot?.session?.estimatedCostUSD == 0.12)
    let previousRevision = try #require(state.snapshot?.revision)
    state.detachRun(); state.beginTurn(runID: second, now: claudeUsageNow.addingTimeInterval(1))
    let resultChanged2 = state.result(claudeUsageResult(input: 20, output: 7, cost: 0.19, modelInput: 600), terminalStatus: .completed, steeringSegment: false, now: claudeUsageNow.addingTimeInterval(2))
    #expect(resultChanged2)
    #expect(state.snapshot?.runID == second && (state.snapshot?.revision ?? 0) > previousRevision)
    #expect(state.snapshot?.turn?.inputTokens == 25 && state.snapshot?.turn?.outputTokens == 7 && state.snapshot?.turn?.hasSubagents == false)
    #expect(state.snapshot?.session?.estimatedCostUSD == 0.19 && state.snapshot?.session?.models.first?.inputTokens == 600)
    let reset: JSONValue = .object(["subtype": .string("success"), "usage": claudeUsageCounts(input: 0, cached: 0, created: 0),
        "total_cost_usd": .number(0), "modelUsage": .object([:])])
    let resultChanged3 = state.result(reset, terminalStatus: .completed, steeringSegment: false, now: claudeUsageNow.addingTimeInterval(3))
    #expect(resultChanged3)
    #expect(state.snapshot?.session?.estimatedCostUSD == 0 && state.snapshot?.session?.models.isEmpty == true)
    #expect(state.snapshot?.session?.modelUsageAvailable == true)
}

@Test func claudeUsageSteeringAddsDistinctNativeSegmentsExactlyOnceAndMissingIdentityCannotClaimCompleteness() throws {
    var state = ClaudeUsageAccumulator(); state.beginTurn(runID: UUID(), now: claudeUsageNow)
    let first = claudeUsageResult(id: "segment-a"), identicalButDistinct = claudeUsageResult(id: "segment-b")
    let resultChanged4 = state.result(first, terminalStatus: .completed, steeringSegment: true, now: claudeUsageNow)
    #expect(resultChanged4)
    let resultChanged5 = state.result(first, terminalStatus: .completed, steeringSegment: true, now: claudeUsageNow)
    #expect(!resultChanged5)
    let resultChanged6 = state.result(identicalButDistinct, terminalStatus: .completed, steeringSegment: true, now: claudeUsageNow)
    #expect(resultChanged6)
    let resultChanged7 = state.result(claudeUsageResult(cost: 0.3, id: "final"), terminalStatus: .completed, steeringSegment: false, now: claudeUsageNow)
    #expect(resultChanged7)
    #expect(state.snapshot?.turn?.inputTokens == 45 && state.snapshot?.turn?.outputTokens == 12 && state.snapshot?.turn?.reasoningTokens == 3)
    #expect(state.snapshot?.turn?.usageStatus == .complete && state.snapshot?.session?.estimatedCostUSD == 0.3)
    state.beginTurn(runID: UUID(), now: claudeUsageNow)
    var missingID = first.object!; missingID.removeValue(forKey: "uuid")
    _ = state.result(.object(missingID), terminalStatus: .completed, steeringSegment: true, now: claudeUsageNow)
    _ = state.result(claudeUsageResult(), terminalStatus: .completed, steeringSegment: false, now: claudeUsageNow)
    #expect(state.snapshot?.turn?.usageStatus == .partial && state.snapshot?.turn?.inputTokens == 15)
    state.beginTurn(runID: UUID(), now: claudeUsageNow)
    for index in 0..<129 { _ = state.result(claudeUsageResult(id: "segment-\(index)"), terminalStatus: .completed, steeringSegment: true, now: claudeUsageNow) }
    _ = state.result(claudeUsageResult(), terminalStatus: .completed, steeringSegment: false, now: claudeUsageNow)
    #expect(state.snapshot?.turn?.usageStatus == .partial)
}

@Test func claudeUsageRateEventsAreFractionsAndOveragePermissionDoesNotPretendThePrimaryWindowReset() throws {
    var state = ClaudeUsageAccumulator(); state.beginTurn(runID: UUID(), now: claudeUsageNow)
    let info: JSONValue = .object(["status": .string("rejected"), "rateLimitType": .string("five_hour"), "utilization": .number(1.2),
        "resetsAt": .number(1_700_003_600), "overageStatus": .string("allowed"), "private": .string("PRIVATE-MUST-NOT-PERSIST")])
    let rateLimitChanged1 = state.rateLimit(.object(["rate_limit_info": info]), now: claudeUsageNow)
    #expect(rateLimitChanged1)
    let first = try #require(state.snapshot?.rateLimits.first)
    #expect(first.utilization == 1.2 && first.resetsAt == claudeUsageNow.addingTimeInterval(3_600))
    #expect(first.status == .rejected && !first.blocked && first.overageStatus == .allowed)
    let revision = state.snapshot?.revision
    let rateLimitChanged2 = state.rateLimit(.object(["rate_limit_info": info]), now: claudeUsageNow)
    #expect(!rateLimitChanged2)
    #expect(state.snapshot?.revision == revision)
    var blocked = info.object!; blocked["overageStatus"] = .string("rejected")
    let rateLimitChanged3 = state.rateLimit(.object(["rate_limit_info": .object(blocked)]), now: claudeUsageNow)
    #expect(rateLimitChanged3)
    #expect(state.snapshot?.rateLimits.first?.blocked == true)
    for malformed in [JSONValue.string("invalid"), .object(["status": .string("allowed"), "rateLimitType": .string("invented_window")]),
                      .object(["status": .string("allowed"), "utilization": .number(-1)]), .object(["status": .string("allowed"), "resetsAt": .bool(true)])] {
        let rateLimitChanged4 = state.rateLimit(.object(["rate_limit_info": malformed]), now: claudeUsageNow)
        #expect(!rateLimitChanged4)
    }
    state.detachRun()
    blocked["status"] = .string("allowed")
    let rateLimitChanged5 = state.rateLimit(.object(["rate_limit_info": .object(blocked)]), now: claudeUsageNow)
    #expect(rateLimitChanged5)
    #expect(state.snapshot?.runID == nil && state.snapshot?.turn == nil)
}

@Test func claudeUsageMalformedCountsStayUnavailableAndSnapshotValidationRejectsForgedOrUnboundedValues() throws {
    var state = ClaudeUsageAccumulator(); state.beginTurn(runID: UUID(), now: claudeUsageNow)
    for invalid in [JSONValue.number(-1), .number(0.5), .number(.infinity), .bool(true), .string("100")] {
        var raw = claudeUsageCounts().object!; raw["input_tokens"] = invalid
        let streamChanged6 = state.stream(claudeUsageStart(usage: .object(raw)), now: claudeUsageNow)
        #expect(!streamChanged6)
        var result = claudeUsageResult().object!; result["usage"] = .object(raw)
        _ = state.result(.object(result), terminalStatus: .failed, steeringSegment: false, now: claudeUsageNow)
        #expect(state.snapshot?.turn?.usageStatus == .unavailable)
    }
    let noThinking: JSONValue = .object(["subtype": .string("success"), "usage": claudeUsageCounts(output: 10)])
    _ = state.result(noThinking, terminalStatus: .completed, steeringSegment: false, now: claudeUsageNow)
    #expect(state.snapshot?.turn?.reasoningTokens == nil)
    let zeroedFailure: JSONValue = .object(["subtype": .string("error_during_execution"), "usage": claudeUsageCounts(input: 0, cached: 0, created: 0),
        "total_cost_usd": .number(0), "modelUsage": .object([:])])
    let previousSession = state.snapshot?.session
    _ = state.result(zeroedFailure, terminalStatus: .failed, steeringSegment: false, now: claudeUsageNow)
    #expect(state.snapshot?.turn?.usageStatus == .unavailable && state.snapshot?.session == previousSession)
    let snapshot = try #require(state.snapshot), data = try JSONEncoder().encode(snapshot)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    var flat = try #require(object)
    #expect(flat["storage"] == nil && flat["revision"] != nil)
    flat["revision"] = -1
    let malformed = try JSONSerialization.data(withJSONObject: flat)
    #expect(throws: ClaudeUsageError.self) { _ = try JSONDecoder().decode(ClaudeUsageSnapshot.self, from: malformed) }
    #expect(throws: ClaudeUsageError.self) { _ = try ClaudeTurnUsage(usageStatus: .complete, inputTokens: 10, cachedInputTokens: 8, cacheCreationTokens: 5, outputTokens: 1) }
    #expect(throws: ClaudeUsageError.self) { _ = try ClaudeSessionUsage(estimatedCostUSD: .nan, observedAt: claudeUsageNow) }
    let models = (0..<129).map { ("model-\($0)", JSONValue.object(["inputTokens": .number(1)])) }
    var large = claudeUsageResult().object!; large["modelUsage"] = .object(Dictionary(uniqueKeysWithValues: models))
    #expect(throws: ClaudeUsageError.self) { _ = try ClaudeUsageParser.session(.object(large), now: claudeUsageNow) }
}
