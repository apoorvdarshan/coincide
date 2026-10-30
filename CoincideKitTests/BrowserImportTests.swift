import Foundation
import SQLite3
import Testing
@testable import CoincideKit

/// Every fixture here is generated: fake keys, fake cookies, made-up sites. No real browser profile, Keychain item or
/// cookie is read.
@Suite struct BrowserImportTests {
    static let fakePassword = Data("not-a-real-safe-storage-password".utf8)

    // MARK: Chromium

    @Test func chromiumCookiesDecryptWithTheDerivedKeyOnly() throws {
        let decryptor = ChromiumCookieDecryptor(safeStoragePassword: Self.fakePassword)
        for version in [18, 24] {
            let encrypted = decryptor.encrypt("session-abc", hostKey: ".example.test", schemaVersion: version)
            #expect(encrypted.prefix(3) == Data("v10".utf8))
            #expect(decryptor.decrypt(encrypted, hostKey: ".example.test", schemaVersion: version) == "session-abc")
            let wrong = ChromiumCookieDecryptor(safeStoragePassword: Data("other".utf8))
            #expect(wrong.decrypt(encrypted, hostKey: ".example.test", schemaVersion: version) != "session-abc")
        }
        #expect(decryptor.decrypt(Data("plain".utf8), hostKey: "x", schemaVersion: 24) == nil)
        #expect(ChromiumCookieDecryptor.deriveKey(Self.fakePassword).count == 16)
        #expect(ChromiumCookieDecryptor.deriveKey(Self.fakePassword) == ChromiumCookieDecryptor.deriveKey(Self.fakePassword))
    }

    @Test func chromiumProfileScanReadsCookiesHistoryAndBookmarks() throws {
        let home = try FixtureFolder()
        let profile = home.url.appendingPathComponent("Library/Application Support/Google/Chrome/Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Network"), withIntermediateDirectories: true)
        let decryptor = ChromiumCookieDecryptor(safeStoragePassword: Self.fakePassword)
        let future = BrowserTime.chromiumValue(Date().addingTimeInterval(86_400))
        let past = BrowserTime.chromiumValue(Date().addingTimeInterval(-86_400))
        let cookies = try FixtureDatabase(profile.appendingPathComponent("Network/Cookies"))
        try cookies.run("CREATE TABLE meta(key TEXT, value TEXT)")
        try cookies.run("INSERT INTO meta VALUES('version', '24')")
        try cookies.run(
            "CREATE TABLE cookies(host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER)")
        try cookies.insert("INSERT INTO cookies VALUES(?, ?, '', ?, '/', ?, 1, 1, 1)",
            [.text(".app.example.test"), .text("sid"), .blob(decryptor.encrypt("fixture-secret-1", hostKey: ".app.example.test", schemaVersion: 24)), .integer(future)])
        try cookies.insert("INSERT INTO cookies VALUES(?, ?, ?, x'', '/docs', 0, 0, 0, -1)",
            [.text("docs.other.test"), .text("pref"), .text("dark")])
        try cookies.insert("INSERT INTO cookies VALUES(?, ?, '', ?, '/', ?, 0, 0, 0)",
            [.text("old.example.test"), .text("gone"), .blob(decryptor.encrypt("expired", hostKey: "old.example.test", schemaVersion: 24)), .integer(past)])
        cookies.close()
        let history = try FixtureDatabase(profile.appendingPathComponent("History"))
        try history.run("CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER, hidden INTEGER)")
        try history.insert("INSERT INTO urls(url, title, visit_count, last_visit_time, hidden) VALUES(?, ?, 7, ?, 0)",
            [.text("https://app.example.test/dashboard"), .text("Dashboard"), .integer(future)])
        try history.insert("INSERT INTO urls(url, title, visit_count, last_visit_time, hidden) VALUES(?, 'Local', 1, 1, 0)",
            [.text("file:///etc/hosts")])
        history.close()
        let bookmarks = #"{"roots":{"bookmark_bar":{"type":"folder","name":"Bookmarks bar","children":[{"type":"url","name":"Docs","url":"https://docs.other.test/"},{"type":"folder","name":"Work","children":[{"type":"url","name":"Tracker","url":"https://tracker.example.test/"}]}]},"other":{"type":"folder","name":"Other","children":[{"type":"url","name":"Script","url":"javascript:alert(1)"}]}}}"#
        try Data(bookmarks.utf8).write(to: profile.appendingPathComponent("Bookmarks"))
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Work person"}}}}"#.utf8)
            .write(to: profile.deletingLastPathComponent().appendingPathComponent("Local State"))

        let detected = try #require(BrowserCatalog.detect(home: home.url, appURL: { _ in nil }).first { $0.id == "chrome" })
        #expect(detected.profiles.map(\.name) == ["Work person"])
        var asked: [String] = []
        let data = BrowserImporter.scan(detected, profile: detected.profiles[0], kinds: [.cookies, .history, .bookmarks], home: home.url) {
            asked = $0
            return Self.fakePassword
        }
        #expect(asked == ["Chrome Safe Storage"])
        #expect(data.problems.isEmpty)
        let session = try #require(data.cookies.first { $0.name == "sid" })
        #expect(session.hasValue("fixture-secret-1"))
        #expect(session.isSecure && session.isHTTPOnly && session.sameSite == .lax)
        #expect(session.site == "example.test")
        #expect(data.cookies.first { $0.name == "pref" }?.path == "/docs")
        #expect(data.cookies(forSites: ["example.test"]).map(\.name) == ["sid"])
        #expect(!data.cookies(forSites: nil).contains { $0.name == "gone" })
        #expect(data.history.map(\.url) == ["https://app.example.test/dashboard"])
        #expect(data.history.first?.visitCount == 7)
        #expect(Set(data.bookmarks.map(\.url)) == ["https://docs.other.test/", "https://tracker.example.test/"])
        #expect(data.bookmarks.first { $0.title == "Tracker" }?.folder == "Google Chrome › Bookmarks bar › Work")
        let cookie = try #require(session.httpCookie)
        #expect(cookie.isSecure && cookie.isHTTPOnly && cookie.domain == ".app.example.test")

        // Without the Keychain key, encrypted cookies are reported rather than silently missing.
        let denied = BrowserImporter.scan(detected, profile: detected.profiles[0], kinds: [.cookies], home: home.url) { _ in nil }
        #expect(denied.problems == [BrowserImportProblem(kind: .cookies, reason: .keyUnavailable)])
        #expect(denied.cookies.map(\.name) == ["pref"])
    }

    @Test func snapshotsLeaveTheSourceUntouchedAndCleanUp() throws {
        let folder = try FixtureFolder()
        let file = folder.url.appendingPathComponent("db.sqlite")
        let database = try FixtureDatabase(file)
        try database.run("CREATE TABLE t(v TEXT)")
        try database.run("INSERT INTO t VALUES('x')")
        database.close()
        let before = try Data(contentsOf: file)
        let snapshot = try SQLiteSnapshot(copying: file)
        #expect(try snapshot.rows("SELECT v FROM t").first?["v"]?.string == "x")
        snapshot.close()
        #expect(try Data(contentsOf: file) == before)
        #expect(!FileManager.default.fileExists(atPath: snapshot.folder.path))
        #expect(throws: SQLiteSnapshot.Failure.missing) { try SQLiteSnapshot(copying: folder.url.appendingPathComponent("none")) }
    }

    @Test func cookieValuesNeverAppearInDescriptions() {
        let cookie = ImportedCookie(domain: ".example.test", name: "sid", value: "do-not-print-me", path: "/", expires: nil,
            isSecure: true, isHTTPOnly: true, sameSite: nil)
        var dumped = ""
        dump(cookie, to: &dumped)
        for text in [cookie.description, cookie.debugDescription, String(describing: cookie), String(reflecting: cookie), dumped, "\([cookie])"] {
            #expect(!text.contains("do-not-print-me"))
        }
    }

    // MARK: Firefox

    @Test func firefoxProfilesCookiesHistoryAndBookmarks() throws {
        let home = try FixtureFolder()
        let root = home.url.appendingPathComponent("Library/Application Support/Firefox", isDirectory: true)
        let profile = root.appendingPathComponent("Profiles/abcd.default-release", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try """
            [Install4F96D1932A9F858E]
            Default=Profiles/abcd.default-release

            [Profile0]
            Name=default-release
            IsRelative=1
            Path=Profiles/abcd.default-release

            [Profile1]
            Name=escape
            IsRelative=1
            Path=../../../../outside
            """.write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
        let cookies = try FixtureDatabase(profile.appendingPathComponent("cookies.sqlite"))
        try cookies.run("CREATE TABLE moz_cookies(host TEXT, name TEXT, value TEXT, path TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER, sameSite INTEGER)")
        let expiry = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970)
        try cookies.insert("INSERT INTO moz_cookies VALUES(?, 'token', 'fixture-ff', '/', ?, 1, 0, 2)", [.text(".shop.test"), .integer(expiry)])
        try cookies.insert("INSERT INTO moz_cookies VALUES(?, 'ms', 'fixture-ms', '/', ?, 0, 1, 0)", [.text("a.shop.test"), .integer(expiry * 1000)])
        cookies.close()
        let places = try FixtureDatabase(profile.appendingPathComponent("places.sqlite"))
        try places.run("CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_date INTEGER, hidden INTEGER)")
        try places.run("CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, title TEXT)")
        try places.run("INSERT INTO moz_places VALUES(1, 'https://shop.test/cart', 'Cart', 3, 1700000000000000, 0)")
        try places.run("INSERT INTO moz_places VALUES(2, 'https://news.test/', 'News', 0, 0, 0)")
        try places.run("INSERT INTO moz_bookmarks VALUES(10, 2, NULL, 1, 'toolbar')")
        try places.run("INSERT INTO moz_bookmarks VALUES(11, 1, 2, 10, 'News site')")
        places.close()

        let detected = try #require(BrowserCatalog.detect(home: home.url, appURL: { _ in nil }).first { $0.id == "firefox" })
        #expect(detected.profiles.map(\.name) == ["default-release"])
        let data = BrowserImporter.scan(detected, profile: detected.profiles[0], kinds: [.cookies, .history, .bookmarks], home: home.url) { _ in
            Issue.record("Firefox needs no Keychain key")
            return nil
        }
        #expect(data.problems.isEmpty)
        #expect(data.cookies.first { $0.name == "token" }?.hasValue("fixture-ff") == true)
        #expect(data.cookies.first { $0.name == "token" }?.sameSite == .strict)
        let ms = try #require(data.cookies.first { $0.name == "ms" }?.expires)
        #expect(abs(ms.timeIntervalSince1970 - Double(expiry)) < 2)
        #expect(data.history.map(\.url) == ["https://shop.test/cart"])
        #expect(data.history.first.map { abs($0.lastVisit.timeIntervalSince1970 - 1_700_000_000) < 1 } == true)
        #expect(data.bookmarks.map(\.title) == ["News site"])
        #expect(data.bookmarks.first?.folder == "Firefox › toolbar")
    }

    // MARK: Safari

    @Test func safariBinaryCookiesHistoryAndBookmarksParse() throws {
        let expiry = Date().addingTimeInterval(7200)
        let file = SafariFixture.binaryCookies([
            (".bank.test", "auth", "/", "fixture-safari", 5, expiry),
            ("www.blog.test", "theme", "/", "light", 0, expiry),
        ])
        let cookies = try SafariDataReader.parseBinaryCookies(file)
        #expect(cookies.count == 2)
        let auth = try #require(cookies.first { $0.name == "auth" })
        #expect(auth.hasValue("fixture-safari") && auth.isSecure && auth.isHTTPOnly)
        #expect(abs((auth.expires?.timeIntervalSince(expiry)) ?? 99) < 1)
        #expect(cookies.first { $0.name == "theme" }?.isSecure == false)
        #expect(throws: (any Error).self) { try SafariDataReader.parseBinaryCookies(Data("cook\u{0}\u{0}\u{0}\u{9}".utf8)) }
        #expect(throws: (any Error).self) { try SafariDataReader.parseBinaryCookies(file.prefix(40)) }

        let home = try FixtureFolder()
        let safari = home.url.appendingPathComponent("Library/Safari", isDirectory: true)
        try FileManager.default.createDirectory(at: safari, withIntermediateDirectories: true)
        let history = try FixtureDatabase(safari.appendingPathComponent("History.db"))
        try history.run("CREATE TABLE history_items(id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER)")
        try history.run("CREATE TABLE history_visits(id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT)")
        try history.run("INSERT INTO history_items VALUES(1, 'https://blog.test/post', 4)")
        try history.run("INSERT INTO history_visits VALUES(1, 1, 700000000, 'Old title')")
        try history.run("INSERT INTO history_visits VALUES(2, 1, 750000000, 'Post')")
        history.close()
        let plist: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList", "Title": "",
            "Children": [
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://blog.test/", "URIDictionary": ["title": "Blog"]],
                ]],
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://later.test/", "URIDictionary": ["title": "Later"]],
                ]],
            ],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: safari.appendingPathComponent("Bookmarks.plist"))
        let cookieFolder = home.url.appendingPathComponent("Library/Cookies", isDirectory: true)
        try FileManager.default.createDirectory(at: cookieFolder, withIntermediateDirectories: true)
        try file.write(to: cookieFolder.appendingPathComponent("Cookies.binarycookies"))

        let detected = try #require(BrowserCatalog.detect(home: home.url, appURL: { $0 == "com.apple.Safari" ? home.url : nil })
            .first { $0.id == "safari" })
        #expect(detected.status == .available)
        let data = BrowserImporter.scan(detected, profile: detected.profiles[0], kinds: [.cookies, .history, .bookmarks], home: home.url) { _ in nil }
        #expect(data.problems.isEmpty)
        #expect(data.cookies.count == 2)
        #expect(data.history.first?.title == "Post")
        #expect(data.history.first.map { abs($0.lastVisit.timeIntervalSinceReferenceDate - 750_000_000) < 1 } == true)
        #expect(data.bookmarks.map(\.url) == ["https://blog.test/"])
        #expect(data.bookmarks.first?.folder == "Safari › Favorites")
    }

    // MARK: Detection

    @Test func detectionListsInstalledBrowsersProfilesAndUnsupportedOnes() throws {
        let home = try FixtureFolder()
        let support = home.url.appendingPathComponent("Library/Application Support", isDirectory: true)
        for path in ["BraveSoftware/Brave-Browser/Default", "BraveSoftware/Brave-Browser/Profile 2", "BraveSoftware/Brave-Browser/System Profile"] {
            let folder = support.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: folder.appendingPathComponent("Preferences"))
        }
        // Opera keeps a single profile at the top of its folder.
        let opera = support.appendingPathComponent("com.operasoftware.Opera", isDirectory: true)
        try FileManager.default.createDirectory(at: opera, withIntermediateDirectories: true)
        try Data().write(to: opera.appendingPathComponent("History"))
        let installed: Set<String> = ["com.duckduckgo.macos.browser", "com.kagi.kagimacOS", "company.thebrowser.dia"]
        let detected = BrowserCatalog.detect(home: home.url) { installed.contains($0) ? home.url : nil }
        let byID = Dictionary(uniqueKeysWithValues: detected.map { ($0.id, $0) })
        #expect(byID["brave"]?.profiles.map { $0.folder.lastPathComponent } == ["Default", "Profile 2"])
        #expect(byID["opera"]?.profiles.count == 1)
        #expect(byID["duckduckgo"]?.status == .unsupported(.encryptedStore))
        #expect(byID["orion"]?.status == .unsupported(.unreadableFormat))
        // Installed with no data yet: listed, with nothing to pick.
        #expect(byID["dia"]?.profiles.isEmpty == true)
        #expect(byID["chrome"] == nil && byID["safari"] == nil)
        #expect(!BrowserCatalog.all.contains { $0.name.localizedCaseInsensitiveContains("Tor") })
        #expect(Set(BrowserCatalog.all.map(\.id)).count == BrowserCatalog.all.count)
    }

    @Test func protectedBrowserFolderAsksForFullDiskAccess() throws {
        let home = try FixtureFolder()
        let chrome = home.url.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        try FileManager.default.createDirectory(at: chrome.appendingPathComponent("Default"), withIntermediateDirectories: true)
        // A folder macOS won't list stands in for one under its app-data protection.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: chrome.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chrome.path) }
        let detected = try #require(BrowserCatalog.detect(home: home.url, appURL: { _ in nil }).first { $0.id == "chrome" })
        #expect(detected.status == .needsFullDiskAccess)
        #expect(detected.profiles.isEmpty)
    }

    @Test func firefoxProfilesStayInsideTheBrowsersFolder() {
        let root = URL(fileURLWithPath: "/tmp/ff-root", isDirectory: true)
        let profiles = FirefoxProfileReader.parseProfiles(
            "[Profile0]\nName=a\nIsRelative=1\nPath=../escape\nDefault=1\n[Profile1]\nName=b\nIsRelative=1\nPath=Profiles/b\n", root: root)
        #expect(profiles.map(\.name) == ["b"])
    }
}

@Suite struct WebDomainTests {
    @Test func sitesGroupSubdomainsButNotStrangers() {
        #expect(WebDomain.site(of: "www.example.com") == "example.com")
        #expect(WebDomain.site(of: ".Login.Example.COM.") == "example.com")
        #expect(WebDomain.site(of: "shop.example.co.uk") == "example.co.uk")
        #expect(WebDomain.site(of: "alice.github.io") == "alice.github.io")
        #expect(WebDomain.site(of: "a.b.s3.amazonaws.com") == "b.s3.amazonaws.com")
        #expect(WebDomain.site(of: "github.io") == nil)
        #expect(WebDomain.site(of: "localhost") == nil)
        #expect(WebDomain.site(of: "127.0.0.1") == nil)
        #expect(WebDomain.site(of: "[::1]") == nil)
        #expect(WebDomain.host("a.example.com", isWithin: "example.com"))
        #expect(!WebDomain.host("evil-example.com", isWithin: "example.com"))
        #expect(!WebDomain.host("example.com.evil.test", isWithin: "example.com"))
    }
}

// MARK: Fixtures

/// A scratch folder removed when the value goes away.
final class FixtureFolder {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-browser-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Writes SQLite fixtures.
final class FixtureDatabase {
    enum Value { case text(String), integer(Int64), blob(Data) }
    private var database: OpaquePointer?

    init(_ url: URL) throws {
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    func run(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    func insert(_ sql: String, _ values: [Value]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, transient)
            case .integer(let number): sqlite3_bind_int64(statement, position, number)
            case .blob(let data): _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), transient) }
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }

    func close() {
        sqlite3_close(database)
        database = nil
    }

    deinit { if database != nil { sqlite3_close(database) } }
}

/// Builds `Cookies.binarycookies` files in WebKit's layout.
enum SafariFixture {
    static func binaryCookies(_ cookies: [(domain: String, name: String, path: String, value: String, flags: UInt32, expiry: Date)]) -> Data {
        func le(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
        func be(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
        var records: [[UInt8]] = []
        for cookie in cookies {
            let strings = [cookie.domain, cookie.name, cookie.path, cookie.value].map { Array($0.utf8) + [0] }
            var offsets: [UInt32] = []
            var position: UInt32 = 56
            for string in strings {
                offsets.append(position)
                position += UInt32(string.count)
            }
            var record = le(position) + le(0) + le(cookie.flags) + le(0)
            for offset in offsets { record += le(offset) }
            record += [UInt8](repeating: 0, count: 8)
            record += withUnsafeBytes(of: cookie.expiry.timeIntervalSinceReferenceDate.bitPattern.littleEndian, Array.init)
            record += withUnsafeBytes(of: Date().timeIntervalSinceReferenceDate.bitPattern.littleEndian, Array.init)
            for string in strings { record += string }
            records.append(record)
        }
        var page: [UInt8] = [0, 0, 1, 0] + le(UInt32(records.count))
        var offset = UInt32(8 + records.count * 4 + 4)
        for record in records {
            page += le(offset)
            offset += UInt32(record.count)
        }
        page += [0, 0, 0, 0]
        for record in records { page += record }
        var file: [UInt8] = Array("cook".utf8) + be(1) + be(UInt32(page.count)) + page
        file += [0, 0, 0, 0, 0x07, 0x17, 0x20, 0x05, 0, 0, 0, 0x4b]
        return Data(file)
    }
}
