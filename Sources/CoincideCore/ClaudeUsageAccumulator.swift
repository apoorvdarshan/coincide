import Foundation

/// Keeps one root request plus bounded native accounting heads. No transcript,
/// settings, tool payloads, account identity or credential fields are retained.
struct ClaudeUsageAccumulator: Sendable {
    private struct RawUsage: Sendable, Equatable {
        var input: Int?, cached: Int?, created: Int?, output: Int?, thinking: Int?
        var ttlMs: Int?
        var hasCounts: Bool { [input, cached, created, output].contains { $0 != nil } }
        var positive: Bool { [input, cached, created, output].contains { ($0 ?? 0) > 0 } }
        var complete: Bool { input != nil && output != nil }
        var totalInput: Int? {
            guard let input else { return nil }
            return try? ClaudeUsageValidation.add(ClaudeUsageValidation.add(input, cached ?? 0), created ?? 0)
        }
        static func decode(_ value: JSONValue) throws -> Self? {
            guard value != .null else { return nil }
            guard value.object != nil else { throw ClaudeUsageError.invalidUsage }
            let cache = value["cache_creation"]
            guard cache == .null || cache.object != nil else { throw ClaudeUsageError.invalidUsage }
            let hour = try ClaudeUsageParser.count(cache["ephemeral_1h_input_tokens"])
            let five = try ClaudeUsageParser.count(cache["ephemeral_5m_input_tokens"])
            let details = value["output_tokens_details"]
            guard details == .null || details.object != nil else { throw ClaudeUsageError.invalidUsage }
            return try .init(input: ClaudeUsageParser.count(value["input_tokens"]), cached: ClaudeUsageParser.count(value["cache_read_input_tokens"]),
                created: ClaudeUsageParser.count(value["cache_creation_input_tokens"]), output: ClaudeUsageParser.count(value["output_tokens"]),
                thinking: ClaudeUsageParser.count(details["thinking_tokens"]), ttlMs: (hour ?? 0) > 0 ? 3_600_000 : (five ?? 0) > 0 ? 300_000 : nil)
        }
        func merging(_ delta: Self) -> Self {
            .init(input: delta.input ?? input, cached: delta.cached ?? cached, created: delta.created ?? created,
                output: delta.output ?? output, thinking: delta.thinking ?? thinking, ttlMs: delta.ttlMs ?? ttlMs)
        }
        func adding(_ earlier: Self) throws -> Self {
            func add(_ a: Int?, _ b: Int?) throws -> Int? {
                guard let a else { return nil }; return try ClaudeUsageValidation.add(a, b ?? 0)
            }
            return try .init(input: add(input, earlier.input), cached: add(cached, earlier.cached), created: add(created, earlier.created),
                output: add(output, earlier.output), thinking: add(thinking, earlier.thinking), ttlMs: nil)
        }
    }
    private struct Request: Sendable {
        let id: String
        let model: String?
        var usage: RawUsage?
        let startedAt: Date?
    }
    private var runID: UUID?
    private var revision: Int64 = 0
    private var context: ClaudeContextUsage?
    private var turn: ClaudeTurnUsage?
    private var session: ClaudeSessionUsage?
    private var rates: [ClaudeRateLimitUsage.Window: ClaudeRateLimitUsage] = [:]
    private var status: ClaudeNativeUsageStatus?
    private var statusObserved = false
    private var compaction: ClaudeCompactionUsage?
    private var request: Request?
    private var earlier: RawUsage?
    private var earlierComplete = true
    private var earlierIDs: Set<String> = []
    private var hasSubagents = false
    private(set) var snapshot: ClaudeUsageSnapshot?

    mutating func beginTurn(runID: UUID?, now: Date = Date()) {
        self.runID = runID; context = nil; request = nil; earlier = nil; earlierComplete = true; earlierIDs = []
        hasSubagents = false; status = nil; statusObserved = false; compaction = nil
        turn = try? .init(usageStatus: .unavailable)
        _ = commit(now: now)
    }
    @discardableResult mutating func detachRun(now: Date = Date()) -> Bool {
        guard runID != nil || turn != nil else { return false }
        runID = nil; turn = nil
        return commit(now: now)
    }
    mutating func observedSubagent() { hasSubagents = true }

    @discardableResult mutating func stream(_ event: JSONValue, now: Date = Date()) -> Bool {
        do {
            switch event["type"].string {
            case "message_start":
                request = nil
                let message = event["message"]
                guard let id = try ClaudeUsageParser.text(message["id"]) else { return false }
                let model = try ClaudeUsageParser.text(message["model"])
                guard model != "<synthetic>" else { return false }
                let raw = try RawUsage.decode(message["usage"])
                request = .init(id: id, model: model, usage: raw, startedAt: now)
                return try publishContext(raw, model: model, startedAt: now, now: now)
            case "message_delta":
                guard var request, let previous = request.usage, let delta = try RawUsage.decode(event["usage"]) else { return false }
                let merged = previous.merging(delta)
                guard merged != previous else { return false }
                request.usage = merged; self.request = request
                return try publishContext(merged, model: request.model, startedAt: request.startedAt, now: now)
            default: return false
            }
        } catch { return false }
    }

    @discardableResult mutating func assistant(_ frame: JSONValue, now: Date = Date()) -> Bool {
        do {
            // A structured /context report is safe to consume even when its
            // visible assistant text is a local <synthetic> command result.
            if frame["context_usage"] != .null {
                let value = frame["context_usage"]
                guard value.object != nil, let total = try ClaudeUsageParser.count(value["total_tokens"]),
                      let maximum = try ClaudeUsageParser.count(value["raw_max_tokens"]), maximum > 0 else { return false }
                context = try .init(source: .nativeReport, model: ClaudeUsageParser.text(value["model"]), usedTokens: total, maxTokens: maximum, observedAt: now)
                return commit(now: now)
            }
            let message = frame["message"], model = try ClaudeUsageParser.text(message["model"])
            guard model != "<synthetic>", let id = try ClaudeUsageParser.text(message["id"]),
                  let raw = try RawUsage.decode(message["usage"]) else { return false }
            if let current = request, current.id.utf8.elementsEqual(id.utf8) {
                // Per-block final snapshots repeat the request's counters. A
                // compacted request stays stale; do not resurrect its old size.
                guard let previous = current.usage, (previous.totalInput ?? 0) <= 0, (raw.totalInput ?? 0) > 0 else { return false }
                var repaired = raw
                if let output = previous.output { repaired.output = max(output, raw.output ?? 0) }
                request?.usage = repaired
                return try publishContext(repaired, model: model ?? current.model, startedAt: current.startedAt, now: now)
            }
            request = .init(id: id, model: model, usage: raw, startedAt: nil)
            return try publishContext(raw, model: model, startedAt: nil, now: now)
        } catch { return false }
    }

    @discardableResult mutating func system(_ frame: JSONValue, now: Date = Date()) -> Bool {
        do {
            if frame["subtype"] == .string("status") {
                guard frame.object?.keys.contains("status") == true else { return false }
                let next: ClaudeNativeUsageStatus?
                if frame["status"] == .null { next = nil }
                else {
                    guard let raw = frame["status"].string, let parsed = ClaudeNativeUsageStatus(rawValue: raw) else { return false }
                    next = parsed
                }
                let outcome = try ClaudeUsageParser.compactionOutcome(frame["compact_result"])
                guard !statusObserved || status != next || outcome != nil else { return false }
                status = next; statusObserved = true
                if let outcome { compaction = try .init(trigger: compaction?.trigger, beforeTokens: compaction?.beforeTokens,
                    afterTokens: compaction?.afterTokens, outcome: outcome, observedAt: now) }
                return commit(now: now)
            }
            guard frame["subtype"] == .string("compact_boundary"), frame["compact_metadata"].object != nil else { return false }
            let metadata = frame["compact_metadata"]
            guard let raw = metadata["trigger"].string, let trigger = ClaudeCompactionUsage.Trigger(rawValue: raw) else { return false }
            let before = try ClaudeUsageParser.count(metadata["pre_tokens"]), after = try ClaudeUsageParser.count(metadata["post_tokens"])
            request?.usage = nil
            if let after, after > 0 { context = try .init(source: .compaction, usedTokens: after, observedAt: now) }
            else { context = nil }
            compaction = try .init(trigger: trigger, beforeTokens: before, afterTokens: after, outcome: .success, observedAt: now)
            return commit(now: now)
        } catch { return false }
    }

    @discardableResult mutating func rateLimit(_ frame: JSONValue, now: Date = Date()) -> Bool {
        do {
            let next = try ClaudeUsageParser.rateLimit(frame["rate_limit_info"])
            guard rates[next.window] != next else { return false }
            rates[next.window] = next
            return commit(now: now)
        } catch { return false }
    }

    @discardableResult mutating func result(_ frame: JSONValue, terminalStatus: ThreadRunStatus, steeringSegment: Bool, now: Date = Date()) -> Bool {
        do {
            if steeringSegment {
                // Native UUID distinguishes genuinely separate equal-cost query
                // segments. Missing identities cannot prove a complete total.
                guard let id = try ClaudeUsageParser.text(frame["uuid"]) else {
                    earlierComplete = false; return updateSession(frame, now: now) ? commit(now: now) : false
                }
                guard !earlierIDs.contains(id) else { return false }
                guard earlierIDs.count < 128 else {
                    earlierComplete = false; return updateSession(frame, now: now) ? commit(now: now) : false
                }
                earlierIDs.insert(id)
                if let raw = try RawUsage.decode(frame["usage"]), raw.hasCounts {
                    if let previous = earlier {
                        func sum(_ a: Int?, _ b: Int?) throws -> Int? {
                            guard a != nil || b != nil else { return nil }
                            return try ClaudeUsageValidation.add(a ?? 0, b ?? 0)
                        }
                        earlier = try .init(input: sum(previous.input, raw.input), cached: sum(previous.cached, raw.cached),
                            created: sum(previous.created, raw.created), output: sum(previous.output, raw.output), thinking: sum(previous.thinking, raw.thinking), ttlMs: nil)
                    } else { earlier = raw }
                    earlierComplete = earlierComplete && raw.complete
                } else { earlierComplete = false }
                _ = updateSession(frame, now: now)
                return commit(now: now)
            }
            let raw = try RawUsage.decode(frame["usage"])
            let combined = try raw.map { value in try earlier.map { try value.adding($0) } ?? value }
            if let combined, combined.hasCounts, frame["subtype"] == .string("success") || combined.positive {
                let complete = terminalStatus == .completed && frame["subtype"] == .string("success") && combined.complete && earlierComplete
                let thinking = combined.output.flatMap { output in combined.thinking.map { min(output, $0) } }
                turn = try .init(usageStatus: complete ? .complete : .partial, inputTokens: combined.totalInput,
                    cachedInputTokens: combined.cached, cacheCreationTokens: combined.created, outputTokens: combined.output,
                    reasoningTokens: thinking, hasSubagents: hasSubagents)
            } else { turn = try .init(usageStatus: .unavailable, hasSubagents: hasSubagents) }
            _ = updateSession(frame, now: now)
            status = nil; statusObserved = false
            return commit(now: now)
        } catch {
            turn = try? .init(usageStatus: .unavailable, hasSubagents: hasSubagents)
            _ = updateSession(frame, now: now)
            status = nil; statusObserved = false
            return commit(now: now)
        }
    }

    @discardableResult mutating func interrupted(now: Date = Date()) -> Bool {
        turn = try? .init(usageStatus: .unavailable, hasSubagents: hasSubagents)
        status = nil; statusObserved = false
        return commit(now: now)
    }
    private mutating func publishContext(_ raw: RawUsage?, model: String?, startedAt: Date?, now: Date) throws -> Bool {
        guard let raw, let input = raw.totalInput, input > 0, let output = raw.output else { return false }
        context = try .init(source: .message, model: model, usedTokens: ClaudeUsageValidation.add(input, output), inputTokens: input,
            cachedInputTokens: raw.cached, cacheCreationTokens: raw.created, outputTokens: output,
            promptCacheTtlMs: raw.ttlMs, promptCacheExpiresAt: raw.ttlMs.flatMap { ttl in startedAt.map { $0.addingTimeInterval(Double(ttl) / 1_000) } }, observedAt: now)
        return commit(now: now)
    }
    private mutating func updateSession(_ frame: JSONValue, now: Date) -> Bool {
        do {
            guard let parsed = try ClaudeUsageParser.session(frame, now: now) else { return false }
            // Known startup/crash failures can carry zeroed placeholders. A
            // successful /clear may really reset totals and is accepted as-is.
            if frame["subtype"] != .string("success"), (parsed.estimatedCostUSD ?? 0) == 0,
               parsed.models.allSatisfy({ ($0.inputTokens ?? 0) == 0 && ($0.outputTokens ?? 0) == 0 && ($0.cacheReadInputTokens ?? 0) == 0 && ($0.cacheCreationInputTokens ?? 0) == 0 }) { return false }
            session = parsed; return true
        } catch { return false }
    }
    private mutating func commit(now: Date) -> Bool {
        guard revision < Int64(ClaudeUsageValidation.maximumTokens) else { return false }
        let next = try? ClaudeUsageSnapshot(runID: runID, revision: revision + 1, context: context, turn: turn, session: session,
            rateLimits: rates.values.sorted { $0.window.rawValue < $1.window.rawValue }, status: status, statusObserved: statusObserved,
            compaction: compaction, observedAt: now)
        guard let next else { return false }; revision += 1; snapshot = next; return true
    }
}

enum ClaudeUsageParser {
    static func count(_ value: JSONValue) throws -> Int? {
        guard value != .null else { return nil }
        guard case .number(let count) = value, count.isFinite, count >= 0,
              count <= Double(ClaudeUsageValidation.maximumTokens), count.rounded(.towardZero) == count else { throw ClaudeUsageError.invalidUsage }
        return Int(count)
    }
    static func cost(_ value: JSONValue) throws -> Double? {
        guard value != .null else { return nil }
        guard case .number(let cost) = value else { throw ClaudeUsageError.invalidUsage }
        try ClaudeUsageValidation.cost(cost); return cost
    }
    static func text(_ value: JSONValue) throws -> String? {
        guard value != .null else { return nil }
        guard let text = value.string else { throw ClaudeUsageError.invalidUsage }
        try ClaudeUsageValidation.text(text); return text
    }
    static func flag(_ value: JSONValue) throws -> Bool? {
        guard value != .null else { return nil }
        guard case .bool(let value) = value else { throw ClaudeUsageError.invalidUsage }; return value
    }
    static func epoch(_ value: JSONValue) throws -> Date? {
        guard value != .null else { return nil }
        guard case .number(let seconds) = value, seconds > 0 else { throw ClaudeUsageError.invalidUsage }
        let date = Date(timeIntervalSince1970: seconds); try ClaudeUsageValidation.date(date); return date
    }
    static func compactionOutcome(_ value: JSONValue) throws -> ClaudeCompactionUsage.Outcome? {
        guard value != .null else { return nil }
        guard let text = value.string, let parsed = ClaudeCompactionUsage.Outcome(rawValue: text) else { throw ClaudeUsageError.invalidUsage }; return parsed
    }
    static func rateLimit(_ value: JSONValue) throws -> ClaudeRateLimitUsage {
        guard value.object != nil, let text = value["status"].string, let status = ClaudeRateLimitUsage.Status(rawValue: text) else { throw ClaudeUsageError.invalidUsage }
        let window: ClaudeRateLimitUsage.Window
        if value["rateLimitType"] == .null { window = .unknown }
        else {
            guard let text = value["rateLimitType"].string, let parsed = ClaudeRateLimitUsage.Window(rawValue: text), parsed != .unknown else { throw ClaudeUsageError.invalidUsage }; window = parsed
        }
        let overage: ClaudeRateLimitUsage.Status?
        if value["overageStatus"] == .null { overage = nil }
        else {
            guard let text = value["overageStatus"].string, let parsed = ClaudeRateLimitUsage.Status(rawValue: text) else { throw ClaudeUsageError.invalidUsage }; overage = parsed
        }
        let utilization: Double?
        if value["utilization"] == .null { utilization = nil }
        else { guard case .number(let number) = value["utilization"] else { throw ClaudeUsageError.invalidUsage }; utilization = number }
        return try .init(window: window, status: status, utilization: utilization, resetsAt: epoch(value["resetsAt"]),
            overageStatus: overage, overageResetsAt: epoch(value["overageResetsAt"]), isUsingOverage: flag(value["isUsingOverage"]), overageInUse: flag(value["overageInUse"]))
    }
    static func session(_ frame: JSONValue, now: Date) throws -> ClaudeSessionUsage? {
        let cost = try cost(frame["total_cost_usd"]), map = frame["modelUsage"]
        guard cost != nil || map != .null else { return nil }
        var rows: [ClaudeModelUsage] = []
        if map != .null {
            guard let object = map.object, object.count <= 128 else { throw ClaudeUsageError.invalidUsage }
            for (model, value) in object.sorted(by: { $0.key < $1.key }) {
                guard value.object != nil else { throw ClaudeUsageError.invalidUsage }
                rows.append(try .init(model: model, inputTokens: count(value["inputTokens"]), outputTokens: count(value["outputTokens"]),
                    thinkingTokens: count(value["thinkingTokens"]), cacheReadInputTokens: count(value["cacheReadInputTokens"]),
                    cacheCreationInputTokens: count(value["cacheCreationInputTokens"]), webSearchRequests: count(value["webSearchRequests"]),
                    estimatedCostUSD: self.cost(value["costUSD"]), contextWindow: count(value["contextWindow"]), maxOutputTokens: count(value["maxOutputTokens"]),
                    canonicalModel: text(value["canonicalModel"]), provider: text(value["provider"]), costBasis: text(value["costBasis"])))
            }
        }
        return try .init(estimatedCostUSD: cost, models: rows, modelUsageAvailable: map != .null, observedAt: now)
    }
}
