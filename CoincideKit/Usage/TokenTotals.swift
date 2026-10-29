import Foundation

/// Tokens billed across one or more model requests, split the way prices are: input read fresh, input read from the
/// prompt cache, input written to it, and output. Unlike `TokenUsage`'s context snapshot, these add up.
public struct TokenTotals: Sendable, Hashable, Codable {
    /// Input tokens that were neither read from nor written to the prompt cache.
    public var input: Int
    public var cacheRead: Int
    /// Input tokens written to the prompt cache.
    public var cacheWrite: Int
    /// The part of `cacheWrite` kept for an hour (Claude prices it higher than the five-minute cache).
    public var cacheWriteLong: Int
    /// Output tokens, reasoning included.
    public var output: Int
    /// The part of `output` the model spent reasoning, when the provider says.
    public var reasoning: Int

    public nonisolated init(
        input: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, cacheWriteLong: Int = 0, output: Int = 0, reasoning: Int = 0
    ) {
        func count(_ value: Int) -> Int { max(0, value) }
        self.input = count(input)
        self.cacheRead = count(cacheRead)
        self.cacheWrite = count(cacheWrite)
        self.cacheWriteLong = min(count(cacheWriteLong), count(cacheWrite))
        self.output = count(output)
        self.reasoning = min(count(reasoning), count(output))
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) -> Int { (try? container.decodeIfPresent(Int.self, forKey: key)) ?? 0 }
        self.init(
            input: value(.input), cacheRead: value(.cacheRead), cacheWrite: value(.cacheWrite),
            cacheWriteLong: value(.cacheWriteLong), output: value(.output), reasoning: value(.reasoning))
    }

    public nonisolated static let zero = TokenTotals()

    /// Every token read or written.
    public nonisolated var total: Int { Int.saturatingSum(input, cacheRead, cacheWrite, output) }

    /// All input, cached or not.
    public nonisolated var allInput: Int { Int.saturatingSum(input, cacheRead, cacheWrite) }

    public nonisolated var isEmpty: Bool { total == 0 }

    public nonisolated static func + (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        TokenTotals(
            input: lhs.input &+ rhs.input, cacheRead: lhs.cacheRead &+ rhs.cacheRead,
            cacheWrite: lhs.cacheWrite &+ rhs.cacheWrite, cacheWriteLong: lhs.cacheWriteLong &+ rhs.cacheWriteLong,
            output: lhs.output &+ rhs.output, reasoning: lhs.reasoning &+ rhs.reasoning)
    }

    public nonisolated static func += (lhs: inout TokenTotals, rhs: TokenTotals) { lhs = lhs + rhs }

    /// Field by field, the larger: Claude Code logs one response several times, its output growing as it streams.
    nonisolated func fieldwiseMax(_ other: TokenTotals) -> TokenTotals {
        TokenTotals(
            input: max(input, other.input), cacheRead: max(cacheRead, other.cacheRead),
            cacheWrite: max(cacheWrite, other.cacheWrite), cacheWriteLong: max(cacheWriteLong, other.cacheWriteLong),
            output: max(output, other.output), reasoning: max(reasoning, other.reasoning))
    }

    /// The totals of an ACP `session/prompt` result's `usage` (Cursor, Grok Build, Antigravity), which counts every
    /// request of the turn. ACP leaves open whether its input count includes the cached tokens and its output count the
    /// thought tokens; `totalTokens`, when present, tells which.
    nonisolated static func acp(_ usage: JSONValue?) -> TokenTotals? {
        guard let usage, usage.object != nil else { return nil }
        func count(_ key: String) -> Int { max(0, usage[key]?.acpInt ?? 0) }
        var input = count("inputTokens")
        let cacheRead = count("cachedReadTokens")
        let cacheWrite = count("cachedWriteTokens")
        var output = count("outputTokens")
        let thought = count("thoughtTokens")
        guard input + cacheRead + cacheWrite + output + thought > 0 else { return nil }
        if let total = usage["totalTokens"]?.acpInt, total > 0 {
            let cache = cacheRead + cacheWrite
            switch total {
            case input + cache + output + thought:
                // Everything counted apart: reasoning joins the output.
                output += thought
            case input + output + thought where cache > 0 && input >= cache:
                input -= cache
                output += thought
            case input + output where cache > 0 && input >= cache:
                input -= cache
            default:
                // Input apart from the cache, reasoning within the output.
                break
            }
        }
        return TokenTotals(input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output, reasoning: thought)
    }

    /// One OpenCode step's `tokens`: `input` leaves out the cache, and `output` the reasoning.
    nonisolated static func openCode(_ tokens: JSONValue?) -> TokenTotals? {
        guard let tokens, tokens.object != nil else { return nil }
        func count(_ path: String) -> Int { max(0, tokens.at(path)?.int ?? 0) }
        let reasoning = count("reasoning")
        let totals = TokenTotals(
            input: count("input"), cacheRead: count("cache.read"), cacheWrite: count("cache.write"),
            output: count("output") + reasoning, reasoning: reasoning)
        return totals.isEmpty ? nil : totals
    }
}
