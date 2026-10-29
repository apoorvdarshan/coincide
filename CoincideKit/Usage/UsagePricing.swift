import Foundation

/// API list prices, for estimating what tokens would cost at pay-as-you-go rates. Subscription usage is not billed
/// per token, so the Usage page calls the result an API-equivalent estimate. Prices are US dollars per million tokens;
/// to update one, edit the tables below (newest models first, so a longer id matches before its prefix).
public struct ModelPrice: Sendable, Hashable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    /// Five-minute cache writes; nil prices them as `input` (OpenAI writes are free unless a model lists a price).
    public var cacheWrite: Double?
    /// One-hour cache writes (Claude); nil prices them as `cacheWrite`.
    public var cacheWriteLong: Double?
    /// Above this many input tokens in one request, the whole request is priced at `longContext`.
    public var longContextThreshold: Int?
    public var longContext: LongContext?

    public struct LongContext: Sendable, Hashable {
        public var inputMultiplier: Double
        public var outputMultiplier: Double
    }

    public nonisolated init(
        input: Double, output: Double, cacheRead: Double, cacheWrite: Double? = nil, cacheWriteLong: Double? = nil,
        longContextThreshold: Int? = nil, longContext: LongContext? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWriteLong = cacheWriteLong
        self.longContextThreshold = longContextThreshold
        self.longContext = longContext
    }

    /// Anthropic's rates: cache reads as listed, writes at 1.25× input for five minutes and 2× for an hour.
    nonisolated static func claude(_ input: Double, _ output: Double, cacheRead: Double) -> ModelPrice {
        ModelPrice(input: input, output: output, cacheRead: cacheRead, cacheWrite: input * 1.25, cacheWriteLong: input * 2)
    }

    /// OpenAI's long-context models: a request above 272K input tokens costs 2× for input and the listed factor for
    /// output.
    nonisolated static func openAI(
        _ input: Double, _ output: Double, cacheRead: Double, cacheWrite: Double? = nil, longOutput: Double? = nil
    ) -> ModelPrice {
        ModelPrice(
            input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
            longContextThreshold: longOutput == nil ? nil : 272_000,
            longContext: longOutput.map { LongContext(inputMultiplier: 2, outputMultiplier: $0 / output) })
    }

    /// What `tokens` cost, in dollars. `longContext` says the request went past the long-context threshold.
    public nonisolated func cost(of tokens: TokenTotals, longContext isLong: Bool = false) -> Double {
        let long = isLong ? longContext : nil
        let inputRate = input * (long?.inputMultiplier ?? 1)
        let outputRate = output * (long?.outputMultiplier ?? 1)
        let readRate = cacheRead * (long?.inputMultiplier ?? 1)
        let writeRate = (cacheWrite ?? input) * (long?.inputMultiplier ?? 1)
        let longWriteRate = (cacheWriteLong ?? cacheWrite ?? input) * (long?.inputMultiplier ?? 1)
        let shortWrites = tokens.cacheWrite - tokens.cacheWriteLong
        let dollars =
            Double(tokens.input) * inputRate + Double(tokens.cacheRead) * readRate + Double(shortWrites) * writeRate
            + Double(tokens.cacheWriteLong) * longWriteRate + Double(tokens.output) * outputRate
        return dollars / 1_000_000
    }
}

public enum UsagePricing {
    /// Claude models by id prefix (Anthropic's price list).
    nonisolated static let claude: [(prefix: String, price: ModelPrice)] = [
        ("claude-fable-5-1", .claude(10, 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", .claude(10, 50, cacheRead: 0.25)),
        ("claude-fable-5", .claude(10, 50, cacheRead: 1)),
        ("claude-mythos-5", .claude(10, 50, cacheRead: 1)),
        ("claude-opus-5-5", .claude(4, 20, cacheRead: 0.2)),
        ("claude-opus-5", .claude(5, 25, cacheRead: 0.5)),
        ("claude-opus-4-8", .claude(5, 25, cacheRead: 0.5)),
        ("claude-opus-4-7", .claude(5, 25, cacheRead: 0.5)),
        ("claude-opus-4-6", .claude(5, 25, cacheRead: 0.5)),
        ("claude-opus-4-5", .claude(5, 25, cacheRead: 0.5)),
        ("claude-opus-4-1", .claude(15, 75, cacheRead: 1.5)),
        ("claude-opus-4", .claude(15, 75, cacheRead: 1.5)),
        ("claude-sonnet-5-5", .claude(2, 10, cacheRead: 0.2)),
        ("claude-sonnet-5", .claude(2, 10, cacheRead: 0.2)),
        ("claude-sonnet-4-6", .claude(3, 15, cacheRead: 0.3)),
        ("claude-sonnet-4-5", .claude(3, 15, cacheRead: 0.3)),
        ("claude-sonnet-4", .claude(3, 15, cacheRead: 0.3)),
        // Claude Haiku 5.5 costs 5× for prompts above 100K tokens.
        (
            "claude-haiku-5-5",
            ModelPrice(
                input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125, cacheWriteLong: 0.2, longContextThreshold: 100_000,
                longContext: .init(inputMultiplier: 5, outputMultiplier: 5))
        ),
        ("claude-haiku-4-5", .claude(1, 5, cacheRead: 0.1)),
        ("claude-3-5-haiku", .claude(0.8, 4, cacheRead: 0.08)),
    ]

    /// OpenAI models Codex runs, by exact id (Codex names models without dates).
    nonisolated static let openAI: [String: ModelPrice] = [
        "gpt-6-astra": .openAI(10, 50, cacheRead: 1, cacheWrite: 12.5, longOutput: 75),
        "gpt-6.1-sol": .openAI(2, 10, cacheRead: 0.1, cacheWrite: 2.5, longOutput: 15),
        "gpt-6-sol": .openAI(2, 10, cacheRead: 0.2, cacheWrite: 2.5, longOutput: 15),
        "gpt-6-luna": .openAI(0.1, 0.5, cacheRead: 0.01, cacheWrite: 0.125, longOutput: 0.75),
        "gpt-5.6-sol": .openAI(4, 20, cacheRead: 0.4, cacheWrite: 5, longOutput: 30),
        "gpt-5.6-terra": .openAI(2, 12, cacheRead: 0.2, cacheWrite: 2.5, longOutput: 18),
        "gpt-5.6-luna": .openAI(0.2, 1.2, cacheRead: 0.02, cacheWrite: 0.25, longOutput: 1.8),
        "gpt-5.5": .openAI(5, 30, cacheRead: 0.5, longOutput: 45),
        "gpt-5.4": .openAI(2.5, 15, cacheRead: 0.25, longOutput: 22.5),
        "gpt-5.4-mini": .openAI(0.75, 4.5, cacheRead: 0.075),
        "gpt-5.4-nano": .openAI(0.2, 1.25, cacheRead: 0.02),
        "gpt-5.3-codex": .openAI(1.75, 14, cacheRead: 0.175),
        "gpt-5.2": .openAI(1.75, 14, cacheRead: 0.175),
        "gpt-5.2-codex": .openAI(1.75, 14, cacheRead: 0.175),
        "gpt-5.1": .openAI(1.25, 10, cacheRead: 0.125),
        "gpt-5.1-codex": .openAI(1.25, 10, cacheRead: 0.125),
        "gpt-5.1-codex-max": .openAI(1.25, 10, cacheRead: 0.125),
        "gpt-5.1-codex-mini": .openAI(0.25, 2, cacheRead: 0.025),
        "gpt-5": .openAI(1.25, 10, cacheRead: 0.125),
        "gpt-5-codex": .openAI(1.25, 10, cacheRead: 0.125),
        "gpt-5-mini": .openAI(0.25, 2, cacheRead: 0.025),
        "gpt-5-nano": .openAI(0.05, 0.4, cacheRead: 0.005),
    ]

    /// The price of a model, from its id as a provider logs it: `claude-opus-5-5`, `claude-sonnet-4-5-20250929`,
    /// `gpt-6.1-sol`, or OpenCode's `anthropic/claude-sonnet-4-5`. Nil for a model without a known price.
    public nonisolated static func price(for model: String) -> ModelPrice? {
        var id = model.lowercased().trimmingCharacters(in: .whitespaces)
        // OpenCode and others prefix the service: `openai/gpt-5`, `anthropic/claude-…`.
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        // Bedrock-style `anthropic.claude-…` and `[1m]` context suffixes.
        if id.hasPrefix("anthropic.") { id.removeFirst("anthropic.".count) }
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if id.hasPrefix("claude-") {
            // `claude-sonnet-4.5`, as some tools write it.
            id = id.replacingOccurrences(of: ".", with: "-")
            return claude.first { id == $0.prefix || id.hasPrefix($0.prefix + "-") }?.price
        }
        if let price = openAI[id] { return price }
        // A dated or suffixed OpenAI id (`gpt-5.4-2026-03-05`) costs what its base model does.
        return openAI.keys.filter { id.hasPrefix($0 + "-") }.max { $0.count < $1.count }.flatMap { openAI[$0] }
    }

    /// What `tokens` would cost at `model`'s list price, or nil for a model without one.
    public nonisolated static func cost(of tokens: TokenTotals, model: String?, longContext: Bool = false) -> Double? {
        guard let model, let price = price(for: model) else { return nil }
        return price.cost(of: tokens, longContext: longContext)
    }
}
