import Foundation

/// How often Coincide reads usage again on its own, for Settings › Usage, the menu bar item and the limit warnings:
/// the plan limits and the agents' logs. Usage is always read at launch, when a usage view opens (if stale) and with
/// Refresh; running agents report their limits as they work in any case.
public enum UsageRefreshInterval: String, Codable, CaseIterable, Hashable, Sendable {
    /// Every 5 minutes while an agent works or Coincide is in front, every 15 minutes otherwise.
    case automatic
    case everyMinute
    case every5Minutes
    case every15Minutes
    case every30Minutes
    case everyHour
    /// Only at launch, when a usage view opens and with Refresh.
    case manual

    /// Seconds between reads, or nil when usage is not read on a schedule. `isBusy` is whether an agent works or
    /// Coincide is in front, which only `automatic` looks at.
    public nonisolated func interval(isBusy: Bool) -> TimeInterval? {
        switch self {
        case .automatic: isBusy ? 5 * 60 : 15 * 60
        case .everyMinute: 60
        case .every5Minutes: 5 * 60
        case .every15Minutes: 15 * 60
        case .every30Minutes: 30 * 60
        case .everyHour: 60 * 60
        case .manual: nil
        }
    }
}
