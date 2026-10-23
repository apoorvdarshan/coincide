import Foundation
import Testing
@testable import CoincideCore

@Test func autoPullOnlyFastForwardsACleanDefaultBranchThatIsOnlyBehind() {
    func observe(_ edit: (inout GitSyncObservation) -> Void = { _ in }) -> GitSyncObservation {
        var value = GitSyncObservation(branch: "main", hasUpstream: true, ahead: 0, behind: 2, isClean: true); edit(&value); return value
    }
    #expect(GitSyncPolicy.pullDecision(observe(), defaultBranch: "main", enabled: true) == .pull)
    #expect(GitSyncPolicy.pullDecision(observe(), defaultBranch: "main", enabled: false) == .skip(.disabled))
    #expect(GitSyncPolicy.pullDecision(observe { $0.branch = "feature" }, defaultBranch: "main", enabled: true) == .skip(.notDefaultBranch))
    #expect(GitSyncPolicy.pullDecision(observe(), defaultBranch: nil, enabled: true) == .skip(.notDefaultBranch))
    #expect(GitSyncPolicy.pullDecision(observe { $0.isClean = false }, defaultBranch: "main", enabled: true) == .skip(.dirty))
    #expect(GitSyncPolicy.pullDecision(observe { $0.ahead = 1 }, defaultBranch: "main", enabled: true) == .skip(.ahead))
    #expect(GitSyncPolicy.pullDecision(observe { $0.behind = 0 }, defaultBranch: "main", enabled: true) == .skip(.upToDate))
    #expect(GitSyncPolicy.pullDecision(observe { $0.hasUpstream = false }, defaultBranch: "main", enabled: true) == .skip(.noUpstream))
    #expect(GitSyncPolicy.pullDecision(observe { $0.ahead = nil }, defaultBranch: "main", enabled: true) == .skip(.unknownTracking))
    #expect(GitSyncPolicy.pullDecision(observe { $0.isDetached = true; $0.branch = nil }, defaultBranch: "main", enabled: true) == .skip(.detached))
}

@Test func syncFailuresBackOffExponentiallyToFifteenMinutesButNeverBelowTheInterval() {
    #expect(GitSyncPolicy.nextDelay(interval: .seconds(30), consecutiveFailures: 0) == .seconds(30))
    #expect(GitSyncPolicy.nextDelay(interval: .seconds(30), consecutiveFailures: 1) == .seconds(30))
    #expect(GitSyncPolicy.nextDelay(interval: .seconds(30), consecutiveFailures: 2) == .seconds(60))
    #expect(GitSyncPolicy.nextDelay(interval: .seconds(30), consecutiveFailures: 4) == .seconds(240))
    #expect(GitSyncPolicy.nextDelay(interval: .seconds(30), consecutiveFailures: 50) == .seconds(900))
    #expect(GitSyncPolicy.nextDelay(interval: .seconds(900), consecutiveFailures: 1) == .seconds(900))
    #expect(GitAutoPullOverride.inherit.resolve(default: true) && !GitAutoPullOverride.disabled.resolve(default: true) && GitAutoPullOverride.enabled.resolve(default: false))
    #expect(GitAutomaticFetchInterval.off.duration == nil && GitAutomaticFetchInterval.seconds30.duration == .seconds(30))
}
