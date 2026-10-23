import CoincideCore
import Foundation
import IOKit.ps
import Observation

/// Holds a ProcessInfo activity while conversations run: App Nap is always prevented,
/// and idle system sleep follows the "Keep Mac awake" preference. Releasing waits 30
/// seconds so a queue moving to its next turn keeps the same assertion.
@MainActor
final class AgentActivityAssertion {
    static let preference = "keepAwakeWhileAgentsRun"
    struct Activities {
        var begin: @MainActor (ActivityAssertionPolicy.Level) -> any NSObjectProtocol
        var end: @MainActor (any NSObjectProtocol) -> Void
        static let system = Activities(begin: { level in
            let reason = String(localized: "Coincide agents are running")
            let options: ProcessInfo.ActivityOptions = level == .preventIdleSleep ? [.userInitiated, .idleSystemSleepDisabled] : [.userInitiatedAllowingIdleSystemSleep]
            return ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
        }, end: { ProcessInfo.processInfo.endActivity($0) })
    }

    private let activeConversations: @MainActor () -> Int
    private let power: @MainActor () -> ActivityAssertionPolicy.PowerSource
    private let defaults: UserDefaults
    private let activities: Activities
    private let releaseDelay: Duration
    private var debouncer = ActivityAssertionPolicy.Debouncer()
    private var token: (any NSObjectProtocol)?
    private var pendingRelease: Task<Void, Never>?
    private var powerPolling: Task<Void, Never>?
    private var tracking = false
    private var stopped = false
    private(set) var level: ActivityAssertionPolicy.Level = .none

    init(activeConversations: @escaping @MainActor () -> Int, power: @escaping @MainActor () -> ActivityAssertionPolicy.PowerSource = AgentActivityAssertion.currentPowerSource,
         defaults: UserDefaults = .standard, activities: Activities = .system, releaseDelay: Duration = ActivityAssertionPolicy.releaseDelay) {
        self.activeConversations = activeConversations; self.power = power; self.defaults = defaults
        self.activities = activities; self.releaseDelay = releaseDelay
    }

    var preference: ActivityAssertionPolicy.Preference {
        ActivityAssertionPolicy.Preference(rawValue: defaults.string(forKey: Self.preference) ?? "") ?? .whilePluggedIn
    }

    /// Re-evaluates whenever observed workspace state read by `activeConversations` changes.
    func start() {
        guard !tracking, !stopped else { return }
        tracking = true; track()
    }

    private func track() {
        guard !stopped else { return }
        let count = withObservationTracking { activeConversations() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        evaluate(count: count)
    }

    func update() { evaluate(count: activeConversations()) }

    private func evaluate(count: Int) {
        guard !stopped else { return }
        let desired = ActivityAssertionPolicy.desiredLevel(activeConversations: count, power: power(), preference: preference)
        apply(debouncer.update(desired: desired, now: .now, delay: releaseDelay))
        // Plugging in or unplugging changes the level only for running work; poll while it runs.
        if count > 0, preference == .whilePluggedIn {
            if powerPolling == nil {
                powerPolling = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(30))
                        guard !Task.isCancelled else { return }
                        self?.update()
                    }
                }
            }
        } else { powerPolling?.cancel(); powerPolling = nil }
    }

    private func apply(_ decision: ActivityAssertionPolicy.Debouncer.Decision) {
        switch decision {
        case .unchanged: break
        case .hold(let next):
            pendingRelease?.cancel(); pendingRelease = nil
            guard next != level else { return }
            if let token { activities.end(token); self.token = nil }
            if next != .none { token = activities.begin(next) }
            level = next
        case .waitUntil(let instant):
            pendingRelease?.cancel()
            pendingRelease = Task { [weak self] in
                try? await Task.sleep(until: instant, clock: .continuous)
                guard !Task.isCancelled else { return }
                self?.update()
            }
        }
    }

    func shutdown() {
        stopped = true
        pendingRelease?.cancel(); pendingRelease = nil; powerPolling?.cancel(); powerPolling = nil
        _ = debouncer.releaseNow()
        if let token { activities.end(token); self.token = nil }
        level = .none
    }

    static func currentPowerSource() -> ActivityAssertionPolicy.PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return .unknown }
        if type == kIOPMACPowerKey { return .ac }
        if type == kIOPMBatteryPowerKey { return .battery }
        return .unknown
    }
}
