import Foundation

public enum ClaudeUsageError: Error, Sendable, Equatable, LocalizedError {
    case invalidUsage, limitExceeded
    public var errorDescription: String? { "Claude returned usage information that could not be verified safely." }
}

/// Main-agent result accounting. Cache reads/writes are included in input;
/// thinking, when reported, is already included in output. Missing is unknown.
public struct ClaudeTurnUsage: Codable, Sendable, Equatable {
    public enum Scope: String, Codable, Sendable { case mainAgent = "main_agent" }
    public enum Status: String, Codable, Sendable { case complete, partial, unavailable }
    private struct Payload: Codable, Sendable, Equatable {
        let usageScope: Scope
        let usageStatus: Status
        let inputTokens: Int?, cachedInputTokens: Int?, cacheCreationTokens: Int?, outputTokens: Int?, reasoningTokens: Int?
        let hasSubagents: Bool
    }
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
        try ClaudeUsageValidation.counts(counts)
        if usageStatus == .unavailable {
            guard counts.allSatisfy({ $0 == nil }) else { throw ClaudeUsageError.invalidUsage }
        } else {
            guard counts.contains(where: { $0 != nil }), usageStatus != .complete || (inputTokens != nil && outputTokens != nil) else { throw ClaudeUsageError.invalidUsage }
        }
        if let inputTokens { guard (cachedInputTokens ?? 0) <= inputTokens, (cacheCreationTokens ?? 0) <= inputTokens - (cachedInputTokens ?? 0) else { throw ClaudeUsageError.invalidUsage } }
        if let reasoningTokens { guard let outputTokens, reasoningTokens <= outputTokens else { throw ClaudeUsageError.invalidUsage } }
    }
}

/// One latest root request/window measurement, never the sum of transcript
/// blocks and never a token/cost estimate for the entire app run.
public struct ClaudeContextUsage: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case message, compaction, nativeReport = "native_report" }
    public let source: Source
    public let model: String?
    public let usedTokens: Int
    public let inputTokens: Int?, cachedInputTokens: Int?, cacheCreationTokens: Int?, outputTokens: Int?
    /// Native context_usage.raw_max_tokens only. It may be a compaction-policy
    /// window rather than the model's hard limit; no bundled capacity is used.
    public let maxTokens: Int?
    public let promptCacheTtlMs: Int?
    public let promptCacheExpiresAt: Date?
    public let observedAt: Date
    public init(source: Source, model: String? = nil, usedTokens: Int, inputTokens: Int? = nil,
                cachedInputTokens: Int? = nil, cacheCreationTokens: Int? = nil, outputTokens: Int? = nil,
                maxTokens: Int? = nil, promptCacheTtlMs: Int? = nil, promptCacheExpiresAt: Date? = nil, observedAt: Date) throws {
        self.source = source; self.model = model; self.usedTokens = usedTokens; self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens; self.cacheCreationTokens = cacheCreationTokens; self.outputTokens = outputTokens
        self.maxTokens = maxTokens; self.promptCacheTtlMs = promptCacheTtlMs; self.promptCacheExpiresAt = promptCacheExpiresAt; self.observedAt = observedAt
        try validate()
    }
    public func validate() throws {
        try ClaudeUsageValidation.counts([usedTokens, inputTokens, cachedInputTokens, cacheCreationTokens, outputTokens, maxTokens])
        try ClaudeUsageValidation.text(model); try ClaudeUsageValidation.date(observedAt)
        if let promptCacheExpiresAt { try ClaudeUsageValidation.date(promptCacheExpiresAt) }
        guard maxTokens.map({ $0 > 0 }) ?? true,
              promptCacheTtlMs.map({ [300_000, 3_600_000].contains($0) }) ?? true,
              promptCacheExpiresAt == nil || promptCacheTtlMs != nil else { throw ClaudeUsageError.invalidUsage }
        if source == .message {
            guard let inputTokens, inputTokens > 0, let outputTokens,
                  try ClaudeUsageValidation.add(inputTokens, outputTokens) == usedTokens,
                  (cachedInputTokens ?? 0) <= inputTokens,
                  (cacheCreationTokens ?? 0) <= inputTokens - (cachedInputTokens ?? 0) else { throw ClaudeUsageError.invalidUsage }
        } else {
            guard inputTokens == nil, cachedInputTokens == nil, cacheCreationTokens == nil, outputTokens == nil,
                  promptCacheTtlMs == nil, promptCacheExpiresAt == nil else { throw ClaudeUsageError.invalidUsage }
        }
    }
}

/// The SDK modelUsage fields are query-session cumulative, including subagents,
/// sidechains and internal query-pipeline calls. They are not per-turn deltas.
public struct ClaudeModelUsage: Codable, Sendable, Equatable {
    public let model: String
    public let inputTokens: Int?, outputTokens: Int?, thinkingTokens: Int?, cacheReadInputTokens: Int?, cacheCreationInputTokens: Int?, webSearchRequests: Int?
    public let estimatedCostUSD: Double?
    public let contextWindow: Int?, maxOutputTokens: Int?
    public let canonicalModel: String?, provider: String?, costBasis: String?
    public init(model: String, inputTokens: Int? = nil, outputTokens: Int? = nil, thinkingTokens: Int? = nil,
                cacheReadInputTokens: Int? = nil, cacheCreationInputTokens: Int? = nil, webSearchRequests: Int? = nil,
                estimatedCostUSD: Double? = nil, contextWindow: Int? = nil, maxOutputTokens: Int? = nil,
                canonicalModel: String? = nil, provider: String? = nil, costBasis: String? = nil) throws {
        self.model = model; self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.thinkingTokens = thinkingTokens
        self.cacheReadInputTokens = cacheReadInputTokens; self.cacheCreationInputTokens = cacheCreationInputTokens; self.webSearchRequests = webSearchRequests
        self.estimatedCostUSD = estimatedCostUSD; self.contextWindow = contextWindow; self.maxOutputTokens = maxOutputTokens
        self.canonicalModel = canonicalModel; self.provider = provider; self.costBasis = costBasis; try validate()
    }
    public func validate() throws {
        try ClaudeUsageValidation.text(model); try ClaudeUsageValidation.text(canonicalModel); try ClaudeUsageValidation.text(provider)
        try ClaudeUsageValidation.counts([inputTokens, outputTokens, thinkingTokens, cacheReadInputTokens, cacheCreationInputTokens, webSearchRequests, contextWindow, maxOutputTokens])
        try ClaudeUsageValidation.cost(estimatedCostUSD)
        guard model != "<synthetic>", costBasis.map({ ["list", "managed", "unknown"].contains($0) }) ?? true else { throw ClaudeUsageError.invalidUsage }
        if let thinkingTokens, let outputTokens { guard thinkingTokens <= outputTokens else { throw ClaudeUsageError.invalidUsage } }
    }
}

public struct ClaudeSessionUsage: Codable, Sendable, Equatable {
    public enum Scope: String, Codable, Sendable { case querySession = "query_session" }
    public let usageScope: Scope
    public let estimatedCostUSD: Double?
    public let models: [ClaudeModelUsage]
    public let modelUsageAvailable: Bool
    public let observedAt: Date
    public init(estimatedCostUSD: Double? = nil, models: [ClaudeModelUsage] = [], modelUsageAvailable: Bool = false, observedAt: Date) throws {
        usageScope = .querySession; self.estimatedCostUSD = estimatedCostUSD; self.models = models
        self.modelUsageAvailable = modelUsageAvailable; self.observedAt = observedAt; try validate()
    }
    public func validate() throws {
        try ClaudeUsageValidation.cost(estimatedCostUSD); try ClaudeUsageValidation.date(observedAt)
        guard models.count <= 128, modelUsageAvailable || models.isEmpty,
              estimatedCostUSD != nil || modelUsageAvailable,
              Set(models.map { Data($0.model.utf8) }).count == models.count else { throw ClaudeUsageError.invalidUsage }
        for model in models { try model.validate() }
    }
}

/// Native subscription-window observations, not an account entitlement claim.
/// Utilization is the SDK fraction; it is intentionally not capped at 100%.
public struct ClaudeRateLimitUsage: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case allowed, allowedWarning = "allowed_warning", rejected }
    public enum Window: String, Codable, Sendable { case fiveHour = "five_hour", sevenDay = "seven_day", sevenDayOpus = "seven_day_opus", sevenDaySonnet = "seven_day_sonnet", sevenDayOverageIncluded = "seven_day_overage_included", overage, unknown }
    public let window: Window
    public let status: Status
    public let utilization: Double?
    public let resetsAt: Date?
    public let overageStatus: Status?
    public let overageResetsAt: Date?
    public let isUsingOverage: Bool?, overageInUse: Bool?
    public var blocked: Bool { status == .rejected && overageStatus != .allowed && overageStatus != .allowedWarning && isUsingOverage != true && overageInUse != true }
    public init(window: Window, status: Status, utilization: Double? = nil, resetsAt: Date? = nil,
                overageStatus: Status? = nil, overageResetsAt: Date? = nil, isUsingOverage: Bool? = nil, overageInUse: Bool? = nil) throws {
        self.window = window; self.status = status; self.utilization = utilization; self.resetsAt = resetsAt
        self.overageStatus = overageStatus; self.overageResetsAt = overageResetsAt; self.isUsingOverage = isUsingOverage; self.overageInUse = overageInUse
        try validate()
    }
    public func validate() throws {
        guard utilization.map({ $0.isFinite && $0 >= 0 && $0 <= Double.greatestFiniteMagnitude / 100 }) ?? true else { throw ClaudeUsageError.invalidUsage }
        if let resetsAt { try ClaudeUsageValidation.date(resetsAt) }
        if let overageResetsAt { try ClaudeUsageValidation.date(overageResetsAt) }
    }
}

public enum ClaudeNativeUsageStatus: String, Codable, Sendable { case compacting, requesting }
public struct ClaudeCompactionUsage: Codable, Sendable, Equatable {
    public enum Trigger: String, Codable, Sendable { case manual, auto }
    public enum Outcome: String, Codable, Sendable { case success, failed }
    public let trigger: Trigger?
    public let beforeTokens: Int?, afterTokens: Int?
    public let outcome: Outcome?
    public let observedAt: Date
    public init(trigger: Trigger? = nil, beforeTokens: Int? = nil, afterTokens: Int? = nil, outcome: Outcome? = nil, observedAt: Date) throws {
        self.trigger = trigger; self.beforeTokens = beforeTokens; self.afterTokens = afterTokens; self.outcome = outcome; self.observedAt = observedAt
        try validate()
    }
    public func validate() throws { try ClaudeUsageValidation.counts([beforeTokens, afterTokens]); try ClaudeUsageValidation.date(observedAt) }
}

/// Whole replacement at each revision. Only turn is main-agent per-run
/// accounting; context and query-session totals have different scopes.
public struct ClaudeUsageSnapshot: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let runID: UUID?
        let revision: Int64
        let context: ClaudeContextUsage?
        let turn: ClaudeTurnUsage?
        let session: ClaudeSessionUsage?
        let rateLimits: [ClaudeRateLimitUsage]
        let status: ClaudeNativeUsageStatus?
        let statusObserved: Bool
        let compaction: ClaudeCompactionUsage?
        let observedAt: Date
    }
    private let storage: [Payload]
    public var runID: UUID? { storage[0].runID }
    public var revision: Int64 { storage[0].revision }
    public var context: ClaudeContextUsage? { storage[0].context }
    public var turn: ClaudeTurnUsage? { storage[0].turn }
    public var session: ClaudeSessionUsage? { storage[0].session }
    public var rateLimits: [ClaudeRateLimitUsage] { storage[0].rateLimits }
    public var status: ClaudeNativeUsageStatus? { storage[0].status }
    public var statusObserved: Bool { storage[0].statusObserved }
    public var compaction: ClaudeCompactionUsage? { storage[0].compaction }
    public var observedAt: Date { storage[0].observedAt }
    public init(runID: UUID? = nil, revision: Int64, context: ClaudeContextUsage? = nil, turn: ClaudeTurnUsage? = nil,
                session: ClaudeSessionUsage? = nil, rateLimits: [ClaudeRateLimitUsage] = [], status: ClaudeNativeUsageStatus? = nil,
                statusObserved: Bool = false, compaction: ClaudeCompactionUsage? = nil, observedAt: Date) throws {
        storage = [.init(runID: runID, revision: revision, context: context, turn: turn, session: session, rateLimits: rateLimits,
            status: status, statusObserved: statusObserved, compaction: compaction, observedAt: observedAt)]; try validate()
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)]; try validate() }
    public func encode(to encoder: any Encoder) throws { try validate(); try storage[0].encode(to: encoder) }
    public func validate() throws {
        guard revision > 0, revision <= Int64(ClaudeUsageValidation.maximumTokens), rateLimits.count <= 7,
              Set(rateLimits.map(\.window)).count == rateLimits.count, statusObserved || status == nil else { throw ClaudeUsageError.invalidUsage }
        try ClaudeUsageValidation.date(observedAt); try context?.validate(); try turn?.validate(); try session?.validate(); try compaction?.validate()
        for rateLimit in rateLimits { try rateLimit.validate() }
    }
}

enum ClaudeUsageValidation {
    static let maximumTokens = 9_007_199_254_740_991
    static func counts(_ values: [Int?]) throws {
        guard values.allSatisfy({ $0.map { (0...maximumTokens).contains($0) } ?? true }) else { throw ClaudeUsageError.invalidUsage }
    }
    static func add(_ a: Int, _ b: Int) throws -> Int {
        guard a >= 0, b >= 0, a <= maximumTokens - b else { throw ClaudeUsageError.limitExceeded }; return a + b
    }
    static func cost(_ value: Double?) throws {
        guard value.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw ClaudeUsageError.invalidUsage }
    }
    static func text(_ value: String?) throws {
        guard value.map({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }) ?? true else { throw ClaudeUsageError.invalidUsage }
    }
    static func date(_ value: Date) throws {
        guard value.timeIntervalSince1970.isFinite, (0...253_402_300_799).contains(value.timeIntervalSince1970) else { throw ClaudeUsageError.invalidUsage }
    }
}
