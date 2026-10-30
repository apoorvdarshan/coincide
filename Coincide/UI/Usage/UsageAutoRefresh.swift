import AppKit
import CoincideKit
import SwiftUI

/// Reads usage on the user's schedule (Settings › Usage › Refresh, `AppSettings.usageRefresh`): once when Coincide
/// starts, then whenever the last read is older than the chosen interval, so the menu bar item and Settings › Usage
/// stay current without being opened. Each part of `UsageInsights` skips itself while fresh, so the frequent tick costs
/// nothing between reads.
@MainActor
final class UsageAutoRefresh {
    static let shared = UsageAutoRefresh()

    private var timer: Timer?
    private var isReading = false
    /// How often the schedule is looked at; reads happen only when one is due.
    private let tick: TimeInterval = 15

    func start(insights: UsageInsights = .shared, store: AppStore = .shared, runner: ThreadRunner = .shared) {
        guard timer == nil else { return }
        insights.refreshIfStale()
        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readIfDue(insights: insights, store: store, runner: runner) }
        }
    }

    private func readIfDue(insights: UsageInsights, store: AppStore, runner: ThreadRunner) {
        guard !isReading else { return }
        let isBusy = NSApp.isActive || !runner.runningThreadIDs.isEmpty
        guard let interval = store.settings.usageRefresh.interval(isBusy: isBusy) else { return }
        isReading = true
        Task {
            // Just short of the interval, so a read due between two ticks isn't put off by a whole tick.
            await insights.refreshAutomatically(every: max(interval - tick, tick))
            isReading = false
        }
    }
}

/// The schedule's choices, in Settings › Usage and the menu bar item's list.
struct UsageRefreshPicker: View {
    var showsDescription = true
    @State private var interval = AppStore.shared.settings.usageRefresh

    var body: some View {
        ThemedPicker(selection: $interval, options: UsageRefreshInterval.allCases.map { .init($0, Self.name($0)) }) {
            Text("Refresh")
            if showsDescription {
                Text("How often plan limits and token counts are read again, for this page and the menu bar. Automatically reads every 5 minutes while an agent works or Coincide is in front, and every 15 minutes otherwise.")
            }
        }
        .onChange(of: interval) {
            guard AppStore.shared.settings.usageRefresh != interval else { return }
            AppStore.shared.updateSettings { $0.usageRefresh = interval }
        }
    }

    static func name(_ interval: UsageRefreshInterval) -> String {
        switch interval {
        case .automatic: String(localized: "Automatically")
        case .everyMinute: String(localized: "Every Minute")
        case .every5Minutes: String(localized: "Every 5 Minutes")
        case .every15Minutes: String(localized: "Every 15 Minutes")
        case .every30Minutes: String(localized: "Every 30 Minutes")
        case .everyHour: String(localized: "Every Hour")
        case .manual: String(localized: "Only When Opened")
        }
    }
}
