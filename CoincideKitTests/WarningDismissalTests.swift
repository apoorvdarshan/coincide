import Foundation
import Testing
@testable import CoincideKit

@MainActor
struct WarningDismissalTests {
    @Test(arguments: ProviderKind.allCases)
    func acknowledgmentSurvivesStoreRecreationAndFutureUsageCycles(provider: ProviderKind) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("warning-memory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        let original = UsageLimitWindow(id: "primary", kind: .session, label: "Session", usedPercent: 92,
            resetsAt: Date().addingTimeInterval(3_600))
        let key = UsageLimits.warningKey(for: original, provider: provider)
        #expect(!store.isWarningDismissed(key))
        store.dismissWarning(key)
        let reopened = AppStore(directory: directory)
        #expect(reopened.isWarningDismissed(key))
        var later = original
        later.usedPercent = 100
        later.continuesOnCredits = true
        later.resetsAt = Date().addingTimeInterval(30 * 86_400)
        later.label = "A localized or renamed session"
        #expect(UsageLimits.warningKey(for: later, provider: provider) == key)
        #expect(reopened.isWarningDismissed(UsageLimits.warningKey(for: later, provider: provider)))
        #expect(!reopened.isWarningDismissed(UsageLimits.warningKey(for: later, provider: provider, account: "another-account")))
        later.id = "weekly"; later.kind = .weekly
        #expect(!reopened.isWarningDismissed(UsageLimits.warningKey(for: later, provider: provider)))
    }

    @Test func warningIdentitySeparatesProvidersAccountsAndArbitraryIDs() {
        let window = UsageLimitWindow(id: "a/b", kind: .session, label: "Session", usedPercent: 100)
        #expect(UsageLimits.warningKey(for: window, provider: .claude) != UsageLimits.warningKey(for: window, provider: .codex))
        #expect(UsageLimits.warningKey(for: window, provider: .codex) == UsageLimits.warningKey(for: window, provider: .codex, account: ProviderAccount.defaultID))
        #expect(UsageLimits.warningKey(for: window, provider: .codex, account: "a/b") != UsageLimits.warningKey(for: window, provider: .codex, account: "a%2Fb"))
    }

    @Test func olderAndUnreadableSettingsKeepTheirOtherPreferences() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize":17}"#.utf8))
        #expect(old.dismissedWarnings.isEmpty)
        let malformed = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize":17,"dismissedWarnings":false}"#.utf8))
        #expect(malformed.dismissedWarnings.isEmpty)
        #expect(malformed.fontSize == 17)
        var saved = old
        saved.dismissedWarnings = ["a", "b"]
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(saved)) == saved)
    }
}
