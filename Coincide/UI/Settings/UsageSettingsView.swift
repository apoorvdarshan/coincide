import AppKit
import Charts
import CoincideKit
import Observation
import SwiftUI

@Observable
final class UsageDashboardModel {
    private(set) var records: [UsageRecord] = []
    private(set) var limits: [ProviderKind: UsageLimits] = [:]
    private(set) var error: String?
    private(set) var refreshing = false
    @ObservationIgnored private let history: UsageHistory
    @ObservationIgnored private let runner: ThreadRunner
    @ObservationIgnored private let registry: ProviderRegistry
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var limitsObserver: NSObjectProtocol?
    @ObservationIgnored private var storeObserver: ObservationToken?

    init(store: AppStore = .shared, runner: ThreadRunner = .shared, registry: ProviderRegistry = .shared) {
        history = runner.usageHistory
        self.runner = runner
        self.registry = registry
        observer = NotificationCenter.default.addObserver(forName: UsageHistory.didChange, object: history, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.reload() }
        }
        storeObserver = store.observe { [weak self] change in
            if case .providers = change { self?.reload() }
        }
        limitsObserver = NotificationCenter.default.addObserver(forName: ThreadRunner.usageLimitsChangedNotification,
            object: runner, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
        reload()
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let limitsObserver { NotificationCenter.default.removeObserver(limitsObserver) }
    }

    func reload() {
        records = history.records
        error = history.error
        limits = Dictionary(uniqueKeysWithValues: registry.orderedKinds.compactMap { kind in
            runner.usageLimits(for: kind).map { (kind, $0) }
        })
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        await registry.refresh()
        refreshing = false
        reload()
    }
}

struct UsageSettingsView: View {
    @State private var model = UsageDashboardModel()
    @State private var days = 30
    @State private var provider: ProviderKind?

    private var records: [UsageRecord] {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        return model.records.filter { $0.finishedAt >= since && (provider == nil || $0.provider == provider) }
    }

    private var activity: [(day: Date, count: Int)] {
        Dictionary(grouping: records, by: { Calendar.current.startOfDay(for: $0.finishedAt) })
            .map { (day: $0.key, count: $0.value.count) }.sorted { $0.day < $1.day }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsPaneHeader(title: String(localized: "Usage")) {
                    SettingsIconTile(symbol: "chart.bar.fill", color: .green, size: 44)
                } subtitle: {
                    Text("Local activity and provider-reported limits. History starts with this update and keeps the latest 10,000 turns.")
                }
                HStack {
                    Picker("Period", selection: $days) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }.frame(maxWidth: 180)
                    Picker("Provider", selection: $provider) {
                        Text("All Providers").tag(nil as ProviderKind?)
                        ForEach(ProviderKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind as ProviderKind?)
                        }
                    }.frame(maxWidth: 230)
                    Spacer()
                }
                HStack(spacing: 28) {
                    metric(String(localized: "Turns"), records.count.formatted())
                    metric(String(localized: "Active time"), duration(records.reduce(0) { $0 + $1.duration }))
                    metric(String(localized: "Threads"), Set(records.map(\.threadID)).count.formatted())
                }
                if !activity.isEmpty {
                    Chart(activity, id: \.day) { day in
                        BarMark(x: .value(String(localized: "Date"), day.day, unit: .day),
                                y: .value(String(localized: "Turns"), day.count))
                            .foregroundStyle(Color(nsColor: Theme.ink))
                    }.frame(height: 130)
                }
                limitsSection
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent turns").font(.headline)
                    Text("Context and output are the latest token snapshots, not billing totals. Reported cost may cover a whole session; missing values mean the provider did not report them.")
                        .font(.caption).foregroundStyle(.secondary)
                    if records.isEmpty {
                        Text("No recorded activity in this period.").foregroundStyle(.secondary).padding(.vertical, 18)
                    }
                    ForEach(records.suffix(50).reversed()) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(record.provider.displayName).fontWeight(.medium)
                                Text(record.modelID ?? "—").foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Text(record.finishedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 16) {
                                Label(outcome(record.outcome), systemImage: record.outcome == .completed ? "checkmark.circle" : "minus.circle")
                                Text(duration(record.duration))
                            }.font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 16) {
                                Text("Context: \(count(record.usage.inputTokens))")
                                Text("Output: \(count(record.usage.outputTokens))")
                                Text("Reported cost: \(record.usage.costUSD?.formatted(.currency(code: "USD")) ?? "—")")
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: Theme.raisedFill), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if let error = model.error {
                    Text("Usage history could not be saved: \(error)").foregroundStyle(.red)
                }
            }.padding(20)
        }.onAppear { model.reload() }
    }

    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Account limits").font(.headline)
                Spacer()
                Button("Check again") { Task { await model.refresh() } }.disabled(model.refreshing)
                if model.refreshing { ProgressView().controlSize(.small) }
            }
            let kinds = ProviderKind.allCases.filter { (provider == nil || $0 == provider) && model.limits[$0] != nil }
            if kinds.isEmpty { Text("No account limits reported.").foregroundStyle(.secondary) }
            ForEach(kinds, id: \.self) { kind in
                if let limits = model.limits[kind] {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(kind.displayName).fontWeight(.medium)
                            Spacer()
                            Text(limits.checkedAt, format: .dateTime.month(.abbreviated).day().hour().minute()).foregroundStyle(.secondary)
                        }
                        ForEach(limits.windows) { window in
                            HStack {
                                Text(window.label).frame(width: 100, alignment: .leading)
                                ProgressView(value: window.usedPercent, total: 100)
                                Text(window.usedPercent / 100, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit().frame(width: 44, alignment: .trailing)
                            }
                            if let reset = window.resetsAt {
                                Text("Resets: \(reset.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(12).background(Color(nsColor: Theme.raisedFill), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond))
    }
    private func count(_ value: Int?) -> String { value?.formatted() ?? "—" }
    private func outcome(_ value: UsageRecord.Outcome) -> String {
        switch value {
        case .completed: String(localized: "Completed")
        case .interrupted: String(localized: "Interrupted")
        case .failed: String(localized: "Failed")
        }
    }
}
