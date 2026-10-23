import Foundation
import Testing
@testable import CoincideCore

@Test func activityAssertionPolicyCoversEveryPreferencePowerSourceAndWorkload() {
    typealias Policy = ActivityAssertionPolicy
    for preference in Policy.Preference.allCases {
        for power in [Policy.PowerSource.ac, .battery, .unknown] {
            #expect(Policy.desiredLevel(activeConversations: 0, power: power, preference: preference) == .none)
            let expected: Policy.Level = switch preference {
            case .never: .preventAppNap
            case .always: .preventIdleSleep
            case .whilePluggedIn: power == .battery ? .preventAppNap : .preventIdleSleep
            }
            #expect(Policy.desiredLevel(activeConversations: 2, power: power, preference: preference) == expected)
        }
    }
    #expect(Policy.Level.none < .preventAppNap && Policy.Level.preventAppNap < .preventIdleSleep)
}

@Test func activityAssertionDebouncerRaisesImmediatelyAndReleasesAfterTheDelay() {
    var debouncer = ActivityAssertionPolicy.Debouncer()
    let start = ContinuousClock.now
    #expect(debouncer.update(desired: .preventIdleSleep, now: start) == .hold(.preventIdleSleep))
    #expect(debouncer.update(desired: .preventIdleSleep, now: start + .seconds(1)) == .unchanged)
    let release = start + .seconds(2) + ActivityAssertionPolicy.releaseDelay
    #expect(debouncer.update(desired: .none, now: start + .seconds(2)) == .waitUntil(release))
    #expect(debouncer.update(desired: .none, now: start + .seconds(10)) == .waitUntil(release), "A repeated lower level keeps the first deadline.")
    #expect(debouncer.held == .preventIdleSleep)
    // Work resuming before the deadline keeps the assertion without a new begin.
    #expect(debouncer.update(desired: .preventIdleSleep, now: start + .seconds(12)) == .unchanged && debouncer.pendingRelease == nil)
    _ = debouncer.update(desired: .preventAppNap, now: start + .seconds(20))
    #expect(debouncer.update(desired: .preventAppNap, now: start + .seconds(20) + ActivityAssertionPolicy.releaseDelay) == .hold(.preventAppNap))
    #expect(debouncer.releaseNow() == .hold(.none) && debouncer.releaseNow() == .unchanged)
}
