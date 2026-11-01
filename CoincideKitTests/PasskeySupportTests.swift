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

    @Test func theDefaultBrowserIsNamedAndMatchedToTheImporter() throws {
        func browser(_ path: String, _ id: String?, _ name: String?) -> PasskeyHandoff.Browser? {
            PasskeyHandoff.browser(appURL: URL(fileURLWithPath: path), bundleID: id, name: name, ownBundleID: "com.apoorvdarshan.coincide")
        }
        let safari = try #require(browser("/Applications/Safari.app", "com.apple.Safari", "Safari"))
        #expect(safari.name == "Safari" && safari.importable?.id == "safari")
        #expect(safari.appURL.path == "/Applications/Safari.app")
        // Finder showing every extension leaves ".app" in the display name.
        let chrome = try #require(browser("/Applications/Google Chrome.app", "com.google.Chrome", "Google Chrome.app"))
        #expect(chrome.name == "Google Chrome" && chrome.importable?.id == "chrome")
        // The app's own name, even where the importer files it under the family it shares a folder with.
        let developer = try #require(browser("/Applications/Firefox Developer Edition.app", "org.mozilla.firefoxdeveloperedition",
            "Firefox Developer Edition"))
        #expect(developer.name == "Firefox Developer Edition" && developer.importable?.id == "firefox")
        // Named, but not importable: a browser the importer can't read, and one it doesn't know.
        let duck = try #require(browser("/Applications/DuckDuckGo.app", "com.duckduckgo.macos.browser", "DuckDuckGo"))
        #expect(duck.name == "DuckDuckGo" && duck.importable == nil)
        let unknown = try #require(browser("/Applications/Lynx Deluxe.app", "example.lynx", nil))
        #expect(unknown.name == "Lynx Deluxe" && unknown.importable == nil)
        // Without a display name, the catalog's name.
        #expect(browser("/Applications/Arc.app", "company.thebrowser.Browser", " ")?.name == "Arc")
        // No default browser, or Coincide itself: nothing to name, so the notice says "your browser".
        #expect(PasskeyHandoff.browser(appURL: nil, bundleID: "com.apple.Safari", name: "Safari", ownBundleID: nil) == nil)
        #expect(browser("/Applications/Coincide.app", "com.apoorvdarshan.coincide", "Coincide") == nil)
    }

    @Test func theNoticeGoesFromOpeningTheBrowserToImportingItsSignIn() {
        let safari = PasskeyHandoff.Browser(name: "Safari", appURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            importable: BrowserCatalog.all.first { $0.id == "safari" })
        var state = PasskeyNoticeState()
        func change(_ body: (inout PasskeyNoticeState) -> Bool) -> Bool { body(&state) }
        var asked = 0
        #expect(change { $0.requested(tabID: "tab-1", host: "github.com", browser: { () -> PasskeyHandoff.Browser? in asked += 1; return safari }()) })
        #expect(state.notice == .init(tabID: "tab-1", site: "github.com", browser: safari, stage: .unavailable))
        // Nothing to import before the page was opened elsewhere.
        #expect(!change { $0.importStarted() } && !change { $0.offerImport() })
        #expect(change { $0.openedElsewhere() })
        #expect(state.notice?.stage == .awaitingImport)
        #expect(!change { $0.openedElsewhere() })
        // The page asking again (it reloads) keeps the stage and doesn't look the browser up again.
        #expect(!change { $0.requested(tabID: "tab-1", host: "github.com", browser: { () -> PasskeyHandoff.Browser? in asked += 1; return nil }()) })
        #expect(asked == 1 && state.notice?.browser == safari)

        #expect(change { $0.importStarted() })
        #expect(!change { $0.importStarted() } && !change { $0.openedElsewhere() } && !change { $0.offerImport() })
        // Another tab's or site's import doesn't land here.
        #expect(!change { $0.importFinished(tabID: "tab-2", site: "github.com", failure: nil) })
        #expect(!change { $0.importFinished(tabID: "tab-1", site: "gitlab.com", failure: nil) })
        #expect(change { $0.importFinished(tabID: "tab-1", site: "github.com", failure: .nothingFound) })
        #expect(state.notice?.stage == .failed(.nothingFound))
        #expect(!change { $0.importFinished(tabID: "tab-1", site: "github.com", failure: nil) })
        #expect(change { $0.importStarted() })
        #expect(change { $0.importFinished(tabID: "tab-1", site: "github.com", failure: .problem(.needsFullDiskAccess)) })
        #expect(change { $0.offerImport() })
        #expect(state.notice?.stage == .awaitingImport)
        #expect(change { $0.importStarted() })
        #expect(change { $0.importFinished(tabID: "tab-1", site: "github.com", failure: nil) })
        #expect(state.notice?.stage == .imported)

        // An import still running when the tab moves to another site finds no notice to update.
        #expect(change { $0.navigated(tabID: "tab-1", host: "gitlab.com") })
        #expect(change { $0.requested(tabID: "tab-1", host: "gitlab.com", browser: safari) })
        #expect(change { $0.openedElsewhere() } && change { $0.importStarted() })
        #expect(change { $0.navigated(tabID: "tab-1", host: "example.com") })
        #expect(!change { $0.importFinished(tabID: "tab-1", site: "gitlab.com", failure: nil) })
        #expect(state.notice == nil)
    }

    /// The import reads the site's cookies only, from the profile links open in. Fixtures are generated: a fake
    /// Keychain password and made-up sites, never a real browser profile.
    @Test func theSignInIsReadForTheSiteFromTheProfileLinksOpenIn() throws {
        let home = try FixtureFolder()
        let root = home.url.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        let decryptor = ChromiumCookieDecryptor(safeStoragePassword: BrowserImportTests.fakePassword)
        let future = BrowserTime.chromiumValue(Date().addingTimeInterval(86_400))
        for (folder, cookies) in [("Default", [(".example.test", "old-account")]),
            ("Profile 1", [(".app.example.test", "sid"), ("other.test", "elsewhere")])] {
            let profile = root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: profile.appendingPathComponent("Network"), withIntermediateDirectories: true)
            let database = try FixtureDatabase(profile.appendingPathComponent("Network/Cookies"))
            try database.run("CREATE TABLE meta(key TEXT, value TEXT)")
            try database.run("INSERT INTO meta VALUES('version', '24')")
            try database.run(
                "CREATE TABLE cookies(host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER)")
            for (host, name) in cookies {
                try database.insert("INSERT INTO cookies VALUES(?, ?, '', ?, '/', ?, 1, 1, 1)",
                    [.text(host), .text(name), .blob(decryptor.encrypt("fixture-\(name)", hostKey: host, schemaVersion: 24)), .integer(future)])
            }
            database.close()
        }
        let localState = root.appendingPathComponent("Local State")
        try Data(#"{"profile":{"last_used":"Profile 1","info_cache":{"Default":{"name":"Old"},"Profile 1":{"name":"Work"}}}}"#.utf8)
            .write(to: localState)
        let chrome = try #require(BrowserCatalog.all.first { $0.id == "chrome" })
        let detected = try #require(BrowserCatalog.detect(chrome, home: home.url, appURL: { _ in nil }))
        #expect(detected.profiles.count == 2)
        #expect(BrowserCatalog.preferredProfile(of: detected, home: home.url)?.name == "Work")

        var asked: [[String]] = []
        let found = PasskeyHandoff.readSignIn(site: "example.test", from: detected, home: home.url) {
            asked.append($0)
            return BrowserImportTests.fakePassword
        }
        guard case .found(let cookies) = found else { Issue.record("Expected cookies, got \(found)"); return }
        #expect(cookies.map(\.name) == ["sid"] && cookies.first?.hasValue("fixture-sid") == true)
        #expect(asked == [["Chrome Safe Storage"]])
        #expect(PasskeyHandoff.readSignIn(site: "nothing.test", from: detected, home: home.url) { _ in BrowserImportTests.fakePassword }
            == .nothingFound)
        // The Keychain prompt refused: said so, rather than importing a signed-out copy.
        #expect(PasskeyHandoff.readSignIn(site: "example.test", from: detected, home: home.url) { _ in nil } == .problem(.keyUnavailable))

        // Without a last used profile, the first one (Default).
        try Data(#"{"profile":{"info_cache":{}}}"#.utf8).write(to: localState)
        #expect(BrowserCatalog.preferredProfile(of: detected, home: home.url)?.folder.lastPathComponent == "Default")
        let fallback = PasskeyHandoff.readSignIn(site: "example.test", from: detected, home: home.url) { _ in BrowserImportTests.fakePassword }
        if case .found(let cookies) = fallback { #expect(cookies.map(\.name) == ["old-account"]) } else { Issue.record("\(fallback)") }

        // Browsers that can't be read now say why without reading anything.
        var protected = detected
        protected.status = .needsFullDiskAccess
        #expect(PasskeyHandoff.readSignIn(site: "example.test", from: protected, home: home.url) { _ in
            Issue.record("The Keychain was asked for")
            return nil
        } == .problem(.needsFullDiskAccess))
        protected.status = .unsupported(.encryptedStore)
        #expect(PasskeyHandoff.readSignIn(site: "example.test", from: protected, home: home.url) { _ in nil } == .problem(.unreadable))
        #expect(PasskeyHandoff.readSignIn(site: "example.test", from: nil, home: home.url) { _ in nil } == .problem(.unreadable))
        // Neither app nor data: not detected.
        let edge = try #require(BrowserCatalog.all.first { $0.id == "edge" })
        #expect(BrowserCatalog.detect(edge, home: home.url, appURL: { _ in nil }) == nil)
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
