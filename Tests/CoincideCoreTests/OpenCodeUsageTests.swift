import Foundation
import Testing
@testable import CoincideCore

func openCodeUsageFixtureTokens(_ input: Int = 10, output: Int = 5, reasoning: Int = 2, read: Int = 3, write: Int = 4) -> JSONValue {
    .object(["input": .number(Double(input)), "output": .number(Double(output)), "reasoning": .number(Double(reasoning)),
        "cache": .object(["read": .number(Double(read)), "write": .number(Double(write))])])
}

@Test func openCodeUsageNormalizesNativeDisjointCacheAndReasoningWithoutDoubleCountingRepeatedSteps() throws {
    var usage = OpenCodeUsageAccumulator()
    let step = try #require(try OpenCodeStepTokens.decode(openCodeUsageFixtureTokens()))
    try usage.record(id: "one", tokens: step); try usage.record(id: "one", tokens: step)
    try usage.record(id: "two", tokens: step)
    let value = usage.snapshot(completed: true)
    #expect(value.usageScope == .mainAgent && value.usageStatus == .complete)
    #expect(value.inputTokens == 34 && value.cachedInputTokens == 6 && value.cacheCreationTokens == 8)
    #expect(value.outputTokens == 14 && value.reasoningTokens == 4 && !value.hasSubagents)
    #expect(usage.snapshot(completed: false).usageStatus == .partial)
    #expect(usage.snapshot(completed: true, unresolved: true).usageStatus == .partial)
    let encoded = try JSONEncoder().encode(value), decoded = try JSONDecoder().decode(OpenCodeTurnUsage.self, from: encoded)
    #expect(decoded == value)
    let json = try JSONDecoder().decode(JSONValue.self, from: encoded)
    #expect(json["usageScope"] == .string("main_agent") && json["inputTokens"] == .number(34) && json["storage"] == .null)
}

@Test func openCodeUsageDistinguishesUnavailableFromObservedZeroAndBoundsNativeCountersAndTotals() throws {
    var usage = OpenCodeUsageAccumulator(); usage.hasSubagents = true
    let absent = usage.snapshot(completed: true)
    #expect(absent.usageStatus == .unavailable && absent.inputTokens == nil && absent.hasSubagents)
    try usage.record(id: "zero", tokens: OpenCodeStepTokens.decode(openCodeUsageFixtureTokens(0, output: 0, reasoning: 0, read: 0, write: 0)))
    #expect(usage.snapshot(completed: true).inputTokens == 0 && usage.snapshot(completed: true).usageStatus == .complete)
    for bad in [JSONValue.number(-1), .number(0.5), .number(9_007_199_254_740_992), .string("10"), .null] {
        var fields = try #require(openCodeUsageFixtureTokens().object); fields["input"] = bad
        #expect(throws: OpenCodeUsageError.self) { try OpenCodeStepTokens.decode(.object(fields)) }
    }
    #expect(throws: OpenCodeUsageError.self) { try OpenCodeTurnUsage(usageStatus: .unavailable, inputTokens: 1) }
    #expect(throws: OpenCodeUsageError.self) { try OpenCodeTurnUsage(usageStatus: .complete, inputTokens: 5, cachedInputTokens: 3, cacheCreationTokens: 4, outputTokens: 1, reasoningTokens: 2) }
    var overflowing = OpenCodeUsageAccumulator()
    let maximum = try #require(try OpenCodeStepTokens.decode(openCodeUsageFixtureTokens(OpenCodeUsageAccumulator.maximumTokens, output: 0, reasoning: 0, read: 0, write: 0)))
    try overflowing.record(id: "maximum", tokens: maximum)
    #expect(throws: OpenCodeUsageError.limitExceeded) { try overflowing.record(id: "overflow", tokens: OpenCodeStepTokens.decode(openCodeUsageFixtureTokens(1, output: 0, reasoning: 0, read: 0, write: 0))) }
    #expect(overflowing.snapshot(completed: true).inputTokens == OpenCodeUsageAccumulator.maximumTokens)
}
