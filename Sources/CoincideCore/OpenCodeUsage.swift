import Foundation

/// Native main-agent accounting. Input includes cache reads/writes; reasoning
/// is already included in output. Child usage is deliberately not added again.
public struct OpenCodeTurnUsage: Codable, Sendable, Equatable {
    public enum Scope: String, Codable, Sendable { case mainAgent = "main_agent" }
    public enum Status: String, Codable, Sendable { case complete, partial, unavailable }
    private struct Payload: Codable, Sendable, Equatable {
        let usageScope: Scope
        let usageStatus: Status
        let inputTokens: Int?, cachedInputTokens: Int?, cacheCreationTokens: Int?, outputTokens: Int?, reasoningTokens: Int?
        let hasSubagents: Bool
    }
    // Preserve value semantics without inflating ProviderEvent/run frames.
    private let storage: [Payload]
    public var usageScope: Scope { storage[0].usageScope }
    public var usageStatus: Status { storage[0].usageStatus }
    public var inputTokens: Int? { storage[0].inputTokens }
    public var cachedInputTokens: Int? { storage[0].cachedInputTokens }
    public var cacheCreationTokens: Int? { storage[0].cacheCreationTokens }
    public var outputTokens: Int? { storage[0].outputTokens }
    public var reasoningTokens: Int? { storage[0].reasoningTokens }
    public var hasSubagents: Bool { storage[0].hasSubagents }
    public init(usageStatus: Status, inputTokens: Int? = nil, cachedInputTokens: Int? = nil,
                cacheCreationTokens: Int? = nil, outputTokens: Int? = nil, reasoningTokens: Int? = nil,
                hasSubagents: Bool = false) throws {
        storage = [.init(usageScope: .mainAgent, usageStatus: usageStatus, inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens, cacheCreationTokens: cacheCreationTokens,
            outputTokens: outputTokens, reasoningTokens: reasoningTokens, hasSubagents: hasSubagents)]
        try validate()
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)]; try validate() }
    public func encode(to encoder: any Encoder) throws { try validate(); try storage[0].encode(to: encoder) }
    public func validate() throws {
        let counts = [inputTokens, cachedInputTokens, cacheCreationTokens, outputTokens, reasoningTokens]
        if usageStatus == .unavailable {
            guard counts.allSatisfy({ $0 == nil }) else { throw OpenCodeUsageError.invalidUsage }
        } else {
            guard counts.allSatisfy({ $0.map { (0...OpenCodeUsageAccumulator.maximumTokens).contains($0) } ?? false }),
                  let inputTokens, let cachedInputTokens, let cacheCreationTokens, let outputTokens, let reasoningTokens,
                  cachedInputTokens <= inputTokens, cacheCreationTokens <= inputTokens - cachedInputTokens,
                  reasoningTokens <= outputTokens else { throw OpenCodeUsageError.invalidUsage }
        }
    }
}

public enum OpenCodeUsageError: Error, Sendable, Equatable, LocalizedError {
    case invalidUsage, limitExceeded
    public var errorDescription: String? { "OpenCode returned token accounting that could not be verified safely." }
}

/// The native step shape is identical in both generations. Never decode arbitrary
/// metadata or provider cost/credential fields into the persisted projection.
public struct OpenCodeStepTokens: Sendable, Equatable {
    public let input: Int, output: Int, reasoning: Int, cacheRead: Int, cacheWrite: Int
    static func decode(_ value: JSONValue) throws -> Self? {
        guard value != .null else { return nil }
        guard value.object != nil, value["cache"].object != nil else { throw OpenCodeUsageError.invalidUsage }
        func count(_ value: JSONValue) throws -> Int {
            guard case .number(let number) = value, number.isFinite, number >= 0,
                  number <= Double(OpenCodeUsageAccumulator.maximumTokens), number.rounded(.towardZero) == number else { throw OpenCodeUsageError.invalidUsage }
            return Int(number)
        }
        return try .init(input: count(value["input"]), output: count(value["output"]), reasoning: count(value["reasoning"]),
            cacheRead: count(value["cache"]["read"]), cacheWrite: count(value["cache"]["write"]))
    }
}

struct OpenCodeUsageAccumulator: Sendable {
    static let maximumTokens = 9_007_199_254_740_991
    private var stepIDs = Set<String>()
    private var input = 0, cached = 0, cacheWrite = 0, output = 0, reasoning = 0
    var hasSubagents = false
    var complete = true
    mutating func record(id: String, tokens: OpenCodeStepTokens?) throws {
        guard let tokens, !stepIDs.contains(id) else { return }
        guard stepIDs.count < 8_192 else { throw OpenCodeUsageError.limitExceeded }
        func add(_ a: Int, _ b: Int) throws -> Int {
            guard b >= 0, a <= Self.maximumTokens - b else { throw OpenCodeUsageError.limitExceeded }; return a + b
        }
        let input = try add(add(add(input, tokens.input), tokens.cacheRead), tokens.cacheWrite)
        let cached = try add(cached, tokens.cacheRead), cacheWrite = try add(cacheWrite, tokens.cacheWrite)
        let output = try add(add(output, tokens.output), tokens.reasoning), reasoning = try add(reasoning, tokens.reasoning)
        self.input = input; self.cached = cached; self.cacheWrite = cacheWrite; self.output = output; self.reasoning = reasoning
        stepIDs.insert(id)
    }
    func snapshot(completed: Bool, unresolved: Bool = false) -> OpenCodeTurnUsage {
        if stepIDs.isEmpty { return try! .init(usageStatus: .unavailable, hasSubagents: hasSubagents) }
        return try! .init(usageStatus: completed && complete && !unresolved ? .complete : .partial,
            inputTokens: input, cachedInputTokens: cached, cacheCreationTokens: cacheWrite,
            outputTokens: output, reasoningTokens: reasoning, hasSubagents: hasSubagents)
    }
}
