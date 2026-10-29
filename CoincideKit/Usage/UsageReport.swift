import Foundation

/// Tokens one provider account spent on one model request (or one Coincide turn), with where they came from.
public struct UsageEvent: Sendable, Hashable {
    public var date: Date
    public var provider: ProviderKind
    /// `ProviderAccount.id`; the default account's is `ProviderAccount.defaultID`.
    public var accountID: String
    public var model: String?
    public var tokens: TokenTotals
    /// The request's whole prompt, for long-context pricing; 0 when unknown (a turn's totals).
    public var promptTokens: Int
    /// The thread's project, for sessions Coincide ran.
    public var projectID: UUID?
    /// Ran in a Coincide thread rather than in the CLI on its own or another app.
    public var isFromCoincide: Bool

    public nonisolated init(
        date: Date, provider: ProviderKind, accountID: String, model: String?, tokens: TokenTotals, promptTokens: Int = 0,
        projectID: UUID? = nil, isFromCoincide: Bool
    ) {
        self.date = date
        self.provider = provider
        self.accountID = accountID
        self.model = model
        self.tokens = tokens
        self.promptTokens = promptTokens
        self.projectID = projectID
        self.isFromCoincide = isFromCoincide
    }

    /// The API-equivalent cost at list prices, or nil when the model has no known price.
    public nonisolated var estimatedCost: Double? {
        guard let model, let price = UsagePricing.price(for: model) else { return nil }
        let long = price.longContextThreshold.map { promptTokens > $0 } ?? false
        return price.cost(of: tokens, longContext: long)
    }
}

/// Totals over a set of usage events.
public struct UsageTotals: Sendable, Hashable {
    public var tokens = TokenTotals()
    /// The API-equivalent cost of the priced events.
    public var cost: Double = 0
    /// Tokens of events whose model has no known price, left out of `cost`.
    public var unpricedTokens = 0
    public var requests = 0

    public nonisolated init() {}

    public nonisolated mutating func add(_ event: UsageEvent, cost eventCost: Double?) {
        tokens += event.tokens
        requests += 1
        if let eventCost { cost += eventCost } else { unpricedTokens += event.tokens.total }
    }

    /// Every token was priced.
    public nonisolated var isFullyPriced: Bool { unpricedTokens == 0 }
    public nonisolated var hasPricedTokens: Bool { tokens.total > unpricedTokens }
}

/// The Usage page's figures for the events a filter kept.
public struct UsageReport: Sendable {
    public struct Day: Sendable, Hashable, Identifiable {
        public var day: Date
        public var provider: ProviderKind
        public var totals: UsageTotals
        public var id: String { "\(day.timeIntervalSince1970)/\(provider.rawValue)" }
    }

    public struct ModelRow: Sendable, Hashable, Identifiable {
        public var provider: ProviderKind
        public var model: String
        public var totals: UsageTotals
        public var id: String { provider.rawValue + "/" + model }
    }

    public struct ProjectRow: Sendable, Hashable, Identifiable {
        public var projectID: UUID
        public var totals: UsageTotals
        public var id: UUID { projectID }
    }

    public var today = UsageTotals()
    public var lastWeek = UsageTotals()
    public var lastMonth = UsageTotals()
    /// The periods just before those: yesterday, the 7 days before the last 7, the 30 before the last 30. They show
    /// the trend.
    public var yesterday = UsageTotals()
    public var previousWeek = UsageTotals()
    public var previousMonth = UsageTotals()
    /// The whole chosen period.
    public var period = UsageTotals()
    /// Per day and provider over the period, oldest first.
    public var days: [Day] = []
    /// Models over the period, most tokens first.
    public var models: [ModelRow] = []
    /// Coincide's projects over the period, most tokens first.
    public var projects: [ProjectRow] = []
    /// The period by provider account, keyed by `accountKey`.
    public var accounts: [String: UsageTotals] = [:]

    /// The key of a provider account in `accounts`.
    public nonisolated static func accountKey(_ provider: ProviderKind, _ accountID: String) -> String {
        provider.rawValue + "/" + accountID
    }

    /// How a period compares with the one before: +0.12 for 12% more tokens. Nil when the one before had none.
    public nonisolated static func trend(_ current: UsageTotals, from previous: UsageTotals) -> Double? {
        guard previous.tokens.total > 0 else { return nil }
        return Double(current.tokens.total - previous.tokens.total) / Double(previous.tokens.total)
    }

    public nonisolated init() {}

    /// Sums `events` from `periodDays` days before `now` (counting today as one), along with today and the last 7 and 30
    /// days whatever the period. Days follow `calendar`.
    public nonisolated static func make(
        _ events: [UsageEvent], periodDays: Int, now: Date = Date(), calendar: Calendar = .current
    ) -> UsageReport {
        var report = UsageReport()
        let today = calendar.startOfDay(for: now)
        func daysBack(_ count: Int) -> Date { calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today }
        let weekStart = daysBack(7)
        let monthStart = daysBack(30)
        let periodStart = daysBack(max(1, periodDays))
        let yesterdayStart = daysBack(2)
        let previousWeekStart = daysBack(14)
        let previousMonthStart = daysBack(60)
        let earliest = min(previousMonthStart, periodStart)
        var days: [Date: [ProviderKind: UsageTotals]] = [:]
        var models: [String: (ProviderKind, String, UsageTotals)] = [:]
        var projects: [UUID: UsageTotals] = [:]
        var dayStarts: [Int: Date] = [:]
        for event in events where event.date >= earliest && event.date <= now.addingTimeInterval(60) {
            let cost = event.estimatedCost
            if event.date >= today { report.today.add(event, cost: cost) }
            if event.date >= weekStart { report.lastWeek.add(event, cost: cost) }
            if event.date >= monthStart {
                report.lastMonth.add(event, cost: cost)
            } else if event.date >= previousMonthStart {
                report.previousMonth.add(event, cost: cost)
            }
            if event.date < weekStart, event.date >= previousWeekStart { report.previousWeek.add(event, cost: cost) }
            if event.date < today, event.date >= yesterdayStart { report.yesterday.add(event, cost: cost) }
            guard event.date >= periodStart else { continue }
            report.period.add(event, cost: cost)
            // Start-of-day lookups are the slow part; events of one hour share a day.
            let hour = Int(event.date.timeIntervalSince1970 / 3600)
            let day = dayStarts[hour] ?? calendar.startOfDay(for: event.date)
            dayStarts[hour] = day
            days[day, default: [:]][event.provider, default: UsageTotals()].add(event, cost: cost)
            let model = event.model?.trimmedNonEmpty ?? ""
            let key = event.provider.rawValue + "/" + model
            var row = models[key] ?? (event.provider, model, UsageTotals())
            row.2.add(event, cost: cost)
            models[key] = row
            if let project = event.projectID { projects[project, default: UsageTotals()].add(event, cost: cost) }
            report.accounts[accountKey(event.provider, event.accountID), default: UsageTotals()].add(event, cost: cost)
        }
        report.days = days.keys.sorted().flatMap { day in
            ProviderKind.allCases.compactMap { provider in
                days[day]?[provider].map { Day(day: day, provider: provider, totals: $0) }
            }
        }
        report.models = models.values.map { ModelRow(provider: $0.0, model: $0.1, totals: $0.2) }
            .sorted { ($0.totals.tokens.total, $0.id) > ($1.totals.tokens.total, $1.id) }
        report.projects = projects.map { ProjectRow(projectID: $0.key, totals: $0.value) }
            .sorted { ($0.totals.tokens.total, $0.projectID.uuidString) > ($1.totals.tokens.total, $1.projectID.uuidString) }
        return report
    }
}

/// Turns logged sessions and Coincide's turn records into usage events.
public enum UsageEvents {
    /// Which Coincide thread ran a provider's native session.
    public struct SessionOwner: Sendable, Hashable {
        public var projectID: UUID

        public nonisolated init(projectID: UUID) { self.projectID = projectID }
    }

    /// The events of logged sessions. Claude Code responses logged more than once (in one file or in a resumed or forked
    /// session's copy) count once, with their largest counts. A session is Coincide's when a thread holds its id, or when
    /// Codex says Coincide started it.
    public nonisolated static func fromLogs(
        _ sessions: [LoggedSession], owners: [ProviderKind: [String: SessionOwner]]
    ) -> [UsageEvent] {
        var events: [UsageEvent] = []
        var keyed: [String: [UInt64: Int]] = [:]
        for session in sessions {
            let owner = session.sessionID.flatMap { owners[session.provider]?[$0] }
            let coincide = owner != nil || session.originator?.lowercased() == CodexProtocol.clientName
            let scope = session.provider.rawValue + "/" + session.accountID
            for request in session.requests {
                let event = UsageEvent(
                    date: request.date, provider: session.provider, accountID: session.accountID, model: request.model,
                    tokens: request.tokens, promptTokens: request.promptTokens, projectID: owner?.projectID,
                    isFromCoincide: coincide)
                guard request.key != 0 else {
                    events.append(event)
                    continue
                }
                if let index = keyed[scope]?[request.key] {
                    var merged = events[index]
                    merged.tokens = merged.tokens.fieldwiseMax(request.tokens)
                    merged.promptTokens = max(merged.promptTokens, request.promptTokens)
                    merged.date = min(merged.date, request.date)
                    if merged.projectID == nil { merged.projectID = event.projectID }
                    merged.isFromCoincide = merged.isFromCoincide || coincide
                    events[index] = merged
                } else {
                    keyed[scope, default: [:]][request.key] = events.count
                    events.append(event)
                }
            }
        }
        return events
    }

    /// The events of Coincide's turns whose provider reported what the whole turn used, for providers whose logs Coincide
    /// does not read (`excluding` lists the ones it does, so no turn counts twice).
    public nonisolated static func fromRecords(_ records: [UsageRecord], excluding logged: Set<ProviderKind>) -> [UsageEvent] {
        records.compactMap { record in
            guard !logged.contains(record.provider), let totals = record.usage.turnTotals, !totals.isEmpty else { return nil }
            return UsageEvent(
                date: record.finishedAt, provider: record.provider, accountID: record.accountID ?? ProviderAccount.defaultID,
                model: record.modelID, tokens: totals, projectID: record.projectID, isFromCoincide: true)
        }
    }
}
