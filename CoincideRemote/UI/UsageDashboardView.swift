import Charts
import CoincideRemoteKit
import SwiftUI

/// Settings › Usage as the Mac shows it: the closest limit and token totals, daily usage, the top models and projects,
/// each account's plan limits with its credits, extra usage and model limits, activity in Coincide, and the Mac's usage
/// options. Figures come worded and formatted by the Mac (`usageDashboard`), so both show the same thing. From a Mac
/// too old for the dashboard, each account's limit windows alone (`usageLimits`).
struct UsageDashboardView: View {
    /// The Mac's Usage page, whose options (used or left, refresh, menu bar) show under the dashboard.
    var page: RemoteSettingsPage?
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme
    @State private var dashboard: RemoteUsageDashboard?
    @State private var legacy: [RemoteUsage]?
    @State private var days = 30
    @State private var provider: String?
    @State private var accountID: String?
    @State private var showsCost = false
    @State private var isRefreshing = false

    var body: some View {
        List {
            if let dashboard {
                content(dashboard)
            } else if let legacy {
                LegacyUsageSections(usage: legacy)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120).listRowBackground(Color.clear)
            }
            if let page {
                ForEach(page.sections.filter { section in !section.rows.contains { $0.kind == .usage } }) { section in
                    Section {
                        ForEach(section.rows) { row in MacSettingsRowView(row: row) }
                    } header: {
                        if let title = section.title { Text(title) }
                    } footer: {
                        if let footer = section.footer { Text(footer) }
                    }
                    .themedCards(theme)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.isDark ? theme.content : theme.sidebar)
        .navigationTitle(page?.title ?? String(localized: "Usage"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filters }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load(refresh: true) } } label: {
                    if isRefreshing { ProgressView() } else { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                .disabled(isRefreshing || !client.isConnected)
            }
        }
        .refreshable { await load(refresh: true) }
        .task(id: "\(days)|\(provider ?? "")|\(accountID ?? "")") { await load(refresh: false) }
        // "Used" or "Left" and the number format change how the Mac words every figure.
        .onChange(of: client.macSettings) { Task { await load(refresh: false) } }
    }

    // MARK: Dashboard

    @ViewBuilder
    private func content(_ dashboard: RemoteUsageDashboard) -> some View {
        Section {
            UsageTiles(tiles: dashboard.tiles)
            if let closest = dashboard.closest {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Closest limit").font(.caption).foregroundStyle(theme.secondaryInk)
                        Spacer()
                        if let provider = dashboard.closestProvider { AgentLogo(provider: provider, size: 13) }
                        if let title = dashboard.closestTitle { Text(title).font(.caption).foregroundStyle(theme.secondaryInk) }
                    }
                    UsageLimitRow(row: closest, provider: dashboard.closestProvider ?? "")
                }
            }
        } header: {
            Text(dashboard.scopeTitle)
        }
        .themedCards(theme)

        Section {
            Picker("Show", selection: $showsCost) {
                Text("Tokens").tag(false)
                Text("Estimated cost").tag(true)
            }
            .pickerStyle(.segmented)
            if dashboard.daily.isEmpty {
                Text(dashboard.isScanning ? String(localized: "Reading logs…") : String(localized: "No usage in this period."))
                    .foregroundStyle(theme.secondaryInk)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                UsageDailyChart(days: dashboard.daily, showsCost: showsCost, period: dashboard.days).frame(height: 190)
            }
        } header: {
            HStack {
                Text("Daily usage")
                Spacer()
                Text(dashboard.periodName)
            }
        }
        .themedCards(theme)

        if !dashboard.topModels.isEmpty {
            Section {
                ForEach(Array(dashboard.topModels.enumerated()), id: \.offset) { _, top in UsageTopRow(top: top, symbol: nil) }
            } header: {
                HStack { Text("Top Models"); Spacer(); Text(dashboard.periodName) }
            }
            .themedCards(theme)
        }
        if !dashboard.topProjects.isEmpty {
            Section {
                ForEach(Array(dashboard.topProjects.enumerated()), id: \.offset) { _, top in UsageTopRow(top: top, symbol: "folder") }
            } header: {
                HStack { Text("Top Projects"); Spacer(); Text(dashboard.periodName) }
            } footer: {
                Text("Coincide’s threads only: sessions run elsewhere belong to no project here.")
            }
            .themedCards(theme)
        }

        if dashboard.accounts.isEmpty {
            Section("Plan Limits") {
                Text("No provider is turned on.").foregroundStyle(theme.secondaryInk)
            }
            .themedCards(theme)
        }
        ForEach(dashboard.accounts) { account in
            Section {
                ForEach(Array(account.rows.enumerated()), id: \.offset) { _, row in UsageLimitRow(row: row, provider: account.provider) }
                if let warning = account.warning {
                    Text(warning).font(.caption).foregroundStyle(account.warningBlocksWork ? .red : .orange)
                }
                if let unavailable = account.unavailable {
                    Text(unavailable).foregroundStyle(theme.secondaryInk)
                }
                ForEach(account.notes, id: \.self) { note in Text(note).font(.caption).foregroundStyle(theme.secondaryInk) }
                LabeledContent {
                    if let tokens = account.periodTokens {
                        HStack(spacing: 8) {
                            Text(tokens).monospacedDigit()
                            if let cost = account.periodCost { Text(cost).monospacedDigit().foregroundStyle(theme.secondaryInk) }
                        }
                    } else {
                        Text("None recorded").foregroundStyle(theme.secondaryInk)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dashboard.periodName)
                        if let source = account.periodSource { Text(source).font(.caption).foregroundStyle(theme.secondaryInk) }
                    }
                }
            } header: {
                UsageAccountHeader(account: account)
            }
            .themedCards(theme)
        }

        Section {
            HStack(spacing: 24) {
                ForEach(dashboard.activity, id: \.title) { metric in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.title).font(.caption).foregroundStyle(theme.secondaryInk)
                        Text(metric.value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(theme.ink)
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
            }
        } header: {
            HStack { Text("Activity in Coincide"); Spacer(); Text(dashboard.periodName) }
        } footer: {
            if let updated = dashboard.updatedAt {
                Text("Updated \(updated.formatted(.relative(presentation: .named)))")
            }
        }
        .themedCards(theme)
    }

    /// The agent, its account and the period, as the Mac's filters.
    private var filters: some View {
        Menu {
            Picker("Agent", selection: Binding(get: { provider }, set: { value in
                provider = value
                accountID = nil
            })) {
                Text("All Agents").tag(String?.none)
                ForEach(dashboard?.providers ?? []) { choice in
                    Label { Text(choice.title) } icon: { AgentLogo(provider: choice.id, size: 16) }.tag(Optional(choice.id))
                }
            }
            if let choices = dashboard?.accountChoices, !choices.isEmpty {
                Picker("Account", selection: $accountID) {
                    Text("All Accounts").tag(String?.none)
                    ForEach(choices) { choice in Text(choice.title).tag(Optional(choice.id)) }
                }
            }
            Picker("Period", selection: $days) {
                ForEach(RemoteUsageDashboard.periods, id: \.self) { days in Text("Last \(days) days").tag(days) }
            }
        } label: {
            Label("Filter", systemImage: provider == nil && days == 30 ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .disabled(dashboard == nil)
    }

    private func load(refresh: Bool) async {
        if refresh { isRefreshing = true }
        defer { if refresh { isRefreshing = false } }
        #if DEBUG
        if DemoData.isEnabled {
            dashboard = DemoData.usageDashboard
            return
        }
        #endif
        guard client.isConnected else { return }
        let query = RemoteUsageQuery(days: days, provider: provider, accountID: accountID, refresh: refresh)
        do {
            if case .usageDashboard(let result) = try await client.request(.usageDashboard(query), timeout: .seconds(refresh ? 60 : 20)) {
                dashboard = result
            }
        } catch let error as RemoteError where error.code == .unsupported {
            if case .usage(let result)? = await client.perform(.usageLimits) { legacy = result }
        } catch {
            client.notice = (error as? RemoteError)?.message ?? error.localizedDescription
        }
    }
}

/// Today, the last 7 days and the last 30: tokens, the estimated cost and the trend.
private struct UsageTiles: View {
    let tiles: [RemoteUsageDashboard.Tile]
    @Environment(\.theme) private var theme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) { tileViews }
            VStack(alignment: .leading, spacing: 12) { tileViews }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var tileViews: some View {
        ForEach(tiles, id: \.title) { tile in
            VStack(alignment: .leading, spacing: 3) {
                Text(tile.title).font(.caption).foregroundStyle(theme.secondaryInk)
                Text(tile.tokens).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(theme.ink)
                Text(tile.cost).font(.footnote.monospacedDigit()).foregroundStyle(theme.secondaryInk)
                if let trend = tile.trend {
                    Label(trend, systemImage: tile.trendIsUp ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryInk)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
    }
}

/// A limit, credits or a figure, as the Mac's usage row draws it: title and value, a bar in the agent's color (orange
/// near the limit, red at it) with the even-pace mark, then when it resets and the pace.
struct UsageLimitRow: View {
    let row: RemoteUsageDashboard.Row
    let provider: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title).lineLimit(1)
                    Spacer(minLength: 0)
                    value.lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                    value
                }
            }
            if let fill = row.fill {
                UsageBar(fill: fill, paceMark: row.paceMark, color: color)
            }
            if !row.details.isEmpty {
                Text(row.details.joined(separator: " · ")).font(.caption).foregroundStyle(theme.secondaryInk)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(([row.title, row.value] + row.details).joined(separator: ", ")))
    }

    private var value: some View {
        Text(row.value)
            .monospacedDigit()
            .foregroundStyle(row.isState ? theme.secondaryInk : row.level == .normal || row.level == .unknown ? theme.ink : color)
    }

    private var color: Color {
        switch row.level {
        case .critical: .red
        case .near: .orange
        case .normal, .unknown: theme.agent(provider)
        }
    }
}

/// A usage bar with the mark where even spending would be.
struct UsageBar: View {
    let fill: Double
    var paceMark: Double?
    let color: Color
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.ink.opacity(0.12))
                Capsule().fill(color).frame(width: max(fill > 0 ? 4 : 0, geometry.size.width * min(1, max(0, fill))))
                if let paceMark {
                    Rectangle()
                        .fill(theme.ink.opacity(0.6))
                        .frame(width: 2, height: 10)
                        .offset(x: geometry.size.width * min(1, max(0, paceMark)) - 1)
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// A model's or project's share of the period, its tokens and cost.
private struct UsageTopRow: View {
    let top: RemoteUsageDashboard.Top
    let symbol: String?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            if let provider = top.provider {
                AgentLogo(provider: provider, size: 16)
            } else if let symbol {
                Image(systemName: symbol).foregroundStyle(theme.secondaryInk).frame(width: 16)
            }
            Text(top.title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Capsule()
                .fill(theme.ink.opacity(0.12))
                .frame(width: 44, height: 5)
                .overlay(alignment: .leading) {
                    Capsule().fill(theme.ink.opacity(0.7)).frame(width: max(top.share > 0 ? 3 : 0, 44 * top.share), height: 5)
                }
                .accessibilityHidden(true)
            VStack(alignment: .trailing, spacing: 1) {
                Text(top.tokens).monospacedDigit()
                Text(top.cost).font(.caption.monospacedDigit()).foregroundStyle(theme.secondaryInk)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// An account's header: its mark and name, the plan, and when its limits were read.
private struct UsageAccountHeader: View {
    let account: RemoteUsageDashboard.Account
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            AgentLogo(provider: account.provider, size: 14)
            Text(account.title)
            if let plan = account.plan {
                Text(plan)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.selection))
                    .overlay(Capsule().strokeBorder(theme.border, lineWidth: theme.borderWidth))
            }
            Spacer()
            if let checked = account.checkedAt {
                Text("Checked \(checked.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                    .font(.caption2)
            }
        }
    }
}

/// Tokens or cost per day, stacked by agent in each agent's color.
private struct UsageDailyChart: View {
    let days: [RemoteUsageDashboard.Day]
    let showsCost: Bool
    let period: Int
    @Environment(\.theme) private var theme

    var body: some View {
        let providers = Array(Set(days.map(\.provider))).sorted()
        Chart(Array(days.enumerated()), id: \.offset) { _, day in
            BarMark(
                x: .value(String(localized: "Date"), day.day, unit: .day),
                y: .value(showsCost ? String(localized: "Cost") : String(localized: "Tokens"), showsCost ? day.cost : day.tokens))
                .foregroundStyle(by: .value(String(localized: "Agent"), AgentLogo.name(day.provider)))
        }
        .chartForegroundStyleScale(domain: providers.map(AgentLogo.name), range: providers.map { theme.agent($0) })
        .chartYAxis {
            AxisMarks { mark in
                AxisGridLine().foregroundStyle(theme.border)
                AxisValueLabel {
                    if let number = mark.as(Double.self) {
                        Text(showsCost ? number.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
                            : number.formatted(.number.notation(.compactName)))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: period > 30 ? 14 : period > 7 ? 7 : 1)) { _ in
                AxisGridLine().foregroundStyle(theme.border.opacity(0.5))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .accessibilityLabel(showsCost ? Text("Estimated cost per day") : Text("Tokens per day"))
    }
}

/// From a Mac too old for the dashboard: each account's limit windows.
private struct LegacyUsageSections: View {
    let usage: [RemoteUsage]
    @Environment(\.theme) private var theme

    var body: some View {
        if usage.isEmpty {
            Text("No agent has reported its usage limits yet.").foregroundStyle(theme.secondaryInk)
        }
        ForEach(usage) { entry in
            Section {
                ForEach(entry.windows) { window in
                    UsageLimitRow(
                        row: RemoteUsageDashboard.Row(
                            title: window.label, value: "\(Int(window.usedPercent.rounded()))%", fill: min(max(window.usedPercent, 0), 100) / 100,
                            level: window.usedPercent >= 95 ? .critical : window.usedPercent >= 70 ? .near : .normal,
                            details: window.resetsAt.map { [String(localized: "Resets \($0.formatted(.relative(presentation: .named)))")] } ?? []),
                        provider: entry.provider)
                }
            } header: {
                HStack(spacing: 6) {
                    AgentLogo(provider: entry.provider, size: 14)
                    // The provider's name once, then the account's when it differs ("Claude Code · Work").
                    Text(entry.accountName.flatMap { $0 == entry.providerName ? nil : "\(entry.providerName) · \($0)" } ?? entry.providerName)
                }
            }
            .themedCards(theme)
        }
    }
}
