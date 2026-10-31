import Foundation

/// Settings › Usage as the Mac shows it, for Coincide Remote (`usageDashboard`): plan limits per account with their
/// credits, extra usage and model-specific limits, the token and cost totals, daily usage, the top models and projects,
/// and activity in Coincide. Figures arrive already worded and formatted by the Mac, in its number format and its
/// "used or left" choice, so both show the same thing; the chart's numbers come raw.
public struct RemoteUsageDashboard: Codable, Hashable, Sendable {
    /// One line of a limit: a window, a model's limit, credits or a figure such as extra usage, as the Mac's row shows it.
    public struct Row: Codable, Hashable, Sendable {
        public enum Level: String, Codable, Sendable {
            case normal, near, critical, unknown

            public init(from decoder: Decoder) throws {
                self = Level(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
        }

        public var title: String
        public var value: String
        /// The value is a state ("Off", "Unlimited") rather than an amount.
        public var isState: Bool
        /// How much of the bar is filled, 0–1, or nil for no bar.
        public var fill: Double?
        /// Where even spending across the period would put the fill.
        public var paceMark: Double?
        public var level: Level
        /// When it resets, the pace, and any word on its state.
        public var details: [String]
        public var help: String?

        public init(
            title: String, value: String, isState: Bool = false, fill: Double? = nil, paceMark: Double? = nil, level: Level = .normal,
            details: [String] = [], help: String? = nil
        ) {
            self.title = title
            self.value = value
            self.isState = isState
            self.fill = fill
            self.paceMark = paceMark
            self.level = level
            self.details = details
            self.help = help
        }
    }

    /// An agent's account: its plan and limits, or why it has none, and its tokens and cost over the period.
    public struct Account: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var provider: String
        public var title: String
        public var plan: String?
        public var checkedAt: Date?
        public var rows: [Row]
        public var warning: String?
        public var warningBlocksWork: Bool
        public var notes: [String]
        /// Why no limits show, when none do.
        public var unavailable: String?
        /// The period's tokens and cost for the account, and where they come from.
        public var periodTokens: String?
        public var periodCost: String?
        public var periodSource: String?

        public init(
            id: String, provider: String, title: String, plan: String? = nil, checkedAt: Date? = nil, rows: [Row] = [],
            warning: String? = nil, warningBlocksWork: Bool = false, notes: [String] = [], unavailable: String? = nil,
            periodTokens: String? = nil, periodCost: String? = nil, periodSource: String? = nil
        ) {
            self.id = id
            self.provider = provider
            self.title = title
            self.plan = plan
            self.checkedAt = checkedAt
            self.rows = rows
            self.warning = warning
            self.warningBlocksWork = warningBlocksWork
            self.notes = notes
            self.unavailable = unavailable
            self.periodTokens = periodTokens
            self.periodCost = periodCost
            self.periodSource = periodSource
        }
    }

    /// Today, the last 7 days or the last 30: tokens, the estimated cost and the trend against the period before.
    public struct Tile: Codable, Hashable, Sendable {
        public var title: String
        public var tokens: String
        public var cost: String
        public var trend: String?
        public var trendIsUp: Bool

        public init(title: String, tokens: String, cost: String, trend: String? = nil, trendIsUp: Bool = false) {
            self.title = title
            self.tokens = tokens
            self.cost = cost
            self.trend = trend
            self.trendIsUp = trendIsUp
        }
    }

    /// One provider's use on one day, for the chart.
    public struct Day: Codable, Hashable, Sendable {
        public var day: Date
        public var provider: String
        public var tokens: Double
        public var cost: Double

        public init(day: Date, provider: String, tokens: Double, cost: Double) {
            self.day = day
            self.provider = provider
            self.tokens = tokens
            self.cost = cost
        }
    }

    /// A model or project among the period's biggest: its share of the period's tokens, its tokens and cost.
    public struct Top: Codable, Hashable, Sendable {
        public var title: String
        public var provider: String?
        public var share: Double
        public var tokens: String
        public var cost: String

        public init(title: String, provider: String? = nil, share: Double, tokens: String, cost: String) {
            self.title = title
            self.provider = provider
            self.share = share
            self.tokens = tokens
            self.cost = cost
        }
    }

    public struct Metric: Codable, Hashable, Sendable {
        public var title: String
        public var value: String

        public init(title: String, value: String) {
            self.title = title
            self.value = value
        }
    }

    /// A choice for the filters: an agent or one of its accounts.
    public struct Choice: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// "All Agents", an agent, or an account; and "Last 30 days".
    public var scopeTitle: String
    public var periodName: String
    public var days: Int
    public var provider: String?
    public var accountID: String?
    public var providers: [Choice]
    /// The chosen agent's accounts, when it has more than one.
    public var accountChoices: [Choice]
    public var tiles: [Tile]
    /// The account closest to a limit, and that limit.
    public var closestTitle: String?
    public var closestProvider: String?
    public var closest: Row?
    public var daily: [Day]
    public var topModels: [Top]
    public var topProjects: [Top]
    public var activity: [Metric]
    public var accounts: [Account]
    public var isScanning: Bool
    public var updatedAt: Date?

    /// The periods the Mac's filter offers.
    public static let periods = [7, 30, 90]

    public init(
        scopeTitle: String, periodName: String, days: Int, provider: String? = nil, accountID: String? = nil,
        providers: [Choice] = [], accountChoices: [Choice] = [], tiles: [Tile] = [], closestTitle: String? = nil,
        closestProvider: String? = nil, closest: Row? = nil, daily: [Day] = [], topModels: [Top] = [], topProjects: [Top] = [], activity: [Metric] = [],
        accounts: [Account] = [], isScanning: Bool = false, updatedAt: Date? = nil
    ) {
        self.scopeTitle = scopeTitle
        self.periodName = periodName
        self.days = days
        self.provider = provider
        self.accountID = accountID
        self.providers = providers
        self.accountChoices = accountChoices
        self.tiles = tiles
        self.closestTitle = closestTitle
        self.closestProvider = closestProvider
        self.closest = closest
        self.daily = daily
        self.topModels = topModels
        self.topProjects = topProjects
        self.activity = activity
        self.accounts = accounts
        self.isScanning = isScanning
        self.updatedAt = updatedAt
    }
}

/// What the phone asks of the dashboard: the period and filters, and whether to read the providers again first.
public struct RemoteUsageQuery: Codable, Hashable, Sendable {
    public var days: Int
    public var provider: String?
    public var accountID: String?
    /// Read every provider's limits again now, as the Mac's refresh button does.
    public var refresh: Bool

    public init(days: Int = 30, provider: String? = nil, accountID: String? = nil, refresh: Bool = false) {
        self.days = days
        self.provider = provider
        self.accountID = accountID
        self.refresh = refresh
    }
}
