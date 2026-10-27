import Foundation

/// Short time labels shared by the sidebar, toolbar and command palette.
enum Formatting {
    private static let compact: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.year, .month, .weekOfMonth, .day, .hour, .minute]
        return formatter
    }()

    /// "now", "5m", "3h", "2d", "1w": how long ago, as T3's sidebar shows it.
    static func compactAge(of date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= 60 else { return String(localized: "now", comment: "Age of a thread updated less than a minute ago") }
        return compact.string(from: elapsed) ?? ""
    }

    /// "0:42", "12:05", "1:02:09": how long a turn has been running.
    static func elapsed(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let duration = Duration.seconds(seconds)
        return seconds >= 3600
            ? duration.formatted(.time(pattern: .hourMinuteSecond))
            : duration.formatted(.time(pattern: .minuteSecond))
    }

    /// A path with the home folder shown as "~".
    static func abbreviatedPath(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}
