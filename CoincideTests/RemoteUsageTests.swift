import CoincideRemoteKit
import Foundation
import Testing

@testable import Coincide
@testable import CoincideKit

/// Settings › Usage on Coincide Remote: the dashboard travels whole, and each limit row reads as the Mac's.
@MainActor
struct RemoteUsageTests {
    @Test func aLimitRowReadsAsTheMacsRow() {
        let window = RemoteStoreAdapter.row(
            UsageRow(
                title: "Weekly", value: "81% used", bar: UsageRow.Bar(fill: 0.81, paceMark: 0.3), level: .near,
                details: ["Resets in 5 days", "Ahead of pace"]))
        #expect(window.title == "Weekly" && window.value == "81% used")
        #expect(window.fill == 0.81 && window.paceMark == 0.3)
        #expect(window.level == .near)
        #expect(window.details == ["Resets in 5 days", "Ahead of pace"])
        // A state such as unlimited credits has no bar.
        let credits = RemoteStoreAdapter.row(UsageRow(title: "Credits", value: "Unlimited", isState: true))
        #expect(credits.isState && credits.fill == nil && credits.level == .normal)
        #expect(RemoteStoreAdapter.row(UsageRow(title: "Extra usage", value: "$60 of $50 used", level: .critical)).level == .critical)
    }

    @Test func theDashboardAndItsQuerySurviveEncoding() throws {
        let query = RemoteUsageQuery(days: 7, provider: "claude", accountID: "work", refresh: true)
        let request = RemoteClientMessage(id: "1", request: .usageDashboard(query))
        #expect(try RemoteProtocol.makeDecoder().decode(RemoteClientMessage.self, from: RemoteProtocol.makeEncoder().encode(request)) == request)
        let dashboard = RemoteUsageDashboard(
            scopeTitle: "Claude Code", periodName: "Last 7 days", days: 7, provider: "claude",
            providers: [.init(id: "claude", title: "Claude Code")], accountChoices: [.init(id: "work", title: "Work")],
            tiles: [.init(title: "Today", tokens: "1.2M", cost: "≈ $3.10", trend: "12% vs yesterday", trendIsUp: true)],
            closestTitle: "Claude Code", closestProvider: "claude",
            closest: .init(title: "Weekly", value: "20% used", fill: 0.2, paceMark: 0.4, details: ["Resets next week"]),
            daily: [.init(day: Date(timeIntervalSince1970: 1_800_000_000), provider: "claude", tokens: 1_200_000, cost: 3.1)],
            topModels: [.init(title: "claude-opus", provider: "claude", share: 0.9, tokens: "1.1M", cost: "$2.90")],
            topProjects: [.init(title: "coincide", share: 1, tokens: "1.2M", cost: "$3.10")],
            activity: [.init(title: "Turns", value: "12")],
            accounts: [
                .init(
                    id: "claude/work", provider: "claude", title: "Claude Code · Work", plan: "Team", checkedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    rows: [.init(title: "Credits", value: "412 left", fill: 0.62)], warning: "Close to the weekly limit", notes: ["Admin key needed"],
                    periodTokens: "1.2M", periodCost: "$3.10", periodSource: "From Claude Code’s logs on this Mac.")
            ], isScanning: false, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let response = RemoteServerMessage.response(id: "1", result: .usageDashboard(dashboard))
        #expect(try RemoteProtocol.makeDecoder().decode(RemoteServerMessage.self, from: RemoteProtocol.makeEncoder().encode(response)) == response)
        // A row level a newer Mac adds reads as unknown.
        let newer = #"{"title":"t","value":"v","isState":false,"level":"overdrawn","details":[]}"#
        #expect(try JSONDecoder().decode(RemoteUsageDashboard.Row.self, from: Data(newer.utf8)).level == .unknown)
    }
}
