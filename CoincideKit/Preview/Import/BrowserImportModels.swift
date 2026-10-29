import Foundation

/// A cookie read from another browser. Its value is a credential, so it never appears in descriptions, mirrors or
/// logs; only `httpCookie` hands it on, to WebKit's cookie store.
public nonisolated struct ImportedCookie: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public enum SameSite: String, Sendable, Hashable { case unrestricted, lax, strict }

    /// The cookie's domain as the browser stored it: a leading dot for one shared with subdomains.
    public var domain: String
    public var name: String
    fileprivate(set) var value: String
    public var path: String
    /// Nil for a session cookie.
    public var expires: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    public var sameSite: SameSite?

    public init(domain: String, name: String, value: String, path: String, expires: Date?, isSecure: Bool, isHTTPOnly: Bool,
        sameSite: SameSite?)
    {
        self.domain = domain
        self.name = name
        self.value = value
        self.path = path.isEmpty ? "/" : path
        self.expires = expires
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.sameSite = sameSite
    }

    /// The site it belongs to, for the import's site list and filter.
    public var site: String { WebDomain.siteOrHost(domain) }

    public func isExpired(at date: Date = Date()) -> Bool { expires.map { $0 <= date } ?? false }

    /// The cookie for `WKHTTPCookieStore`. Nil when Foundation rejects it (an empty name or domain).
    public var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain, .path: path, .name: name, .value: value,
        ]
        if let expires { properties[.expires] = expires } else { properties[.discard] = "TRUE" }
        if isSecure { properties[.secure] = "TRUE" }
        if isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        switch sameSite {
        case .lax: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
        case .strict: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
        case .unrestricted, nil: break
        }
        return HTTPCookie(properties: properties)
    }

    /// Whether the value is the one given, without exposing it. For tests.
    public func hasValue(_ candidate: String) -> Bool { value == candidate }

    public var description: String { "ImportedCookie(\(name) for \(domain), value redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["domain": domain, "name": name, "value": "<redacted>"]) }
}

/// What a scan of one browser profile found. Cookies are kept in memory only until imported or discarded.
public nonisolated struct BrowserImportData: Sendable {
    public var cookies: [ImportedCookie] = []
    public var history: [BrowserHistoryItem] = []
    public var bookmarks: [BrowserBookmark] = []
    /// Kinds that couldn't be read, with why, such as cookies whose key the user didn't allow.
    public var problems: [BrowserImportProblem] = []

    public init() {}

    /// Sites with cookies, most cookies first, for the import's site picker.
    public var sites: [(site: String, cookies: Int)] {
        Dictionary(grouping: cookies, by: \.site).map { ($0.key, $0.value.count) }
            .sorted { $0.cookies != $1.cookies ? $0.cookies > $1.cookies : $0.site < $1.site }
    }

    /// The cookies to import: unexpired, and only for `sites` when given.
    public func cookies(forSites sites: Set<String>?, at date: Date = Date()) -> [ImportedCookie] {
        cookies.filter { !$0.isExpired(at: date) && (sites?.contains($0.site) ?? true) }
    }
}

public nonisolated enum BrowserImportKind: String, Sendable, Hashable, CaseIterable, Codable {
    case cookies, history, bookmarks
}

public nonisolated struct BrowserImportProblem: Sendable, Hashable, Error {
    public enum Reason: Sendable, Hashable {
        /// macOS kept Coincide from the file; Full Disk Access is needed (Safari).
        case needsFullDiskAccess
        /// The user denied the Keychain prompt, or the browser's key wasn't found.
        case keyUnavailable
        /// Cookies were there but none could be decrypted with the key.
        case undecryptable
        case unreadable
    }

    public var kind: BrowserImportKind
    public var reason: Reason

    public init(kind: BrowserImportKind, reason: Reason) {
        self.kind = kind
        self.reason = reason
    }
}

/// What the import added, for its summary.
public nonisolated struct BrowserImportSummary: Sendable, Equatable {
    public var cookies = 0
    public var sites = 0
    public var history = 0
    public var bookmarks = 0

    public init(cookies: Int = 0, sites: Int = 0, history: Int = 0, bookmarks: Int = 0) {
        self.cookies = cookies
        self.sites = sites
        self.history = history
        self.bookmarks = bookmarks
    }
}

/// Times as browsers store them.
nonisolated enum BrowserTime {
    /// Chromium: microseconds since 1601-01-01 UTC.
    static func chromium(_ value: Int64) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value) / 1_000_000 - 11_644_473_600)
    }

    static func chromiumValue(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000) }

    /// Firefox cookie expiry: seconds since 1970, or milliseconds in newer versions.
    static func firefoxExpiry(_ value: Int64) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? Double(value) / 1000 : Double(value))
    }

    /// Firefox history: microseconds since 1970.
    static func firefoxVisit(_ value: Int64) -> Date? {
        value > 0 ? Date(timeIntervalSince1970: Double(value) / 1_000_000) : nil
    }

    /// Safari: seconds since 2001-01-01 UTC.
    static func safari(_ value: Double) -> Date? { value > 0 ? Date(timeIntervalSinceReferenceDate: value) : nil }
}
