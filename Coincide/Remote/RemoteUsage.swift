import CoincideKit
import CoincideRemoteKit
import Foundation

/// Settings › Usage for Coincide Remote: the same figures the Mac's dashboard (`UsageDashboardModel`) and its menu bar
/// item show, worded and formatted here so the phone shows exactly what the Mac does, in the user's number format and
/// "used or left" choice.
extension RemoteStoreAdapter {
    func usageDashboard(_ query: RemoteUsageQuery) async -> RemoteUsageDashboard {
        let model = UsageDashboardModel(insights: .shared, store: store)
        if query.refresh { await model.refresh() }
        model.days = RemoteUsageDashboard.periods.contains(query.days) ? query.days : 30
        model.provider = query.provider.flatMap(ProviderKind.init(rawValue:))
        model.account = model.provider == nil ? nil : query.accountID
        model.reload()
        return Self.dashboard(model)
    }

    static func dashboard(_ model: UsageDashboardModel) -> RemoteUsageDashboard {
        let report = model.report
        let periodName = String(localized: "Last \(model.days) days")
        func tile(_ title: String, _ totals: UsageTotals, previous: UsageTotals, comparedWith: String) -> RemoteUsageDashboard.Tile {
            let trend = UsageReport.trend(totals, from: previous)
            return RemoteUsageDashboard.Tile(
                title: title, tokens: UsageFormat.tokens(totals.tokens.total),
                cost: totals.hasPricedTokens ? String(localized: "≈ \(UsageFormat.cost(totals.cost))") : String(localized: "No priced usage"),
                trend: trend.map { String(localized: "\(UsageFormat.percent(abs($0))) vs \(comparedWith)") }, trendIsUp: (trend ?? 0) >= 0)
        }
        func top(_ title: String, provider: ProviderKind?, _ totals: UsageTotals) -> RemoteUsageDashboard.Top {
            let share = report.period.tokens.total > 0 ? Double(totals.tokens.total) / Double(report.period.tokens.total) : 0
            return RemoteUsageDashboard.Top(
                title: title, provider: provider?.rawValue, share: share, tokens: UsageFormat.tokens(totals.tokens.total),
                cost: UsageFormat.cost(of: totals))
        }
        let closest = UsageInsights.mostConstrained(model.shownAccounts)
        let records = model.periodRecords
        let activeSeconds = records.reduce(0) { $0 + $1.duration }
        let duration = Duration.seconds(Int(activeSeconds)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return RemoteUsageDashboard(
            scopeTitle: model.scopeTitle, periodName: periodName, days: model.days, provider: model.provider?.rawValue,
            accountID: model.account,
            providers: ProviderKind.allCases.filter { kind in model.accounts.contains { $0.provider == kind } }.map {
                RemoteUsageDashboard.Choice(id: $0.rawValue, title: $0.displayName)
            },
            accountChoices: model.accountChoices.map { RemoteUsageDashboard.Choice(id: $0.id, title: $0.name) },
            tiles: [
                tile(String(localized: "Today"), report.today, previous: report.yesterday, comparedWith: String(localized: "yesterday")),
                tile(
                    String(localized: "Last 7 days"), report.lastWeek, previous: report.previousWeek,
                    comparedWith: String(localized: "the 7 days before")),
                tile(
                    String(localized: "Last 30 days"), report.lastMonth, previous: report.previousMonth,
                    comparedWith: String(localized: "the 30 days before")),
            ],
            closestTitle: closest.map { UsageFormat.title($0.account) }, closestProvider: closest?.account.provider.rawValue,
            closest: closest.map { row(.window($0.window, mode: model.displayMode, now: model.now)) },
            daily: report.days.map {
                RemoteUsageDashboard.Day(day: $0.day, provider: $0.provider.rawValue, tokens: Double($0.totals.tokens.total), cost: $0.totals.cost)
            },
            topModels: report.models.prefix(8).map {
                top($0.model.isEmpty ? String(localized: "Unknown model") : $0.model, provider: $0.provider, $0.totals)
            },
            topProjects: report.projects.prefix(8).map { top(model.projectName($0.projectID), provider: nil, $0.totals) },
            activity: [
                RemoteUsageDashboard.Metric(title: String(localized: "Turns"), value: AppNumbers.current.integer(records.count)),
                RemoteUsageDashboard.Metric(title: String(localized: "Active time"), value: duration),
                RemoteUsageDashboard.Metric(
                    title: String(localized: "Threads"), value: AppNumbers.current.integer(Set(records.map(\.threadID)).count)),
            ],
            accounts: model.shownAccounts.map { account(model, $0, periodName: periodName) },
            isScanning: model.isScanning, updatedAt: model.lastScan)
    }

    private static func account(
        _ model: UsageDashboardModel, _ account: UsageInsights.AccountLimits, periodName: String
    ) -> RemoteUsageDashboard.Account {
        let limits = account.limits
        let hasLimits = limits.map { !$0.windows.isEmpty || !$0.modelWindows.isEmpty || $0.credits != nil || !$0.figures.isEmpty } ?? false
        let rows = hasLimits ? limits.map { UsageRow.rows($0, marks: account.balanceMarks, mode: model.displayMode, now: model.now).map(row) } ?? []
            : []
        let totals = model.report.accounts[UsageReport.accountKey(account.provider, account.account.id)]
        let warning = limits?.warning
        return RemoteUsageDashboard.Account(
            id: account.id, provider: account.provider.rawValue, title: UsageFormat.title(account),
            plan: limits?.plan.map(UsageFormat.plan), checkedAt: limits?.checkedAt, rows: rows,
            warning: warning.map { UsageLimits.warningText(for: $0, provider: account.provider, at: model.now) },
            warningBlocksWork: warning?.blocksWork ?? false, notes: limits?.notes ?? [],
            unavailable: hasLimits ? nil : UsageFormat.unavailable(account, settings: model.settings),
            periodTokens: totals.flatMap { $0.tokens.total > 0 ? UsageFormat.tokens($0.tokens.total) : nil },
            periodCost: totals.flatMap { $0.tokens.total > 0 ? UsageFormat.cost(of: $0) : nil },
            periodSource: UsageInsights.loggedProviders.contains(account.provider)
                ? String(localized: "From \(account.provider.displayName)’s logs on this Mac.")
                : String(localized: "Turns run in Coincide whose agent reported its token use."))
    }

    /// A row as the Mac's `UsageRowView` draws it.
    static func row(_ row: UsageRow) -> RemoteUsageDashboard.Row {
        let level: RemoteUsageDashboard.Row.Level =
            switch row.level {
            case .normal: .normal
            case .near: .near
            case .critical: .critical
            }
        return RemoteUsageDashboard.Row(
            title: row.title, value: row.value, isState: row.isState, fill: row.bar?.fill, paceMark: row.bar?.paceMark, level: level,
            details: row.details, help: row.help)
    }
}
