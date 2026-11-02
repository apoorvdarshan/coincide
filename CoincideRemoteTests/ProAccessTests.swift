import CoincideRemoteKit
import Foundation
import Testing

@testable import CoincideRemote

/// What unlocks Coincide Pro (`ProAccess`, kept from RevenueCat's last answer) and which requests need it
/// (`RemoteRequest.needsPro`, checked for every request in `RemoteClient.request`).
struct ProAccessTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func access(active: Bool = true, plan: ProPlan.Kind? = .annual, expiresIn days: Double?) -> ProAccess {
        ProAccess(
            isActive: active, productID: plan?.productID, expiresAt: days.map { now.addingTimeInterval($0 * day) },
            willRenew: true, isTrial: false, checkedAt: now)
    }

    @Test func lifetimeGrantsWithNoEndDate() {
        #expect(access(plan: .lifetime, expiresIn: nil).grants(at: now.addingTimeInterval(3_650 * day)))
    }

    @Test func anInactiveEntitlementNeverGrants() {
        #expect(!access(active: false, expiresIn: nil).grants(at: now))
        #expect(!access(active: false, expiresIn: 30).grants(at: now))
    }

    /// A subscription keeps working for three days past its end while no newer answer arrives (the phone was offline),
    /// and not after.
    @Test func aSubscriptionGrantsUntilItsEndPlusTheOfflineGrace() {
        let subscription = access(expiresIn: 30)
        #expect(subscription.grants(at: now))
        #expect(subscription.grants(at: now.addingTimeInterval(30 * day)))
        #expect(subscription.grants(at: now.addingTimeInterval(32.9 * day)))
        #expect(!subscription.grants(at: now.addingTimeInterval(33 * day)))
        #expect(!subscription.grants(at: now.addingTimeInterval(60 * day)))
    }

    @Test func thePlanComesFromTheProductID() {
        #expect(access(plan: .annual, expiresIn: 30).plan == .annual)
        #expect(access(plan: .monthly, expiresIn: 30).plan == .monthly)
        #expect(access(plan: .lifetime, expiresIn: nil).plan == .lifetime)
        #expect(access(plan: nil, expiresIn: nil).plan == nil)
    }

    /// Reading stays free: the workspace, threads, diffs, git state, pull requests, settings and media.
    @Test func readingNeedsNoPro() {
        let thread = UUID()
        let reads: [RemoteRequest] = [
            .ping, .workspace(includeArchived: false), .openThread(threadID: thread, limit: 50), .markSeen(threadID: thread),
            .diff(threadID: thread, turnID: nil), .gitState(threadID: thread), .settings, .usageLimits, .scheduledTasks,
            .media(threadID: thread, itemID: UUID(), index: 0, full: true),
        ]
        for request in reads { #expect(!request.needsPro, "\(request)") }
    }

    /// Anything the Mac would act on shows the paywall without Pro: prompts, stopping, new threads, git, bots, settings.
    @Test func actingNeedsPro() {
        let thread = UUID()
        let actions: [RemoteRequest] = [
            .stop(threadID: thread), .newThread(projectID: nil), .gitAction(RemoteGitActionRequest(threadID: thread, action: .push)),
            .deleteBot(botID: UUID(), deletesConversations: false), .settingsAction(key: "general.remote"),
            .runScript(threadID: thread, scriptID: UUID()),
        ]
        for request in actions { #expect(request.needsPro, "\(request)") }
    }
}
