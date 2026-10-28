import AppKit
import CoincideKit

/// T3 Code's snooze: a thread leaves the list until a chosen time and then comes back on its own, at the top as if it
/// had just been updated. A snoozed thread whose agent needs the user (an approval or a question) or is working stays
/// in view.
@MainActor
final class ThreadSnooze {
    static let shared = ThreadSnooze()

    struct Preset {
        var title: String
        /// When it wakes, such as "9:00 AM" or "Mon 9:00 AM".
        var detail: String
        var date: Date
    }

    private let store: AppStore
    private var token: ObservationToken?
    private var timer: Timer?
    private var isScheduling = false

    init(store: AppStore = .shared) {
        self.store = store
    }

    isolated deinit {
        timer?.invalidate()
    }

    /// Wakes threads whose time has passed and keeps a timer for the next one.
    func start() {
        guard token == nil else { return }
        token = store.observe { [weak self] change in
            switch change {
            case .threadList, .thread: self?.schedule()
            default: break
            }
        }
        schedule()
    }

    func snooze(_ threadID: UUID, until date: Date) {
        store.updateThread(threadID) { $0.snoozedUntil = date }
    }

    func unsnooze(_ threadID: UUID) {
        store.updateThread(threadID) { $0.snoozedUntil = nil }
    }

    /// Whether the list leaves the thread out now.
    static func isHidden(_ thread: ThreadSummary, now: Date = Date()) -> Bool {
        guard let until = thread.snoozedUntil, until > now else { return false }
        let needsUser = ThreadActivity.shared.pendingApprovalCount(thread.id) > 0
            || ThreadActivity.shared.pendingQuestionCount(thread.id) > 0
            || ThreadRunner.shared.isRunning(thread.id)
        return !needsUser
    }

    /// T3 Code's choices: in an hour, in three hours, this evening, tomorrow morning and next Monday morning.
    static func presets(now: Date = Date(), calendar: Calendar = .current) -> [Preset] {
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        let hour: TimeInterval = 3_600
        var presets = [
            Preset(title: String(localized: "In 1 Hour"), detail: now.addingTimeInterval(hour).formatted(time), date: now.addingTimeInterval(hour)),
            Preset(
                title: String(localized: "In 3 Hours"), detail: now.addingTimeInterval(3 * hour).formatted(time),
                date: now.addingTimeInterval(3 * hour)),
        ]
        func at(_ hourOfDay: Int, daysAhead: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: daysAhead, to: now) ?? now
            return calendar.date(bySettingHour: hourOfDay, minute: 0, second: 0, of: day) ?? day
        }
        let evening = at(18, daysAhead: 0)
        if evening.timeIntervalSince(now) > hour {
            presets.append(Preset(title: String(localized: "This Evening"), detail: evening.formatted(time), date: evening))
        }
        let tomorrow = at(9, daysAhead: 1)
        presets.append(Preset(title: String(localized: "Tomorrow"), detail: tomorrow.formatted(time), date: tomorrow))
        let weekday = calendar.component(.weekday, from: now)
        let daysToMonday = (2 - weekday + 7) % 7 == 0 ? 7 : (2 - weekday + 7) % 7
        let monday = at(9, daysAhead: daysToMonday)
        if monday != tomorrow {
            let detail = monday.formatted(.dateTime.weekday(.abbreviated)) + " " + monday.formatted(time)
            presets.append(Preset(title: String(localized: "Next Week"), detail: detail, date: monday))
        }
        return presets
    }

    private func schedule() {
        // Store observers run synchronously; waking a batch must not recursively process the same batch.
        guard !isScheduling else { return }
        isScheduling = true
        defer { isScheduling = false }
        timer?.invalidate()
        timer = nil
        let now = Date()
        let due = store.threadSummaries.values.filter { ($0.snoozedUntil ?? .distantFuture) <= now }
        for thread in due { store.updateThread(thread.id, touch: true) { $0.snoozedUntil = nil } }
        guard let next = store.threadSummaries.values.compactMap(\.snoozedUntil).min() else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
