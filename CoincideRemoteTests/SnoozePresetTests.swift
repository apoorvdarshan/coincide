import Foundation
import Testing

@testable import CoincideRemote

/// The thread menu's Snooze choices (`SnoozePreset.presets`), as the Mac offers them: in an hour, in three, this evening
/// while it's more than an hour away, tomorrow at nine, and next Monday at nine unless that's tomorrow.
struct SnoozePresetTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func presets(at now: Date) -> [(title: String, date: Date)] {
        SnoozePreset.presets(now: now, calendar: calendar).map { ($0.title, $0.date) }
    }

    @Test func aMondayMorningOffersEveryChoice() {
        let now = date(day: 2, hour: 10)  // Monday
        let presets = presets(at: now)
        #expect(presets.map(\.title) == ["In 1 Hour", "In 3 Hours", "This Evening", "Tomorrow", "Next Week"])
        #expect(presets.map(\.date) == [
            date(day: 2, hour: 11), date(day: 2, hour: 13), date(day: 2, hour: 18), date(day: 3, hour: 9), date(day: 9, hour: 9),
        ])
    }

    @Test func thisEveningGoesWithinTheHourBeforeIt() {
        let titles = presets(at: date(day: 2, hour: 17, minute: 30)).map(\.title)
        #expect(titles == ["In 1 Hour", "In 3 Hours", "Tomorrow", "Next Week"])
    }

    @Test func onSundayTomorrowIsAlreadyNextWeek() {
        let presets = presets(at: date(day: 1, hour: 10))  // Sunday
        #expect(presets.map(\.title) == ["In 1 Hour", "In 3 Hours", "This Evening", "Tomorrow"])
        #expect(presets.last?.date == date(day: 2, hour: 9))
    }

    @Test func midweekNextWeekIsTheComingMonday() {
        let presets = presets(at: date(day: 4, hour: 20))  // Wednesday evening
        #expect(presets.map(\.title) == ["In 1 Hour", "In 3 Hours", "Tomorrow", "Next Week"])
        #expect(presets.last?.date == date(day: 9, hour: 9))
    }
}
