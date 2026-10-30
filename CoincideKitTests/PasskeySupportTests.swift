import Foundation
import Testing
@testable import CoincideKit

@Suite struct PasskeySupportTests {
    @Test func availabilityFollowsTheBrowserPasskeyEntitlementOnly() {
        let asked = Recorder()
        let granted = PasskeySupport { key in asked.append(key); return true }
        #expect(granted.isAvailable)
        #expect(asked.keys == ["com.apple.developer.web-browser.public-key-credential"])
        #expect(!PasskeySupport { _ in false }.isAvailable)
        // Another entitlement (say, the iCloud container) doesn't count.
        #expect(!PasskeySupport { $0 == "com.apple.developer.icloud-services" }.isAvailable)
    }

    @Test func theRunningProcessIsReadFromItsOwnSignature() {
        // Test runs are signed ad hoc or with a profile that lacks the managed entitlement.
        #expect(!PasskeySupport.currentProcessHasEntitlement(PasskeySupport.entitlement))
        #expect(!PasskeySupport.currentProcessHasEntitlement("com.apoorvdarshan.coincide.no-such-entitlement"))
        #expect(PasskeySupport.current.isAvailable == PasskeySupport.currentProcessHasEntitlement(PasskeySupport.entitlement))
    }

    @Test func theNoticeShowsOncePerSiteUntilDismissedOrTheTabLeaves() {
        var state = PasskeyNoticeState()
        func change(_ body: (inout PasskeyNoticeState) -> Bool) -> Bool { body(&state) }
        #expect(change { $0.requested(tabID: "tab-1", host: "accounts.google.com") })
        #expect(state.notice == .init(tabID: "tab-1", site: "google.com"))
        // The page asking again, or from another subdomain of the site, changes nothing.
        #expect(!change { $0.requested(tabID: "tab-1", host: "accounts.google.com") })
        #expect(!change { $0.requested(tabID: "tab-1", host: "myaccount.google.com") })
        // Moving within the site keeps it; another site's page clears it, another tab's doesn't.
        #expect(!change { $0.navigated(tabID: "tab-1", host: "www.google.com") })
        #expect(!change { $0.navigated(tabID: "tab-2", host: "chatgpt.com") })
        #expect(change { $0.navigated(tabID: "tab-1", host: "chatgpt.com") })
        #expect(state.notice == nil)

        // Dismissed: not shown again for that site, in any tab; other sites still get it.
        #expect(change { $0.requested(tabID: "tab-2", host: "accounts.google.com") })
        state.dismiss()
        #expect(state.notice == nil && state.dismissedSites == ["google.com"])
        #expect(!change { $0.requested(tabID: "tab-1", host: "accounts.google.com") })
        #expect(change { $0.requested(tabID: "tab-1", host: "github.com") })
        #expect(!change { $0.closed(tabID: "tab-2") })
        #expect(change { $0.closed(tabID: "tab-1") })
        #expect(state.notice == nil)
    }

    /// The opt-in entitlements files: the passkey one asks for exactly the key, and the combined one is the union of
    /// it and the iCloud one, so neither drifts.
    @Test func optInEntitlementsFilesStayInStep() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Coincide")
        func read(_ name: String) throws -> NSDictionary {
            try #require(NSDictionary(contentsOf: folder.appendingPathComponent(name)), "\(name) is missing or not a plist")
        }
        let passkeys = try read("Passkeys.entitlements"), cloudKit = try read("CoincideCloudKit.entitlements")
        #expect(passkeys == [PasskeySupport.entitlement: true] as NSDictionary)
        let union = NSMutableDictionary(dictionary: cloudKit)
        union.addEntries(from: passkeys as! [AnyHashable: Any])
        #expect(try read("CoincideCloudKitPasskeys.entitlements") == union)
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var keys: [String] { lock.withLock { recorded } }
    func append(_ key: String) { lock.withLock { recorded.append(key) } }
}
