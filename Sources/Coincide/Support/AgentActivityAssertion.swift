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
            guard Self.systemEffectsAllowed else { return NSObject() }
            let reason = String(localized: "Coincide agents are running")
            let options: ProcessInfo.ActivityOptions = level == .preventIdleSleep ? [.userInitiated, .idleSystemSleepDisabled] : [.userInitiatedAllowingIdleSystemSleep]
            return ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
        }, end: { token in if Self.systemEffectsAllowed { ProcessInfo.processInfo.endActivity(token) } })
        private static var systemEffectsAllowed: Bool {
            Bundle.main.bundleIdentifier == "com.apoorvdarshan.coincide" && Bundle.main.bundleURL.pathExtension == "app"
                && ProcessInfo.processInfo.environment["COINCIDE_UI_TESTING"] != "1"
        }
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
    private var pendingTasks: [UUID: Task<Void, Never>] = [:]
    private var tracking = false
    private var stopped = false
    private(set) var level: ActivityAssertionPolicy.Level = .none

    init(activeConversations: @escaping @MainActor () -> Int, power: @escaping @MainActor () -> ActivityAssertionPolicy.PowerSource = AgentActivityAssertion.currentPowerSource,
         defaults: UserDefaults = .standard, activities: Activities = .system, releaseDelay: Duration = ActivityAssertionPolicy.releaseDelay) {
        self.activeConversations = activeConversations; self.power = power; self.defaults = defaults
        self.activities = activities; self.releaseDelay = releaseDelay
    }

    var preference: ActivityAssertionPolicy.Preference {
        ActivityAssertionPolicy.Preference(rawValue: defaults.string(forKey: Self.preference) ?? "") ?? ActivityAssertionPolicy.defaultPreference
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
        } else { retire(powerPolling); powerPolling = nil }
    }

    private func apply(_ decision: ActivityAssertionPolicy.Debouncer.Decision) {
        switch decision {
        case .unchanged: break
        case .hold(let next):
            retire(pendingRelease); pendingRelease = nil
            guard next != level else { return }
            if let token { activities.end(token); self.token = nil }
            if next != .none { token = activities.begin(next) }
            level = next
        case .waitUntil(let instant):
            retire(pendingRelease)
            pendingRelease = Task { [weak self] in
                try? await Task.sleep(until: instant, clock: .continuous)
                guard !Task.isCancelled else { return }
                self?.update()
            }
        }
    }

    func shutdown() {
        stopped = true
        retire(pendingRelease); pendingRelease = nil; retire(powerPolling); powerPolling = nil
        _ = debouncer.releaseNow()
        if let token { activities.end(token); self.token = nil }
        level = .none
    }
    private func retire(_ task: Task<Void, Never>?) {
        guard let task else { return }
        task.cancel()
        let id = UUID()
        pendingTasks[id] = Task { [weak self] in await task.value; self?.pendingTasks[id] = nil }
    }
    func drain() async {
        while !pendingTasks.isEmpty { for task in Array(pendingTasks.values) { await task.value }; await Task.yield() }
    }

    static func currentPowerSource() -> ActivityAssertionPolicy.PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return .unknown }
        if type == kIOPMACPowerKey { return .ac }
        if type == kIOPMBatteryPowerKey { return .battery }
        return .unknown
    }
}
