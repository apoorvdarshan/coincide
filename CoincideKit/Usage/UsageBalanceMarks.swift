import Foundation

/// The highest balance Coincide has seen for a figure that reports a balance but no total (Codex's credits, say), and
/// when it saw it. It is Coincide's own observation, not the provider's: the balance's bar measures what has been spent
/// since then. Whenever the balance goes up (a top-up, a new grant), the mark starts over at the new balance, so what
/// was spent since the mark is always the mark less the balance.
public struct UsageBalanceMark: Codable, Hashable, Sendable {
    /// The balance when it last went up (or was first seen): the highest since then.
    public var highest: Double
    /// When that balance was first seen.
    public var seenAt: Date
    /// The balance seen last, which tells whether the next one went up.
    public var last: Double

    public nonisolated init(highest: Double, seenAt: Date, last: Double? = nil) {
        self.highest = highest
        self.seenAt = seenAt
        self.last = last ?? highest
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let highest = try container.decode(Double.self, forKey: .highest)
        self.init(
            highest: highest, seenAt: try container.decode(Date.self, forKey: .seenAt),
            last: try container.decodeIfPresent(Double.self, forKey: .last))
    }

    /// The mark after seeing `balance` at `date`: the same mark (with `last` updated) while the balance holds or falls,
    /// a new one at the balance when there was none or the balance went up since the last sighting.
    public nonisolated static func updated(_ mark: UsageBalanceMark?, balance: Double, at date: Date) -> UsageBalanceMark {
        guard var mark, mark.highest.isFinite, mark.last.isFinite, balance <= mark.last else {
            return UsageBalanceMark(highest: balance, seenAt: date)
        }
        mark.last = balance
        return mark
    }
}

/// The marks of every account's bare balances, kept in `usage-balance-marks.json` beside the turn history. Only
/// amounts, dates and account IDs are stored: no key, token or account detail.
@MainActor
public final class UsageBalanceMarks {
    /// The figure ID that stands for an account's `UsageCredits` balance, which is not a figure.
    public nonisolated static let creditsID = "@credits"

    public private(set) var marks: [String: UsageBalanceMark] = [:]
    private let file: URL
    private let writer = DispatchQueue(label: "Coincide.usage-balance-marks", qos: .utility)

    public init(directory: URL) {
        file = directory.appendingPathComponent("usage-balance-marks.json")
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Unreadable marks start over: they are only an observation, and the next check sees the balance again.
        marks = ((try? decoder.decode([String: UsageBalanceMark].self, from: data)) ?? [:]).filter { $0.value.highest.isFinite }
    }

    /// Where an account's figure is kept.
    public nonisolated static func key(_ provider: ProviderKind, account: String, figure: String) -> String {
        UsageReport.accountKey(provider, account) + "#" + figure
    }

    /// The mark of an account's figure.
    public func mark(_ provider: ProviderKind, account: String, figure: String) -> UsageBalanceMark? {
        marks[Self.key(provider, account: account, figure: figure)]
    }

    /// Records a balance seen now and returns the figure's mark; saves when the mark changed.
    @discardableResult
    public func observe(_ balance: Double, provider: ProviderKind, account: String, figure: String, at date: Date = Date())
        -> UsageBalanceMark?
    {
        let key = Self.key(provider, account: account, figure: figure)
        guard balance.isFinite else { return marks[key] }
        let updated = UsageBalanceMark.updated(marks[key], balance: balance, at: date)
        if marks[key] != updated {
            marks[key] = updated
            save()
        }
        return updated
    }

    /// Every bare balance of an account's limits with its mark, by figure ID (`creditsID` for its credits), recording
    /// each balance as seen at `date`.
    public func observe(_ limits: UsageLimits, provider: ProviderKind, account: String, at date: Date = Date())
        -> [String: UsageBalanceMark]
    {
        var seen: [String: UsageBalanceMark] = [:]
        for (id, balance) in Self.bareBalances(limits) {
            seen[id] = observe(balance, provider: provider, account: account, figure: id, at: date)
        }
        return seen
    }

    /// The balances in `limits` with no total to measure against, by figure ID: credits with a numeric balance (and not
    /// unlimited), and money or credit figures that report only what remains.
    public nonisolated static func bareBalances(_ limits: UsageLimits) -> [(id: String, balance: Double)] {
        var balances: [(id: String, balance: Double)] = []
        if let credits = limits.credits, !credits.unlimited,
            let balance = credits.balance.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), balance.isFinite
        {
            balances.append((creditsID, balance))
        }
        for figure in limits.figures where isBareBalance(figure) {
            if let remaining = figure.remaining { balances.append((figure.id, remaining)) }
        }
        return balances
    }

    /// Whether a figure is a balance with no total: money or credits left, with no limit and nothing used reported.
    public nonisolated static func isBareBalance(_ figure: UsageFigure) -> Bool {
        guard figure.limit == nil, figure.used == nil, figure.remaining != nil else { return false }
        switch figure.unit {
        case .currency, .credits: return true
        case .requests, .tokens, .count: return false
        }
    }

    /// Called by tests to wait for the last save.
    public func flush() { writer.sync {} }

    /// Writes the marks off the main thread. A failed write costs only an observation: the marks in memory stay right,
    /// and after a relaunch the next check sees the balance again.
    private func save() {
        let snapshot = marks
        let file = file
        writer.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}
