import AppKit
import Charts
import CoincideKit
import Observation
import SwiftUI

/// Settings › Usage's state: the shared usage figures (`UsageInsights`), the filters, and the report they make.
@Observable
final class UsageDashboardModel {
    enum Metric: String, CaseIterable { case tokens, cost }

    private(set) var accounts: [UsageInsights.AccountLimits] = []
    private(set) var report = UsageReport()
    private(set) var records: [UsageRecord] = []
    private(set) var isScanning = false
    private(set) var isCheckingLimits = false
    private(set) var lastScan: Date?
    private(set) var historyError: String?
    private(set) var now = Date()

    var days = 30 { didSet { if days != oldValue { rebuild() } } }
    /// Nil for every provider.
    var provider: ProviderKind? {
        didSet {
            guard provider != oldValue else { return }
            account = nil
            rebuild()
        }
    }
    /// An account of `provider`, or nil for all of them.
    var account: String? { didSet { if account != oldValue { rebuild() } } }
    var metric: Metric = .tokens

    @ObservationIgnored let insights: UsageInsights
    @ObservationIgnored private let store: AppStore
    /// Used or what is left, kept in step with the setting (which the menu bar popover may change while this shows).
    var displayMode: UsageDisplayMode {
        didSet {
            guard store.settings.usageDisplayMode != displayMode else { return }
            store.updateSettings { $0.usageDisplayMode = displayMode }
        }
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var storeObserver: ObservationToken?
    /// What the report was last made from, so a change elsewhere (a provider check, say) does not make it again.
    @ObservationIgnored private var builtFrom: (version: Int, records: Int, includesOther: Bool)?

    init(insights: UsageInsights = .shared, store: AppStore = .shared) {
        self.insights = insights
        self.store = store
        displayMode = store.settings.usageDisplayMode
        provider = UsageNavigation.requestedProvider
        UsageNavigation.requestedProvider = nil
        observers.append(
            NotificationCenter.default.addObserver(forName: UsageInsights.didChange, object: insights, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        observers.append(
            NotificationCenter.default.addObserver(forName: UsageNavigation.requestNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let requested = UsageNavigation.requestedProvider else { return }
                    UsageNavigation.requestedProvider = nil
                    self.provider = requested
                }
            })
        storeObserver = store.observe { [weak self] change in
            guard change == .settings, let self, self.displayMode != self.store.settings.usageDisplayMode else { return }
            self.displayMode = self.store.settings.usageDisplayMode
        }
        reload()
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    var settings: AppSettings { store.settings }

    var includesOtherSessions: Bool {
        get { store.settings.usageIncludesOtherSessions }
        set {
            store.updateSettings { $0.usageIncludesOtherSessions = newValue }
            rebuild()
        }
    }

    var showsInMenuBar: Bool {
        get { store.settings.showsUsageInMenuBar }
        set { store.updateSettings { $0.showsUsageInMenuBar = newValue } }
    }

    var menuBarUsage: MenuBarUsageChoice? {
        get { store.settings.menuBarUsage }
        set { store.updateSettings { $0.menuBarUsage = newValue ?? .lastActive } }
    }

    var menuBarSecondaryUsage: MenuBarUsageChoice? {
        get { store.settings.menuBarSecondaryUsage }
        set { store.updateSettings { $0.menuBarSecondaryUsage = newValue } }
    }

    func reload() {
        now = Date()
        accounts = insights.accountLimits(now: now)
        records = insights.records
        isScanning = insights.isScanning
        isCheckingLimits = insights.isCheckingLimits
        lastScan = insights.lastScan
        historyError = insights.historyError
        let source = (insights.eventsVersion, records.count, store.settings.usageIncludesOtherSessions)
        if builtFrom.map({ $0 != source }) ?? true { rebuild() }
    }

    private func rebuild() {
        builtFrom = (insights.eventsVersion, records.count, store.settings.usageIncludesOtherSessions)
        let events = insights.events.filter { event in
            (provider == nil || event.provider == provider) && (account == nil || event.accountID == account)
        }
        report = UsageReport.make(events, periodDays: days, now: Date())
    }

    func appeared() { insights.refreshIfStale() }

    func refresh() async { await insights.refreshNow() }

    /// Accounts the page lists, after the provider and account filters.
    var shownAccounts: [UsageInsights.AccountLimits] {
        accounts.filter { (provider == nil || $0.provider == provider) && (account == nil || $0.account.id == account) }
    }

    /// The selected provider's accounts, when it has more than one to choose between.
    var accountChoices: [ProviderAccount] {
        guard let provider else { return [] }
        let all = accounts.filter { $0.provider == provider }.map(\.account)
        return all.count > 1 ? all : []
    }

    /// What the overview is about: every agent, one, or one account.
    var scopeTitle: String {
        guard let provider else { return String(localized: "All Agents") }
        if let account, let shown = accounts.first(where: { $0.provider == provider && $0.account.id == account }) {
            return UsageFormat.title(UsageInsights.AccountLimits(
                provider: provider, account: shown.account, showsAccountName: true, status: shown.status, limits: nil))
        }
        return provider.displayName
    }

    /// Coincide's turns in the period, for the activity figures.
    var periodRecords: [UsageRecord] {
        let since = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: now)) ?? .distantPast
        return records.filter {
            $0.finishedAt >= since && (provider == nil || $0.provider == provider)
                && (account == nil || ($0.accountID ?? ProviderAccount.defaultID) == account)
        }
    }

    func projectName(_ id: UUID) -> String {
        store.project(id)?.name ?? String(localized: "Removed project")
    }
}

struct UsageSettingsView: View {
    @State private var model = UsageDashboardModel()

    var body: some View {
        Form {
            Section {
                header
            }
            filtersSection
            overviewSection
            chartSection
            modelsSection
            projectsSection
            accountSections
            activitySection
            optionsSection
            Section {
                notes
            }
        }
        .formStyle(.grouped)
        .onAppear { model.appeared() }
    }

    private var periodName: String {
        String(localized: "Last \(model.days) days")
    }

    // MARK: Header and filters

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            SettingsPaneHeader(title: String(localized: "Usage")) {
                SettingsIconTile(symbol: "chart.bar.fill", color: .green, size: 44)
            } subtitle: {
                Text("Plan limits, and the tokens your agents used on this Mac.")
            }
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    if model.isScanning || model.isCheckingLimits { ProgressView().controlSize(.small) }
                    Button("Refresh") { Task { await model.refresh() } }
                        .disabled(model.isScanning || model.isCheckingLimits)
                }
                if model.isScanning && model.lastScan == nil {
                    Text("Reading logs…").font(.caption).foregroundStyle(.secondary)
                } else if let lastScan = model.lastScan {
                    Text("Updated \(lastScan.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var filtersSection: some View {
        Section {
            ThemedPicker(
                selection: $model.provider,
                options: [.init(nil, String(localized: "All agents"))]
                    + ProviderKind.allCases.map { .init($0, $0.displayName, image: Theme.logo(for: $0, size: 14)) }
            ) {
                Text("Show")
            }
            if !model.accountChoices.isEmpty {
                ThemedPicker(
                    selection: $model.account,
                    options: [.init(nil, String(localized: "All accounts"))] + model.accountChoices.map { .init($0.id, $0.name) }
                ) {
                    Text("Account")
                }
            }
            ThemedPicker(
                selection: $model.days,
                options: [.init(7, String(localized: "Last 7 days")), .init(30, String(localized: "Last 30 days")),
                          .init(90, String(localized: "Last 90 days"))]
            ) {
                Text("Period")
                Text("For the chart, the split and the lists below.")
            }
        }
    }

    // MARK: Overview

    private var overviewSection: some View {
        let report = model.report
        return Section {
            HStack(alignment: .top, spacing: 0) {
                UsageTotalsTile(
                    title: String(localized: "Today"), totals: report.today,
                    trend: UsageReport.trend(report.today, from: report.yesterday), comparedWith: String(localized: "yesterday"))
                Divider().padding(.horizontal, 14)
                UsageTotalsTile(
                    title: String(localized: "Last 7 days"), totals: report.lastWeek,
                    trend: UsageReport.trend(report.lastWeek, from: report.previousWeek),
                    comparedWith: String(localized: "the 7 days before"))
                Divider().padding(.horizontal, 14)
                UsageTotalsTile(
                    title: String(localized: "Last 30 days"), totals: report.lastMonth,
                    trend: UsageReport.trend(report.lastMonth, from: report.previousMonth),
                    comparedWith: String(localized: "the 30 days before"))
            }
            .padding(.vertical, 6)
            UsageTokenMix(totals: report.period, title: periodName)
            if let constrained = UsageInsights.mostConstrained(model.shownAccounts) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Closest limit").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        SettingsProviderIcon(kind: constrained.account.provider, size: 14)
                        Text(UsageFormat.title(constrained.account)).font(.caption).foregroundStyle(.secondary)
                    }
                    UsageRowView(
                        row: .window(constrained.window, mode: model.displayMode, now: model.now), provider: constrained.account.provider)
                }
            }
        } header: {
            Text(model.scopeTitle)
        }
    }

    @ViewBuilder private var chartSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily usage").font(.headline)
                    Text(periodName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ThemedPicker(
                    selection: $model.metric,
                    options: [.init(.tokens, String(localized: "Tokens")), .init(.cost, String(localized: "Estimated cost"))]
                ) {
                    EmptyView()
                }
                .labelsHidden()
                .fixedSize()
            }
            if model.report.days.isEmpty {
                Text(model.isScanning ? String(localized: "Reading logs…") : String(localized: "No usage in this period."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                UsageDailyChart(days: model.report.days, metric: model.metric, period: model.days)
                    .frame(height: 180)
            }
        }
    }

    @ViewBuilder private var modelsSection: some View {
        if !model.report.models.isEmpty {
            Section {
                ForEach(model.report.models.prefix(8)) { row in
                    UsageTotalsRow(totals: row.totals, period: model.report.period) {
                        HStack(spacing: 8) {
                            SettingsProviderIcon(kind: row.provider, size: 18)
                            Text(row.model.isEmpty ? String(localized: "Unknown model") : row.model)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            } header: {
                UsageSectionHeader(title: String(localized: "Top Models"), detail: periodName)
            }
        }
    }

    @ViewBuilder private var projectsSection: some View {
        if !model.report.projects.isEmpty {
            Section {
                ForEach(model.report.projects.prefix(8)) { row in
                    UsageTotalsRow(totals: row.totals, period: model.report.period) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 18)
                            Text(model.projectName(row.projectID)).lineLimit(1)
                        }
                    }
                }
            } header: {
                UsageSectionHeader(title: String(localized: "Top Projects"), detail: periodName)
            } footer: {
                Text("Coincide’s threads only: sessions run elsewhere belong to no project here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Accounts

    @ViewBuilder private var accountSections: some View {
        let accounts = model.shownAccounts
        if accounts.isEmpty {
            Section("Plan Limits") {
                Text("No provider is turned on.").foregroundStyle(.secondary)
            }
        }
        ForEach(accounts) { account in
            Section {
                UsageAccountLimitsView(account: account, settings: model.settings, mode: model.displayMode, now: model.now)
                UsageAccountTotalsRow(
                    account: account, totals: model.report.accounts[UsageReport.accountKey(account.provider, account.account.id)],
                    periodName: periodName)
            } header: {
                UsageAccountHeader(account: account)
            }
        }
    }

    // MARK: Activity and options

    private var activitySection: some View {
        let records = model.periodRecords
        return Section {
            HStack(spacing: 28) {
                metric(String(localized: "Turns"), records.count.formatted())
                metric(String(localized: "Active time"), duration(records.reduce(0) { $0 + $1.duration }))
                metric(String(localized: "Threads"), Set(records.map(\.threadID)).count.formatted())
                Spacer()
            }
            if let error = model.historyError {
                Text("Usage history could not be saved: \(error)").foregroundStyle(Color(nsColor: Theme.failure))
            }
        } header: {
            UsageSectionHeader(title: String(localized: "Activity in Coincide"), detail: periodName)
        }
    }

    private var optionsSection: some View {
        Section {
            ThemedPicker(
                selection: $model.displayMode,
                options: UsageDisplayMode.allCases.map { .init($0, UsageFormat.displayModeName($0)) }
            ) {
                Text("Show")
                Text("Plan limits, credits and the menu bar read as what is used or what is left.")
            }
            Toggle(isOn: $model.includesOtherSessions) {
                Text("Include usage from outside Coincide")
                Text("Also count Claude Code and Codex sessions you ran in a terminal or another app, from their logs on this Mac.")
            }
            Toggle(isOn: $model.showsInMenuBar) {
                Text("Show usage in the menu bar")
                Text("Click the menu bar item for every account’s limits and today’s usage.")
            }
            if model.showsInMenuBar {
                MenuBarUsagePicker(title: String(localized: "Menu bar shows"), choice: $model.menuBarUsage, accounts: model.accounts)
                MenuBarUsagePicker(
                    title: String(localized: "Also show"), choice: $model.menuBarSecondaryUsage, accounts: model.accounts, allowsNone: true)
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "Costs are estimates at API list prices: what the tokens would cost through the API. Subscription plans aren’t billed per token."
            )
            if model.report.period.unpricedTokens > 0 {
                Text(
                    "\(UsageFormat.tokens(model.report.period.unpricedTokens)) tokens are from models without a known price and aren’t in the cost."
                )
            }
            Text(
                "Claude Code and Codex usage comes from their logs on this Mac, which include Coincide’s threads. Cursor, Grok Build, OpenCode and Antigravity count only turns run in Coincide whose agent reports its token use. Nothing is uploaded."
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond))
    }
}

/// A section title with what it covers on the right, such as the period.
private struct UsageSectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(.secondary).font(.caption)
        }
    }
}

/// A provider account's section header: its logo and name, the plan, and when its limits were read.
private struct UsageAccountHeader: View {
    let account: UsageInsights.AccountLimits

    var body: some View {
        HStack(spacing: 8) {
            SettingsProviderIcon(kind: account.provider, size: 16)
            Text(UsageFormat.title(account))
            if let plan = account.limits?.plan {
                Text(UsageFormat.plan(plan))
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: Theme.raisedFill)))
                    .overlay(Capsule().strokeBorder(Color(nsColor: Theme.surfaceBorder), lineWidth: 1))
            }
            Spacer()
            if let checked = account.limits?.checkedAt {
                Text("Checked \(checked.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(checked.formatted(date: .abbreviated, time: .standard))
            }
        }
    }
}

/// A provider account's limit windows, model-specific limits, credits and figures, each as a row, or why it has none.
private struct UsageAccountLimitsView: View {
    let account: UsageInsights.AccountLimits
    let settings: AppSettings
    let mode: UsageDisplayMode
    let now: Date

    var body: some View {
        if let limits = account.limits, !limits.windows.isEmpty || !limits.modelWindows.isEmpty || limits.credits != nil
            || !limits.figures.isEmpty
        {
            ForEach(Array(UsageRow.rows(limits, mode: mode, now: now).enumerated()), id: \.offset) { _, row in
                UsageRowView(row: row, provider: account.provider)
            }
            if let warning = limits.warning {
                Text(UsageLimits.warningText(for: warning, provider: account.provider, at: now))
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: warning.blocksWork ? Theme.failure : Theme.warning))
            }
        } else {
            Text(UsageFormat.unavailable(account, settings: settings))
                .foregroundStyle(.secondary)
        }
        ForEach(account.limits?.notes ?? [], id: \.self) { note in
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if UsageInsights.shared.canCheckRateLimits(account.account) {
            UsageRateLimitCheck(account: account.account)
        }
    }
}

/// Reads an Anthropic API key's rate limits on request, since that takes a (one-token) model request.
private struct UsageRateLimitCheck: View {
    let account: ProviderAccount
    @State private var isChecking = false
    @State private var failed = false

    var body: some View {
        LabeledContent {
            Button {
                isChecking = true
                failed = false
                Task {
                    failed = !(await UsageInsights.shared.checkRateLimits(account))
                    isChecking = false
                }
            } label: {
                HStack(spacing: 5) {
                    if isChecking { ProgressView().controlSize(.mini) }
                    Text("Check Rate Limits")
                }
            }
            .buttonStyle(ThemedButtonStyle())
            .disabled(isChecking)
        } label: {
            Text("Rate limits")
            Text(
                failed
                    ? String(localized: "The check failed. Anthropic may have refused the key or the request.")
                    : String(localized: "Sends a one-token message to read the key’s per-minute limits from Anthropic’s answer. It costs a fraction of a cent."))
        }
    }
}

/// An account's tokens and cost over the period, with where they come from.
private struct UsageAccountTotalsRow: View {
    let account: UsageInsights.AccountLimits
    let totals: UsageTotals?
    let periodName: String

    var body: some View {
        LabeledContent {
            if let totals, totals.tokens.total > 0 {
                HStack(spacing: 10) {
                    Text(UsageFormat.tokens(totals.tokens.total))
                        .monospacedDigit()
                        .help(UsageFormat.exactTokens(totals.tokens.total))
                    Text(UsageFormat.cost(of: totals))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help(UsageFormat.exactCost(totals))
                }
            } else {
                Text("None recorded").foregroundStyle(.secondary)
            }
        } label: {
            Text(periodName)
            Text(UsageInsights.loggedProviders.contains(account.provider)
                ? String(localized: "From \(account.provider.displayName)’s logs on this Mac.")
                : String(localized: "Turns run in Coincide whose agent reported its token use."))
        }
    }
}

/// One period's totals: tokens, the estimated cost and the trend against the period before.
private struct UsageTotalsTile: View {
    let title: String
    let totals: UsageTotals
    let trend: Double?
    let comparedWith: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(UsageFormat.tokens(totals.tokens.total))
                .font(.title2.weight(.semibold).monospacedDigit())
                .help(UsageFormat.exactTokens(totals.tokens.total))
            Text(totals.hasPricedTokens ? String(localized: "≈ \(UsageFormat.cost(totals.cost))") : String(localized: "No priced usage"))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(UsageFormat.exactCost(totals))
            if let trend {
                HStack(spacing: 3) {
                    Image(systemName: trend >= 0 ? "arrow.up.right" : "arrow.down.right")
                    Text(String(localized: "\(UsageFormat.percent(abs(trend))) vs \(comparedWith)"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// How the period's tokens split into fresh input, cache reads, cache writes and output, as one bar with a legend.
private struct UsageTokenMix: View {
    let totals: UsageTotals
    let title: String

    private var parts: [(name: String, count: Int, opacity: Double)] {
        let tokens = totals.tokens
        return [
            (String(localized: "Input"), tokens.input, 0.95),
            (String(localized: "Cache read"), tokens.cacheRead, 0.35),
            (String(localized: "Cache write"), tokens.cacheWrite, 0.6),
            (String(localized: "Output"), tokens.output, 0.8),
        ]
    }

    var body: some View {
        let total = max(1, totals.tokens.total)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(
                    totals.hasPricedTokens
                        ? String(localized: "\(UsageFormat.tokens(totals.tokens.total)) tokens · ≈ \(UsageFormat.cost(totals.cost))")
                        : String(localized: "\(UsageFormat.tokens(totals.tokens.total)) tokens")
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(UsageFormat.exactTokens(totals.tokens.total) + " · " + UsageFormat.exactCost(totals))
            }
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(parts.filter { $0.count > 0 }, id: \.name) { part in
                        Rectangle()
                            .fill(Color(nsColor: Theme.ink).opacity(part.opacity))
                            .frame(width: max(2, (geometry.size.width - 6) * Double(part.count) / Double(total)))
                            .help("\(part.name): \(UsageFormat.exactTokens(part.count))")
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            .background(Capsule().fill(Color(nsColor: .tertiaryLabelColor).opacity(0.2)))
            .accessibilityHidden(true)
            HStack(spacing: 16) {
                ForEach(parts, id: \.name) { part in
                    HStack(spacing: 5) {
                        Circle().fill(Color(nsColor: Theme.ink).opacity(part.opacity)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(UsageFormat.tokens(part.count)).font(.callout.monospacedDigit())
                            Text(part.name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .help(UsageFormat.exactTokens(part.count))
                    .accessibilityElement(children: .combine)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(UsageFormat.tokens(totals.tokens.reasoning)).font(.callout.monospacedDigit())
                    Text("Reasoning (in output)").font(.caption).foregroundStyle(.secondary)
                }
                .help(UsageFormat.exactTokens(totals.tokens.reasoning))
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A model's or project's row: its name, a share bar of the period, tokens and cost.
private struct UsageTotalsRow<Label: View>: View {
    let totals: UsageTotals
    let period: UsageTotals
    @ViewBuilder let label: () -> Label

    var body: some View {
        HStack(spacing: 12) {
            label()
            Spacer(minLength: 8)
            let share = period.tokens.total > 0 ? Double(totals.tokens.total) / Double(period.tokens.total) : 0
            Capsule()
                .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.3))
                .frame(width: 60, height: 5)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color(nsColor: Theme.ink).opacity(0.7)).frame(width: max(share > 0 ? 3 : 0, 60 * share), height: 5)
                }
                .help(UsageFormat.percent(share))
                .accessibilityHidden(true)
            Text(UsageFormat.tokens(totals.tokens.total))
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .trailing)
                .help(UsageFormat.exactTokens(totals.tokens.total))
            Text(UsageFormat.cost(of: totals))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
                .help(UsageFormat.exactCost(totals))
        }
        .accessibilityElement(children: .combine)
    }
}

/// Tokens or cost per day, stacked by provider in each provider's color.
private struct UsageDailyChart: View {
    let days: [UsageReport.Day]
    let metric: UsageDashboardModel.Metric
    let period: Int
    @State private var hovered: Date?

    var body: some View {
        let providers = ProviderKind.allCases.filter { kind in days.contains { $0.provider == kind } }
        Chart {
            ForEach(days) { day in
                BarMark(
                    x: .value(String(localized: "Date"), day.day, unit: .day),
                    y: .value(metric == .tokens ? String(localized: "Tokens") : String(localized: "Cost"), value(day)))
                    .foregroundStyle(by: .value(String(localized: "Provider"), day.provider.displayName))
                    .opacity(hovered == nil || hovered == day.day ? 1 : 0.45)
            }
            if let hovered {
                RuleMark(x: .value(String(localized: "Date"), hovered, unit: .day))
                    .foregroundStyle(Color(nsColor: Theme.surfaceBorder))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(for: hovered)
                    }
            }
        }
        .chartForegroundStyleScale(domain: providers.map(\.displayName), range: providers.map { Color(nsColor: Theme.color(for: $0)) })
        .chartYAxis {
            AxisMarks { mark in
                AxisGridLine().foregroundStyle(Color(nsColor: Theme.surfaceBorder))
                AxisValueLabel {
                    if let number = mark.as(Double.self) {
                        Text(metric == .tokens ? UsageFormat.tokens(Int(number)) : UsageFormat.cost(number))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: period > 30 ? 14 : period > 7 ? 7 : 1)) { _ in
                AxisGridLine().foregroundStyle(Color(nsColor: Theme.surfaceBorder).opacity(0.5))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .chartOverlay { proxy in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let date: Date? = proxy.value(atX: point.x)
                        hovered = date.map { Calendar.current.startOfDay(for: $0) }
                    case .ended:
                        hovered = nil
                    }
                }
        }
        .accessibilityLabel(metric == .tokens ? String(localized: "Tokens per day") : String(localized: "Estimated cost per day"))
    }

    private func value(_ day: UsageReport.Day) -> Double {
        metric == .tokens ? Double(day.totals.tokens.total) : day.totals.cost
    }

    /// The hovered day's figures per provider, exact.
    private func tooltip(for day: Date) -> some View {
        let rows = days.filter { $0.day == day }
        return VStack(alignment: .leading, spacing: 3) {
            Text(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).font(.caption.weight(.semibold))
            ForEach(rows) { row in
                HStack(spacing: 5) {
                    Circle().fill(Color(nsColor: Theme.color(for: row.provider))).frame(width: 6, height: 6)
                    Text(row.provider.displayName)
                    Spacer(minLength: 8)
                    Text(metric == .tokens ? UsageFormat.exactTokens(row.totals.tokens.total) : UsageFormat.exactCost(row.totals))
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(minWidth: 180)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Theme.floatingFill)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: Theme.surfaceBorder), lineWidth: 1))
    }
}
